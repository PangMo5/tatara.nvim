// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import TataraCore
import Testing

struct FilePathSearchTests {
  @Test(arguments: ["needle", "Needle", "NEEDLE"])
  func `mixed case paths keep filename and parent highlights`(_ query: String) async throws {
    let path = "NeedleDomain/Sources/NeedleController.swift"
    let result = try await FilePathSearch.ranked([path, "docs/needle.jsonl"], query: query)
    let hit = try #require(result.first { $0.path == path })
    #expect(hit.ranges.contains(0..<6))
    let offset = path.utf16.count - "NeedleController.swift".utf16.count
    #expect(hit.ranges.contains(offset..<(offset + 6)))
  }

  @Test
  func `fff ranks abbreviations and typos without changing candidate identity`() async throws {
    let paths = ["SearchController/Unrelated.swift", "Sources/SearchController.swift", "Deleted/OldViewModel.swift"]
    for query in ["srchctrl", "searchcontroler", "SearchController"] {
      let result = try await FilePathSearch.ranked(paths, query: query)
      #expect(result.first?.path == "Sources/SearchController.swift")
      #expect(result.map(\.score) == result.map(\.score).sorted(by: >))
    }
    #expect(try await FilePathSearch.ranked(paths, query: "oldvm").first?.path == "Deleted/OldViewModel.swift")
    #expect(try await FilePathSearch.ranked(paths, query: "").map(\.path) == paths)
  }

  @Test
  func `constraints and complete results`() async throws {
    let paths = (0..<1600).map { "Sources/File\($0).swift" } + ["Tests/File.swift", "Sources/File.txt"]
    let result = try await FilePathSearch.ranked(paths, query: "*.swift !Tests")
    #expect(result.count == 1600)
    #expect(!result.contains { $0.path == "Sources/File.txt" })
    #expect(try await FilePathSearch.ranked(paths, query: "/Tests/ *.swift").map(\.path) == ["Tests/File.swift"])
  }

  @Test
  func `unicode byte offsets project into UTF 16`() async throws {
    let path = "😀폴더/CaféView.swift"
    #expect(try await FilePathSearch.ranked([path], query: "View").first?.ranges == [9..<13])
    #expect(try await FilePathSearch.ranked([path], query: "Café").first?.ranges == [5..<9])
    #expect(try await FilePathSearch.ranked([path], query: "폴더").first?.ranges == [2..<4])
  }

  @Test
  func `content fuzzy matching does not interpret source as filename constraints`() async throws {
    let lines = ["let values = [0, 1]", "no bracket here"]
    let matches = try await FilePathSearch.fuzzyText(lines, query: "[0")
    #expect(matches.map(\.index) == [0])
    #expect(matches.first?.ranges == [13..<15])
  }

  @Test
  func `cancellation never publishes partial results`() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await FilePathSearch.ranked(["File.swift"], query: "file")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
