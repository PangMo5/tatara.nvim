// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraSystem
import Testing

struct AnalysisPreparationTests {

  // MARK: Internal

  @Test
  func `setup clones only ignored inputs and leaves user source unchanged`() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try plan(f, inputs: [".inputs"], argv: ["/usr/bin/touch", "{workspace}/.prepared"])
    try await AnalysisPreparation.run(
      planURL: f.plan,
      source: f.source,
      workspace: f.workspace,
      repository: "github.com/owner/repo",
      revision: f.revision,
    )
    #expect(try String(contentsOf: f.workspace.appendingPathComponent(".inputs/data"), encoding: .utf8) == "build input")
    #expect(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent(".prepared").path))
    #expect(!FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".prepared").path))
    #expect(try String(contentsOf: f.source.appendingPathComponent("Source.swift"), encoding: .utf8) == "original\n")
    let status = try await CommandRunner.live.checked(
      "git",
      ["-C", f.workspace.path, "status", "--porcelain", "--untracked-files=no"],
    )
    #expect(status.output.isEmpty)
  }

  @Test(arguments: ["Source.swift", "../outside", ".git/config"])
  func `setup refuses tracked or escaping copy inputs`(_ input: String) async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try plan(f, inputs: [input], argv: ["/usr/bin/touch", "{workspace}/.prepared"])
    await #expect(throws: TataraError.self) {
      try await AnalysisPreparation.run(
        planURL: f.plan,
        source: f.source,
        workspace: f.workspace,
        repository: "github.com/owner/repo",
        revision: f.revision,
      )
    }
    #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent(".prepared").path))
  }

  @Test
  func `setup reports source changes without restoring or hiding them`() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try plan(f, inputs: [".inputs"], argv: ["/bin/cp", "{workspace}/.inputs/data", "{workspace}/Source.swift"])
    await #expect(throws: TataraError.self) {
      try await AnalysisPreparation.run(
        planURL: f.plan,
        source: f.source,
        workspace: f.workspace,
        repository: "github.com/owner/repo",
        revision: f.revision,
      )
    }
    #expect(try String(contentsOf: f.workspace.appendingPathComponent("Source.swift"), encoding: .utf8) == "build input")
    #expect(try String(contentsOf: f.source.appendingPathComponent("Source.swift"), encoding: .utf8) == "original\n")
  }

  @Test
  func `setup refuses a plan supplied by the reviewed checkout`() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try plan(f, inputs: [], argv: ["/usr/bin/touch", "{workspace}/.prepared"])
    let unsafe = f.workspace.appendingPathComponent("plan.json")
    try FileManager.default.copyItem(at: f.plan, to: unsafe)
    await #expect(throws: TataraError.self) {
      try await AnalysisPreparation.run(
        planURL: unsafe,
        source: f.source,
        workspace: f.workspace,
        repository: "github.com/owner/repo",
        revision: f.revision,
      )
    }
  }

  @Test
  func `setup input contents participate in workspace identity`() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try "first".write(to: f.plan, atomically: true, encoding: .utf8)
    let item = try ItemID(repository: RepositoryID("owner/repo"), number: 1)
    let context = AnalysisContext(
      item: item,
      revision: .init(mergeBase: f.revision, head: f.revision),
      path: "Source.swift",
      side: .right,
      line: 1,
      column: 0,
    )
    let configuration = AnalysisConfiguration(repositoryDirectory: f.source.path)
    let profile = AnalysisServerProfile(setupInputs: [f.plan.path], requiresBuildSettings: false)
    let first = try await AnalysisWorkspace.prepare(
      context: context,
      configuration: configuration,
      profile: profile,
      scope: "fixture",
      cacheDirectory: f.root.appendingPathComponent("cache"),
    )
    try "second".write(to: f.plan, atomically: true, encoding: .utf8)
    let second = try await AnalysisWorkspace.prepare(
      context: context,
      configuration: configuration,
      profile: profile,
      scope: "fixture",
      cacheDirectory: f.root.appendingPathComponent("cache"),
    )
    #expect(first.directory != second.directory)
  }

  @Test
  func `repository profiles isolate Xcode toolchains and preserve explicit choice`() throws {
    let base = AnalysisServerProfile()
    let project = AnalysisServerProfile(id: "project", repositories: ["github.example.com/owner/repo"])
    var configuration = AnalysisConfiguration(servers: [base, project])
    #expect(try configuration.server(repository: RepositoryID("owner/repo", host: "github.example.com"), path: "A.swift")
      .id == "project")
    #expect(try configuration.server(repository: RepositoryID("owner/repo"), path: "A.swift").id == "swift")
    configuration.profile = "swift"
    #expect(try configuration.server(repository: RepositoryID("owner/repo", host: "github.example.com"), path: "A.swift")
      .id == "swift")
  }

  // MARK: Private

  private struct Fixture {
    let root: URL
    let source: URL
    let workspace: URL
    let revision: String
    let plan: URL
  }

  private func fixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-prepare-\(UUID())")
    let source = root.appendingPathComponent("repository")
    let workspace = root.appendingPathComponent("checkout")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try "original\n".write(to: source.appendingPathComponent("Source.swift"), atomically: true, encoding: .utf8)
    try ".inputs\n.prepared\n".write(to: source.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    let runner = CommandRunner.live
    for args in [
      ["init", "--quiet"],
      ["config", "user.name", "Fixture"],
      ["config", "user.email", "fixture@example.invalid"],
      ["remote", "add", "origin", "https://github.com/owner/repo.git"],
      ["add", "."],
      ["commit", "--quiet", "-m", "Fixture"],
    ] {
      _ = try await runner.checked("git", ["-C", source.path] + args)
    }
    let revision = try await runner.checked("git", ["-C", source.path, "rev-parse", "HEAD"]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await runner.checked("git", ["-C", source.path, "worktree", "add", "--detach", workspace.path, revision])
    try FileManager.default.createDirectory(at: source.appendingPathComponent(".inputs"), withIntermediateDirectories: true)
    try "build input".write(to: source.appendingPathComponent(".inputs/data"), atomically: true, encoding: .utf8)
    return .init(
      root: root,
      source: source,
      workspace: workspace,
      revision: revision,
      plan: root.appendingPathComponent("plan.json"),
    )
  }

  private func plan(_ fixture: Fixture, inputs: [String], argv: [String]) throws {
    let value: [String: Any] = ["projects": ["github.com/owner/repo": [
      "inputs": inputs,
      "commands": [["argv": argv]],
      "environment": ["SDKROOT": NSNull()],
    ]]]
    try JSONSerialization.data(withJSONObject: value).write(to: fixture.plan)
  }

}
