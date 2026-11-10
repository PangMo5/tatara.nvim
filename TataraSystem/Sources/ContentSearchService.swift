// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraKit

public enum ContentSearchService {
  public static func fileFinder(forge: ForgeClient) -> FileFinderClient {
    .init(search: { try await FilePathSearch.ranked($0, query: $1) }, preview: { detail, path in
      guard let file = detail.file(at: path), let document = try await prepare(
        .init(item: detail.item, revision: detail.revision, files: [file]),
        forge: forge,
      ).first else {
        throw TataraError(.unavailable, detail: "No text preview is available for this file.")
      }
      return document
    })
  }

  public static func client(forge: ForgeClient) -> ContentSearchClient {
    .init(prepare: { try await prepare($0, forge: forge) }, search: { try await search($0, query: $1, mode: $2) })
  }

  @concurrent
  public static func prepare(_ detail: ItemDetail, forge: ForgeClient) async throws -> [FileContentDocument] {
    guard let revision = detail.revision else { throw TataraError(
      .unavailable,
      detail: "Content search requires immutable revisions.",
    ) }
    return try await withThrowingTaskGroup(of: (Int, FileContentDocument?, Int).self) { group in
      var iterator = detail.files.enumerated().makeIterator()
      var documents = [Int: FileContentDocument]()
      var total = 0
      func enqueue(_ index: Int, _ file: ChangedFile) {
        group.addTask {
          let side: InlineComment.Side = file.status == "removed" ? .left : .right
          let data = try await forge.content(
            detail.item.id.repository,
            side == .left ? revision.mergeBase : revision.head,
            file.path,
          )
          try Task.checkCancellation()
          guard data.count <= 32 * 1024 * 1024 else { throw TataraError(
            .invalidResponse,
            detail: "File exceeds the 32 MiB content search limit: \(file.path)",
          ) }
          guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return (index, nil, 0) }
          return (
            index,
            FileContentDocument(
              path: file.path,
              side: side,
              lines: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
            ),
            data.count,
          )
        }
      }
      for _ in 0..<4 {
        if let (i, file) = iterator.next() {
          enqueue(i, file)
        }
      }
      while let (i, document, bytes) = try await group.next() {
        total += bytes
        guard total <= 64 * 1024 * 1024 else { throw TataraError(
          .invalidResponse,
          detail: "Content search exceeds the 64 MiB snapshot limit.",
        ) }
        documents[i] = document
        if let (i, file) = iterator.next() {
          enqueue(i, file)
        }
      }
      return documents.keys.sorted().compactMap { documents[$0] }
    }
  }

  @concurrent
  public static func search(
    _ documents: [FileContentDocument],
    query: String,
    mode: ContentSearchMode,
  ) async throws -> [FileContentHit] {
    guard !query.isEmpty else { return [] }
    let lines = documents.flatMap { document in document.lines.enumerated().map { (
      document.path,
      document.side,
      $0.offset + 1,
      $0.element,
    ) } }
    let matches: [(Int, [Range<Int>])]
    if mode == .fuzzy {
      matches = try await FilePathSearch.fuzzyText(lines.map(\.3), query: query).map { ($0.index, $0.ranges) }
    } else {
      let pattern = try SearchPattern(mode == .plain ? "(?i)" + NSRegularExpression.escapedPattern(for: query) : query)
      var found = [(Int, [Range<Int>])]()
      for (index, line) in lines.enumerated() {
        try Task.checkCancellation()
        let ranges = try pattern.ranges(in: line.3)
        if !ranges.isEmpty {
          found.append((index, ranges))
        }
        guard found.count <= 10_000 else { throw TataraError(
          .invalidResponse,
          detail: "Content search exceeds 10,000 matching lines.",
        ) }
      }
      matches = found
    }
    guard matches.count <= 10_000 else { throw TataraError(
      .invalidResponse,
      detail: "Content search exceeds 10,000 matching lines.",
    ) }
    return try matches.map { index, ranges in
      try Task.checkCancellation()
      let (path, side, number, text) = lines[index]
      let raw = text as NSString
      let first = ranges.first?.lowerBound ?? 0
      var start = max(0, first - 40)
      var end = min(raw.length, max(first + 160, start + 200))
      if start > 0, (0xDC00...0xDFFF).contains(raw.character(at: start)) {
        start -= 1
      }
      if end < raw.length, (0xDC00...0xDFFF).contains(raw.character(at: end)) {
        end += 1
      }
      return FileContentHit(
        location: .init(path: path, line: number, side: side),
        excerpt: raw.substring(with: NSRange(location: start, length: end - start)),
        ranges: ranges.compactMap { range in let lower = max(start, range.lowerBound)
          let upper = min(end, range.upperBound)
          return lower < upper ? (lower - start)..<(upper - start) : nil
        },
        column: first,
      )
    }
  }
}
