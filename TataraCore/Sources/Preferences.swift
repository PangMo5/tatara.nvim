// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - Language

public enum Language: String, CaseIterable, Codable, Sendable {
  case english = "en"
  case korean = "ko"
  case japanese = "ja"
  case simplifiedChinese = "zh-Hans"
  case traditionalChinese = "zh-Hant"

  public static func resolve(_ identifier: String) -> Self {
    let tag = identifier.replacing("_", with: "-").lowercased()
    if tag.hasPrefix("ko") {
      return .korean
    }
    if tag.hasPrefix("ja") {
      return .japanese
    }
    if tag.hasPrefix("zh") {
      return tag.contains("hant") || tag.contains("tw") || tag.contains("hk") ? .traditionalChinese : .simplifiedChinese
    }
    return .english
  }
}

// MARK: - TerminalText

/// Remote text never controls the terminal. Preserve text, tabs and line feeds only.
public enum TerminalText {
  public static func sanitize(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.filter {
      $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && !(0x7F ... 0x9F).contains($0.value))
    }))
  }
}
