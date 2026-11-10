// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - SourceLocation

public struct SourceLocation: Hashable, Codable, Sendable {
  public init(path: String, line: Int, side: InlineComment.Side) {
    self.path = path
    self.line = line
    self.side = side
  }

  public let path: String
  public let line: Int
  public let side: InlineComment.Side
}

// MARK: - SearchPattern

public struct SearchPattern: Sendable {

  // MARK: Lifecycle

  public init(_ query: String) throws {
    do { expression = try NSRegularExpression(pattern: query) }
    catch { throw TataraError(.invalidResponse, detail: "Invalid search expression: \(error.localizedDescription)") }
  }

  // MARK: Public

  public func ranges(in text: String) throws -> [Range<Int>] {
    var result = [Range<Int>]()
    var exceededLimit = false
    expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(
      text.startIndex...,
      in: text,
    )) { match, _, stop in
      if Task.isCancelled {
        stop.pointee = true
        return
      }
      if let match {
        if result.count >= 100_000 {
          exceededLimit = true
          stop.pointee = true
          return
        }
        result.append(match.range.location ..< match.range.location + match.range.length)
      }
    }
    try Task.checkCancellation()
    guard !exceededLimit else { throw TataraError(
      .invalidResponse,
      detail: "Search exceeds 100,000 matches; narrow the expression.",
    ) }
    return result
  }

  public func contains(in text: String) throws -> Bool {
    var found = false
    expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(
      text.startIndex...,
      in: text,
    )) { match, _, stop in
      if Task.isCancelled {
        stop.pointee = true
        return
      }
      if match != nil {
        found = true
        stop.pointee = true
      }
    }
    try Task.checkCancellation()
    return found
  }

  // MARK: Private

  private let expression: NSRegularExpression

}
