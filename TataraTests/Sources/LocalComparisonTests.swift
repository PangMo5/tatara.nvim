// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraBridge
import TataraCore
import TataraPersistence
import TataraSystem
import Testing

struct LocalComparisonTests {
  @Test
  func `a linked worktree resolves its own HEAD and retains notes at their exact revision`() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-local-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("linked")
    @Sendable
    func git(_ directory: URL, _ args: String...) async throws -> String {
      try await CommandRunner.live.checked("git", [
        "-C",
        directory.path,
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "commit.gpgsign=false",
      ] + args).text.trimmingCharacters(in: .newlines)
    }
    _ = try await git(root, "init", "-q", "-b", "base")
    _ = try await git(root, "config", "user.name", "Tatara Fixture")
    _ = try await git(root, "config", "user.email", "tatara@localhost")
    try Data("first\r\nold\r\nlast\r\n".utf8).write(to: root.appendingPathComponent("source.txt"))
    try Data("regular file\n".utf8).write(to: root.appendingPathComponent("type.txt"))
    _ = try await git(root, "add", "source.txt", "type.txt")
    _ = try await git(root, "commit", "-qm", "Base")
    let base = try await git(root, "rev-parse", "HEAD")
    _ = try await git(root, "worktree", "add", "-qb", "feature", source.path)
    let file = source.appendingPathComponent("source.txt")
    try Data("first\r\nnew\r\nlast\r\n".utf8).write(to: file)
    try Data([0, 1, 2]).write(to: source.appendingPathComponent("binary"))
    let type = source.appendingPathComponent("type.txt")
    try FileManager.default.removeItem(at: type)
    try FileManager.default.createSymbolicLink(atPath: type.path, withDestinationPath: "source.txt")
    _ = try await git(source, "add", ".")
    _ = try await git(source, "commit", "-qm", "Feature")
    let head = try await git(source, "rev-parse", "HEAD")

    let store = try await ReviewSessionStore.open(at: root.appendingPathComponent("state/reviews.sqlite"))
    let backend = Backend(reviewStore: store)
    _ = try await backend.call("initialize", .object([
      "localBase": .string("HEAD~"),
      "includeWorktree": .bool(false),
      "source": .string(source.path),
    ]))
    let opened = try await backend.call("open", .object(["kind": .string("localComparison")]))
    let original = try opened.decode(ItemDetail.self)
    #expect(original.revision == .init(mergeBase: base, head: head))
    #expect(original.file(at: "type.txt")?.isNonSource == true)
    #expect(original.file(at: "binary")?.isNonSource == true)
    let sourceFile = try #require(original.file(at: "source.txt"))
    #expect(sourceFile.anchors.contains(range: 1...2, side: .right))
    let params: [String: RPCValue] = ["number": .number(0), "head": .string(head), "mergeBase": .string(base)]
    let comment = try RPCValue.encode(InlineComment(path: "source.txt", line: 2, side: .right, body: "Keep the end marker."))
    let drafts = try await backend.call("draft.add", .object(params.merging(["comment": comment]) { _, extra in extra }))
    #expect(drafts.array?.count == 1)
    await #expect(throws: TataraError.self) { try await backend.call("review.preview", .object(params)) }
    await #expect(throws: TataraError.self) { try await backend.call("write.confirm", .object(params)) }

    try Data("first\r\nupdated\r\nlast\r\n".utf8).write(to: file)
    _ = try await git(source, "commit", "-qam", "Next revision")
    let refreshed = try await backend.call("refresh", .object(params))
    #expect(refreshed["revision"]?["mergeBase"]?.string == head)
    #expect(refreshed["drafts"]?.array?.isEmpty == true)
    _ = try await git(source, "switch", "--detach", head)
    let restored = try await backend.call("refresh", .object([:]))
    #expect(restored["drafts"]?.array == drafts.array)
    await backend.close()
  }
}
