// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import SQLiteData
import TataraCore

// MARK: - SavedReviewSession

@Table
private struct SavedReviewSession: Identifiable, Sendable {
  let id: String
  var owner: String
  var repository: String
  var identity: String
  var draftCount: Int
  var reviewedCount: Int
  var excerpt: String
  var payload: String
  var updatedAt: Double
}

// MARK: - ReviewListing

@Selection
private struct ReviewListing {
  var id: String
  var identity: String
  var updatedAt: Double
  var draftCount: Int
  var reviewedCount: Int
  var excerpt: String
}

// MARK: - ReviewSessionStore

public actor ReviewSessionStore {

  // MARK: Lifecycle

  private init(_ database: any DatabaseWriter) {
    self.database = database
  }

  // MARK: Public

  @concurrent
  public static func open(at url: URL? = nil) async throws -> Self {
    let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
    let file = url ?? base.appendingPathComponent("tatara/state/reviews.sqlite")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    let database = try DatabaseQueue(path: file.path, configuration: configuration)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("Create saved review sessions") { db in
      try #sql("""
        CREATE TABLE "savedReviewSessions" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "owner" TEXT NOT NULL,
          "repository" TEXT NOT NULL,
          "identity" TEXT NOT NULL,
          "draftCount" INTEGER NOT NULL,
          "reviewedCount" INTEGER NOT NULL,
          "excerpt" TEXT NOT NULL,
          "payload" TEXT NOT NULL,
          "updatedAt" REAL NOT NULL
        ) STRICT
        """).execute(db)
      try #sql("CREATE INDEX \"savedReviewSessions_owner\" ON \"savedReviewSessions\" (\"owner\")").execute(db)
    }
    try migrator.migrate(database)
    return Self(database)
  }

  public func load(_ identity: ReviewSessionIdentity) async throws -> ReviewSessionState {
    let key = try Self.key(identity)
    return try await database.read { db in
      guard let row = try SavedReviewSession.where({ $0.id.eq(key) }).fetchOne(db) else { return .init() }
      return try Self.decode(row.payload)
    }
  }

  public func change(_ identity: ReviewSessionIdentity, _ change: ReviewSessionChange) async throws -> ReviewSessionState {
    let key = try Self.key(identity)
    let owner = Self.owner(identity)
    return try await database.write { db in
      let row = try SavedReviewSession.where { $0.id.eq(key) }.fetchOne(db)
      var state = try row.map { try Self.decode($0.payload) } ?? ReviewSessionState()
      try change.apply(to: &state)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let payload = try encoder.encode(state)
      guard payload.count <= 10 * 1024 * 1024 else { throw TataraError(.unavailable, detail: "The saved review exceeds 10 MiB.") }
      if row == nil {
        guard try SavedReviewSession.where({ $0.owner.eq(owner) }).fetchCount(db) < 128 else {
          throw TataraError(
            .unavailable,
            detail: "The account has 128 saved review revisions. Remove old revisions before saving another.",
          )
        }
      }
      let encodedIdentity = String(decoding: try encoder.encode(identity), as: UTF8.self)
      try SavedReviewSession.upsert { SavedReviewSession(
        id: key,
        owner: owner,
        repository: identity.repository.description,
        identity: encodedIdentity,
        draftCount: state.drafts.count,
        reviewedCount: state.reviewedFiles.count,
        excerpt: String(state.summary.prefix(160)),
        payload: String(decoding: payload, as: UTF8.self),
        updatedAt: Date().timeIntervalSince1970,
      ) }.execute(db)
      return state
    }
  }

  public func list(_ identity: ReviewSessionIdentity) async throws -> [SavedReviewSummary] {
    let owner = Self.owner(identity)
    let repository = identity.repository.description
    return try await database.read { db in
      try SavedReviewSession.where { $0.owner.eq(owner) && $0.repository.eq(repository) }
        .order { $0.updatedAt.desc() }
        .select { ReviewListing.Columns(
          id: $0.id,
          identity: $0.identity,
          updatedAt: $0.updatedAt,
          draftCount: $0.draftCount,
          reviewedCount: $0.reviewedCount,
          excerpt: $0.excerpt,
        ) }
        .fetchAll(db).map { row in
          SavedReviewSummary(
            id: row.id,
            identity: try JSONDecoder().decode(ReviewSessionIdentity.self, from: Data(row.identity.utf8)),
            updatedAt: row.updatedAt,
            drafts: row.draftCount,
            reviewed: row.reviewedCount,
            excerpt: row.excerpt,
          )
        }
    }
  }

  public func remove(_ identity: ReviewSessionIdentity, id: String, expectedUpdatedAt: Double) async throws {
    let owner = Self.owner(identity)
    let repository = identity.repository.description
    try await database.write { db in
      guard
        let row = try SavedReviewSession.where({ $0.id.eq(id) && $0.owner.eq(owner) && $0.repository.eq(repository) })
          .fetchOne(db),
        row.updatedAt == expectedUpdatedAt
      else { throw TataraError(
        .revisionChanged,
        detail: "The saved review changed. Open the saved reviews list again.",
      ) }
      try SavedReviewSession.where { $0.id.eq(id) }.delete().execute(db)
    }
  }

  // MARK: Private

  private let database: any DatabaseWriter

  private static func decode(_ payload: String) throws -> ReviewSessionState {
    guard payload.utf8.count <= 10 * 1024 * 1024 else { throw TataraError(.invalidResponse) }
    let state = try JSONDecoder().decode(ReviewSessionState.self, from: Data(payload.utf8))
    try state.validate()
    return state
  }

  private static func owner(_ identity: ReviewSessionIdentity) -> String {
    "\(identity.repository.forge.rawValue):\(identity.repository.host):\(identity.account)"
  }

  private static func key(_ identity: ReviewSessionIdentity) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
  }

}
