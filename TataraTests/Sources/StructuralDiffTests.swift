// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import Testing

struct StructuralDiffTests {
  @Test(arguments: ["created", "changed", "deleted"])
  func `binary results never acquire source anchors`(status: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["language": "Binary", "status": status])
    let value = try ReviewDiff.decode(data, before: "", after: "\u{0}text", path: "binary.dat")
    #expect(value.status == "binary")
    #expect(value.rows.isEmpty)
    #expect(try value.firstChange() == nil)
  }

  @Test
  func `incomplete alignment cannot hide a real source line`() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "language": "Text",
      "status": "changed",
      "aligned_lines": [[0, 0], [2, 1]],
      "chunks": [],
    ] as [String: Any])
    #expect(throws: TataraError.self) { try ReviewDiff.decode(data, before: "a\nb\nc", after: "a\nc", path: "text.txt") }
  }

  @Test
  func `complete alignment survives collapsed context and serialization`() throws {
    let source = (0..<20).map { "value\($0)" }
    var after = source
    after[10] = "changed"
    let alignment: [[Int?]] = (0..<20).map { [$0, $0] }
    let json: [String: Any] = [
      "language": "Text",
      "status": "changed",
      "aligned_lines": alignment,
      "chunks": [[[
        "lhs": [
          "line_number": 10,
          "changes": [["start": 0, "end": 7, "content": "value10", "highlight": "comment"]],
        ],
        "rhs": [
          "line_number": 10,
          "changes": [["start": 0, "end": 7, "content": "changed", "highlight": "keyword"]],
        ],
      ]]],
    ]
    let value = try ReviewDiff.decode(
      JSONSerialization.data(withJSONObject: json),
      before: source.joined(separator: "\n"),
      after: after.joined(separator: "\n"),
      path: "example.txt",
    )
    #expect(value.rows.count < 20)
    #expect(value.alignment?.count == 20)
    #expect(value.alignment?.first == [1, 1])
    #expect(try value.firstChange()?.line == 11)
    let roundtrip = try JSONDecoder().decode(ReviewDiff.self, from: JSONEncoder().encode(value))
    #expect(roundtrip == value)
  }

  @Test(arguments: [("created", InlineComment.Side.right), ("deleted", InlineComment.Side.left)])
  func `whole file changes select an actual first source line`(status: String, side: InlineComment.Side) throws {
    let data = try JSONSerialization.data(withJSONObject: ["status": status, "language": "Text"])
    let value = try ReviewDiff.decode(
      data,
      before: status == "deleted" ? "first\n" : "",
      after: status == "created"
        ? "first\n"
        : "",
      path: "new.txt",
    )
    #expect(try value.firstChange() == SourceLocation(path: "new.txt", line: 1, side: side))
  }
}
