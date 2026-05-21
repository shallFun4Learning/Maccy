import Foundation
import SQLite3
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = Self.fileSize(at: url), size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  var hasDatabase: Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }

  func removeOrphanedContents() {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )

    guard let orphanedContents = try? context.fetch(descriptor), !orphanedContents.isEmpty else {
      return
    }

    orphanedContents.forEach(context.delete)
    context.processPendingChanges()
    try? context.save()
  }

  func reclaimDiskSpace() async throws -> String {
    context.processPendingChanges()
    try context.save()
    removeOrphanedContents()

    let databaseURL = url
    try await Task.detached(priority: .utility) {
      try Self.compactDatabase(at: databaseURL)
    }.value

    return size
  }

  private static func fileSize(at url: URL) -> Int64? {
    try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
  }

  private static func compactDatabase(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unable to open database."
      sqlite3_close(database)
      throw CompactError.openDatabase(message)
    }

    defer {
      sqlite3_close(database)
    }

    sqlite3_busy_timeout(database, 5_000)

    try execute(database, statement: "PRAGMA wal_checkpoint(TRUNCATE);")
    try execute(database, statement: "DELETE FROM ZHISTORYITEMCONTENT WHERE ZITEM IS NULL;")
    try execute(database, statement: "VACUUM;")
  }

  private static func execute(_ database: OpaquePointer?, statement: String) throws {
    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
      let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Database operation failed."
      throw CompactError.execute(statement, message)
    }
  }

  enum CompactError: LocalizedError {
    case openDatabase(String)
    case execute(String, String)

    var errorDescription: String? {
      switch self {
      case let .openDatabase(message):
        return message
      case let .execute(statement, message):
        return "\(statement) \(message)"
      }
    }
  }
}
