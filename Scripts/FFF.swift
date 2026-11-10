// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let output = root.appendingPathComponent(".artifacts/fff-bridge")
let manifest = root.appendingPathComponent("Native/FFFBridge/Cargo.toml")
let inputs = [
  "Native/FFFBridge/Cargo.toml",
  "Native/FFFBridge/Cargo.lock",
  "Native/FFFBridge/src/lib.rs",
  "Native/FFFBridge/include/TataraFFF.h",
  "Native/FFFBridge/include/module.modulemap",
  "Scripts/FFF.swift",
]

func hash(_ url: URL) throws -> String {
  try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

@discardableResult
func run(_ executable: String, _ arguments: [String], capture: Bool = false) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments
  process.currentDirectoryURL = root
  var environment = ProcessInfo.processInfo.environment
  environment["MACOSX_DEPLOYMENT_TARGET"] = "15.0"
  environment["CARGO_ENCODED_RUSTFLAGS"] = [
    "--remap-path-prefix",
    root.path + "=.",
    "--remap-path-prefix",
    fm.homeDirectoryForCurrentUser.path + "=/build",
  ].joined(separator: "\u{1F}")
  process.environment = environment
  let pipe = capture ? Pipe() : nil
  if let pipe {
    process.standardOutput = pipe
  }
  try process.run()
  let data = pipe?.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw NSError(domain: "FFFBridge", code: Int(process.terminationStatus), userInfo: [
      NSLocalizedDescriptionKey: "Failed: \(executable) \(arguments.joined(separator: " "))"
    ])
  }
  return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

if CommandLine.arguments.contains("--check") {
  let directory = root.appendingPathComponent("ThirdParty/FFFBridge")
  let record = try JSONSerialization
    .jsonObject(with: Data(contentsOf: directory.appendingPathComponent("upstream.json"))) as! [String: Any]
  let expected = record["sources"] as! [String: String]
  for file in inputs {
    guard try hash(root.appendingPathComponent(file)) == expected[file] else {
      fatalError("FFF source changed: \(file). Rebuild with swift Scripts/FFF.swift.")
    }
  }
  let archive = directory.appendingPathComponent("TataraFFF.xcframework/macos-arm64_x86_64/libtatara_fff.a")
  guard try hash(archive) == record["sha256"] as? String else { fatalError("FFF archive does not match its provenance.") }
  for name in ["TataraFFF.h", "module.modulemap"] {
    guard
      try Data(contentsOf: directory.appendingPathComponent("TataraFFF.xcframework/macos-arm64_x86_64/Headers/" + name)) ==
      Data(contentsOf: root.appendingPathComponent("Native/FFFBridge/include/" + name))
    else {
      fatalError("FFF headers do not match their sources.")
    }
  }
  print("Validated FFF source, header and archive hashes.")
  exit(0)
}

try fm.createDirectory(at: output, withIntermediateDirectories: true)
for target in ["aarch64-apple-darwin", "x86_64-apple-darwin"] {
  try run("cargo", [
    "build",
    "--manifest-path",
    manifest.path,
    "--locked",
    "--release",
    "--target",
    target,
    "--target-dir",
    output.path,
  ])
}

let library = output.appendingPathComponent("libtatara_fff.a")
try run("xcrun", [
  "lipo",
  "-create",
  output.appendingPathComponent("aarch64-apple-darwin/release/libtatara_fff.a").path,
  output.appendingPathComponent("x86_64-apple-darwin/release/libtatara_fff.a").path,
  "-output",
  library.path,
])
let framework = output.appendingPathComponent("TataraFFF.xcframework")
if fm.fileExists(atPath: framework.path) {
  try fm.removeItem(at: framework)
}

try run("xcodebuild", [
  "-create-xcframework",
  "-library",
  library.path,
  "-headers",
  root.appendingPathComponent("Native/FFFBridge/include").path,
  "-output",
  framework.path,
])
let destination = root.appendingPathComponent("ThirdParty/FFFBridge/TataraFFF.xcframework")
try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
if fm.fileExists(atPath: destination.path) {
  try fm.removeItem(at: destination)
}

try fm.copyItem(at: framework, to: destination)
let metadata = try JSONSerialization.jsonObject(with: Data(run("cargo", [
  "metadata",
  "--manifest-path",
  manifest.path,
  "--locked",
  "--offline",
  "--format-version",
  "1",
], capture: true).utf8)) as! [String: Any]
let packages = metadata["packages"] as! [[String: Any]]
var licenses = [String]()
for package in packages.sorted(by: { ($0["name"] as! String) < ($1["name"] as! String) }) {
  let name = package["name"] as! String
  guard name != "tatara-fff" else { continue }
  let directory = URL(fileURLWithPath: package["manifest_path"] as! String).deletingLastPathComponent()
  let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
  let candidates = files.filter { $0.lastPathComponent == "LICENSE-MIT" || $0.lastPathComponent == "LICENSE-UNICODE" }
  let selected = candidates.isEmpty
    ? [name == "fff-query-parser"
      ? directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LICENSE")
      : directory.appendingPathComponent("LICENSE")]
    : candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }
  licenses += ["\(name) \(package["version"] as! String)", "Source: \(package["source"] as! String)", ""]
  for file in selected { licenses += [try String(contentsOf: file, encoding: .utf8), ""] }
}

licenses += [
  "Rust standard library",
  "Source: https://github.com/rust-lang/rust/tree/1.99.1",
  try String(contentsOf: root.appendingPathComponent("Native/FFFBridge/Rust-LICENSE-MIT.txt"), encoding: .utf8),
]
try licenses.joined(separator: "\n").write(
  to: destination.deletingLastPathComponent().appendingPathComponent("LICENSE.txt"),
  atomically: true,
  encoding: .utf8,
)
var hashes = [String: String]()
for relative in inputs {
  hashes[relative] = try SHA256.hash(data: Data(contentsOf: root.appendingPathComponent(relative))).map { String(
    format: "%02x",
    $0,
  ) }.joined()
}

let binary = destination.appendingPathComponent("macos-arm64_x86_64/libtatara_fff.a")
let provenance: [String: Any] = [
  "repository": "https://github.com/dmtrKovalenko/fff",
  "revision": "977102516557c29a1ed92fa3792384f353f652a3",
  "rust": "1.99.1",
  "sources": hashes,
  "sha256": try SHA256.hash(data: Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined(),
]
try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(
  to: destination.deletingLastPathComponent().appendingPathComponent("upstream.json"),
  options: .atomic,
)
print("Prepared static FFF bridge for arm64 and x86_64.")
