// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

@main
struct Smoke {
  static func main() {
    do { try run() } catch { fputs("\(error)\n", stderr)
      exit(1)
    }
  }

  static func run() throws {
    if CommandLine.arguments.count == 4, CommandLine.arguments[3] == "--audit-ui" {
      try auditUI()
      return
    }
    if CommandLine.arguments.count == 4, ["--capture-reference", "--capture-workbench"].contains(CommandLine.arguments[3]) {
      try capture(reference: CommandLine.arguments[3] == "--capture-reference")
      return
    }
    guard CommandLine.arguments.count == 3 else { throw SmokeError("Expected backend and Neovim executable paths.") }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let backend = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let nvim = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let socket = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-pty-\(UUID()).sock")
    let artifacts = root.appendingPathComponent(".artifacts/neovim-pty")
    let t = try PTY(
      binary: nvim,
      arguments: [
        "--clean",
        "-u",
        root.appendingPathComponent("tests/nvim/pty_init.lua").path,
        "-i",
        "NONE",
        "--listen",
        socket.path,
        "--cmd",
        "lua vim.opt.rtp:prepend(vim.env.TATARA_SOURCE_ROOT)",
      ],
      columns: 176,
      rows: 48,
      environment: ["TATARA_TEST_BACKEND": backend.path, "TATARA_SOURCE_ROOT": root.path],
      cwd: root,
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Keep review navigation within bounds")
    try t.wait("Sources/Selection.swift")
    try t.screenshot("combined-review")
    t.key("jj\r")
    try t.wait(" · RIGHT")
    try t.wait("guard files.indices")
    try t.waitUntil("native source cursor") { t.isCursorVisible && t.cursorCell.x > t.columns / 2 && t.cursorCell.y < t.rows - 3 }
    let origin = t.cursorCell
    var timings = [Double]()
    for _ in 0..<24 {
      for (key, delta) in [("l", 1), ("h", 0)] {
        let start = ProcessInfo.processInfo.systemUptime
        t.key(key)
        try t
          .waitUntil("Neovim cursor movement") {
            t.isCursorVisible && t.cursorCell.x == origin.x + delta && t.cursorCell.y == origin.y
          }
        timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      }
    }
    try t.screenshot("native-review")
    t.key("\u{17}h")
    try t.waitUntil("native window movement") { t.cursorCell.x < origin.x }
    t.key("\u{17}l")
    try t.waitUntil("native head window") { t.cursorCell.x == origin.x }
    t.key("gFG\r")
    try t.wait("Sources/Selection.swift · RIGHT")
    t.key("\u{0f}")
    try t.wait("Sources/ReviewQueue.swift · RIGHT")
    t.key("\t")
    try t.wait("Sources/Selection.swift · RIGHT")
    t.key("\u{0f}")
    try t.wait("Sources/ReviewQueue.swift · RIGHT")
    t.key("c")
    try t.wait("Write your review")
    t.key("A comment from the native Neovim PTY.\u{1b}:write\r")
    try t.wait("Pending review")
    try t.waitUntil("inline editor closed") { !t.text.contains("Write your review") }
    t.key("R")
    try t.wait("Request changes")
    t.key("A summary from the native Neovim PTY.\u{1b}:write\r")
    try t.wait("This will be posted to GitHub.")
    try t.wait("A comment from the native Neovim PTY.")
    try t.screenshot("write-preview")
    t.key("q\u{1b}")
    try t.wait(" · RIGHT")
    try t.waitUntil("source restored") { t.cursorCell.x == origin.x && t.cursorCell.y == origin.y }
    t.resize(columns: 80, rows: 32)
    let geometry = Process()
    let output = Pipe()
    geometry.executableURL = nvim
    geometry.arguments = ["--server", socket.path, "--remote-expr", "json_encode([&columns,&lines])"]
    geometry.standardOutput = output
    geometry.standardError = FileHandle.nullDevice
    try geometry.run()
    geometry.waitUntilExit()
    let size = try JSONDecoder().decode([Int].self, from: output.fileHandleForReading.readDataToEndOfFile())
    try expect(size == [80, 32], "Neovim did not receive the PTY resize: \(size)")
    try t.wait("ReviewQueue.swift")
    t.key("gFG\r")
    try t.wait("Sources/Selection.swift")
    try t.wait("5 −")
    try t.wait("5 +")
    try t.screenshot("native-review-narrow")
    t.key(":qa!\r")
    try t.finish()
    timings.sort()
    let result: [String: Any] = [
      "samples": timings.count,
      "p95_ms": timings[Int(ceil(Double(timings.count) * 0.95)) - 1],
      "max_ms": timings.last!,
      "workload": "Warm immutable two-file demo, native Neovim source h/l, 176x48; combined root, native window moves, draft/preview, 80x32 resize and unified diff",
      "forge_writes": 0,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: artifacts.appendingPathComponent("latency.json"))
    try launcher(backend, nvim: nvim, root: root)
    print(
      "Release Neovim PTY passed: combined root, native source/window movement, local comment, exact write preview, narrow unified source and clean exit; no forge writes."
    )
  }

  static func capture(reference: Bool) throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let backend = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let nvim = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let emptyConfig = root.appendingPathComponent(".artifacts/ux-reset-20261113/reference-config.toml")
    try "".write(to: emptyConfig, atomically: true, encoding: .utf8)
    let args = reference
      ? ["--demo", "--current", "--stable-output", "--config", emptyConfig.path]
      : [
        "--clean",
        "-u",
        root.appendingPathComponent("tests/nvim/pty_init.lua").path,
        "-i",
        "NONE",
        "--cmd",
        "lua vim.opt.rtp:prepend(vim.env.TATARA_SOURCE_ROOT)",
      ]
    let path = root.appendingPathComponent(".artifacts/ux-reset-20261113/" + (reference ? "reference" : "workbench"))
    for phase in reference ? ["workspace", "comment", "review"] : ["workspace", "comment", "review", "selection", "filters"] {
      let t = try PTY(
        binary: reference ? backend : nvim,
        arguments: args,
        columns: 176,
        rows: 48,
        environment: ["TATARA_TEST_BACKEND": backend.path, "TATARA_SOURCE_ROOT": root.path],
        cwd: root,
        artifacts: path,
      )
      defer { t.close() }
      try t.wait("Keep review navigation within bounds")
      try t.wait("Ready")
      if !reference {
        try t.wait("Sources/Selection.swift")
      }
      if phase == "comment" {
        t.key("ggjj\r")
        if reference {
          try t.wait("Normal · Diff")
          t.key("jjjc")
        } else {
          try t.wait(" · RIGHT")
          try t.waitUntil("source cursor") { t.cursorCell.x > t.columns / 2 }
          t.key("c")
        }
        try t.wait("Write your review")
      } else if phase == "review" {
        t.key("R")
        try t.wait("Finish review")
      } else if phase == "selection" {
        t.key("\u{10}")
        try t.wait("Pull requests")
        try t.wait("Preview")
      } else if phase == "filters" {
        t.key("f")
        try t.wait("GitHub search query")
        try t.wait("Presets")
        try t.wait("Labels")
      }
      try t.screenshot(phase)
      t.key(reference ? "\u{1b}\u{1b}q" : "\u{1b}\u{1b}:qa!\r")
    }
  }

  static func launcher(_ backend: URL, nvim: URL, root: URL) throws {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appendingPathComponent("tatara-launcher-\(UUID())")
    let config = fixture.appendingPathComponent("config/nvim")
    try fm.createDirectory(at: config, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }
    let initLua = """
      vim.g.tatara_fixture_loaded = true
      vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()
        vim.schedule(function() vim.cmd.tabnew(); vim.api.nvim_buf_set_lines(0,0,-1,false,{'Restored user session'}) end)
      end })
      require('tatara').setup({ layout = { sidebar_width = 27 } })
      vim.api.nvim_create_autocmd('User', { pattern = 'TataraReady', callback = function()
        local context = require('tatara').get_context()
        local result = { user_config = vim.g.tatara_fixture_loaded, width = vim.api.nvim_win_get_width(context.windows.files), repository = context.repository, foreground = vim.api.nvim_get_current_tabpage() == context.tab, entered = vim.v.vim_did_enter }
        vim.fn.writefile({vim.json.encode(result)}, vim.env.TATARA_LAUNCH_RESULT)
      end })
      """
    try initLua.write(to: config.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    let result = fixture.appendingPathComponent("result.json")
    let t = try PTY(
      binary: backend,
      arguments: ["--demo"],
      environment: [
        "PATH": nvim.deletingLastPathComponent().path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
        "XDG_CONFIG_HOME": fixture.appendingPathComponent("config").path,
        "XDG_DATA_HOME": fixture.appendingPathComponent("data").path,
        "XDG_CACHE_HOME": fixture.appendingPathComponent("cache").path,
        "XDG_STATE_HOME": fixture.appendingPathComponent("state").path,
        "TATARA_LAUNCH_RESULT": result.path,
      ],
      cwd: root,
      artifacts: root.appendingPathComponent(".artifacts/neovim-launcher-pty"),
    )
    defer { t.close() }
    try t.wait("Keep review navigation within bounds")
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any]
    else { throw SmokeError("Launcher did not load Neovim user configuration.") }
    try expect(
      value["user_config"] as? Bool == true && value["width"] as? Int == 27 && value["foreground"] as? Bool == true &&
        value["entered"] as? Int == 1,
      "Launcher must honor user configuration and open the foreground review after session restoration.",
    )
    try t.screenshot("launcher")
    t.key(":qa!\r")
    try t.finish()
    print("Installed entry point passed: user configuration, setup options and foreground review after session restoration.")
  }
}
