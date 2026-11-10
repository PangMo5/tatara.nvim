// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore

// MARK: - RPCWriter

public actor RPCWriter {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public func write(_ value: RPCValue) throws {
    var data = try JSONEncoder().encode(value)
    if data.count > 16 * 1024 * 1024 {
      data = try JSONEncoder().encode(RPCValue.object([
        "jsonrpc": .string("2.0"),
        "id": value["id"] ?? .null,
        "error": .object(["code": .number(-32001), "message": .string("Backend response exceeds 16 MiB.")]),
      ]))
    }
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
  }

}

// MARK: - RPCTransport

/// Newline-framed JSON-RPC with bounded frames, cancellation and one editor owner.
public actor RPCTransport {

  // MARK: Lifecycle

  public init(backend: Backend = Backend(), writer: RPCWriter = RPCWriter()) {
    self.backend = backend
    self.writer = writer
  }

  // MARK: Public

  @concurrent
  public static func run() async throws {
    let transport = RPCTransport()
    var buffer = Data()
    while true {
      let chunk = FileHandle.standardInput.availableData
      if chunk.isEmpty {
        break
      }
      buffer.append(chunk)
      guard buffer.count <= 16 * 1024 * 1024 else { throw TataraError(.invalidResponse, detail: "RPC frame exceeds 16 MiB.") }
      while let end = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<end])
        buffer.removeSubrange(...end)
        if !line.isEmpty {
          await transport.accept(line)
        }
      }
    }
    await transport.finish()
  }

  public func accept(_ data: Data) async {
    do {
      let value = try JSONDecoder().decode(RPCValue.self, from: data)
      if value["method"]?.string == "$/cancelRequest", let id = value["params"]?["id"]?.integer {
        if !writes.contains(id) {
          tasks.removeValue(forKey: id)?.cancel()
        }
        return
      }
      guard
        value["jsonrpc"]?.string == "2.0",
        let id = value["id"]?.integer,
        id > lastID,
        let method = value["method"]?.string,
        tasks[id] == nil,
        tasks.count < 32
      else { throw TataraError(.invalidResponse, detail: "Invalid, duplicate or excessive RPC requests.") }
      lastID = id
      let params = value["params"] ?? .object([:])
      if method == "write.confirm" {
        writes.insert(id)
      }
      tasks[id] = Task {
        let response: RPCValue
        do {
          let result = try await backend.call(method, params, progress: { [writer] message in
            try? await writer.write(.object([
              "jsonrpc": .string("2.0"),
              "method": .string("progress"),
              "params": .object(["id": .number(Double(id)), "message": .string(message)]),
            ]))
          })
          try Task.checkCancellation()
          response = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result])
        } catch {
          let error = TataraError.wrapping(error)
          response = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "error": .object([
              "code": .number(-32000),
              "message": .string(error.messageKey),
              "data": .object(["kind": .string(error.code.rawValue), "detail": .string(String(error.detail.prefix(8192)))]),
            ]),
          ])
        }
        if !Task.isCancelled {
          try? await writer.write(response)
        }
        tasks[id] = nil
        writes.remove(id)
      }
    } catch {
      try? await writer.write(.object([
        "jsonrpc": .string("2.0"),
        "id": .null,
        "error": .object(["code": .number(-32600), "message": .string("Invalid RPC request.")]),
      ]))
    }
  }

  public func finish() async {
    let pending = tasks
    for (id, task) in pending where !writes.contains(id) { task.cancel() }
    for task in pending.values { await task.value }
    await backend.close()
  }

  // MARK: Private

  private let backend: Backend
  private let writer: RPCWriter
  private var tasks = [Int: Task<Void, Never>]()
  private var writes = Set<Int>()
  private var lastID = 0

}
