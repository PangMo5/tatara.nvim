// swift-tools-version: 6.4
// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription
let package = Package(
  name: "TataraNvimSmoke",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "tatara-nvim-smoke", targets: ["Smoke"])],
  dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.2")],
  targets: [.executableTarget(
    name: "Smoke",
    dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
    path: ".",
    sources: ["Smoke.swift", "PTY.swift", "ScreenshotStyle.swift", "UIAudit.swift"],
  )],
  swiftLanguageModes: [.v6],
)
