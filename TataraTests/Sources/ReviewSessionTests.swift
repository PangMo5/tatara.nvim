// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraPersistence
import Testing

struct ReviewSessionTests {

  // MARK: Internal

  @Test
  func `saved review restores exact Unicode drafts summary and hunk progress after reconnect`() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-review-\(UUID())/reviews.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try await ReviewSessionStore.open(at: url)
    let owner = try identity()
    let comment = InlineComment(path: "Sources/한글.swift", line: 8, side: .right, body: "```suggestion\n수정()\n```", startLine: 7)
    let entry = ReviewDraft(comment: comment)
    _ = try await store.change(owner, .add(entry))
    _ = try await store.change(owner, .summary("검토 요약", .requestChanges))
    _ = try await store.change(owner, .markFile(comment.path, true))
    _ = try await store.change(owner, .markHunk("hunk", true))
    let reopened = try await ReviewSessionStore.open(at: url)
    let state = try await reopened.load(owner)
    #expect(state.drafts == [entry])
    #expect(state.summary == "검토 요약")
    #expect(state.event == .requestChanges)
    #expect(state.reviewedFiles == [comment.path])
    #expect(state.reviewedHunks == ["hunk"])
    let listing = try await reopened.list(owner)
    #expect(listing.count == 1)
    let row = try #require(listing.first)
    _ = try await reopened.change(owner, .summary("Newer editor", .comment))
    await #expect(throws: TataraError.self) {
      try await store.remove(owner, id: row.id, expectedUpdatedAt: row.updatedAt)
    }
    let current = try #require(try await reopened.list(owner).first)
    try await reopened.remove(owner, id: current.id, expectedUpdatedAt: current.updatedAt)
    #expect(try await reopened.load(owner).drafts.isEmpty)
  }

  @Test(arguments: ["account", "host", "repository", "kind", "head", "base"])
  func `review state never crosses its source or account identity`(_ field: String) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-scope-\(UUID())/reviews.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try await ReviewSessionStore.open(at: url)
    let owner = try identity()
    _ = try await store.change(owner, .summary("Private review", .comment))
    let other = try identity(
      account: field == "account" ? "other" : "first",
      repository: field == "repository" ? "owner/other" : "owner/project",
      host: field == "host" ? "enterprise.example" : "github.com",
      kind: field == "kind" ? .issue : .pullRequest,
      head: field == "head" ? "other-head" : "head",
      base: field == "base" ? "other-base" : "base",
    )
    #expect(try await store.load(other) == ReviewSessionState())
  }

  @Test
  func `concurrent editor mutations merge and submission clears only its own previewed drafts`() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-concurrent-\(UUID())/reviews.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try await ReviewSessionStore.open(at: url)
    let second = try await ReviewSessionStore.open(at: url)
    let owner = try identity()
    let a = ReviewDraft(comment: .init(path: "a.swift", line: 1, side: .right, body: "One"))
    let b = ReviewDraft(comment: .init(path: "b.swift", line: 2, side: .left, body: "Two"))
    async let one = first.change(owner, .add(a))
    async let two = second.change(owner, .add(b))
    _ = try await (one, two)
    #expect(Set(try await first.load(owner).drafts.map(\.id)) == [a.id, b.id])
    _ = try await first.change(owner, .summary("Summary in another editor", .comment))
    _ = try await second.change(owner, .submitted([a], "Older summary"))
    let retained = try await first.load(owner)
    #expect(retained.drafts == [b])
    #expect(retained.summary == "Summary in another editor")
    let markdown = ReviewExport.markdown(identity: owner, state: retained)
    #expect(markdown.contains("b.swift:2 · LEFT"))
    #expect(!markdown.contains("a.swift"))
    var edited = b.comment
    edited.body = "Edited in another editor"
    _ = try await first.change(owner, .update(b.id, edited, expectedBody: b.comment.body))
    await #expect(throws: TataraError.self) { try await second.change(owner, .remove(b.id, expectedBody: b.comment.body)) }
    _ = try await second.change(owner, .submitted([b], ""))
    #expect(try await first.load(owner).drafts.first?.comment.body == edited.body)
    let beforeFailure = try await first.load(owner)
    let invalid = ReviewDraft(comment: .init(path: "x", line: 1, side: .right, body: String(repeating: "a", count: 65537)))
    await #expect(throws: TataraError.self) { try await first.change(owner, .add(invalid)) }
    #expect(try await first.load(owner) == beforeFailure)
  }

  @Test
  func `forge hunks preserve zero sided ranges and stable path identities`() {
    let file = ChangedFile(
      path: "Sources/a:b.swift",
      patch: "@@ -0,0 +1,3 @@\n+one\n+two\n+three\n@@ -9 +12,0 @@ name\n-old\n@@ - +1 @@\n",
    )
    let hunks = ReviewHunk.parse(file)
    #expect(hunks.count == 2)
    #expect(hunks.first?.oldCount == 0)
    #expect(hunks.last?.newCount == 0)
    #expect(Set(hunks.map(\.id)).count == 2)
  }

  // MARK: Private

  private func identity(
    account: String = "first",
    repository: String = "owner/project",
    host: String = "github.com",
    kind: ItemKind = .pullRequest,
    head: String = "head",
    base: String = "base",
  ) throws -> ReviewSessionIdentity {
    let repo = try RepositoryID(repository, host: host)
    let item = ForgeItem(
      id: .init(repository: repo, number: 1),
      kind: kind,
      title: "Review",
      author: "author",
      url: URL(string: "https://github.com/owner/project/pull/1")!,
    )
    return ReviewSessionIdentity(account: account, detail: .init(item: item, revision: .init(mergeBase: base, head: head)))
  }

}
