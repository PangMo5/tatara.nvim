// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - AnalysisValue

public enum AnalysisValue: Equatable, Sendable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([Self])
  case object([String: Self])

  // MARK: Lifecycle

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let v = try? value.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? value.decode(Double.self) {
      self = .number(v)
    } else if let v = try? value.decode(String.self) {
      self = .string(v)
    } else if let v = try? value.decode([Self].self) {
      self = .array(v)
    } else {
      self = .object(try value.decode([String: Self].self))
    }
  }

  // MARK: Public

  public var string: String? {
    if case .string(let v) = self {
      return v
    }
    return nil
  }

  public var array: [Self]? {
    if case .array(let v) = self {
      return v
    }
    return nil
  }

  public var integer: Int? {
    if
      case .number(let v) = self,
      v.isFinite,
      v >= Double(Int.min),
      v < Double(Int.max)
    {
      return Int(v)
    }
    return nil
  }

  public var boolean: Bool? {
    if case .bool(let v) = self {
      return v
    }
    return nil
  }

  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .bool(let v): try value.encode(v)
    case .number(let v): try value.encode(v)
    case .string(let v): try value.encode(v)
    case .array(let v): try value.encode(v)
    case .object(let v): try value.encode(v)
    }
  }

  public subscript(_ key: String) -> Self? {
    if case .object(let fields) = self {
      return fields[key]
    }
    return nil
  }
}

// MARK: - AnalysisServerProfile

public struct AnalysisServerProfile: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  public init(
    id: String = "swift",
    language: String = "swift",
    extensions: [String] = ["swift"],
    command: [String] = ["xcrun", "sourcekit-lsp"],
    setupCommand: [String]? = nil,
    setupInputs: [String] = [],
    repositories: [String] = [],
    requiresBuildSettings: Bool = true,
    initializationOptions: AnalysisValue? = .object([
      "backgroundIndexing": .bool(true),
      "backgroundPreparationMode": .string("enabled"),
    ]),
    settings: AnalysisValue? = nil,
    prepareTask: ServerTask? = nil,
  ) {
    self.id = id
    self.language = language
    self.extensions = extensions
    self.command = command
    self.setupCommand = setupCommand
    self.setupInputs = setupInputs
    self.repositories = repositories
    self.requiresBuildSettings = requiresBuildSettings
    self.initializationOptions = initializationOptions
    self.settings = settings
    self.prepareTask = prepareTask
  }

  public init(from decoder: any Decoder) throws {
    try rejectUnknownAnalysisKeys(
      decoder,
      allowed: [
        "id",
        "language",
        "extensions",
        "command",
        "settings",
        "setup_command",
        "setup_inputs",
        "repositories",
        "requires_build_settings",
        "initialization_options",
        "prepare_task",
      ],
    )
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decodeIfPresent(String.self, forKey: .id) ?? "swift",
      language: try c.decodeIfPresent(String.self, forKey: .language) ?? "swift",
      extensions: try c.decodeIfPresent([String].self, forKey: .extensions) ?? ["swift"],
      command: try c.decodeIfPresent([String].self, forKey: .command) ?? ["xcrun", "sourcekit-lsp"],
      setupCommand: try c.decodeIfPresent([String].self, forKey: .setupCommand),
      setupInputs: try c.decodeIfPresent([String].self, forKey: .setupInputs) ?? [],
      repositories: try c.decodeIfPresent([String].self, forKey: .repositories) ?? [],
      requiresBuildSettings: try c.decodeIfPresent(Bool.self, forKey: .requiresBuildSettings) ?? true,
      initializationOptions: try c.decodeIfPresent(AnalysisValue.self, forKey: .initializationOptions),
      settings: try c.decodeIfPresent(AnalysisValue.self, forKey: .settings),
      prepareTask: try c.decodeIfPresent(ServerTask.self, forKey: .prepareTask),
    )
    for repository in repositories {
      let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 3 else { throw TataraError(
        .configuration,
        detail: "Analysis repositories require HOST/OWNER/REPO identities.",
      ) }
      _ = try RepositoryID(String(parts[1]) + "/" + String(parts[2]), host: String(parts[0]))
    }

    guard
      command.first?.isEmpty == false,
      !language.isEmpty,
      !extensions.isEmpty,
      extensions.allSatisfy({ !$0.isEmpty && $0 == $0.lowercased() && !$0.contains(".") }),
      !id.isEmpty,
      setupCommand?.isEmpty != true,
      setupCommand?.first?.isEmpty != true
    else {
      throw TataraError(.configuration, detail: "Analysis profiles require an ID, extensions and command arguments.")
    }
  }

  // MARK: Public

  public struct ServerTask: Codable, Equatable, Sendable {
    public init(command: String, arguments: [AnalysisValue]? = nil) {
      self.command = command
      self.arguments = arguments
    }

    public init(from decoder: any Decoder) throws {
      try rejectUnknownAnalysisKeys(decoder, allowed: ["command", "arguments"])
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        command: try c.decode(String.self, forKey: .command),
        arguments: try c.decodeIfPresent([AnalysisValue].self, forKey: .arguments),
      )
      guard !command.isEmpty else { throw TataraError(.configuration, detail: "Analysis prepare_task requires a command.") }
    }

    public var command: String
    public var arguments: [AnalysisValue]?
  }

  public var id: String
  public var language: String
  public var extensions: [String]
  public var command: [String]
  public var setupCommand: [String]?
  public var setupInputs: [String]
  public var repositories: [String]
  public var requiresBuildSettings: Bool
  public var initializationOptions: AnalysisValue?
  public var settings: AnalysisValue?
  public var prepareTask: ServerTask?

  // MARK: Internal

  enum CodingKeys: String, CodingKey {
    case id
    case language
    case extensions
    case command
    case settings
    case setupCommand = "setup_command"
    case setupInputs = "setup_inputs"
    case repositories
    case requiresBuildSettings = "requires_build_settings"
    case initializationOptions = "initialization_options"
    case prepareTask = "prepare_task"
  }

}

// MARK: - AnalysisConfiguration

public struct AnalysisConfiguration: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  public init(repositoryDirectory: String? = nil, servers: [AnalysisServerProfile] = [.init()], profile: String? = nil) {
    self.repositoryDirectory = repositoryDirectory
    self.servers = servers
    self.profile = profile
  }

  public init(from decoder: any Decoder) throws {
    try rejectUnknownAnalysisKeys(decoder, allowed: ["repository_directory", "servers", "profile"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      repositoryDirectory: try c.decodeIfPresent(String.self, forKey: .repositoryDirectory),
      servers: try c.decodeIfPresent([AnalysisServerProfile].self, forKey: .servers) ?? [.init()],
      profile: try c.decodeIfPresent(String.self, forKey: .profile),
    )
    guard Set(servers.map(\.id)).count == servers.count else { throw TataraError(
      .configuration,
      detail: "Analysis profile IDs must be unique.",
    ) }
    if let profile, !servers.contains(where: { $0.id == profile }) {
      throw TataraError(
        .configuration,
        detail: "analysis.profile must name a configured server.",
      )
    }
  }

  // MARK: Public

  public var repositoryDirectory: String?
  public var servers: [AnalysisServerProfile]
  public var profile: String?

  public func server(repository: RepositoryID, path: String) throws -> AnalysisServerProfile {
    let ext = (path as NSString).pathExtension.lowercased()
    let matching = servers
      .filter {
        $0.extensions
          .contains(ext) &&
          ($0.repositories.isEmpty || $0.repositories
            .contains(where: { $0.lowercased() == repository.description.lowercased() })) &&
          (profile == nil || $0.id == profile)
      }
    let scoped = matching.filter { !$0.repositories.isEmpty }
    let candidates = profile == nil && !scoped.isEmpty ? scoped : matching
    guard candidates.count <= 1 else { throw TataraError(
      .configuration,
      detail: "Multiple analysis profiles match .\(ext); select analysis.profile explicitly.",
    ) }
    guard let selected = candidates.first else { throw TataraError(
      .configuration,
      detail: "No language-server profile is configured for .\(ext) in \(repository).",
    ) }
    return selected
  }

  // MARK: Internal

  enum CodingKeys: String, CodingKey { case repositoryDirectory = "repository_directory"
    case servers
    case profile
  }

}

// MARK: - AnalysisContext

public struct AnalysisContext: Equatable, Sendable {

  // MARK: Lifecycle

  public init(
    item: ItemID,
    revision: PullRequestRevision,
    path: String,
    side: InlineComment.Side,
    line: Int,
    column: Int,
    sourcePath: String? = nil,
  ) {
    self.item = item
    self.revision = revision
    self.path = path
    self.sourcePath = sourcePath ?? path
    self.side = side
    self.line = line
    self.column = column
  }

  // MARK: Public

  public let item: ItemID
  public let revision: PullRequestRevision
  public let path: String
  public let sourcePath: String
  public let side: InlineComment.Side
  public let line: Int
  public let column: Int

  public var commit: String {
    side == .left ? revision.mergeBase : revision.head
  }

}

// MARK: - AnalysisCodingKey

private struct AnalysisCodingKey: CodingKey {
  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue _: Int) {
    nil
  }

  let stringValue: String

  var intValue: Int? {
    nil
  }
}

private func rejectUnknownAnalysisKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
  let c = try decoder.container(keyedBy: AnalysisCodingKey.self)
  let unknown = c.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
  guard unknown.isEmpty else { throw TataraError(
    .configuration,
    detail: "Unknown analysis configuration keys: " + unknown.joined(separator: ", "),
  ) }
}
