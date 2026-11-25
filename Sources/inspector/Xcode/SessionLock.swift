import Darwin
import Foundation
import InspectorKit

/// `.inspector/session.lock`: held by the one process that starts an Xcode device interaction
/// session for the folder, so another call waits for that session instead of starting its own or
/// calling into the one it replaces.
///
/// The file holds the holder's process ID and appears with it in one step, so a reader never sees
/// it empty. A lock whose process no longer runs is stale and is removed by the next reader.
struct SessionLock: Sendable {
  /// The file's name inside `.inspector/`.
  static let fileName = "session.lock"

  /// The lock file.
  let file: URL
  /// The process ID this process writes into the lock.
  let processID: Int32
  /// Whether a process runs; a lock whose process does not is stale.
  let isAlive: @Sendable (Int32) -> Bool
  /// How often a waiting call looks at the lock again.
  var pollInterval: Duration = .milliseconds(50)
  /// How long a call waits for a live holder at most.
  var maximumWait: Duration = .seconds(120)

  /// The lock of `folder`, taken in the name of `processID`.
  init(in folder: InspectorFolder, processID: Int32, isAlive: @escaping @Sendable (Int32) -> Bool) {
    file = folder.url.appending(path: Self.fileName)
    self.processID = processID
    self.isAlive = isAlive
  }

  /// What the lock file says right now.
  enum Holder: Equatable, Sendable {
    /// There is no lock file.
    case none
    /// A running process holds the lock.
    case live(Int32)
    /// The file names a process that no longer runs, or no process at all.
    case stale
  }

  /// Who holds the lock right now.
  var holder: Holder {
    guard let data = try? Data(contentsOf: file) else {
      return FileManager.default.fileExists(atPath: file.path) ? .stale : .none
    }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(text), pid > 0, isAlive(pid) else { return .stale }
    return .live(pid)
  }

  /// Waits while another running process holds the lock, at most ``maximumWait``, and removes a
  /// stale lock.
  ///
  /// - Returns: whether a live holder was waited for, so the caller reads `config.json` again.
  @discardableResult
  func waitWhileHeld() async -> Bool {
    let deadline = ContinuousClock.now + maximumWait
    var waited = false
    while true {
      switch holder {
      case .none:
        return waited
      case .stale:
        removeStale()
        return waited
      case .live(let pid):
        guard pid != processID, ContinuousClock.now < deadline else { return waited }
        waited = true
        try? await Task.sleep(for: pollInterval)
      }
    }
  }

  /// Takes the lock, waiting first while another running process holds it.
  ///
  /// - Returns: whether a live holder was waited for, so the caller reads `config.json` again.
  /// - Throws: ``ErrorCode/timeout`` when a live holder keeps the lock longer than
  ///   ``maximumWait``, ``ErrorCode/badRequest`` when the file cannot be written.
  @discardableResult
  func acquire() async throws(InspectorError) -> Bool {
    let deadline = ContinuousClock.now + maximumWait
    var waited = false
    while true {
      if try create() { return waited }
      switch holder {
      case .none:
        // The holder released it between the two looks.
        continue
      case .stale:
        removeStale()
      case .live(let pid):
        if pid == processID { return waited }
        guard ContinuousClock.now < deadline else {
          throw InspectorError(
            code: .timeout,
            message: "process \(pid) has held `\(Self.fileName)` for \(maximumWait.inSeconds) s",
            detail: file.path)
        }
        waited = true
        try? await Task.sleep(for: pollInterval)
      }
    }
  }

  /// Gives the lock up, if this process holds it.
  func release() {
    guard holder == .live(processID) else { return }
    try? FileManager.default.removeItem(at: file)
  }

  /// Whether `pid` names a running process.
  static func isRunning(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    // Signal 0 checks existence only; EPERM means it runs under another user.
    return kill(pid, 0) == 0 || errno == EPERM
  }

  /// Creates the lock file with this process's ID, unless it exists.
  ///
  /// The ID goes into a temporary file first, which is then hard-linked as the lock: `link` fails
  /// for an existing file, and a reader never sees the lock without its ID.
  private func create() throws(InspectorError) -> Bool {
    let temporary = file.deletingLastPathComponent()
      .appending(path: "\(Self.fileName).\(processID).\(UUID().uuidString)")
    do {
      try Data("\(processID)\n".utf8).write(to: temporary)
    } catch {
      throw InspectorError(code: .badRequest, message: "could not write `\(Self.fileName)`", detail: "\(error)")
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    if link(temporary.path, file.path) == 0 { return true }
    let failure = errno
    guard failure == EEXIST else {
      throw InspectorError(
        code: .badRequest, message: "could not create `\(Self.fileName)`",
        detail: String(cString: strerror(failure)))
    }
    return false
  }

  /// Removes a lock whose process no longer runs.
  private func removeStale() {
    guard holder == .stale else { return }
    try? FileManager.default.removeItem(at: file)
  }
}
