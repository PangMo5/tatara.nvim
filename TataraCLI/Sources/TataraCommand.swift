// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ArgumentParser
import Darwin
import Foundation
import TataraBridge
import TataraCore
import TataraSystem

// MARK: - TataraCommand

@main
struct TataraCommand: AsyncParsableCommand {

  // MARK: Internal

  static let configuration = CommandConfiguration(
    commandName: "tatara",
    abstract: "Open tatara.nvim in Neovim, or serve its Swift backend.",
    version: TataraVersion.current,
    subcommands: [Serve.self, AnalysisPreparationCommand.self],
  )

  @Option(name: .shortAndLong)
  var repo: String?
  @Option var host: String?
  @Option var number: Int?
  @Option(help: "Plugin runtime directory (development override).")
  var runtime: String?
  @Flag var demo = false
  @Flag(help: "Open the current branch's pull request, or choose a pull request if absent (the default).")
  var current = false
  @Flag(help: "Open the detailed repository item selector.")
  var list = false
  @Flag(help: "Browse repository issues instead of pull requests.")
  var issues = false
  @Option(help: "UI language: en, ko, ja, zh-Hans, zh-Hant.")
  var language: String?
  @Option(help: "Neovim colorscheme; Catppuccin flavor names select catppuccin-FLAVOR.")
  var theme: String?
  @Option(help: "Files pane layout: tree or list.")
  var filesView: String?
  @Option(help: "Files sidebar width, at least 24 columns.")
  var sidebarWidth: Int?
  @Option(help: "Wrap source lines: on or off.")
  var wrap: String?
  @Flag(help: "Keep Tatara's loading artwork still.")
  var reduceMotion = false
  @Flag(help: "Use stable Tatara presentation for captures.")
  var stableOutput = false
  @Flag(help: "Use the native editor cursor and suppress Tatara animation.")
  var accessible = false

  mutating func validate() throws {
    if let language, !Language.allCases.map(\.rawValue).contains(language) {
      throw ValidationError("Unknown UI language.")
    }
    if let filesView, !["tree", "list"].contains(filesView) {
      throw ValidationError("--files-view must be tree or list.")
    }
    if let sidebarWidth, sidebarWidth < 24 {
      throw ValidationError("--sidebar-width must be at least 24.")
    }
    if let wrap, !["on", "off"].contains(wrap) {
      throw ValidationError("--wrap must be on or off.")
    }
    if let number, number <= 0 {
      throw ValidationError("--number must be positive.")
    }
    if current, list || issues || repo != nil {
      throw ValidationError("--current cannot be combined with --list, --issues or --repo.")
    }
  }

  func run() async throws {
    var options = [String: RPCValue]()
    options["list"] = .bool(list || ((issues || repo != nil) && number == nil))
    options["kind"] = .string(issues ? "issue" : "pullRequest")
    if reduceMotion || stableOutput || accessible {
      options["reduce_motion"] = .bool(true)
    }
    if let language {
      options["language"] = .string(language)
    }
    if let theme {
      options["colorscheme"] = .string(["latte", "frappe", "macchiato", "mocha"].contains(theme)
        ? "catppuccin-" + theme
        : theme)
    }
    if let filesView {
      options["files_view"] = .string(filesView)
    }
    if let sidebarWidth {
      options["sidebar_width"] = .number(Double(sidebarWidth))
    }
    if let wrap {
      options["wrap"] = .bool(wrap == "on")
    }
    try await Self.launch(repo: repo, host: host, number: number, runtime: runtime, demo: demo, overrides: options)
  }

  // MARK: Private

  @concurrent
  private static func launch(
    repo: String?,
    host: String?,
    number: Int?,
    runtime: String?,
    demo: Bool,
    overrides: [String: RPCValue],
  ) async throws {
    guard let executable = Bundle.main.executableURL else { throw TataraError(
      .configuration,
      detail: "Could not locate the backend executable.",
    ) }
    let directory = executable.deletingLastPathComponent()
    let candidates = [
      runtime.map { URL(fileURLWithPath: $0) },
      directory.appendingPathComponent("runtime"),
      directory.deletingLastPathComponent().appendingPathComponent("share/tatara/runtime"),
    ].compactMap { $0 }
    guard
      let plugin = candidates
        .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("lua/tatara/init.lua").path) })
    else {
      throw TataraError(
        .configuration,
        detail: "The Neovim plugin runtime is missing. Install it beside the backend or pass --runtime.",
      )
    }
    var options: [String: RPCValue] = ["demo": .bool(demo), "cwd": .string(FileManager.default.currentDirectoryPath)]
    options.merge(overrides) { _, new in new }
    if let repo {
      options["repository"] = .string(repo)
    }
    if let host {
      options["host"] = .string(host)
    }
    if let number {
      options["number"] = .number(Double(number))
    }
    let environment = [
      "TATARA_RUNTIME": plugin.path,
      "TATARA_BACKEND": executable.path,
      "TATARA_OPEN": String(decoding: try JSONEncoder().encode(RPCValue.object(options)), as: UTF8.self),
    ]
    for (name, value) in environment {
      guard setenv(name, value, 1) == 0 else { throw TataraError(
        .configuration,
        detail: "Could not set the Neovim launch environment.",
      ) }
    }
    let arguments = [
      "nvim",
      "--cmd",
      "lua vim.opt.rtp:prepend(vim.env.TATARA_RUNTIME)",
      "-c",
      "lua require('tatara').start(vim.json.decode(vim.env.TATARA_OPEN))",
    ]
    // Replace the foreground job, preserving its controlling terminal and signals.
    var argv = arguments.map { strdup($0) } + [nil]
    defer { for argument in argv { free(argument) } }
    let result = argv.withUnsafeMutableBufferPointer { execvp("nvim", $0.baseAddress!) }
    guard result != -1 else { throw TataraError(
      .commandFailed,
      detail: "Could not execute Neovim: " + String(cString: strerror(errno)),
    ) }
  }

}

// MARK: - Serve

struct Serve: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Serve newline-framed JSON-RPC on stdin/stdout.")

  func run() async throws {
    try await RPCTransport.run()
  }
}
