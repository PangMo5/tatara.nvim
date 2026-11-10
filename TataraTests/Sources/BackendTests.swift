// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraBridge
import TataraCore
import Testing

struct BackendTests {

  // MARK: Internal

  @Test
  func `native editor receives true immutable worktree paths and first change coordinates`() async throws {
    let (backend, detail) = try await session()
    do {
      let result = try await backend.call("file", params(detail, extra: ["path": .string("Sources/ReviewQueue.swift")]))
      let head = try #require(result["workspace"]?["path"]?.string)
      let headRoot = try #require(result["workspace"]?["root"]?.string)
      #expect(head.hasPrefix(headRoot + "/"))
      let base = try #require(result["baseWorkspace"]?["path"]?.string)
      #expect(head != base)
      #expect(try String(contentsOfFile: head, encoding: .utf8) == result["after"]?.string)
      #expect(try String(contentsOfFile: base, encoding: .utf8) == result["before"]?.string)
      #expect(result["initial"]?["line"]?.integer == 5)
      #expect(result["initial"]?["side"]?.string == "RIGHT")
      #expect(!FileManager.default
        .fileExists(atPath: URL(fileURLWithPath: head).deletingLastPathComponent().deletingLastPathComponent()
          .appendingPathComponent("buildServer.json").path))
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `concurrent file reads coalesce immutable worktree creation`() async throws {
    let (backend, detail) = try await session()
    do {
      async let first = backend.call("file", params(detail, extra: ["path": .string("Sources/ReviewQueue.swift")]))
      async let second = backend.call("file", params(detail, extra: ["path": .string("Sources/Selection.swift")]))
      let (a, b) = try await (first, second)
      #expect(a["workspace"]?["root"] == b["workspace"]?["root"])
      #expect(a["baseWorkspace"]?["root"] == b["baseWorkspace"]?["root"])
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `source-only reads are explicit and drafts require valid patch ownership`() async throws {
    let (backend, detail) = try await session()
    do {
      let result = try await backend.call(
        "file",
        params(detail, extra: ["path": .string("Sources/ReviewQueue.swift"), "checkout": .bool(false)]),
      )
      #expect(result["workspace"] == .null)
      let draft = try await backend.call("draft.add", params(detail, extra: ["comment": try comment()]))
      #expect(draft.array?.count == 1)
      let invalid = try RPCValue.encode(InlineComment(
        path: "Sources/ReviewQueue.swift",
        line: 500,
        side: .right,
        body: "Invalid",
      ))
      await #expect(throws: TataraError.self) { try await backend.call("draft.add", params(detail, extra: ["comment": invalid])) }
      await #expect(throws: TataraError.self) { try await backend.call(
        "draft.list",
        .object(["number": .number(42), "head": .string("stale")]),
      ) }
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `review previews contain the exact inline draft and are invalidated by refresh`() async throws {
    let (backend, detail) = try await session()
    do {
      _ = try await backend.call("draft.add", params(detail, extra: ["comment": try comment()]))
      let preview = try await backend.call("review.preview", params(detail, extra: ["body": .string("Review summary")]))
      #expect(preview["preview"]?["number"]?.integer == 42)
      #expect(preview["preview"]?["body"]?.string == "Review summary")
      #expect(preview["preview"]?["comments"]?.array?.count == 1)
      _ = try await backend.call("refresh", .object([:]))
      let token = try #require(preview["id"]?.string)
      await #expect(throws: TataraError.self) { try await backend.call(
        "write.confirm",
        params(detail, extra: ["preview": .string(token)]),
      ) }
      let retained = try await backend.call("draft.list", params(detail))
      #expect(retained.array?.count == 1)
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `failed writes consume a preview once and are never automatically repeated`() async throws {
    let (backend, detail) = try await session()
    do {
      let preview = try await backend.call(
        "review.preview",
        params(detail, extra: ["single": .bool(true), "comment": try comment()]),
      )
      let token = try #require(preview["id"]?.string)
      do {
        _ = try await backend.call("write.confirm", params(detail, extra: ["preview": .string(token)]))
        Issue.record("The demo must never perform a remote write.")
      } catch let error as TataraError { #expect(error.code == .unavailable) }
      do {
        _ = try await backend.call("write.confirm", params(detail, extra: ["preview": .string(token)]))
        Issue.record("An already consumed preview was accepted.")
      } catch let error as TataraError { #expect(error.code == .revisionChanged) }
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `editing materialized source invalidates write confirmation without restoring user changes`() async throws {
    let (backend, detail) = try await session()
    do {
      let file = try await backend.call("file", params(detail, extra: ["path": .string("Sources/ReviewQueue.swift")]))
      let path = try #require(file["workspace"]?["path"]?.string)
      let preview = try await backend.call(
        "review.preview",
        params(detail, extra: ["single": .bool(true), "comment": try comment()]),
      )
      try "Modified managed source\n".write(toFile: path, atomically: true, encoding: .utf8)
      let token = try #require(preview["id"]?.string)
      do {
        _ = try await backend.call("write.confirm", params(detail, extra: ["preview": .string(token)]))
        Issue.record("A changed source checkout was accepted.")
      } catch let error as TataraError { #expect(error.code == .revisionChanged) }
      #expect(try String(contentsOfFile: path, encoding: .utf8) == "Modified managed source\n")
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `draft identifiers survive editing removal and pull request switches`() async throws {
    let (backend, detail) = try await session()
    do {
      let added = try await backend.call("draft.add", params(detail, extra: ["comment": try comment()]))
      let id = try #require(added.array?.first?["id"]?.string)
      let changed = try RPCValue.encode(InlineComment(
        path: "Sources/ReviewQueue.swift",
        line: 5,
        side: .right,
        body: "Edited body",
      ))
      let edited = try await backend.call("draft.update", params(detail, extra: ["id": .string(id), "comment": changed]))
      #expect(edited.array?.first?["id"]?.string == id)
      #expect(edited.array?.first?["body"]?.string == "Edited body")
      _ = try await backend.call("open", .object(["number": .number(44)]))
      let restored = try await backend.call("open", .object(["number": .number(42)]))
      #expect(restored["drafts"]?.array?.first?["body"]?.string == "Edited body")
      #expect(restored["drafts"]?.array?.first?["id"]?.string == id)
      let remaining = try await backend.call("draft.remove", params(detail, extra: ["id": .string(id)]))
      #expect(remaining.array?.isEmpty == true)
      await #expect(throws: TataraError.self) { try await backend.call(
        "draft.update",
        params(detail, extra: ["id": .string(id), "comment": changed]),
      ) }
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `published comment actions use fresh permissions reaction choice and content version`() async throws {
    let (backend, detail) = try await session()
    do {
      let key = try #require(detail["comments"]?.array?.first?["key"]?.string)
      let context = try await backend.call("comment.context", params(detail, extra: ["key": .string(key)]))
      #expect(context["actions"]?.array?.contains(.string("react")) == true)
      #expect(context["actions"]?.array?.contains(.string("unresolve")) == false)
      let preview = try await backend.call(
        "comment.preview",
        params(detail, extra: ["key": .string(key), "operation": .string("react"), "reaction": .string("HEART")]),
      )
      #expect(preview["preview"]?["reaction"]?.string == "HEART")
      #expect(preview["preview"]?["removesReaction"]?.boolean == true)
      await #expect(throws: TataraError.self) { try await backend.call(
        "comment.preview",
        params(
          detail,
          extra: ["key": .string(key), "operation": .string("edit"), "expectedBody": .string("stale"), "body": .string("edited")],
        ),
      ) }
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `issue comments pagination labels and user presets remain available`() async throws {
    let (backend, _) = try await session()
    do {
      let page = try await backend.call("pulls", .object([:]))
      #expect(page["nextPage"]?.integer == 2)
      let second = try await backend.call("pulls", .object(["page": .number(2)]))
      #expect(second["items"]?.array?.first?["id"]?["number"]?.integer == 44)
      let preset = try RPCValue.encode(FilterPreset(id: "saved", name: "Review queue", query: "is:open label:\"needs review\""))
      _ = try await backend.call("filter.save", .object(["preset": preset]))
      let filters = try await backend.call("filters", .object([:]))
      #expect(filters["presets"]?.array?.contains(preset) == true)
      #expect(filters["labels"]?.array?.contains(.string("needs review")) == true)
      let toggled = try await backend.call(
        "filter.label",
        .object(["query": .string("is:open"), "label": .string("needs review")]),
      )
      #expect(toggled.string == "is:open label:\"needs review\"")
      _ = try await backend.call("filter.delete", .object(["id": .string("saved")]))
      let issue = try await backend.call("open", .object(["number": .number(43), "kind": .string("issue")]))
      #expect(issue["item"]?["kind"]?.string == "issue")
      let preview = try await backend.call(
        "review.preview",
        .object(["number": .number(43), "head": .string(""), "body": .string("Issue discussion")]),
      )
      #expect(preview["preview"]?["body"]?.string == "Issue discussion")
      await #expect(throws: TataraError.self) { try await backend.call(
        "review.preview",
        .object(["number": .number(43), "head": .string(""), "event": .string("APPROVE")]),
      ) }
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `selection preview never changes the active review or drafts`() async throws {
    let (backend, detail) = try await session()
    do {
      _ = try await backend.call("draft.add", params(detail, extra: ["comment": try comment()]))
      let inspected = try await backend.call("inspect", .object(["number": .number(44)]))
      #expect(inspected["item"]?["id"]?["number"]?.integer == 44)
      let retained = try await backend.call("draft.list", params(detail))
      #expect(retained.array?.count == 1)
      let hits = try await backend.call(
        "search.content",
        params(detail, extra: ["query": .string("guard"), "mode": .string("plain")]),
      )
      #expect(hits.array?.count == 2)
      _ = try await backend.call("open", .object(["number": .number(44)]))
      await #expect(throws: TataraError.self) { try await backend.call(
        "search.content",
        params(detail, extra: ["query": .string("guard")]),
      ) }
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  @Test
  func `saved review RPC preserves progress and exports the exact owned revision`() async throws {
    let (backend, detail) = try await session()
    do {
      let hunk = try #require(detail["hunks"]?.array?.first?["id"]?.string)
      _ = try await backend.call("review.mark", params(detail, extra: ["hunk": .string(hunk), "reviewed": .bool(true)]))
      _ = try await backend.call(
        "review.mark",
        params(detail, extra: ["path": .string("Sources/ReviewQueue.swift"), "reviewed": .bool(true)]),
      )
      _ = try await backend.call(
        "review.summary",
        params(detail, extra: ["body": .string("Durable summary"), "event": .string("APPROVE")]),
      )
      let draft = try await backend.call("draft.add", params(detail, extra: ["comment": try comment()]))
      let refreshed = try await backend.call("refresh", .object([:]))
      #expect(refreshed["reviewState"]?["summary"]?.string == "Durable summary")
      #expect(refreshed["reviewState"]?["reviewedHunks"]?.array?.first?.string == hunk)
      #expect(refreshed["drafts"] == draft)
      let exported = try await backend.call("review.export", params(detail))
      #expect(exported.string?.contains("Sources/ReviewQueue.swift:5 · RIGHT") == true)
      let json = try await backend.call("review.export", params(detail, extra: ["format": .string("json")]))
      #expect(json["identity"]?["head"] == detail["revision"]?["head"])
      #expect(json["identity"]?["mergeBase"] == detail["revision"]?["mergeBase"])
      let scoped = try await backend.call("search.content", params(detail, extra: [
        "query": .string("guard"),
        "paths": .array([.string("Sources/Selection.swift")]),
      ]))
      #expect(scoped.array?.count == 1)
      #expect(scoped.array?.first?["location"]?["path"]?.string == "Sources/Selection.swift")
      let empty = try await backend.call(
        "search.content",
        params(detail, extra: ["query": .string("guard"), "paths": .array([])]),
      )
      #expect(empty.array?.isEmpty == true)
      await #expect(throws: TataraError.self) { try await backend.call(
        "search.files",
        params(detail, extra: ["paths": .array([.string("foreign.swift")])]),
      ) }
      let file = try await backend.call("review.preview", params(detail, extra: ["single": .bool(true), "fileComment": .object([
        "path": .string("Sources/ReviewQueue.swift"),
        "body": .string("File level comment"),
      ])]))
      #expect(file["preview"]?["fileComment"]?["path"]?.string == "Sources/ReviewQueue.swift")
      #expect(file["preview"]?["comments"]?.array?.isEmpty == true)
      await #expect(throws: TataraError.self) { try await backend.call(
        "review.mark",
        params(detail, extra: ["hunk": .string("foreign"), "reviewed": .bool(true)]),
      ) }
      await #expect(throws: TataraError.self) { try await backend.call(
        "review.export",
        params(detail, extra: ["mergeBase": .string("other-base")]),
      ) }
      await backend.close()
    } catch { await backend.close()
      throw error
    }
  }

  // MARK: Private

  private func session() async throws -> (Backend, RPCValue) {
    let backend = Backend()
    _ = try await backend.call("initialize", .object(["demo": .bool(true)]))
    let detail = try await backend.call("open", .object([:]))
    return (backend, detail)
  }

  private func params(_ detail: RPCValue, extra: [String: RPCValue] = [:]) throws -> RPCValue {
    let head = try #require(detail["revision"]?["head"]?.string)
    let number = try #require(detail["item"]?["id"]?["number"]?.integer)
    return .object(extra.merging(["head": .string(head), "number": .number(Double(number))]) { _, owner in owner })
  }

  private func comment() throws -> RPCValue {
    try .encode(InlineComment(
      path: "Sources/ReviewQueue.swift",
      line: 5,
      side: .right,
      body: "Keep the empty collection case covered.",
    ))
  }

}
