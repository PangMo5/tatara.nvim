// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - AnalysisPhase

public enum AnalysisPhase: Equatable, Sendable {
  case preparingCheckout
  case runningSetup
  case startingServer
  case ready
}

// MARK: - AnalysisProgress
