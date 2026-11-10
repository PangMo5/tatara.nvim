// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraKit
import TataraSystem

struct DemoRepository: Sendable {
  let root: URL
  let repository: RepositoryID
  let client: ForgeClient

  @concurrent
  static func create() async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-nvim-demo-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    let before = """
      struct ReviewQueue {
        var files: [String] = []

        func next(after index: Int) -> String? {
          files[index + 1]
        }
      }
      """ + "\n"
    let after = """
      struct ReviewQueue {
        var files: [String] = []

        func next(after index: Int) -> String? {
          guard files.indices.contains(index + 1) else { return nil }
          return files[index + 1]
        }
      }
      """ + "\n"
    let paths = ["Sources/ReviewQueue.swift", "Sources/Selection.swift"]
    func write(_ text: String) throws {
      for path in paths { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
    }
    let runner = CommandRunner.live
    for args in [
      ["init", "--quiet"],
      ["config", "user.name", "Tatara demo"],
      ["config", "commit.gpgsign", "false"],
      ["config", "core.hooksPath", "/dev/null"],
      ["config", "user.email", "demo@example.invalid"],
      ["remote", "add", "origin", "https://github.com/example/reviews.git"],
    ] {
      _ = try await runner.checked("git", ["-C", root.path] + args)
    }
    try write(before)
    try "struct SharedType {}\n".write(
      to: root.appendingPathComponent("Sources/Unchanged.swift"),
      atomically: true,
      encoding: .utf8,
    )
    _ = try await runner.checked("git", ["-C", root.path, "add", "."])
    _ = try await runner.checked("git", ["-C", root.path, "commit", "--quiet", "-m", "Original"])
    let base = try await runner.checked("git", ["-C", root.path, "rev-parse", "HEAD"]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try write(after)
    _ = try await runner.checked("git", ["-C", root.path, "add", "."])
    _ = try await runner.checked("git", ["-C", root.path, "commit", "--quiet", "-m", "Bound navigation"])
    let head = try await runner.checked("git", ["-C", root.path, "rev-parse", "HEAD"]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let repository = try RepositoryID("example/reviews")
    let revision = PullRequestRevision(mergeBase: base, head: head)
    let item = ForgeItem(
      id: .init(repository: repository, number: 42),
      kind: .pullRequest,
      title: "Keep review navigation within bounds",
      author: "contributor",
      body: "Review an immutable change with native Neovim windows and buffers.",
      url: URL(string: "https://github.com/example/reviews/pull/42")!,
      github: .init(
        updatedAt: "2026-11-12T00:00:00Z",
        assignees: ["contributor"],
        requestedReviewers: ["reviewer"],
        commentCount: 1,
        reviewDecision: .reviewRequired,
        checksState: .success,
        headOID: head,
        headBranch: "review-bounds",
        baseBranch: "main",
        additions: 4,
        deletions: 2,
        changedFiles: 2,
        commits: 1,
      ),
    )
    let files = paths.map { ChangedFile(
      path: $0,
      status: "modified",
      additions: 2,
      deletions: 1,
      patch: "@@ -1,7 +1,8 @@\n struct ReviewQueue {\n   var files: [String] = []\n \n   func next(after index: Int) -> String? {\n-    files[index + 1]\n+    guard files.indices.contains(index + 1) else { return nil }\n+    return files[index + 1]\n   }\n }",
    ) }
    let detail = ItemDetail(
      item: item,
      revision: revision,
      files: files,
      comments: [.init(
        id: 1,
        author: "reviewer",
        body: "Keep the empty collection case covered.",
        anchor: .init(path: paths[0], line: 5, side: .right),
        nodeID: "demo-comment",
        url: URL(string: "https://github.com/example/reviews/pull/42#discussion_r1"),
      )],
      metadata: .github(.init(
        baseBranch: "main",
        headBranch: "review-bounds",
        mergeableState: "clean",
        checks: ["Unit tests: success"],
        reviews: ["reviewer: COMMENTED"],
      )),
    )
    let issue = ForgeItem(
      id: .init(repository: repository, number: 43),
      kind: .issue,
      title: "Track review navigation",
      author: "contributor",
      body: "Keep review navigation accessible.",
      url: URL(string: "https://github.com/example/reviews/issues/43")!,
    )
    var second = item
    second.id.number = 44
    second.title = "Keep review drafts across pull requests"
    second.url = URL(string: "https://github.com/example/reviews/pull/44")!
    let secondItem = second
    let client = ForgeClient(
      list: { _, kind, page in kind == .issue
        ? .init(items: [issue])
        : page == 1 ? .init(items: [item], nextPage: 2) : .init(items: [secondItem])
      },
      search: { _, kind, _, _ in .init(items: [kind == .issue ? issue : item]) },
      labels: { _ in ["bug", "needs review"] },
      detail: { selected in selected.kind == .issue
        ? .init(item: issue, comments: [])
        : selected.id.number == 44
          ? .init(item: secondItem, revision: revision, files: files, comments: detail.comments, metadata: detail.metadata)
          : detail
      },
      content: { _, commit, _ in Data((commit == base
          ? before
          : after).utf8) },
      submit: { _ in throw TataraError(.unavailable, detail: "The demo cannot publish reviews.") },
      commentContext: { _, comment in
        .init(
          comment: comment,
          canReply: true,
          canEdit: true,
          canDelete: true,
          canReact: true,
          thread: .init(id: "demo-thread", isResolved: false, canResolve: true, canUnresolve: false, canReply: true),
          reactions: [.init(content: .heart, count: 1, viewerHasReacted: true)],
          viewer: "reviewer",
        )
      },
    )
    return .init(root: root, repository: repository, client: client)
  }
}
