// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraFFF

// MARK: - FilePathMatch

public struct FilePathMatch: Equatable, Codable, Sendable {
  public init(path: String, score: Int, ranges: [Range<Int>]) {
    self.path = path
    self.score = score
    self.ranges = ranges
  }

  public let path: String
  public let score: Int
  public let ranges: [Range<Int>]
}

// MARK: - FuzzyTextMatch

public struct FuzzyTextMatch: Equatable, Sendable {
  public let index: Int
  public let score: Int
  public let ranges: [Range<Int>]
}

// MARK: - FilePathSearch

/// FFF searches immutable candidates; presentation never reorders the Files tree.
public enum FilePathSearch {

  // MARK: Public

  @concurrent
  public static func ranked(_ paths: [String], query: String) async throws -> [FilePathMatch] {
    try await match(paths, query: query, text: false).map {
      .init(path: paths[$0.index], score: $0.score, ranges: $0.ranges)
    }
  }

  @concurrent
  public static func fuzzyText(_ lines: [String], query: String) async throws -> [FuzzyTextMatch] {
    try await match(lines, query: query, text: true)
  }

  // MARK: Private

  private struct Request: Encodable { let query: String
    let paths: [String]
    let matchText: Bool
  }

  private struct Response: Decodable { let error: String?
    let hits: [Hit]?
  }

  private struct Hit: Decodable { let index: Int
    let score: Int
    let ranges: [[Int]]
  }

  @concurrent
  private static func match(_ values: [String], query: String, text: Bool) async throws -> [FuzzyTextMatch] {
    let input = try JSONEncoder().encode(Request(query: query, paths: values, matchText: text))
    try Task.checkCancellation()
    var count = 0
    let output = input.withUnsafeBytes { bytes in
      tatara_fff_search(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &count)
    }
    guard let output else { throw TataraError(.invalidResponse, detail: "FFF did not return search results.") }
    defer { tatara_fff_free(output, count) }
    let response = try JSONDecoder().decode(Response.self, from: Data(bytes: output, count: count))
    try Task.checkCancellation()
    if let error = response.error {
      throw TataraError(.invalidResponse, detail: error)
    }
    guard let hits = response.hits else { throw TataraError(.invalidResponse, detail: "FFF omitted search results.") }
    var matches = [FuzzyTextMatch]()
    for hit in hits {
      try Task.checkCancellation()
      guard values.indices.contains(hit.index)
      else { throw TataraError(.invalidResponse, detail: "FFF returned an invalid index.") }
      guard hit.ranges.allSatisfy({ $0.count == 2 && $0[0] >= 0 && $0[0] < $0[1] && $0[1] <= values[hit.index].utf16.count })
      else {
        throw TataraError(.invalidResponse, detail: "FFF returned an invalid highlight range.")
      }
      matches.append(.init(index: hit.index, score: hit.score, ranges: hit.ranges.map { $0[0] ..< $0[1] }))
    }
    return matches.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
  }

}
