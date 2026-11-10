// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import TataraCore

// MARK: - ContentSearchMode

public enum ContentSearchMode: String, CaseIterable, Sendable {
  case plain
  case regex
  case fuzzy

  public var titleKey: String {
    switch self { case .plain: "Plain text"
    case .regex: "Regular expression"
    case .fuzzy: "Fuzzy" }
  }

  public var next: Self {
    switch self { case .plain: .regex
    case .regex: .fuzzy
    case .fuzzy: .plain }
  }
}

// MARK: - FileContentDocument

public struct FileContentDocument: Equatable, Codable, Sendable {
  public init(path: String, side: InlineComment.Side, lines: [String]) {
    self.path = path
    self.side = side
    self.lines = lines
  }

  public let path: String
  public let side: InlineComment.Side
  public let lines: [String]
}

// MARK: - FileContentHit

public struct FileContentHit: Equatable, Codable, Sendable {
  public init(location: SourceLocation, excerpt: String, ranges: [Range<Int>], column: Int = 0) {
    self.location = location
    self.excerpt = excerpt
    self.ranges = ranges
    self.column = column
  }

  public let location: SourceLocation
  public let excerpt: String
  public let ranges: [Range<Int>]
  public let column: Int
}
