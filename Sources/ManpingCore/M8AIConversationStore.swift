import CSQLite
import Foundation

/// One answer in a thread.
public struct AITurn: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let presetID: String
  public let presetName: String
  /// The user's question, nil for a preset button.
  public let question: String?
  public let content: AIAnswerContent
  /// The model's text as received (structured answers: the JSON).
  public let rawText: String
  /// Kinds whose content was sent for this answer (directly or through history).
  public let materials: Set<AIMaterialKind>
  public let model: String
  public let provider: String
  public let createdAt: Date
  /// Degradations: dropped layers, partial coverage, fallbacks.
  public let notes: [String]
  public let fromCache: Bool
  public init(id: String = UUID().uuidString, presetID: String, presetName: String, question: String?, content: AIAnswerContent,
    rawText: String, materials: Set<AIMaterialKind>, model: String, provider: String, createdAt: Date = Date(), notes: [String] = [],
    fromCache: Bool = false) {
    self.id = id; self.presetID = presetID; self.presetName = presetName; self.question = question; self.content = content
    self.rawText = rawText; self.materials = materials; self.model = model; self.provider = provider; self.createdAt = createdAt
    self.notes = notes; self.fromCache = fromCache
  }
  /// How the turn appears in later history.
  public var historyTurn: AIHistoryTurn {
    AIHistoryTurn(question: question ?? "（使用预设：\(presetName)）", answer: rawText, materials: materials)
  }
}

/// One conversation about one source.
public struct AIThread: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let sourceKey: String
  public var title: String
  public var turns: [AITurn]
  public var updatedAt: Date
  public init(id: String = UUID().uuidString, sourceKey: String, title: String, turns: [AITurn] = [], updatedAt: Date = Date()) {
    self.id = id; self.sourceKey = sourceKey; self.title = title; self.turns = turns; self.updatedAt = updatedAt
  }
}

/// A cached answer, keyed by the hash of everything that determined it.
public struct AIStoredAnswer: Codable, Sendable, Equatable {
  public let content: AIAnswerContent
  public let rawText: String
  public let materials: Set<AIMaterialKind>
  public let notes: [String]
  public let createdAt: Date
}

/// Application-wide AI storage (`Application Support/Manping/ai.sqlite`): threads, answers and
/// segment summaries, every row owned by an account (`mid:<n>`) or `anonymous`.
///
/// Reads and writes carry a `Ticket` (owner + generation) and are checked under the same lock as
/// the statement, so after an account change or a clear no stale task can read or write. A clear
/// first bumps the generation, then empties the three tables in one transaction.
public final class AIConversationStore: @unchecked Sendable {
  public struct Ticket: Sendable, Equatable {
    public let owner: String
    public let generation: UInt64
  }
  public struct Usage: Sendable, Equatable {
    public let sources: Int
    public let answers: Int
    public let bytes: Int
  }
  public static let anonymous = "anonymous"
  public static func owner(mid: Int64?) -> String { mid.map { $0 > 0 ? "mid:\($0)" : anonymous } ?? anonymous }
  public static var defaultURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Manping", isDirectory: true).appendingPathComponent("ai.sqlite")
  }
  private var db: OpaquePointer?
  private let lock = NSLock()
  private var owner: String
  private var generation: UInt64 = 0
  /// 设置 › AI › 在本机保存回答与对话. Checked under the write lock, so once `setSaving(false)`
  /// returns no save of any request (running or not) can reach the database.
  private var saving = true
  /// Tests: runs at the start of every save, before the lock is taken.
  var beforeSave: (@Sendable () -> Void)?

  /// `url == nil` opens an in-memory database (fixtures and tests).
  public init(url: URL?) throws {
    if let url {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    guard sqlite3_open_v2(url?.path ?? ":memory:", &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
      throw BiliError.dependency("无法打开 AI 对话数据库")
    }
    if let url { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    owner = Self.anonymous
    for sql in [
      "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS threads (id TEXT NOT NULL, owner TEXT NOT NULL, source_key TEXT NOT NULL, updated_at REAL NOT NULL, payload BLOB NOT NULL, PRIMARY KEY (owner, id))",
      "CREATE INDEX IF NOT EXISTS threads_source ON threads(owner, source_key, updated_at)",
      "CREATE TABLE IF NOT EXISTS answers (key TEXT NOT NULL, owner TEXT NOT NULL, created_at REAL NOT NULL, payload BLOB NOT NULL, PRIMARY KEY (owner, key))",
      "CREATE TABLE IF NOT EXISTS segments (key TEXT NOT NULL, owner TEXT NOT NULL, created_at REAL NOT NULL, payload BLOB NOT NULL, PRIMARY KEY (owner, key))",
    ] { try execute(sql) }
    // The last owner is remembered so an account change while the app was closed is noticed.
    owner = try metaValue("owner") ?? Self.anonymous
  }
  deinit { sqlite3_close(db) }

  public var currentOwner: String { lock.withLock { owner } }
  public func ticket() -> Ticket { lock.withLock { Ticket(owner: owner, generation: generation) } }
  public func isCurrent(_ ticket: Ticket) -> Bool { lock.withLock { ticket.owner == owner && ticket.generation == generation } }

  /// Makes `newOwner` the readable owner. With `purgeOthers`, rows of every other owner are deleted
  /// (account switch); without, they only become unreadable (signed-out window before restore).
  public func switchOwner(to newOwner: String, purgeOthers: Bool) throws {
    try lock.withLock {
      guard newOwner != owner || purgeOthers else { return }
      generation &+= 1
      owner = newOwner
      try setMeta("owner", newOwner)
      if purgeOthers {
        try transaction {
          for table in ["threads", "answers", "segments"] { try run("DELETE FROM \(table) WHERE owner <> ?", [.text(newOwner)]) }
        }
      }
    }
  }
  /// Invalidates in-flight work, then removes every row of every owner.
  public func clearAll() throws {
    try lock.withLock {
      generation &+= 1
      try transaction { for table in ["threads", "answers", "segments"] { try run("DELETE FROM \(table)", []) } }
    }
  }
  /// Follows the saving switch. Waits for a save already writing; every later save is refused.
  public func setSaving(_ enabled: Bool) { lock.withLock { saving = enabled } }
  public var isSaving: Bool { lock.withLock { saving } }

  public func purge(olderThan cutoff: Date) throws {
    try lock.withLock {
      try transaction {
        try run("DELETE FROM threads WHERE updated_at < ?", [.real(cutoff.timeIntervalSince1970)])
        try run("DELETE FROM answers WHERE created_at < ?", [.real(cutoff.timeIntervalSince1970)])
        try run("DELETE FROM segments WHERE created_at < ?", [.real(cutoff.timeIntervalSince1970)])
      }
    }
  }
  public func usage() throws -> Usage {
    try lock.withLock {
      let sources = try scalar("SELECT COUNT(DISTINCT source_key) FROM threads WHERE owner = ?", [.text(owner)])
      let answers = try scalar("SELECT COUNT(*) FROM answers WHERE owner = ?", [.text(owner)])
      let pages = try scalar("PRAGMA page_count", []), size = try scalar("PRAGMA page_size", [])
      return Usage(sources: sources, answers: answers, bytes: pages * size)
    }
  }

  // MARK: Threads
  public func thread(id: String, ticket: Ticket) throws -> AIThread? {
    try read(ticket, "SELECT payload FROM threads WHERE owner = ? AND id = ?", [.text(ticket.owner), .text(id)]).first
  }
  /// Most recently updated first.
  public func threads(sourceKey: String, ticket: Ticket) throws -> [AIThread] {
    try read(ticket, "SELECT payload FROM threads WHERE owner = ? AND source_key = ? ORDER BY updated_at DESC", [.text(ticket.owner), .text(sourceKey)])
  }
  /// False (nothing written) when the ticket is stale or saving is off.
  @discardableResult
  public func save(_ thread: AIThread, ticket: Ticket) throws -> Bool {
    try write(ticket, saving: true, "INSERT OR REPLACE INTO threads(id, owner, source_key, updated_at, payload) VALUES(?,?,?,?,?)",
      [.text(thread.id), .text(ticket.owner), .text(thread.sourceKey), .real(thread.updatedAt.timeIntervalSince1970), .blob(try JSONEncoder().encode(thread))])
  }
  @discardableResult
  public func deleteThread(id: String, ticket: Ticket) throws -> Bool {
    try write(ticket, "DELETE FROM threads WHERE owner = ? AND id = ?", [.text(ticket.owner), .text(id)])
  }

  // MARK: Answers and segments
  public func answer(key: String, ticket: Ticket) throws -> AIStoredAnswer? {
    try read(ticket, "SELECT payload FROM answers WHERE owner = ? AND key = ?", [.text(ticket.owner), .text(key)]).first
  }
  @discardableResult
  public func save(answer: AIStoredAnswer, key: String, ticket: Ticket) throws -> Bool {
    try write(ticket, saving: true, "INSERT OR REPLACE INTO answers(key, owner, created_at, payload) VALUES(?,?,?,?)",
      [.text(key), .text(ticket.owner), .real(answer.createdAt.timeIntervalSince1970), .blob(try JSONEncoder().encode(answer))])
  }
  public func segment(key: String, ticket: Ticket) throws -> String? {
    let rows: [String] = try read(ticket, "SELECT payload FROM segments WHERE owner = ? AND key = ?", [.text(ticket.owner), .text(key)])
    return rows.first
  }
  @discardableResult
  public func save(segment: String, key: String, ticket: Ticket, now: Date = Date()) throws -> Bool {
    try write(ticket, saving: true, "INSERT OR REPLACE INTO segments(key, owner, created_at, payload) VALUES(?,?,?,?)",
      [.text(key), .text(ticket.owner), .real(now.timeIntervalSince1970), .blob(try JSONEncoder().encode(segment))])
  }

  // MARK: SQLite
  enum Value { case text(String), real(Double), blob(Data) }
  private func read<T: Decodable>(_ ticket: Ticket, _ sql: String, _ values: [Value]) throws -> [T] {
    try lock.withLock {
      guard ticket.owner == owner, ticket.generation == generation else { return [] }
      var result: [T] = []
      try query(sql, values) { statement in
        guard let blob = sqlite3_column_blob(statement, 0) else { return }
        let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
        // A row that no longer decodes (older format) is skipped rather than failing the read.
        if let value = try? JSONDecoder().decode(T.self, from: data) { result.append(value) }
      }
      return result
    }
  }
  /// `saving`: the statement stores content and is refused while saving is off (deletes are not).
  private func write(_ ticket: Ticket, saving needsSaving: Bool = false, _ sql: String, _ values: [Value]) throws -> Bool {
    if needsSaving, let hook = lock.withLock({ beforeSave }) { hook() }
    return try lock.withLock {
      guard ticket.owner == owner, ticket.generation == generation, !needsSaving || saving else { return false }
      try run(sql, values)
      return true
    }
  }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw BiliError.dependency("AI 对话数据库结构异常") }
  }
  private func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
  }
  private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw BiliError.dependency("AI 对话数据库准备失败") }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let status: Int32
      switch value {
      case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, transient)
      case .real(let number): status = sqlite3_bind_double(statement, index, number)
      case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
      }
      guard status == SQLITE_OK else { sqlite3_finalize(statement); throw BiliError.dependency("AI 对话数据库参数无效") }
    }
    return statement
  }
  private func run(_ sql: String, _ values: [Value]) throws {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw BiliError.dependency("AI 对话保存失败") }
  }
  private func query(_ sql: String, _ values: [Value], row: (OpaquePointer?) throws -> Void) throws {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return }
      guard status == SQLITE_ROW else { throw BiliError.dependency("AI 对话读取失败") }
      try row(statement)
    }
  }
  private func scalar(_ sql: String, _ values: [Value]) throws -> Int {
    var value = 0
    try query(sql, values) { value = Int(sqlite3_column_int64($0, 0)) }
    return value
  }
  private func metaValue(_ key: String) throws -> String? {
    var value: String?
    try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { statement in
      if let text = sqlite3_column_text(statement, 0) { value = String(cString: text) }
    }
    return value
  }
  private func setMeta(_ key: String, _ value: String) throws {
    try run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [.text(key), .text(value)])
  }
}

/// Keeps the store's owner in step with the signed-in account. Only an account change moves
/// data: a new login or restore that only bumps epoch/revision changes nothing; switching to a
/// different account deletes the previous account's rows; signing out after an account was
/// active in this process deletes everything; the signed-out moment at launch (before the saved
/// login is restored) only makes rows unreadable.
public actor AIIdentityCoordinator {
  private let store: AIConversationStore
  private var accountSeen = false
  public init(store: AIConversationStore) { self.store = store }
  public func apply(mid: Int64?, state: AuthorizationState) throws {
    let next = AIConversationStore.owner(mid: mid)
    let current = store.currentOwner
    if next == current { if mid != nil { accountSeen = true }; return }
    if mid == nil {
      if accountSeen && state == .needsLogin {
        try store.clearAll()
        try store.switchOwner(to: next, purgeOthers: false)
      } else {
        try store.switchOwner(to: next, purgeOthers: false)
      }
      return
    }
    accountSeen = true
    try store.switchOwner(to: next, purgeOthers: true)
  }
  /// Follows the service's identity events for the life of the returned task.
  public nonisolated func follow(_ service: BiliService) -> Task<Void, Never> {
    Task { [weak service] in
      guard let events = await service?.identityEvents() else { return }
      for await event in events {
        guard !Task.isCancelled, let service else { return }
        let mid = await service.accountMid()
        try? await self.apply(mid: mid, state: event.state)
      }
    }
  }
}
