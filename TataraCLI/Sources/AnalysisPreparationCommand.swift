// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ArgumentParser
import Foundation
import TataraSystem

struct AnalysisPreparationCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prepare-analysis",
    abstract: "Run a user-owned preparation plan for an immutable analysis checkout.",
  )

  @Option var plan: String
  @Option var source: String
  @Option var workspace: String
  @Option var repository: String
  @Option var revision: String

  func run() async throws {
    try await AnalysisPreparation.run(
      planURL: URL(fileURLWithPath: plan),
      source: URL(fileURLWithPath: source),
      workspace: URL(fileURLWithPath: workspace),
      repository: repository,
      revision: revision,
    )
  }
}
