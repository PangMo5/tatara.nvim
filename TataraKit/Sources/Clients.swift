// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore

// MARK: - ForgeClient

public struct ForgeClient: Sendable {

  // MARK: Lifecycle

  public init(
    invalidate: @escaping @Sendable (RepositoryID) async throws -> Void = { _ in },
    list: @escaping @Sendable (RepositoryID, ItemKind, Int) async throws -> ItemPage = { _, _, _ in
      throw TataraError(.unavailable)
    },
    search: @escaping @Sendable (RepositoryID, ItemKind, String, Int) async throws -> ItemPage = { _, _, _, _ in
      throw TataraError(.unavailable)
    },
    labels: @escaping @Sendable (RepositoryID) async throws -> [String] = { _ in throw TataraError(.unavailable) },
    detail: @escaping @Sendable (ForgeItem) async throws -> ItemDetail = { _ in throw TataraError(.unavailable) },
    content: @escaping @Sendable (RepositoryID, String, String) async throws -> Data = { _, _, _ in
      throw TataraError(.unavailable)
    },
    submit: @escaping @Sendable (ReviewSubmission) async throws -> Void = { _ in throw TataraError(.unavailable) },
    commentContext: @escaping @Sendable (ForgeItem, DiscussionComment) async throws -> CommentContext = { _, _ in
      throw TataraError(.unavailable)
    },
    mutateComment: @escaping @Sendable (CommentMutation) async throws -> Void = { _ in throw TataraError(.unavailable) },
  ) {
    self.invalidate = invalidate
    self.list = list
    self.search = search
    self.labels = labels
    self.detail = detail
    self.content = content
    self.submit = submit
    self.commentContext = commentContext
    self.mutateComment = mutateComment
  }

  // MARK: Public

  public var invalidate: @Sendable (RepositoryID) async throws -> Void
  public var list: @Sendable (RepositoryID, ItemKind, Int) async throws -> ItemPage
  public var search: @Sendable (RepositoryID, ItemKind, String, Int) async throws -> ItemPage
  public var labels: @Sendable (RepositoryID) async throws -> [String]
  public var detail: @Sendable (ForgeItem) async throws -> ItemDetail
  public var content: @Sendable (RepositoryID, String, String) async throws -> Data
  public var submit: @Sendable (ReviewSubmission) async throws -> Void
  public var commentContext: @Sendable (ForgeItem, DiscussionComment) async throws -> CommentContext
  public var mutateComment: @Sendable (CommentMutation) async throws -> Void

}

// MARK: - DiffClient

public struct DiffClient: Sendable {
  public init(
    render: @escaping @Sendable (DiffRequest) async throws -> ReviewDiff = { _ in throw TataraError(.unavailable) }
  ) {
    self.render = render
  }

  public var render: @Sendable (DiffRequest) async throws -> ReviewDiff
}

// MARK: - FileFinderClient

public struct FileFinderClient: Sendable {
  public init(
    search: @escaping @Sendable ([String], String) async throws -> [FilePathMatch] = { paths, query in
      try await FilePathSearch.ranked(
        paths,
        query: query,
      )
    },
    preview: @escaping @Sendable (ItemDetail, String) async throws -> FileContentDocument = { _, _ in
      throw TataraError(.unavailable)
    },
  ) {
    self.search = search
    self.preview = preview
  }

  public var search: @Sendable ([String], String) async throws -> [FilePathMatch]
  public var preview: @Sendable (ItemDetail, String) async throws -> FileContentDocument
}

// MARK: - ContentSearchClient

public struct ContentSearchClient: Sendable {
  public init(
    prepare: @escaping @Sendable (ItemDetail) async throws -> [FileContentDocument] = { _ in throw TataraError(.unavailable) },
    search: @escaping @Sendable ([FileContentDocument], String, ContentSearchMode) async throws -> [FileContentHit] = { _, _, _ in
      throw TataraError(.unavailable)
    },
  ) {
    self.prepare = prepare
    self.search = search
  }

  public var prepare: @Sendable (ItemDetail) async throws -> [FileContentDocument]
  public var search: @Sendable ([FileContentDocument], String, ContentSearchMode) async throws -> [FileContentHit]
}

// MARK: - FilterPresetClient

public struct FilterPresetClient: Sendable {
  public init(
    load: @escaping @Sendable (RepositoryID) async throws -> [FilterPreset] = { _ in throw TataraError(.unavailable) },
    save: @escaping @Sendable (RepositoryID, FilterPreset) async throws -> Void = { _, _ in throw TataraError(.unavailable) },
    delete: @escaping @Sendable (RepositoryID, String) async throws -> Void = { _, _ in throw TataraError(.unavailable) },
  ) {
    self.load = load
    self.save = save
    self.delete = delete
  }

  public var load: @Sendable (RepositoryID) async throws -> [FilterPreset]
  public var save: @Sendable (RepositoryID, FilterPreset) async throws -> Void
  public var delete: @Sendable (RepositoryID, String) async throws -> Void
}

// MARK: - CacheClient

public struct CacheClient: Sendable {

  // MARK: Lifecycle

  public init(
    read: @escaping @Sendable (String, String, Double?) async throws -> Data?,
    write: @escaping @Sendable (String, String, Data) async throws -> Void,
    invalidate: @escaping @Sendable (String) async throws -> Void,
  ) {
    self.read = read
    self.write = write
    self.invalidate = invalidate
  }

  // MARK: Public

  public static let disabled = Self(read: { _, _, _ in nil }, write: { _, _, _ in }, invalidate: { _ in })

  public var read: @Sendable (_ namespace: String, _ key: String, _ maximumAge: Double?) async throws -> Data?
  public var write: @Sendable (_ namespace: String, _ key: String, _ value: Data) async throws -> Void
  public var invalidate: @Sendable (_ namespace: String) async throws -> Void

  public func scoped(to scope: String) -> Self {
    Self(
      read: { try await read(scope + ":" + $0, $1, $2) },
      write: { try await write(scope + ":" + $0, $1, $2) },
      invalidate: { try await invalidate(scope + ":" + $0) },
    )
  }

}

// MARK: - DiffRequest

public struct DiffRequest: Equatable, Sendable {

  // MARK: Lifecycle

  public init(
    repository: RepositoryID,
    revision: PullRequestRevision,
    file: ChangedFile,
    revealing: SourceLocation? = nil,
  ) {
    self.repository = repository
    self.revision = revision
    self.file = file
    self.revealing = revealing
  }

  // MARK: Public

  public var repository: RepositoryID
  public var revision: PullRequestRevision
  public var file: ChangedFile
  public var revealing: SourceLocation?

}
