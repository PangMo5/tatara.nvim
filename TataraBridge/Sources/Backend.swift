// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraGitHub
import TataraKit
import TataraPersistence
import TataraSystem

public typealias RPCValue = AnalysisValue

extension RPCValue {

  // MARK: Public

  public static func encode(_ value: some Encodable) throws -> Self {
    try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
  }

  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }

  // MARK: Internal

  func required(_ key: String) throws -> String {
    guard let value = self[key]?.string, !value.isEmpty else { throw TataraError(
      .invalidResponse,
      detail: "Missing parameter: " + key,
    ) }
    return value
  }

}

// MARK: - Backend

/// One account/repository and immutable PR snapshot per editor connection.
public actor Backend {

  // MARK: Lifecycle

  public init(reviewStore: ReviewSessionStore? = nil) {
    self.reviewStore = reviewStore
  }

  // MARK: Public

  public func call(_ method: String, _ params: RPCValue, progress: @Sendable (String) async -> Void = { _ in
  }) async throws -> RPCValue {
    switch method {
    case "initialize":
      guard repository == nil else { throw TataraError(.configuration, detail: "This backend is already initialized.") }
      demo = params["demo"]?.boolean == true
      let adapter = GitHubAdapter()
      let repo: RepositoryID
      let client: ForgeClient
      let cache: CacheClient
      if demo {
        let fixture = try await DemoRepository.create()
        demoRoot = fixture.root
        source = fixture.root.path
        repo = fixture.repository
        client = fixture.client
        cache = .disabled
        account = "demo"
      } else {
        if let slug = params["repository"]?.string {
          repo = try RepositoryID(slug, host: params["host"]?.string ?? "github.com")
        } else {
          repo = try await adapter.detectRepository(host: params["host"]?.string)
        }
        account = try await adapter.accountIdentifier(host: repo.host)
        cache = try await PersistentCache.bootstrapDatabase().client.scoped(to: "github:\(repo.host):\(account)")
        let local = try await LocalGitReader.discover(repository: repo)
        client = GitHubAdapter(cache: cache, localGit: local).client
        source = params["source"]?.string ?? FileManager.default.currentDirectoryPath
      }
      if reviewStore == nil {
        reviewStore = try await ReviewSessionStore.open(at: demoRoot?.appendingPathComponent("state/reviews.sqlite"))
      }
      repository = repo
      forge = client
      diff = Difftastic(forge: client, cache: cache).client
      return try .encode(["protocol": "1", "repository": repo.description, "version": TataraVersion.current])

    case "pulls":
      let (repo, client) = try connection()
      let page = params["page"]?.integer ?? 1
      guard (1...100).contains(page) else { throw TataraError(.invalidResponse) }
      let kind = ItemKind(rawValue: params["kind"]?.string ?? "pullRequest") ?? .pullRequest
      if let query = params["query"]?.string, !query.isEmpty {
        return try await .encode(client.search(repo, kind, query, page))
      }
      return try await .encode(client.list(repo, kind, page))

    case "filters":
      let (repo, client) = try connection()
      let kind = ItemKind(rawValue: params["kind"]?.string ?? "pullRequest") ?? .pullRequest
      let store = try await filterStore()
      async let saved = store.load(repo)
      async let labels = client.labels(repo)
      return try await .object([
        "presets": .encode(FilterPreset.defaults(for: kind) + saved),
        "labels": .encode(labels),
      ])

    case "filter.save":
      let (repo, _) = try connection()
      let preset = try params["preset"]?.decode(FilterPreset.self)
      guard
        let preset,
        !preset.isBuiltIn,
        preset.name.utf8.count <= 256,
        preset.query.utf8.count <= 4096,
        !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw TataraError(.invalidResponse) }
      try await filterStore().save(repo, preset)
      return .bool(true)

    case "filter.delete":
      let (repo, _) = try connection()
      let id = try params.required("id")
      guard !id.hasPrefix("builtin:") else { throw TataraError(.configuration) }
      try await filterStore().delete(repo, id)
      return .bool(true)

    case "filter.label":
      return .string(LabelQuery.toggling(try params.required("label"), in: params["query"]?.string ?? ""))

    case "inspect":
      let (repo, client) = try connection()
      guard let number = params["number"]?.integer, number > 0 else { throw TataraError(.invalidResponse) }
      let kind = ItemKind(rawValue: params["kind"]?.string ?? "pullRequest") ?? .pullRequest
      let item = ForgeItem(
        id: .init(repository: repo, number: number),
        kind: kind,
        title: "",
        author: "",
        url: URL(string: "https://\(repo.host)/\(repo.slug)/\(kind == .issue ? "issues" : "pull")/\(number)")!,
      )
      let loaded = try await client.detail(item)
      try Task.checkCancellation()
      guard loaded.item.id == item.id, loaded.item.kind == kind else { throw TataraError(.invalidResponse) }
      return try serialize(loaded)

    case "open":
      let (repo, client) = try connection()
      generation += 1
      let epoch = generation
      selectionPending = true
      defer {
        if generation == epoch {
          selectionPending = false
        }
      }
      await progress("Loading pull request")
      let item: ForgeItem
      let kind = ItemKind(rawValue: params["kind"]?.string ?? "pullRequest") ?? .pullRequest
      if let number = params["number"]?.integer {
        guard number > 0 else { throw TataraError(.invalidResponse) }
        item = .init(
          id: .init(repository: repo, number: number),
          kind: kind,
          title: "",
          author: "",
          url: URL(string: "https://\(repo.host)/\(repo.slug)/\(kind == .issue ? "issues" : "pull")/\(number)")!,
        )
      } else if demo {
        guard let first = try await client.list(repo, .pullRequest, 1).items.first else { throw TataraError(.unavailable) }
        item = first
      } else {
        item = try await GitHubAdapter().currentPullRequest(repo)
      }
      let loaded = try await client.detail(item)
      try Task.checkCancellation()
      guard generation == epoch else { throw CancellationError() }
      guard loaded.item.kind == .issue || loaded.revision != nil else { throw TataraError(
        .incompleteResponse,
        detail: "The pull request has no immutable revision.",
      ) }
      guard loaded.item.id == item.id else { throw TataraError(
        .invalidResponse,
        detail: "The forge returned another pull request.",
      ) }
      let restored = try await savedReviews().load(ReviewSessionIdentity(account: account, detail: loaded))
      guard generation == epoch else { throw CancellationError() }
      searchPreparation?.cancel()
      searchPreparation = nil
      searchDocuments = nil
      detail = loaded
      materializedRoots = [:]
      sessionState = restored
      previews = [:]
      guard case .object(var value) = try serialize(loaded) else { throw TataraError(.invalidResponse) }
      value["drafts"] = try serializeDraft()
      value["reviewState"] = try .encode(sessionState)
      value["hunks"] = try .encode(ReviewHunk.all(in: loaded.files))
      return .object(value)

    case "refresh":
      let (repo, client) = try connection()
      guard let current = detail else { throw TataraError(.unavailable) }
      try await client.invalidate(repo)
      let updated = try await client.detail(current.item)
      guard detail?.item.id == current.item.id, detail?.revision == current.revision else { throw CancellationError() }
      let restored = try await savedReviews().load(ReviewSessionIdentity(account: account, detail: updated))
      guard detail?.item.id == current.item.id, detail?.revision == current.revision else { throw CancellationError() }
      generation += 1
      detail = updated
      sessionState = restored
      searchPreparation?.cancel()
      searchPreparation = nil
      searchDocuments = nil
      previews = [:]
      guard case .object(var refreshed) = try serialize(updated) else { throw TataraError(.invalidResponse) }
      refreshed["drafts"] = try serializeDraft()
      refreshed["reviewState"] = try .encode(sessionState)
      refreshed["hunks"] = try .encode(ReviewHunk.all(in: updated.files))
      return .object(refreshed)

    case "file":
      let (_, client) = try connection()
      let current = try owned(params)
      let epoch = generation
      let path = try params.required("path")
      guard let file = current.file(at: path), let revision = current.revision, let diff else { throw TataraError(
        .invalidResponse,
        detail: "Unknown changed file.",
      ) }
      await progress("Preparing immutable files")
      async let rendered = diff.render(.init(
        repository: current.item.id.repository,
        revision: revision,
        file: file,
      ))
      async let old: Data = file.status == "added"
        ? Data()
        : client.content(current.item.id.repository, revision.mergeBase, file.previousPath ?? path)
      async let new: Data = file.status == "removed" ? Data() : client.content(current.item.id.repository, revision.head, path)
      let (before, after, structural) = try await (old, new, rendered)
      guard generation == epoch else { throw CancellationError() }
      let location = try structural.firstChange()
      let profile = AnalysisServerProfile(id: "neovim", requiresBuildSettings: false)
      let configuration = AnalysisConfiguration(repositoryDirectory: source)
      var local = RPCValue.null
      var baseWorkspace = RPCValue.null
      // Worktree materialization never starts an LSP server or generates build settings.
      if params["checkout"]?.boolean != false, structural.status != "binary" {
        let context = AnalysisContext(item: current.item.id, revision: revision, path: path, side: .right, line: 1, column: 0)
        let workspace = try await materialize(
          context: context,
          configuration: configuration,
          profile: profile,
          scope: "github:\(current.item.id.repository.host):\(account)",
          cacheDirectory: demoRoot?.appendingPathComponent("state"),
          configureBuildSettings: false,
        )
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        if file.status != "removed" {
          _ = try await workspace.text(path: path)
        }
        materializedRoots[workspace.directory] = revision.head
        let headDirectory = try await workspace.canonicalDirectory()
        local = .object([
          "root": .string(headDirectory),
          "source": .string(source ?? ""),
          "path": .string(headDirectory + "/" + path),
        ])
        if file.status != "added" {
          let beforeContext = AnalysisContext(
            item: current.item.id,
            revision: revision,
            path: path,
            side: .left,
            line: 1,
            column: 0,
            sourcePath: file.previousPath,
          )
          let base = try await materialize(
            context: beforeContext,
            configuration: configuration,
            profile: profile,
            scope: "github:\(current.item.id.repository.host):\(account)",
            cacheDirectory: demoRoot?.appendingPathComponent("state"),
            configureBuildSettings: false,
          )
          _ = try await base.text(path: file.previousPath ?? path)
          materializedRoots[base.directory] = revision.mergeBase
          let baseDirectory = try await base.canonicalDirectory()
          baseWorkspace = .object([
            "root": .string(baseDirectory),
            "path": .string(baseDirectory + "/" + (file.previousPath ?? path)),
          ])
        }
      }
      guard generation == epoch else { throw CancellationError() }
      try await validateMaterializedSources()
      guard generation == epoch else { throw CancellationError() }
      return .object([
        "path": .string(path),
        "previousPath": file.previousPath.map(RPCValue.string) ?? .null,
        "head": .string(revision.head),
        "mergeBase": .string(revision.mergeBase),
        "before": structural.status == "binary" ? .null : try Self.text(before),
        "after": structural.status == "binary" ? .null : try Self.text(after),
        "diff": try .encode(structural),
        "initial": try .encode(location),
        "workspace": local,
        "baseWorkspace": baseWorkspace,
        "status": .string(file.status),
        "binary": .bool(structural.status == "binary"),
      ])

    case "search.files":
      let current = try owned(params)
      return try await .encode(FilePathSearch.ranked(
        try searchFiles(params, current).map(\.path),
        query: params["query"]?.string ?? "",
      ))

    case "search.preview":
      let current = try owned(params)
      let (_, client) = try connection()
      let value = try await ContentSearchService.fileFinder(forge: client).preview(current, params.required("path"))
      _ = try owned(params)
      let start = max(0, min(value.lines.count, (params["line"]?.integer ?? 1) - 21))
      return .object([
        "lines": .array(value.lines.dropFirst(start).prefix(300).map(RPCValue.string)),
        "startLine": .number(Double(start + 1)),
      ])

    case "search.content":
      let (_, client) = try connection()
      let current = try owned(params)
      await progress("Finding…")
      let search = ContentSearchService.client(forge: client)
      let epoch = generation
      let files = try searchFiles(params, current)
      let scope = files.map(\.path)
      if searchScope != scope {
        searchScope = scope
        searchEpoch += 1
        searchPreparation?.cancel()
        searchPreparation = nil
        searchDocuments = nil
      }
      let queryEpoch = searchEpoch
      if searchDocuments == nil {
        if searchPreparation == nil {
          let scoped = ItemDetail(
            item: current.item,
            revision: current.revision,
            files: files,
            comments: current.comments,
            metadata: current.metadata,
          )
          searchPreparation = Task { try await search.prepare(scoped) }
        }
        guard let preparation = searchPreparation else { throw TataraError(.unavailable) }
        let documents: [FileContentDocument]
        do { documents = try await preparation.value }
        catch {
          if searchEpoch == queryEpoch {
            searchPreparation = nil
          }
          throw error
        }
        guard generation == epoch, searchEpoch == queryEpoch else { throw CancellationError() }
        searchDocuments = documents
        searchPreparation = nil
      }
      guard let documents = searchDocuments else { throw TataraError(.unavailable) }
      guard let mode = ContentSearchMode(rawValue: params["mode"]?.string ?? "plain") else { throw TataraError(.invalidResponse) }
      let hits = try await search.search(documents, params["query"]?.string ?? "", mode)
      _ = try owned(params)
      guard generation == epoch, searchEpoch == queryEpoch else { throw CancellationError() }
      return try .encode(hits)

    case "draft.add":
      let current = try owned(params)
      let comment = try params["comment"].map { try $0.decode(InlineComment.self) }
      guard let comment else { throw TataraError(.invalidResponse) }
      try validate(comment, current)
      try await validateMaterializedSources()
      _ = try owned(params)
      try await change(current, .add(.init(comment: comment)))
      previews = [:]
      return try serializeDraft()

    case "draft.list":
      let current = try owned(params)
      try await reloadState(current)
      return try serializeDraft()

    case "draft.remove":
      let current = try owned(params)
      try await change(current, .remove(try params.required("id"), expectedBody: params["expectedBody"]?.string))
      previews = [:]
      return try serializeDraft()

    case "draft.update":
      let current = try owned(params)
      guard let value = params["comment"] else { throw TataraError(.invalidResponse) }
      let comment = try value.decode(InlineComment.self)
      try validate(comment, current)
      try await change(current, .update(try params.required("id"), comment, expectedBody: params["expectedBody"]?.string))
      previews = [:]
      return try serializeDraft()

    case "review.sessions":
      let current = try owned(params)
      return try await .encode(savedReviews().list(ReviewSessionIdentity(account: account, detail: current)))

    case "review.forget":
      let current = try owned(params)
      guard case .number(let stamp)? = params["updatedAt"] else { throw TataraError(.invalidResponse) }
      try await savedReviews().remove(
        ReviewSessionIdentity(account: account, detail: current),
        id: try params.required("id"),
        expectedUpdatedAt: stamp,
      )
      try await reloadState(current)
      return try .encode(sessionState)

    case "review.state":
      let current = try owned(params)
      try await reloadState(current)
      return try .encode(sessionState)

    case "review.mark":
      let current = try owned(params)
      guard let reviewed = params["reviewed"]?.boolean else { throw TataraError(.invalidResponse) }
      if let hunk = params["hunk"]?.string {
        guard ReviewHunk.all(in: current.files).contains(where: { $0.id == hunk }) else { throw TataraError(.invalidLine) }
        try await change(current, .markHunk(hunk, reviewed))
      } else {
        let path = try params.required("path")
        guard current.file(at: path) != nil else { throw TataraError(.invalidResponse) }
        try await change(current, .markFile(path, reviewed))
      }
      return try .encode(sessionState)

    case "review.summary":
      let current = try owned(params)
      guard let event = ReviewEvent(rawValue: params["event"]?.string ?? "COMMENT") else { throw TataraError(.invalidResponse) }
      try await change(current, .summary(params["body"]?.string ?? "", event))
      return try .encode(sessionState)

    case "review.export":
      let current = try owned(params)
      try await reloadState(current)
      let identity = ReviewSessionIdentity(account: account, detail: current)
      if params["format"]?.string == "json" {
        return .object(["schema": .number(1), "identity": try .encode(identity), "review": try .encode(sessionState)])
      }
      guard params["format"]?.string == nil || params["format"]?.string == "markdown" else { throw TataraError(.invalidResponse) }
      return .string(ReviewExport.markdown(identity: identity, state: sessionState))

    case "review.preview":
      let current = try owned(params)
      guard let event = ReviewEvent(rawValue: params["event"]?.string ?? "COMMENT") else { throw TataraError(.invalidResponse) }
      guard current.item.kind == .pullRequest || event == .comment else { throw TataraError(.invalidResponse) }
      try await reloadState(current)
      let single = params["single"]?.boolean == true
      let body = params["body"]?.string ?? ""
      guard !single || (event == .comment && body.isEmpty) else { throw TataraError(.invalidResponse) }
      guard body.utf8.count <= 65536 else { throw TataraError(.invalidResponse, detail: "Review body exceeds 64 KiB.") }
      let fileComment = try params["fileComment"].map { try $0.decode(ReviewFileComment.self) }
      let comments: [InlineComment]
      if let fileComment {
        guard
          single,
          params["comment"] == nil,
          event == .comment,
          current.item.kind == .pullRequest,
          current.file(at: fileComment.path) != nil,
          fileComment.body.utf8.count <= 65536,
          !fileComment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw TataraError(.invalidResponse) }
        comments = []
      } else if single {
        guard let value = params["comment"] else { throw TataraError(.invalidResponse) }
        let comment = try value.decode(InlineComment.self)
        try validate(comment, current)
        comments = [comment]
      } else {
        comments = draft.map(\.comment)
        for comment in comments { try validate(comment, current) }
      }
      guard
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !comments
          .isEmpty || fileComment != nil || event == .approve
      else { throw TataraError(.emptyReview) }
      let submission = ReviewSubmission(
        item: current.item,
        expectedHead: current.revision?.head,
        event: event,
        body: single
          ? ""
          : body,
        comments: comments,
        expectedMergeBase: current.revision?.mergeBase,
        singleComment: single,
        fileComment: fileComment,
      )
      let value = RPCValue.object([
        "number": .number(Double(current.item.id.number)),
        "event": .string(event.rawValue),
        "body": .string(submission.body),
        "comments": try .encode(comments),
        "head": .string(current.revision?.head ?? ""),
        "single": .bool(single),
        "fileComment": try fileComment.map(RPCValue.encode) ?? .null,
      ])
      return try store(.init(
        generation: generation,
        review: submission,
        mutation: nil,
        value: value,
        drafts: single ? [] : draft,
      ))

    case "comment.context":
      let current = try owned(params)
      let (_, client) = try connection()
      guard let comment = current.comment(for: try params.required("key")) else { throw TataraError(.invalidResponse) }
      let context = try await client.commentContext(current.item, comment)
      _ = try owned(params)
      var value = try RPCValue.encode(context)
      if case .object(var fields) = value {
        fields["actions"] = .array(CommentOperation.allCases.filter { context.allows($0) }.map { .string($0.rawValue) })
        value = .object(fields)
      }
      return value

    case "comment.preview":
      let current = try owned(params)
      let (_, client) = try connection()
      guard
        let key = params["key"]?.string,
        let comment = current.comment(for: key),
        let operation = CommentOperation(rawValue: params["operation"]?.string ?? "")
      else { throw TataraError(.invalidResponse) }
      let context = try await client.commentContext(current.item, comment)
      _ = try owned(params)
      guard context.allows(operation)
      else { throw TataraError(.unavailable, detail: "GitHub does not allow this comment action.") }
      if let expected = params["expectedBody"]?.string, expected != context.comment.body {
        throw TataraError(
          .revisionChanged,
          detail: "The comment changed while it was being edited. Open it again before previewing a mutation.",
        )
      }
      if let expected = params["expectedUpdatedAt"]?.string, expected != context.comment.updatedAt {
        throw TataraError(.revisionChanged, detail: "The comment version changed. Open it again before previewing a mutation.")
      }
      let mutation = CommentMutation(
        item: current.item,
        expectedHead: current.revision?.head,
        context: context,
        operation: operation,
        body: params["body"]?.string ?? "",
        reaction: ReactionContent(rawValue: params["reaction"]?.string ?? "THUMBS_UP") ?? .thumbsUp,
      )
      let value = RPCValue.object([
        "number": .number(Double(current.item.id.number)),
        "operation": .string(operation.rawValue),
        "body": .string(mutation.body),
        "comment": try .encode(context.comment),
        "head": .string(current.revision?.head ?? ""),
        "reaction": operation == .react ? .string(mutation.reaction.rawValue) : .null,
        "removesReaction": .bool(context.reactions.contains { $0.content == mutation.reaction && $0.viewerHasReacted }),
      ])
      return try store(.init(generation: generation, review: nil, mutation: mutation, value: value))

    case "write.confirm":
      let current = try owned(params)
      let id = try params.required("preview")
      guard let preview = previews.removeValue(forKey: id), preview.generation == generation else { throw TataraError(
        .revisionChanged,
        detail: "The write preview expired or was already consumed.",
      ) }
      let (repo, client) = try connection()
      try await validateMaterializedSources()
      if !demo {
        guard try await GitHubAdapter().accountIdentifier(host: repo.host) == account else { throw TataraError(
          .authentication,
          detail: "The active gh account changed after the preview.",
        ) }
      }
      guard preview.generation == generation else { throw TataraError(.revisionChanged) }
      if let review = preview.review {
        if !review.singleComment {
          try await reloadState(current)
          guard preview.drafts.allSatisfy({ sessionState.drafts.contains($0) }) else {
            throw TataraError(
              .revisionChanged,
              detail: "The previewed drafts changed in another editor. Preview the review again.",
            )
          }
        }
        try await client.submit(review)
        if !review.singleComment {
          try await change(current, .submitted(preview.drafts, review.body))
        }
      }
      if let mutation = preview.mutation {
        try await client.mutateComment(mutation)
      }
      previews = [:]
      return .object(["submitted": .bool(true)])

    default: throw TataraError(.invalidResponse, detail: "Unknown backend method: " + method)
    }
  }

  public func close() async {
    let search = searchPreparation
    searchPreparation = nil
    search?.cancel()
    _ = try? await search?.value
    let tasks = workspaceTasks.values.map { $0.1 }
    workspaceTasks = [:]
    for task in tasks { task.cancel() }
    for task in tasks { _ = try? await task.value }
    filters = nil
    if let demoRoot {
      try? FileManager.default.removeItem(at: demoRoot)
    }
  }

  // MARK: Private

  private struct Preview: Sendable {
    let generation: Int
    let review: ReviewSubmission?
    let mutation: CommentMutation?
    let value: RPCValue
    var drafts = [ReviewDraft]()
  }

  private var repository: RepositoryID?
  private var forge: ForgeClient?
  private var diff: DiffClient?
  private var account = ""
  private var detail: ItemDetail?
  private var generation = 0
  private var selectionPending = false
  private var sessionState = ReviewSessionState()
  private var reviewStore: ReviewSessionStore?
  private var filters: FilterPresetClient?
  private var searchEpoch = 0
  private var searchScope: [String]?
  private var searchDocuments: [FileContentDocument]?
  private var searchPreparation: Task<[FileContentDocument], any Error>?
  private var previews = [String: Preview]()
  private var source: String?
  private var demoRoot: URL?
  private var demo = false
  private var materializedRoots = [URL: String]()
  private var workspaceTasks = [String: (UUID, Task<AnalysisWorkspace, any Error>)]()

  private var draft: [ReviewDraft] {
    sessionState.drafts
  }

  private static func text(_ data: Data) throws -> RPCValue {
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw TataraError(
      .unavailable,
      detail: "Binary files cannot be opened as source buffers.",
    ) }
    return .string(text)
  }

  private func materialize(
    context: AnalysisContext,
    configuration: AnalysisConfiguration,
    profile: AnalysisServerProfile,
    scope: String,
    cacheDirectory: URL?,
    configureBuildSettings: Bool,
  ) async throws -> AnalysisWorkspace {
    let key = context.commit
    let task: Task<AnalysisWorkspace, any Error>
    let token: UUID
    if let pending = workspaceTasks[key] {
      token = pending.0
      task = pending.1
    } else {
      guard workspaceTasks.count < 8 else { throw TataraError(.unavailable, detail: "The session worktree limit is reached.") }
      token = UUID()
      task = Task {
        try await AnalysisWorkspace.prepare(
          context: context,
          configuration: configuration,
          profile: profile,
          scope: scope,
          cacheDirectory: cacheDirectory,
          configureBuildSettings: configureBuildSettings,
        )
      }
      workspaceTasks[key] = (token, task)
    }
    let result: AnalysisWorkspace
    do { result = try await task.value }
    catch {
      if workspaceTasks[key]?.0 == token {
        workspaceTasks[key] = nil
      }
      throw error
    }
    try Task.checkCancellation()
    return result
  }

  private func serialize(_ detail: ItemDetail) throws -> RPCValue {
    guard case .object(var fields) = try RPCValue.encode(detail) else { throw TataraError(.invalidResponse) }
    fields["comments"] = .array(try detail.comments.map { comment in
      guard case .object(var object) = try RPCValue.encode(comment) else { throw TataraError(.invalidResponse) }
      object["key"] = .string(comment.key)
      return .object(object)
    })
    return .object(fields)
  }

  private func serializeDraft() throws -> RPCValue {
    .array(try draft.map { entry in
      guard case .object(var fields) = try RPCValue.encode(entry.comment) else { throw TataraError(.invalidResponse) }
      fields["id"] = .string(entry.id)
      return .object(fields)
    })
  }

  private func searchFiles(_ params: RPCValue, _ current: ItemDetail) throws -> [ChangedFile] {
    guard let scope = params["paths"] else { return current.files }
    guard let values = scope.array, values.count <= current.files.count else { throw TataraError(.invalidResponse) }
    let paths = try values.map { value in
      guard let path = value.string, current.file(at: path) != nil else { throw TataraError(.invalidResponse) }
      return path
    }
    let selected = Set(paths)
    guard selected.count == paths.count else { throw TataraError(.invalidResponse) }
    return current.files.filter { selected.contains($0.path) }
  }

  private func savedReviews() throws -> ReviewSessionStore {
    guard let reviewStore else { throw TataraError(.configuration) }
    return reviewStore
  }

  private func reloadState(_ current: ItemDetail) async throws {
    let epoch = generation
    let state = try await savedReviews().load(ReviewSessionIdentity(account: account, detail: current))
    guard
      epoch == generation,
      detail?.item.id == current.item.id,
      detail?.revision == current.revision
    else { throw CancellationError() }
    sessionState = state
  }

  private func change(_ current: ItemDetail, _ change: ReviewSessionChange) async throws {
    let epoch = generation
    let state = try await savedReviews().change(ReviewSessionIdentity(account: account, detail: current), change)
    guard
      epoch == generation,
      detail?.item.id == current.item.id,
      detail?.revision == current.revision
    else { throw CancellationError() }
    sessionState = state
  }

  private func filterStore() async throws -> FilterPresetClient {
    if let filters {
      return filters
    }
    let store = try await FilterPresetStore.open(at: demoRoot?.appendingPathComponent("state/filters.sqlite"))
    let value = store.client
    filters = value
    return value
  }

  private func connection() throws -> (RepositoryID, ForgeClient) {
    guard let repository, let forge else { throw TataraError(.configuration, detail: "Initialize this backend first.") }
    return (repository, forge)
  }

  private func owned(_ params: RPCValue) throws -> ItemDetail {
    guard
      !selectionPending,
      let detail,
      params["head"]?.string == (detail.revision?.head ?? ""),
      params["number"]?.integer == detail.item.id.number,
      params["mergeBase"]?.string == nil || params["mergeBase"]?.string == (detail.revision?.mergeBase ?? "")
    else { throw TataraError(.revisionChanged) }
    return detail
  }

  private func validate(_ comment: InlineComment, _ current: ItemDetail) throws {
    guard
      comment.body.utf8.count <= 65536,
      !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let file = current.file(at: comment.path),
      ReviewAnchor.contains(
        range: (comment.startLine ?? comment.line)...max(comment.startLine ?? comment.line, comment.line),
        side: comment.side,
        patch: file.patch,
      ),
      (comment.startLine ?? comment.line) <= comment.line
    else { throw TataraError(.invalidLine) }
  }

  private func validateMaterializedSources() async throws {
    for (root, commit) in materializedRoots {
      let head = try await CommandRunner.live.checked("git", ["-C", root.path, "rev-parse", "HEAD"])
      guard head.text.trimmingCharacters(in: .whitespacesAndNewlines) == commit else { throw TataraError(.revisionChanged) }
      let dirty = try await CommandRunner.live.checked("git", ["-C", root.path, "status", "--porcelain", "--untracked-files=no"])
      guard dirty.output.isEmpty else { throw TataraError(
        .revisionChanged,
        detail: "An immutable source checkout was modified after opening it.",
      ) }
    }
  }

  private func store(_ preview: Preview) throws -> RPCValue {
    let bytes = try JSONEncoder().encode(preview.value).count
    let retainedBytes = try previews.values.reduce(0) { try $0 + JSONEncoder().encode($1.value).count }
    guard bytes <= 4 * 1024 * 1024, retainedBytes + bytes <= 8 * 1024 * 1024 else { throw TataraError(
      .unavailable,
      detail: "Write previews exceed their byte limit.",
    ) }
    guard previews.count < 16 else { throw TataraError(.unavailable, detail: "Too many unconfirmed write previews.") }
    let id = UUID().uuidString
    previews[id] = preview
    return .object(["id": .string(id), "preview": preview.value])
  }

}
