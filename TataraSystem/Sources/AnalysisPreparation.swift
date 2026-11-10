// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Subprocess
import TataraCore

/// User-owned setup plans prepare ignored build inputs without changing reviewed source.
public enum AnalysisPreparation {

  // MARK: Public

  public struct Plan: Decodable, Sendable {
    public init(from decoder: any Decoder) throws {
      try rejectUnknown(decoder, allowed: ["projects"])
      let c = try decoder.container(keyedBy: CodingKeys.self)
      projects = try c.decode([String: Project].self, forKey: .projects)
    }

    public var projects: [String: Project]

    enum CodingKeys: String, CodingKey { case projects }
  }

  public struct Project: Decodable, Sendable {
    public init(from decoder: any Decoder) throws {
      try rejectUnknown(decoder, allowed: ["inputs", "commands", "environment"])
      let c = try decoder.container(keyedBy: CodingKeys.self)
      inputs = try c.decodeIfPresent([String].self, forKey: .inputs)
      commands = try c.decode([Command].self, forKey: .commands)
      environment = try c.decodeIfPresent([String: String?].self, forKey: .environment)
    }

    public var inputs: [String]?
    public var commands: [Command]
    public var environment: [String: String?]?

    enum CodingKeys: String, CodingKey { case inputs, commands, environment }
  }

  public struct Command: Decodable, Sendable {
    public init(from decoder: any Decoder) throws {
      try rejectUnknown(decoder, allowed: ["argv", "environment"])
      let c = try decoder.container(keyedBy: CodingKeys.self)
      argv = try c.decode([String].self, forKey: .argv)
      environment = try c.decodeIfPresent([String: String?].self, forKey: .environment)
    }

    public var argv: [String]
    public var environment: [String: String?]?

    enum CodingKeys: String, CodingKey { case argv, environment }
  }

  @concurrent
  public static func run(planURL: URL, source: URL, workspace: URL, repository: String, revision: String) async throws {
    let fm = FileManager.default
    let source = source.resolvingSymlinksInPath()
    let workspace = workspace.resolvingSymlinksInPath()
    guard source != workspace, !planURL.resolvingSymlinksInPath().path.hasPrefix(workspace.path + "/") else {
      throw TataraError(.configuration, detail: "The analysis plan must be user-owned and outside the immutable checkout.")
    }
    let attributes = try planURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 2 * 1024 * 1024 else { throw TataraError(
      .configuration,
      detail: "Analysis plans must be regular files no larger than 2 MiB.",
    ) }
    let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
    let matches = plan.projects.filter { $0.key.lowercased() == repository.lowercased() }
    guard matches.count <= 1
    else { throw TataraError(.configuration, detail: "Multiple preparation plans match this repository.") }
    guard let project = matches.first?.value else { return }
    guard (project.inputs?.count ?? 0) <= 32, project.commands.count <= 16 else { throw TataraError(
      .configuration,
      detail: "Analysis plans are limited to 32 ignored inputs and 16 commands.",
    ) }
    let runner = CommandRunner.live
    let actual = try await runner.checked("git", ["-C", workspace.path, "rev-parse", "HEAD"])
    guard actual.text.trimmingCharacters(in: .whitespacesAndNewlines) == revision else { throw TataraError(.revisionChanged) }
    let sourceGit = try await runner.checked(
      "git",
      ["-C", source.path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
    )
    let targetGit = try await runner.checked(
      "git",
      ["-C", workspace.path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
    )
    guard sourceGit.text == targetGit.text else { throw TataraError(
      .configuration,
      detail: "Preparation inputs must come from the same local repository as the reviewed checkout.",
    ) }
    for relative in project.inputs ?? [] {
      try Task.checkCancellation()
      guard
        !relative.isEmpty,
        !relative.hasPrefix("/"),
        !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == ".git" })
      else {
        throw TataraError(.configuration, detail: "Preparation inputs require repository-relative ignored paths.")
      }
      let input = source.appendingPathComponent(relative)
      let output = workspace.appendingPathComponent(relative)
      guard try input.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw TataraError(
        .configuration,
        detail: "Preparation inputs must not be symbolic-link roots.",
      ) }
      guard
        input.resolvingSymlinksInPath().path.hasPrefix(source.path + "/"),
        output.resolvingSymlinksInPath().path.hasPrefix(workspace.path + "/")
      else {
        throw TataraError(.configuration, detail: "Preparation input escaped its checkout through a symlink.")
      }
      for root in [source, workspace] {
        _ = try await runner.checked("git", ["-C", root.path, "check-ignore", "--quiet", "--", relative])
        let tracked = try await runner.checked("git", ["-C", root.path, "ls-files", "--", relative])
        guard tracked.output.isEmpty else { throw TataraError(
          .configuration,
          detail: "Preparation must not copy tracked source: " + relative,
        ) }
      }
      if fm.fileExists(atPath: output.path) {
        continue
      }
      guard fm.fileExists(atPath: input.path) else { throw TataraError(
        .configuration,
        detail: "A configured preparation input is missing: " + relative,
      ) }
      try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      let staging = workspace.deletingLastPathComponent().appendingPathComponent(".input-" + UUID().uuidString)
      defer { try? fm.removeItem(at: staging) }
      let copied = try await Subprocess.run(
        .path(.init("/bin/cp")),
        arguments: Arguments(["-cRp", input.path, staging.path]),
        output: .string(limit: 65536),
        error: .string(limit: 65536),
      )
      guard case .exited(0) = copied.terminationStatus else { throw TataraError(.commandFailed, detail: copied.standardError) }
      try Task.checkCancellation()
      try fm.moveItem(at: staging, to: output)
    }
    func expand(_ value: String) -> String {
      value.replacing("{workspace}", with: workspace.path)
        .replacing("{source}", with: source.path)
        .replacing("{repository}", with: repository)
        .replacing("{revision}", with: revision)
    }
    let log = workspace.deletingLastPathComponent().appendingPathComponent("preparation.log")
    var history = Data()
    for (index, command) in project.commands.enumerated() {
      try Task.checkCancellation()
      guard let first = command.argv.first, !first.isEmpty else { throw TataraError(
        .configuration,
        detail: "Preparation commands require an executable argument.",
      ) }
      let argv = command.argv.map(expand)
      var environment = ProcessInfo.processInfo.environment
      for overrides in [project.environment ?? [:], command.environment ?? [:]] {
        for (key, value) in overrides {
          if let value {
            environment[key] = expand(value)
          } else {
            environment.removeValue(forKey: key)
          }
        }
      }
      let result = try await Subprocess.run(
        argv[0].contains("/") ? .path(.init(argv[0])) : .name(argv[0]),
        arguments: Arguments(Array(argv.dropFirst())),
        environment: .custom(Dictionary(uniqueKeysWithValues: environment.map { (
          Environment.Key(stringLiteral: $0.key),
          $0.value,
        ) })),
        workingDirectory: .init(workspace.path),
        output: .string(limit: 4 * 1024 * 1024),
        error: .string(limit: 4 * 1024 * 1024),
      )
      history
        .append(contentsOf: ("Step \(index + 1)/\(project.commands.count)\n" + result.standardOutput + "\n" + result
            .standardError + "\n").utf8)
      if history.count > 8 * 1024 * 1024 {
        history = Data(history.suffix(8 * 1024 * 1024))
      }
      try history.write(to: log, options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
      try Task.checkCancellation()
      guard case .exited(0) = result.terminationStatus else {
        throw TataraError(
          .commandFailed,
          detail: "Analysis preparation step \(index + 1) failed. See \(log.path).\n" + String((result.standardError.isEmpty
              ? result.standardOutput
              : result.standardError).suffix(6000)),
        )
      }
    }
    let final = try await runner.checked("git", ["-C", workspace.path, "rev-parse", "HEAD"])
    guard final.text == actual.text else { throw TataraError(
      .revisionChanged,
      detail: "The preparation command switched the reviewed revision.",
    ) }
    let dirty = try await runner.checked("git", ["-C", workspace.path, "status", "--porcelain", "--untracked-files=no"])
    guard dirty.output.isEmpty else { throw TataraError(
      .revisionChanged,
      detail: "The preparation command changed tracked source in the reviewed checkout.",
    ) }
  }

  // MARK: Private

  private struct Key: CodingKey {
    init?(stringValue: String) {
      self.stringValue = stringValue
    }

    init?(intValue _: Int) {
      nil
    }

    let stringValue: String

    var intValue: Int? {
      nil
    }
  }

  private static func rejectUnknown(_ decoder: any Decoder, allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: Key.self)
    let unknown = c.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else { throw TataraError(
      .configuration,
      detail: "Unknown preparation keys: " + unknown.joined(separator: ", "),
    ) }
  }

}
