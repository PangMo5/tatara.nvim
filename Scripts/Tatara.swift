#!/usr/bin/env swift
// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Darwin
import Foundation

// MARK: - ToolError

struct ToolError: Error, CustomStringConvertible {
  init(_ message: String) {
    description = message
  }

  var description: String
}

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
var environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

func require(_ condition: Bool, _ message: String) throws {
  if !condition {
    throw ToolError(message)
  }
}

func path(_ name: String) -> URL {
  root.appendingPathComponent(name)
}

func read(_ url: URL) throws -> String {
  try String(contentsOf: url, encoding: .utf8)
}

func write(_ text: String, _ url: URL) throws {
  try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try text.write(to: url, atomically: true, encoding: .utf8)
}

func json(_ url: URL) throws -> [String: Any] {
  guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  else { throw ToolError("Invalid JSON: \(url.path)") }
  return value
}

@discardableResult
func run(
  _ command: String,
  _ args: [String] = [],
  cwd: URL = root,
  capture: Bool = false,
  output: URL? = nil,
  secret: Bool = false,
  mergeStandardError: Bool = false,
) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [command] + args
  process.currentDirectoryURL = cwd
  process.environment = environment
  // A temporary file avoids pipe-capacity deadlocks for large command output.
  let directory = try temporary("command")
  defer { try? fm.removeItem(at: directory) }
  let destination = output ?? directory.appendingPathComponent("stdout")
  var handle: FileHandle?
  if capture || output != nil {
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: destination.path, contents: nil)
    handle = try FileHandle(forWritingTo: destination)
    process.standardOutput = handle
    if mergeStandardError {
      process.standardError = handle
    }
  }
  defer { try? handle?.close() }
  try process.run()
  process.waitUntilExit()
  try require(
    process.terminationStatus == 0,
    "\(command) failed with status \(process.terminationStatus)\(secret ? "" : ": " + args.joined(separator: " "))",
  )
  return capture ? try read(destination) : ""
}

func temporary(_ name: String) throws -> URL {
  let value = fm.temporaryDirectory.appendingPathComponent("tatara-\(name)-\(UUID().uuidString)")
  try fm.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return value
}

@discardableResult

func version() throws -> String {
  let source = try read(path("TataraCore/Sources/TataraVersion.swift"))
  let regex = try NSRegularExpression(pattern: #"(?m)^  public static let current = "(\d+\.\d+\.\d+)"$"#)
  guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), let range = Range(
    match.range(at: 1),
    in: source,
  ) else { throw ToolError("TataraVersion.current must declare a semantic version.") }
  return String(source[range])
}

func digest(_ url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hasher = SHA256()
  while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
    hasher.update(data: data)
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func swiftLiteral(_ text: String) throws -> String {
  let encoded = try String(decoding: JSONEncoder().encode(text), as: UTF8.self)
  return encoded.replacing("\\/", with: "/")
}

func generated(_ text: String, at url: URL, check: Bool) throws {
  if check {
    try require(read(url) == text, "Generated file is stale: \(url.lastPathComponent)")
  } else if (try? read(url)) != text {
    try write(text, url)
  }
}

func notices(check: Bool) throws {
  guard let pins = try json(path("Package.resolved"))["pins"] as? [[String: Any]]
  else { throw ToolError("Missing package pins.") }
  var sources = pins.map { ($0, path(".build/checkouts/\($0["identity"] as? String ?? "")")) }
  let fff = try json(path("ThirdParty/FFFBridge/upstream.json"))
  sources.append(([
    "identity": "fff-search-components",
    "location": fff["repository"] as? String ?? "",
    "state": ["revision": fff["revision"] as? String ?? ""],
  ], path("ThirdParty/FFFBridge")))
  if
    fm.fileExists(atPath: path("Scripts/NvimSmoke/Package.resolved").path),
    let helperPins = try json(path("Scripts/NvimSmoke/Package.resolved"))["pins"] as? [[String: Any]]
  {
    for pin in helperPins where !sources.contains(where: { $0.0["identity"] as? String == pin["identity"] as? String }) {
      sources.append((pin, path("Scripts/NvimSmoke/.build/checkouts/\(pin["identity"] as? String ?? "")")))
    }
  }
  var parts = [
    "# Third-Party Notices",
    "",
    "Tatara is licensed under AGPL-3.0-only. Dependencies retain their own licenses.",
    "Versions below come from Package.resolved, Scripts/NvimSmoke/Package.resolved, Native/FFFBridge/Cargo.lock and the vendored upstream.json records. Notices include build dependencies and vendored components.",
    "",
    "<!-- REUSE-IgnoreStart -->",
    "",
  ]
  for (pin, sourceDirectory) in sources {
    guard
      let identity = pin["identity"] as? String,
      let location = pin["location"] as? String,
      let state = pin["state"] as? [String: String],
      let revision = state["revision"]
    else { throw ToolError("Invalid dependency pin.") }
    let directory = sourceDirectory.resolvingSymlinksInPath()
    guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { throw ToolError("Run swift Scripts/Tatara.swift resolve first.") }
    var files = [URL]()
    for case let file as URL in enumerator {
      if file.pathComponents.contains(".git") {
        enumerator.skipDescendants()
        continue
      }
      let name = file.lastPathComponent.uppercased().components(separatedBy: ".")[0]
      if
        ["LICENSE", "LICENCE", "NOTICE", "COPYING"].contains(name),
        try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
      {
        files.append(file)
      }
    }
    try require(!files.isEmpty, "No license found for \(identity)")
    let heading = state["version"].map { "\(identity) \($0)" } ?? identity
    parts += ["## \(heading)", "", "Source: \(location)", "", "Revision: `\(revision)`", ""]
    for file in files.sorted(by: { $0.path < $1.path }) {
      try parts += [
        "### \(file.path.dropFirst(directory.path.count + 1))",
        "",
        "~~~~text",
        read(file).trimmingCharacters(in: .whitespacesAndNewlines),
        "~~~~",
        "",
      ]
    }
    if identity == "swift-toml" {
      let header = try read(directory.appendingPathComponent("Sources/CTomlPlusPlus/toml.hpp"))
      parts += [
        "### Vendored toml++",
        "",
        "~~~~text",
        header.components(separatedBy: "#ifndef")[0].trimmingCharacters(in: .whitespacesAndNewlines),
        "~~~~",
        "",
      ]
    }
  }
  try parts += [
    "## Swift compatibility runtime",
    "",
    "Source: https://github.com/swiftlang/swift/blob/swift-6.4.2-RELEASE/LICENSE.txt",
    "",
    "The pinned Swift 6.4.2 toolchain supplies libswiftCompatibilitySpan.dylib. Installation and release archives include it alongside the executable when required.",
    "",
    "~~~~text",
    read(path("ThirdParty/SwiftRuntime.txt")).trimmingCharacters(in: .whitespacesAndNewlines),
    "~~~~",
    "",
    "## Catppuccin palette",
    "",
    "Source: https://github.com/catppuccin/catppuccin",
    "",
    "~~~~text",
    read(path("ThirdParty/Catppuccin.txt")).trimmingCharacters(in: .whitespacesAndNewlines),
    "~~~~",
    "",
    "<!-- REUSE-IgnoreEnd -->",
    "",
  ]
  try generated(parts.joined(separator: "\n"), at: path("THIRD_PARTY_NOTICES.md"), check: check)
  print("Validated notices for \(sources.count) packages, the Swift runtime and Catppuccin.")
}

func checkTests(_ url: URL) throws {
  let text = try read(url)
  let regex = try NSRegularExpression(pattern: #"Test run with (\d+) tests? (?:in \d+ suites? )?passed"#)
  guard
    let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
    let range = Range(match.range(at: 1), in: text),
    let count = Int(text[range]),
    count > 0
  else { throw ToolError("No nonzero successful Swift Testing run found.") }
  print("Confirmed \(count) executed Swift Testing tests.")
}

func runtimeLibraries(for binary: URL, architecture: String? = nil) throws -> [String] {
  let flags = architecture.map { ["-arch", $0] } ?? []
  let dependencies = try run("otool", flags + ["-L", binary.path], capture: true)
    .components(separatedBy: "\n").dropFirst()
    .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
  var libraries = [String]()
  for dependency in dependencies {
    if dependency.hasPrefix("/usr/lib/") || dependency.hasPrefix("/System/Library/") {
      continue
    }
    try require(
      dependency == "@rpath/libswiftCompatibilitySpan.dylib",
      "Unexpected non-system dynamic dependency: \(dependency)",
    )
    libraries.append(URL(fileURLWithPath: dependency).lastPathComponent)
  }
  return libraries
}

func runtimeFiles(in directory: URL, architecture: String? = nil) throws -> [URL] {
  let binary = directory.appendingPathComponent("tatara")
  let files = try [binary] + runtimeLibraries(for: binary, architecture: architecture)
    .map { directory.appendingPathComponent($0) }
  for file in files {
    try require(
      fm.fileExists(atPath: file.path),
      "Missing runtime file: \(file.path). Run swift Scripts/Tatara.swift build Release.",
    )
  }
  return files
}

func prepareRuntime(in directory: URL) throws {
  let binary = directory.appendingPathComponent("tatara")
  let libraries = try runtimeLibraries(for: binary)
  if !libraries.isEmpty {
    try run("xcrun", [
      "swift-stdlib-tool",
      "--copy",
      "--scan-executable",
      binary.path,
      "--platform",
      "macosx",
      "--destination",
      directory.path,
    ])
  }
  for file in try runtimeFiles(in: directory).dropFirst() {
    try run("codesign", ["--force", "--sign", "-", file.path])
    try run("codesign", ["--verify", "--strict", file.path])
  }
  let commands = try run("otool", ["-l", binary.path], capture: true)
  let regex = try NSRegularExpression(pattern: #"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+) \(offset \d+\)"#)
  let paths = regex.matches(in: commands, range: NSRange(commands.startIndex..., in: commands)).compactMap { match in
    Range(match.range(at: 1), in: commands).map { String(commands[$0]) }
  }
  try require(libraries.isEmpty || paths.contains("@loader_path"), "Swift runtime requires a loader-relative search path.")
  for path in paths where path != "/usr/lib/swift" && path != "@loader_path" {
    try run("install_name_tool", ["-delete_rpath", path, binary.path])
  }
}

func toolchain(requiresReleaseBuild: Bool = false) throws {
  let xcode = try run("xcodebuild", ["-version"], capture: true)
  let compiler = try run("swift", ["--version"], capture: true)
  let sdk = try run("xcrun", ["--sdk", "macosx", "--show-sdk-version"], capture: true)
  print(xcode, terminator: "")
  print(compiler, terminator: "")
  print("macOS SDK: \(sdk)", terminator: "")
  try require(xcode.hasPrefix("Xcode 27.2\n"), "Tatara requires Xcode 27.2. Select it with DEVELOPER_DIR.")
  try require(compiler.contains("Swift version 6.4.2"), "Tatara requires the Xcode 27.2 Swift 6.4.2 compiler.")
  try require(sdk.trimmingCharacters(in: .whitespacesAndNewlines) == "27.2", "Tatara requires the macOS 27.2 SDK.")
  if requiresReleaseBuild {
    try require(xcode.contains("Build version 27B52"), "Binary releases require the stable Xcode 27.2 build 27B52.")
  }
  let sdkRoot = try run("xcrun", ["--sdk", "macosx", "--show-sdk-path"], capture: true)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  try require(sdkRoot.hasPrefix("/") && sdkRoot.hasSuffix(".sdk"), "xcrun must report an absolute macOS SDK path.")
  environment["SDKROOT"] = sdkRoot
  print("macOS SDK path: \(sdkRoot)")
}

func buildArguments(_ configuration: String, architecture: String? = nil) throws -> [String] {
  let configuration = configuration.lowercased()
  try require(["debug", "release"].contains(configuration), "Expected debug or release configuration.")
  var args = ["--configuration", configuration]
  if let architecture {
    try require(["arm64", "x86_64"].contains(architecture), "Unsupported architecture: \(architecture)")
    // Preserve each dependency's deployment target; the root manifest owns macOS 15.
    args += ["--arch", architecture]
  }
  return args
}

func swiftProducts(_ configuration: String = "release", architecture: String? = nil, packagePath: String? = nil) throws -> URL {
  var args = try buildArguments(configuration, architecture: architecture)
  if let packagePath {
    args += ["--package-path", packagePath]
  }
  let output = try run("swift", ["build"] + args + ["--show-bin-path"], capture: true)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  try require(!output.isEmpty, "SwiftPM did not report a products directory.")
  return URL(fileURLWithPath: output)
}

func products(_ configuration: String = "release", architecture: String? = nil) throws -> URL {
  let architecture = try architecture ?? run("uname", ["-m"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
  _ = try buildArguments(configuration, architecture: architecture)
  return path(".artifacts/products/\(configuration.lowercased())-\(architecture)")
}

func validateBuildMetadata(_ binary: URL) throws {
  let data = try Data(run("swift", ["package", "dump-package"], capture: true).utf8)
  guard
    let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let platforms = manifest["platforms"] as? [[String: Any]],
    let minimum = platforms.first(where: { $0["platformName"] as? String == "macos" })?["version"] as? String
  else { throw ToolError("Package.swift must declare the macOS deployment target.") }
  let expectedSDK = try run("xcrun", ["--sdk", "macosx", "--show-sdk-version"], capture: true)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let commands = try run("otool", ["-l", binary.path], capture: true)
  let regex = try NSRegularExpression(
    pattern: #"cmd LC_BUILD_VERSION\n\s+cmdsize \d+\n\s+platform 1\n\s+minos ([\d.]+)\n\s+sdk ([\d.]+)"#
  )
  guard
    let match = regex.firstMatch(in: commands, range: NSRange(commands.startIndex..., in: commands)),
    let minimumRange = Range(match.range(at: 1), in: commands),
    let sdkRange = Range(match.range(at: 2), in: commands)
  else { throw ToolError("The executable must contain macOS build metadata.") }
  try require(commands[minimumRange] == minimum, "Executable deployment target does not match Package.swift.")
  try require(commands[sdkRange] == expectedSDK, "Executable SDK metadata does not match the selected macOS SDK.")
  print("Validated Mach-O deployment target \(minimum), SDK \(expectedSDK).")
}

func build(_ configuration: String, architecture: String? = nil) throws {
  try toolchain()
  try localizations(check: true)
  let args = try buildArguments(configuration, architecture: architecture)
  try run("swift", ["build", "--force-resolved-versions", "--product", "tatara"] + args)
  let source = try swiftProducts(configuration, architecture: architecture).appendingPathComponent("tatara")
  let stage = try temporary("runtime")
  defer { try? fm.removeItem(at: stage) }
  let binary = stage.appendingPathComponent("tatara")
  try fm.copyItem(at: source, to: binary)
  try validateBuildMetadata(binary)
  try prepareRuntime(in: stage)
  try copyPlugin(to: stage.appendingPathComponent("runtime"))
  try run("codesign", ["--force", "--sign", "-", "--identifier", "dev.PangMo5.tatara", binary.path])
  let directory = try products(configuration, architecture: architecture)
  try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
  if fm.fileExists(atPath: directory.path) {
    try fm.removeItem(at: directory)
  }
  try fm.moveItem(at: stage, to: directory)
  print("Prepared runtime at \(directory.path).")
}

func nativePackageTarget(runtime: URL) throws -> URL {
  let value = try run(
    "nvim",
    ["--headless", "--clean", "-i", "NONE", "-c", "lua io.stdout:write(vim.json.encode(vim.fn.stdpath('data')))", "-c", "qa"],
    capture: true,
  )
  let directory = try JSONDecoder().decode(String.self, from: Data(value.utf8))
  let target = URL(fileURLWithPath: directory).appendingPathComponent("site/pack/tatara/start/tatara.nvim")
  let attributes = try? fm.attributesOfItem(atPath: target.path)
  if attributes != nil {
    guard
      let link = try? fm.destinationOfSymbolicLink(atPath: target.path),
      URL(fileURLWithPath: link).standardizedFileURL == runtime.standardizedFileURL
    else {
      throw ToolError("A different native Tatara package already exists at " + target
        .path + ". Preserve it and configure your preferred installation explicitly.")
    }
  }
  return target
}

func installLocal(products: URL, prefix: URL) throws {
  let source = products.appendingPathComponent("tatara")
  let runtime = try runtimeFiles(in: products)
  for file in runtime {
    try run("codesign", ["--verify", "--strict", file.path])
  }
  try require(
    run(source.path, ["--version"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines) == version(),
    "Built version does not match TataraVersion.current.",
  )
  let bin = prefix.appendingPathComponent("bin")
  let share = prefix.appendingPathComponent("share/tatara")
  let installedRuntime = share.appendingPathComponent("runtime")
  let nativePackage = try nativePackageTarget(runtime: installedRuntime)
  try fm.createDirectory(at: bin, withIntermediateDirectories: true)
  try fm.createDirectory(at: share, withIntermediateDirectories: true)
  let staged = bin.appendingPathComponent(".tatara-\(UUID())")
  defer { try? fm.removeItem(at: staged) }
  try fm.copyItem(at: source, to: staged)
  for file in runtime.dropFirst() {
    let stagedLibrary = bin.appendingPathComponent(".\(file.lastPathComponent)-\(UUID())")
    defer { try? fm.removeItem(at: stagedLibrary) }
    try fm.copyItem(at: file, to: stagedLibrary)
    try require(
      rename(stagedLibrary.path, bin.appendingPathComponent(file.lastPathComponent).path) == 0,
      "Atomic runtime library replacement failed: \(errno)",
    )
  }
  for name in ["LICENSE", "LICENSES", "THIRD_PARTY_NOTICES.md", "README.md", "CONTRIBUTING.md", "docs"] {
    let destination = share.appendingPathComponent(name)
    if fm.fileExists(atPath: destination.path) {
      try fm.removeItem(at: destination)
    }
    try fm.copyItem(at: path(name), to: destination)
  }
  try copyPlugin(to: installedRuntime)
  try run("nvim", ["--headless", "--clean", "-i", "NONE", "-c", "helptags doc", "-c", "qa"], cwd: installedRuntime)
  try require(
    fm.fileExists(atPath: installedRuntime.appendingPathComponent("doc/tags").path),
    "Neovim did not generate help tags for the installed runtime.",
  )
  try fm.createDirectory(at: nativePackage.deletingLastPathComponent(), withIntermediateDirectories: true)
  if !fm.fileExists(atPath: nativePackage.path) {
    try fm.createSymbolicLink(at: nativePackage, withDestinationURL: installedRuntime)
  }
  let metadata: [String: Any] = try [
    "source": root.path,
    "source_commit": run("git", ["rev-parse", "HEAD"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines),
    "source_modified": !run("git", ["status", "--porcelain"], capture: true).isEmpty,
    "version": version(),
    "kind": "local-release-build",
    "sha256": digest(staged),
    "runtime_libraries": runtime.dropFirst().map { try ["name": $0.lastPathComponent, "sha256": digest($0)] },
    "updated_at": ISO8601DateFormatter().string(from: Date()),
  ]
  try require(
    rename(staged.path, bin.appendingPathComponent("tatara").path) == 0,
    "Atomic executable replacement failed: \(errno)",
  )
  try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    .write(to: share.appendingPathComponent("installation.json"), options: .atomic)
  try print("Installed \(version()) at \(bin.path). Native Neovim package: \(nativePackage.path).")
}

func copyPlugin(to destination: URL) throws {
  try fm.createDirectory(at: destination, withIntermediateDirectories: true)
  for name in ["lua", "plugin", "doc"] {
    let target = destination.appendingPathComponent(name)
    if fm.fileExists(atPath: target.path) {
      try fm.removeItem(at: target)
    }
    try fm.copyItem(at: path(name), to: target)
  }
}

func localizations(check: Bool) throws {
  let catalog = try json(path("SharedResources/Localizable.xcstrings"))
  guard let strings = catalog["strings"] as? [String: [String: Any]] else { throw ToolError("Missing catalog strings.") }
  var output = [String: [String: String]]()
  for lang in ["en", "ko", "ja", "zh-Hans", "zh-Hant"] {
    for (key, entry) in strings {
      guard
        let values = entry["localizations"] as? [String: [String: Any]],
        let unit = values[lang]?["stringUnit"] as? [String: String],
        unit["state"] == "translated",
        let value = unit["value"],
        !value.isEmpty
      else { throw ToolError("Missing translation: \(lang)/\(key)") }
      output[lang, default: [:]][key] = value
    }
  }
  let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
  let literal = try swiftLiteral(String(decoding: data, as: UTF8.self))
  let text =
    "-- Generated by Scripts/Tatara.swift localizations. Do not edit.\n-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors\n-- SPDX-License-Identifier: AGPL-3.0-only\nreturn vim.json.decode(" +
    literal + ")\n"
  try generated(text, at: path("lua/tatara/strings.lua"), check: check)
  print("Validated \(strings.count) strings across 5 locales.")
}

let sourcePaths = [
  "TataraCore",
  "TataraKit",
  "TataraSystem",
  "TataraGitHub",
  "TataraPersistence",
  "TataraBridge",
  "TataraCLI",
  "TataraTests",
  "Scripts",
  "Package.swift",
]
do {
  let command = arguments.first ?? "build"
  let args = Array(arguments.dropFirst())
  switch command {
  case "toolchain": try toolchain()

  case "resolve":
    try run("swift", ["package", "resolve"])
    try run("swift", ["package", "--package-path", "Scripts/NvimSmoke", "resolve"])

  case "localizations": try localizations(check: args.contains("--check"))

  case "notices": try notices(check: args.contains("--check"))

  case "format":
    try run("swiftformat", sourcePaths + ["--cache", "ignore"])
    try run("stylua", ["build.lua", "lua", "plugin", "tests/nvim"])

  case "build": try localizations(check: true)
    try build(args.first ?? "release", architecture: environment["ARCH"])

  case "install-local": try installLocal(
      products: products(),
      prefix: fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/tatara/local"),
    )

  case "test":
    try fm.createDirectory(at: path(".artifacts"), withIntermediateDirectories: true)
    let log = path(".artifacts/neovim-swift-tests.log")
    try run("swift", ["test", "-c", "release"], output: log, mergeStandardError: true)
    try checkTests(log)

  case "lint":
    try run("swiftformat", sourcePaths + ["--lint", "--cache", "ignore"])
    try run("stylua", ["--check", "build.lua", "lua", "plugin", "tests/nvim"])
    try run("swift", ["Scripts/FFF.swift", "--check"])
    try localizations(check: true)
    try notices(check: true)
    try run("uvx", ["--from", "reuse[charset-normalizer]==6.2.0", "reuse", "lint"])

  case "nvim-ui-audit",
       "nvim-smoke",
       "smoke":
    try run("swift", ["build", "--package-path", "Scripts/NvimSmoke", "-c", "release"])
    let helper = try swiftProducts(packagePath: "Scripts/NvimSmoke").appendingPathComponent("tatara-nvim-smoke")
    let nvim = try run("which", ["nvim"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
    try run(
      helper.path,
      [try products().appendingPathComponent("tatara").path, nvim]
        + (command == "nvim-ui-audit" ? ["--audit-ui"] : []),
    )

  case "nvim-test":
    try run("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root.path, "-l", "tests/nvim/startup.lua"])
    try run("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root.path, "-l", "tests/nvim/integration.lua"])
    try run("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root.path, "-l", "tests/nvim/workbench.lua"])
    try run("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root.path, "-l", "tests/nvim/projection.lua"])
    try run("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root.path, "-l", "tests/nvim/progress.lua"])
    try run("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root.path, "-l", "tests/nvim/session_restore.lua"])
    try run("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root.path, "-l", "tests/nvim/sidebar.lua"])
    try run("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root.path, "-l", "tests/nvim/review_workflow.lua"])
    try run("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root.path, "-l", "tests/nvim/local_review.lua"])

  case "version": print(try version())

  default: throw ToolError("Unknown command: " + command)
  }
} catch { fputs("Error: \(error)\n", stderr)
  exit(1)
}
