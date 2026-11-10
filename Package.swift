// swift-tools-version: 6.4
// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let macOSDeploymentTarget = "15.0"
let macOSSDKVersion = "27.2"
let swiftSettings: [SwiftSetting] = [.defaultIsolation(nil)]
/// Record the pinned SDK independently of the linker's inherited SDKROOT.
let linkerSettings: [LinkerSetting] = [.unsafeFlags([
  "-Xlinker",
  "-platform_version",
  "-Xlinker",
  "macos",
  "-Xlinker",
  macOSDeploymentTarget,
  "-Xlinker",
  macOSSDKVersion,
])]

let package = Package(
  name: "tatara.nvim",
  platforms: [.macOS(macOSDeploymentTarget)],
  products: [.executable(name: "tatara", targets: ["TataraCLI"])],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.2"),
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.12.1"),
  ],
  targets: [
    .binaryTarget(name: "TataraFFF", path: "ThirdParty/FFFBridge/TataraFFF.xcframework"),
    .target(name: "TataraCore", dependencies: ["TataraFFF"], path: "TataraCore/Sources", swiftSettings: swiftSettings),
    .target(name: "TataraKit", dependencies: ["TataraCore"], path: "TataraKit/Sources", swiftSettings: swiftSettings),
    .target(
      name: "TataraSystem",
      dependencies: ["TataraCore", "TataraKit", .product(name: "Subprocess", package: "swift-subprocess")],
      path: "TataraSystem/Sources",
      swiftSettings: swiftSettings,
    ),
    .target(
      name: "TataraGitHub",
      dependencies: ["TataraCore", "TataraKit", "TataraSystem"],
      path: "TataraGitHub/Sources",
      swiftSettings: swiftSettings,
    ),
    .target(
      name: "TataraPersistence",
      dependencies: ["TataraCore", "TataraKit", .product(name: "SQLiteData", package: "sqlite-data")],
      path: "TataraPersistence/Sources",
      swiftSettings: swiftSettings,
    ),
    .target(
      name: "TataraBridge",
      dependencies: ["TataraCore", "TataraKit", "TataraSystem", "TataraGitHub", "TataraPersistence"],
      path: "TataraBridge/Sources",
      swiftSettings: swiftSettings,
    ),
    .executableTarget(
      name: "TataraCLI",
      dependencies: [
        "TataraBridge",
        "TataraCore",
        "TataraSystem",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "TataraCLI/Sources",
      swiftSettings: swiftSettings,
      linkerSettings: linkerSettings,
    ),
    .testTarget(
      name: "TataraTests",
      dependencies: ["TataraCore", "TataraKit", "TataraSystem", "TataraGitHub", "TataraPersistence", "TataraBridge"],
      path: "TataraTests/Sources",
      swiftSettings: swiftSettings,
      linkerSettings: linkerSettings,
    ),
  ],
  swiftLanguageModes: [.v6],
)
