// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - ReviewSessionIdentity

public struct ReviewSessionIdentity: Codable, Equatable, Sendable {
  public init(account: String, detail: ItemDetail) {
    self.account = account
    repository = detail.item.id.repository
    number = detail.item.id.number
    kind = detail.item.kind
    mergeBase = detail.revision?.mergeBase ?? ""
    head = detail.revision?.head ?? ""
  }

  public let account: String
  public let repository: RepositoryID
  public let number: Int
  public let kind: ItemKind
  public let mergeBase: String
  public let head: String
}

// MARK: - ReviewDraft

public struct ReviewDraft: Codable, Equatable, Sendable, Identifiable {
  public init(id: String = UUID().uuidString, comment: InlineComment) {
    self.id = id
    self.comment = comment
  }

  public let id: String
  public var comment: InlineComment
}

// MARK: - ReviewSessionState

public struct ReviewSessionState: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public var drafts = [ReviewDraft]()
  public var reviewedFiles = Set<String>()
  public var reviewedHunks = Set<String>()
  public var summary = ""
  public var event = ReviewEvent.comment

  public func validate() throws {
    guard
      drafts.count <= 128,
      Set(drafts.map(\.id)).count == drafts.count,
      drafts.allSatisfy({ !$0.id.isEmpty && $0.comment.body.utf8.count <= 65536 }),
      summary.utf8.count <= 65536,
      drafts.reduce(summary.utf8.count, { $0 + $1.comment.body.utf8.count }) <= 8 * 1024 * 1024,
      reviewedFiles.count <= 20000,
      reviewedHunks.count <= 20000,
      reviewedFiles.allSatisfy({ $0.utf8.count <= 4096 }),
      reviewedHunks.allSatisfy({ $0.utf8.count <= 8192 })
    else { throw TataraError(.unavailable, detail: "The saved review exceeds its storage limit.") }
  }

}

// MARK: - ReviewSessionChange

public enum ReviewSessionChange: Sendable {
  case add(ReviewDraft)
  case update(String, InlineComment, expectedBody: String? = nil)
  case remove(String, expectedBody: String? = nil)
  case markFile(String, Bool)
  case markHunk(String, Bool)
  case summary(String, ReviewEvent)
  case submitted([ReviewDraft], String)

  // MARK: Public

  public func apply(to state: inout ReviewSessionState) throws {
    switch self {
    case .add(let draft):
      guard !state.drafts.contains(where: { $0.id == draft.id }) else { throw TataraError(.invalidResponse) }
      state.drafts.append(draft)

    case .update(let id, let comment, let expectedBody):
      guard let index = state.drafts.firstIndex(where: { $0.id == id }) else { throw TataraError(.revisionChanged) }
      if let expectedBody, state.drafts[index].comment.body != expectedBody {
        throw TataraError(
          .revisionChanged,
          detail: "This draft changed in another editor. Reload the review before editing it.",
        )
      }
      state.drafts[index].comment = comment

    case .remove(let id, let expectedBody):
      guard state.drafts.contains(where: { $0.id == id }) else { throw TataraError(.revisionChanged) }
      if let expectedBody, state.drafts.first(where: { $0.id == id })?.comment.body != expectedBody {
        throw TataraError(
          .revisionChanged,
          detail: "This draft changed in another editor. Reload the review before removing it.",
        )
      }
      state.drafts.removeAll { $0.id == id }

    case .markFile(let path, let reviewed):
      if reviewed {
        state.reviewedFiles.insert(path)
      } else {
        state.reviewedFiles.remove(path)
      }

    case .markHunk(let id, let reviewed):
      if reviewed {
        state.reviewedHunks.insert(id)
      } else {
        state.reviewedHunks.remove(id)
      }

    case .summary(let text, let event): state.summary = text
      state.event = event

    case .submitted(let drafts, let body):
      state.drafts.removeAll { drafts.contains($0) }
      if state.summary == body {
        state.summary = ""
      }
    }
    try state.validate()
  }
}

// MARK: - ReviewHunk

public struct ReviewHunk: Codable, Equatable, Sendable {
  public let id: String
  public let path: String
  public let oldStart: Int
  public let oldCount: Int
  public let newStart: Int
  public let newCount: Int

  public static func all(in files: [ChangedFile]) -> [Self] {
    var result = [Self]()
    for file in files { result.append(contentsOf: parse(file)) }
    return result
  }

  public static func parse(_ file: ChangedFile) -> [Self] {
    (file.patch ?? "").split(separator: "\n").compactMap { row in
      guard row.hasPrefix("@@ ") else { return nil }
      let fields = row.split(separator: " ")
      guard fields.count >= 4, fields[3] == "@@" else { return nil }
      func range(_ text: Substring, _ prefix: Character) -> (Int, Int)? {
        guard text.first == prefix else { return nil }
        let parts = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard
          !parts.isEmpty,
          parts.count <= 2,
          let start = Int(parts[0]),
          start >= 0,
          let count = parts.count == 2 ? Int(parts[1]) : 1,
          count >= 0,
          start <= Int.max - count
        else { return nil }
        return (start, count)
      }
      guard let old = range(fields[1], "-"), let new = range(fields[2], "+") else { return nil }
      let id = "\(file.path.utf8.count):\(file.path):\(old.0),\(old.1):\(new.0),\(new.1)"
      return Self(id: id, path: file.path, oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1)
    }
  }
}

// MARK: - ReviewExport

public enum ReviewExport {
  public static func markdown(identity: ReviewSessionIdentity, state: ReviewSessionState) -> String {
    var result = "# Review · \(identity.repository.slug)#\(identity.number)\n\n"
    result += "Head: \(identity.head)\nMerge base: \(identity.mergeBase)\n\n"
    if !state.summary.isEmpty {
      result += state.summary + "\n\n"
    }
    for (index, draft) in state.drafts.enumerated() {
      let comment = draft.comment
      let range = comment.startLine.map { "\($0)-\(comment.line)" } ?? "\(comment.line)"
      result += "## \(index + 1). \(comment.path):\(range) · \(comment.side.rawValue)\n\n\(comment.body)\n\n"
    }
    return result
  }
}

// MARK: - SavedReviewSummary

public struct SavedReviewSummary: Codable, Sendable {
  public init(id: String, identity: ReviewSessionIdentity, updatedAt: Double, drafts: Int, reviewed: Int, excerpt: String) {
    self.id = id
    self.identity = identity
    self.updatedAt = updatedAt
    self.drafts = drafts
    self.reviewed = reviewed
    self.excerpt = excerpt
  }

  public let id: String
  public let identity: ReviewSessionIdentity
  public let updatedAt: Double
  public let drafts: Int
  public let reviewed: Int
  public let excerpt: String
}

// MARK: - ReviewFileComment

public struct ReviewFileComment: Codable, Equatable, Sendable {
  public init(path: String, body: String) {
    self.path = path
    self.body = body
  }

  public let path: String
  public let body: String
}
