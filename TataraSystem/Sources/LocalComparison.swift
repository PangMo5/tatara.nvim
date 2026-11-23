// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TataraCore
import TataraKit

public struct LocalComparison: Sendable {

  // MARK: Public

  public let root: URL
  public let repository: RepositoryID

  public var item: ForgeItem {
    .init(
      id: .init(repository: repository, number: 0),
      kind: .localComparison,
      title: root.lastPathComponent,
      author: "",
      url: root,
    )
  }

  public var client: ForgeClient {
    ForgeClient(
      detail: { requested in
        guard requested.id == item.id, requested.kind == .localComparison else { throw TataraError(.invalidResponse) }
        return try await detail()
      },
      content: { requested, revision, path in
        guard requested == repository, Self.isObjectID(revision), !path.utf8.contains(0) else {
          throw TataraError(.invalidResponse)
        }
        return try await Self.git(["--git-dir", directory, "cat-file", "blob", revision + ":" + path]).output
      },
    )
  }

  @concurrent
  public static func discover(source: String, base: String, includeWorktree: Bool) async throws -> Self {
    let result = try await git(["-C", source, "rev-parse", "--show-toplevel"])
    let root = URL(fileURLWithPath: try path(result), isDirectory: true).resolvingSymlinksInPath()
    let common = try await git(["-C", root.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
    let directory = try path(common)
    let repository = try identity(gitDirectory: directory)
    return Self(root: root, repository: repository, directory: directory, base: base, includeWorktree: includeWorktree)
  }

  // MARK: Internal

  static func identity(gitDirectory: String) throws -> RepositoryID {
    let path = URL(fileURLWithPath: gitDirectory, isDirectory: true).resolvingSymlinksInPath().path
    let id = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    return try RepositoryID("git/" + id, host: "localhost", forge: .local)
  }

  static func isObjectID(_ value: String) -> Bool {
    (value.utf8.count == 40 || value.utf8.count == 64) && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  static func offlineRunner(_ runner: CommandRunner) -> CommandRunner {
    CommandRunner { executable, arguments, input in
      guard executable == "git" else { return try await runner.run(executable, arguments, input) }
      return try await runner.run("git", ["--no-lazy-fetch", "--no-replace-objects"] + arguments, input)
    }
  }

  // MARK: Private

  private let directory: String
  private let base: String
  private let includeWorktree: Bool

  @concurrent
  private static func git(_ arguments: [String]) async throws -> CommandResult {
    try await offlineRunner(.live).checked("git", arguments)
  }

  private static func path(_ result: CommandResult) throws -> String {
    guard
      result.output.last == 10,
      let value = String(data: result.output.dropLast(), encoding: .utf8),
      value.hasPrefix("/")
    else {
      throw TataraError(.invalidResponse, detail: "Invalid local Git repository path.")
    }
    return value
  }

  private static func files(_ data: Data) throws -> [ChangedFile] {
    guard !data.isEmpty else { return [] }
    guard let boundary = data.range(of: Data([0, 0])), boundary.upperBound < data.endIndex else {
      throw TataraError(.invalidResponse, detail: "Invalid Git raw diff and patch boundary.")
    }
    // Git emits the NUL-delimited raw records and then a patch for each record in the same order.
    let payload = data[boundary.upperBound...]
    var patches = [[Data.SubSequence]]()
    for line in payload.split(separator: 10, omittingEmptySubsequences: false) {
      if line.starts(with: "diff --git ".utf8) {
        patches.append([])
      }
      guard !patches.isEmpty else { throw TataraError(.invalidResponse, detail: "Missing Git patch header.") }
      patches[patches.count - 1].append(line)
    }
    var patchRecords = patches.makeIterator()
    var remaining = data[..<boundary.lowerBound].split(separator: 0).makeIterator()
    func readPath() throws -> String {
      guard let field = remaining.next(), let path = String(data: field, encoding: .utf8), !path.isEmpty else {
        throw TataraError(.invalidResponse, detail: "The Git diff contains an invalid or non-UTF-8 path.")
      }
      return path
    }
    var files = [ChangedFile]()
    while let record = remaining.next() {
      try Task.checkCancellation()
      guard record.first == 58, var lines = patchRecords.next() else { throw TataraError(.invalidResponse) }
      let fields = String(decoding: record.dropFirst(), as: UTF8.self).split(separator: " ")
      guard fields.count == 5 else { throw TataraError(.invalidResponse) }
      let first = try readPath()
      let status: String
      switch fields[4].first {
      case "A": status = "added"

      case "D": status = "removed"

      case "R": status = "renamed"

      case "M": status = "modified"

      case "T":
        guard let replacement = patchRecords.next() else { throw TataraError(.invalidResponse) }
        lines.append(contentsOf: replacement)
        status = "modified"

      default: throw TataraError(.invalidResponse, detail: "Unsupported local Git diff status.")
      }
      let renamed = status == "renamed"
      let path = renamed ? try readPath() : first
      let binary = lines.contains { $0.starts(with: "Binary files ".utf8) || $0.contains(0) }
      let regular = fields.prefix(2).allSatisfy { $0 == "000000" || $0 == "100644" || $0 == "100755" }
      let hunkLines = lines.drop { !$0.starts(with: "@@ ".utf8) }
      // Patch text indexes coordinates only. Source buffers retain the original bytes.
      let patch = hunkLines.lazy.map {
        String(decoding: $0.last == 13 ? $0.dropLast() : $0, as: UTF8.self)
      }.joined(separator: "\n")
      files.append(.init(
        path: path,
        previousPath: renamed ? first : nil,
        status: status,
        additions: hunkLines.count { $0.first == 43 },
        deletions: hunkLines.count { $0.first == 45 },
        patch: !binary && regular && !patch.isEmpty ? patch : nil,
        isNonSource: binary || !regular ? true : nil,
      ))
    }
    guard patchRecords.next() == nil, Set(files.map(\.path)).count == files.count else {
      throw TataraError(.invalidResponse, detail: "Git raw records and patches do not match.")
    }
    return files
  }

  @concurrent
  private func snapshot(head: String) async throws -> String {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent("tatara-index-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temporary) }
    let index = temporary.appendingPathComponent("index")
    let location = try await Self.git(["-C", root.path, "rev-parse", "--path-format=absolute", "--git-path", "index"])
    let original = URL(fileURLWithPath: try Self.path(location))
    let runner = Self.offlineRunner(CommandRunner { executable, arguments, input in
      try await CommandRunner.live.run("/usr/bin/env", [
        "GIT_INDEX_FILE=" + index.path,
        "GIT_AUTHOR_NAME=Tatara",
        "GIT_AUTHOR_EMAIL=tatara@localhost",
        "GIT_AUTHOR_DATE=@0 +0000",
        "GIT_COMMITTER_NAME=Tatara",
        "GIT_COMMITTER_EMAIL=tatara@localhost",
        "GIT_COMMITTER_DATE=@0 +0000",
        executable,
      ] + arguments, input)
    })
    // Retain tracked paths, staged additions and sparse entries from the user's index.
    // All updates run against the private copy; Git's clean filters apply as for a normal commit.
    if fm.fileExists(atPath: original.path) {
      try fm.copyItem(at: original, to: index)
    }
    let arguments = ["-C", root.path, "-c", "core.splitIndex=false", "-c", "core.fsmonitor=false"]
    _ = try await runner.checked("git", arguments + ["add", "--all", "--", "."])
    let tree = try await runner.checked("git", arguments + ["write-tree"]).text.trimmingCharacters(in: .newlines)
    let headTree = try await Self.git(["--git-dir", directory, "rev-parse", head + "^{tree}"]).text
      .trimmingCharacters(in: .newlines)
    let current = try await Self.git(["-C", root.path, "rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .newlines)
    guard current == head else {
      throw TataraError(.revisionChanged, detail: "HEAD changed during worktree capture. Refresh to try again.")
    }
    guard Self.isObjectID(tree), Self.isObjectID(headTree) else { throw TataraError(.invalidResponse) }
    if tree == headTree {
      return head
    }
    // Identical content and parent produce the same snapshot without creating a branch or reflog entry.
    let commit = try await runner.checked("git", arguments + [
      "commit-tree",
      tree,
      "-p",
      head,
      "--no-gpg-sign",
      "-m",
      "Tatara worktree snapshot",
    ]).text.trimmingCharacters(in: .newlines)
    guard Self.isObjectID(commit) else { throw TataraError(.invalidResponse) }
    return commit
  }

  @concurrent
  private func detail() async throws -> ItemDetail {
    let prefix = ["--git-dir", directory]
    let branchHead = try await Self.git(["-C", root.path, "rev-parse", "--verify", "HEAD^{commit}"]).text
      .trimmingCharacters(in: .newlines)
    let target = try await Self.git(["-C", root.path, "rev-parse", "--verify", "--end-of-options", base + "^{commit}"]).text
      .trimmingCharacters(in: .newlines)
    guard Self.isObjectID(branchHead), Self.isObjectID(target) else { throw TataraError(.invalidResponse) }
    let mergeBase = try await Self.git(prefix + ["merge-base", "--all", target, branchHead]).text
      .trimmingCharacters(in: .newlines)
    guard Self.isObjectID(mergeBase) else {
      throw TataraError(.configuration, detail: "The local comparison requires a single merge base.")
    }
    let head = try await includeWorktree ? snapshot(head: branchHead) : branchHead
    let result = try await Self.git(prefix + [
      "--attr-source=" + head,
      "-c",
      "diff.suppressBlankEmpty=false",
      "diff",
      "--raw",
      "-z",
      "--patch",
      "--find-renames",
      "--ignore-submodules=none",
      "--submodule=short",
      "--no-color",
      "--no-ext-diff",
      "--no-textconv",
      "--src-prefix=a/",
      "--dst-prefix=b/",
      "--output-indicator-new=+",
      "--output-indicator-old=-",
      "--output-indicator-context= ",
      "--unified=3",
      "--inter-hunk-context=0",
      mergeBase,
      head,
      "--",
    ])
    return try .init(
      item: item,
      revision: .init(mergeBase: mergeBase, head: head),
      files: Self.files(result.output),
      metadata: .localComparison(.init(base: base, head: "HEAD", worktreeParent: includeWorktree ? branchHead : nil)),
    )
  }

}
