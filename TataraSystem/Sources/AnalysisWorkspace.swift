// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Darwin
import Foundation
import Subprocess
import TataraCore

public struct AnalysisWorkspace: Equatable, Sendable {

  // MARK: Public

  public let directory: URL
  public let commit: String

  @concurrent
  public static func prepare(
    context: AnalysisContext,
    configuration: AnalysisConfiguration,
    profile: AnalysisServerProfile,
    scope: String,
    cacheDirectory: URL? = nil,
    runner: CommandRunner = .live,
    configureBuildSettings: Bool = true,
    progress: @Sendable (AnalysisPhase) async -> Void = { _ in },
  ) async throws -> Self {
    await progress(.preparingCheckout)
    let requestedSource = configuration.repositoryDirectory ?? FileManager.default.currentDirectoryPath
    let root = try await runner.checked("git", ["-C", requestedSource, "rev-parse", "--show-toplevel"])
    let source = root.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let remotes = try await runner.checked("git", ["-C", source, "config", "--get-regexp", "^remote\\..*\\.url$"])
    let matches = remotes.text.split(separator: "\n").contains { line in
      guard let space = line.firstIndex(where: \.isWhitespace) else { return false }
      return LocalGitReader.matchesRemote(String(line[line.index(after: space)...]), repository: context.item.repository)
    }
    guard matches else { throw TataraError(
      .configuration,
      detail: "The analysis repository does not match the reviewed forge, host and repository. Configure analysis.repository_directory.",
    ) }
    let commit = context.commit
    guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { throw TataraError(
      .invalidResponse,
      detail: "Analysis requires an exact commit identity.",
    ) }
    let resolved = try await runner.checked("git", ["-C", source, "rev-parse", "--verify", commit + "^{commit}"])
    guard resolved.text.trimmingCharacters(in: .whitespacesAndNewlines) == commit else { throw TataraError(.revisionChanged) }
    let cache = cacheDirectory ?? ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
    guard profile.setupInputs.count <= 16 else { throw TataraError(
      .configuration,
      detail: "Analysis setup_inputs exceeds sixteen files.",
    ) }
    var fingerprints = [String]()
    for path in profile.setupInputs {
      let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).resolvingSymlinksInPath()
      let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 2 * 1024 * 1024 else { throw TataraError(
        .configuration,
        detail: "Analysis setup_inputs require regular files no larger than 2 MiB.",
      ) }
      let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
      fingerprints.append(url.path + ":" + digest)
    }
    let identity = try scope + "|" + context.item.repository.description + "|" + commit + "|" + String(
      decoding: canonicalAnalysisJSON(profile),
      as: UTF8.self,
    ) + "|" + fingerprints.joined(separator: "|")
    let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    let parent = cache.appendingPathComponent("tatara/analysis-workspaces")
    let resource = parent.appendingPathComponent(key)
    let directory = resource.appendingPathComponent("checkout")
    let ready = resource.appendingPathComponent("ready.json")
    let fm = FileManager.default
    if !fm.fileExists(atPath: directory.path) {
      try fm.createDirectory(at: parent, withIntermediateDirectories: true)
      let entries = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
      guard entries.count < 8 else { throw TataraError(
        .unavailable,
        detail: "The eight-workspace analysis limit is reached. Remove unused managed worktrees before preparing another revision.",
      ) }
      try fm.createDirectory(at: resource, withIntermediateDirectories: true)
      _ = try await runner.checked(
        "git",
        ["-C", source, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", directory.path, commit],
      )
    }
    let existingHead = try await runner.checked("git", ["-C", directory.path, "rev-parse", "HEAD"])
    let existingChanges = try await runner.checked("git", ["-C", directory.path, "status", "--porcelain", "--untracked-files=no"])
    guard existingHead.text.trimmingCharacters(in: .whitespacesAndNewlines) == commit, existingChanges.output.isEmpty else {
      throw TataraError(
        .revisionChanged,
        detail: "The managed analysis checkout is incomplete or modified. Preserve any local changes and remove this managed worktree before preparing it again.",
      )
    }
    if !configureBuildSettings {
      return Self(directory: directory, commit: commit)
    }
    let hasProvider = ["Package.swift", "buildServer.json", "compile_commands.json"]
      .contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
    if !fm.fileExists(atPath: ready.path) || profile.requiresBuildSettings && !hasProvider, let command = profile.setupCommand {
      await progress(.runningSetup)
      let arguments = command.map {
        $0.replacing("{workspace}", with: directory.path)
          .replacing("{source}", with: source)
          .replacing("{revision}", with: commit)
          .replacing("{repository}", with: context.item.repository.description)
      }
      try await runHook(arguments, directory: directory)
    }
    let actual = try await runner.checked("git", ["-C", directory.path, "rev-parse", "HEAD"])
    guard actual.text.trimmingCharacters(in: .whitespacesAndNewlines) == commit else { throw TataraError(
      .revisionChanged,
      detail: "The analysis checkout no longer matches the reviewed commit.",
    ) }
    let dirty = try await runner.checked("git", ["-C", directory.path, "status", "--porcelain", "--untracked-files=no"])
    guard dirty.output.isEmpty else { throw TataraError(
      .revisionChanged,
      detail: "The analysis setup changed tracked source files.",
    ) }
    if profile.requiresBuildSettings {
      let supported = ["Package.swift", "buildServer.json", "compile_commands.json"]
        .contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
      guard supported else { throw TataraError(
        .configuration,
        detail: "No build-settings provider was discovered. Configure analysis.servers.setup_command to produce a BSP connection specification for this checkout. LSP does not define Xcode project or scheme selection.",
      ) }
    }
    try Data(commit.utf8).write(to: ready, options: .atomic)
    return Self(directory: directory, commit: commit)
  }

  @concurrent
  public func canonicalDirectory() async throws -> String {
    guard let path = realpath(directory.path, nil) else {
      throw TataraError(.unavailable, detail: "Could not resolve the immutable checkout: " + String(cString: strerror(errno)))
    }
    defer { free(path) }
    return String(cString: path)
  }

  public func relativePath(_ uri: String) -> String? {
    guard let url = URL(string: uri), url.isFileURL else { return nil }
    let root = directory.resolvingSymlinksInPath().path + "/"
    let path = url.resolvingSymlinksInPath().path
    guard path.hasPrefix(root) else { return nil }
    return String(path.dropFirst(root.count))
  }

  @concurrent
  public func text(path: String, runner: CommandRunner = .live) async throws -> String {
    guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw TataraError(
      .invalidResponse,
      detail: "Analysis location escaped its immutable checkout.",
    ) }
    let entry = try await runner.checked("git", ["-C", directory.path, "ls-tree", commit, "--", path])
    guard entry.text.hasPrefix("100644 ") || entry.text.hasPrefix("100755 ") else {
      throw TataraError(
        .unavailable,
        detail: "Analysis navigation requires a tracked regular source file in the reviewed commit.",
      )
    }
    let data = try await runner.checked("git", ["-C", directory.path, "show", commit + ":" + path]).output
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw TataraError(
      .unavailable,
      detail: "Analysis source is not UTF-8 text.",
    ) }
    return text
  }

  // MARK: Private

  @concurrent
  private static func runHook(_ command: [String], directory: URL) async throws {
    guard let executable = command.first else { throw TataraError(.configuration, detail: "Empty analysis setup command.") }
    var options = PlatformOptions()
    options.createSession = true
    options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(1))]
    let result = try await Subprocess.run(
      executable.contains("/") ? .path(.init(executable)) : .name(executable),
      arguments: Arguments(Array(command.dropFirst())),
      workingDirectory: .init(directory.path),
      platformOptions: options,
      output: .string(limit: 65536),
      error: .string(limit: 65536),
    )
    guard case .exited(0) = result.terminationStatus else { throw TataraError(.commandFailed, detail: result.standardError) }
  }

}
