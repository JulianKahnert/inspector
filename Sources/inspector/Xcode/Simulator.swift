import Foundation
import InspectorKit

/// The simulator a cold `init` of an iOS app runs it on: one per worktree, kept across `init`s so
/// the app's data (a login) survives, and never one another live session holds.
///
/// A simulator is named `<label> inspector <device type>`, the label being the ticket key in the
/// branch or directory name, else the repository directory's name (``label(branch:directory:)``).
/// Which `.inspector/` folder holds a simulator is recorded as a claim, one file per UDID in
/// ``Environment/simulatorClaims``; the claim is live while that folder's `config.json` names the
/// UDID, so a worktree whose `.inspector/` is gone frees its simulator.
enum Simulator {
  /// The device family the app targets.
  enum Family: String, Sendable {
    case iPhone
    case iPad
  }

  /// The UDID to start the session on.
  ///
  /// In order: `requested` (`--udid`); the previous `config.json`'s `udid` when this folder
  /// claims it or it carries this worktree's name; a simulator named for this worktree that no
  /// other live session claims; otherwise a new one, of the previous simulator's device type and
  /// runtime when it still exists, else of the newest `family` device on the newest iOS runtime.
  ///
  /// - Throws: ``ErrorCode/deviceInUse`` when another live session claims `requested`,
  ///   ``ErrorCode/badRequest`` when `simctl` fails or there is no runtime to create one on.
  static func choose(
    requested: String?, previous: String?, label: String, family: Family, folder: InspectorFolder,
    in environment: Environment
  ) async throws(InspectorError) -> String {
    let list = try await SimulatorList.load(in: environment)
    let claims = SimulatorClaims(directory: environment.simulatorClaims, now: environment.now())
    let prefix = "\(label) inspector "

    if let requested {
      guard list.device(requested) != nil else {
        throw InspectorError(
          code: .badRequest, message: "no simulator `\(requested)`; `xcrun simctl list devices` lists them",
          detail: requested)
      }
      guard claims.claim(requested, for: folder) else {
        let owner = claims.liveOwner(of: requested, other: folder)?.path ?? "another session"
        throw InspectorError(
          code: .deviceInUse,
          message: "the simulator `\(requested)` belongs to the session in `\(owner)`; run `init` without `--udid`",
          detail: owner)
      }
      return requested
    }

    if let previous, let device = list.device(previous),
      claims.owner(of: previous) == folder.url.standardizedFileURL.path
        || (claims.owner(of: previous) == nil && device.name.hasPrefix(prefix)),
      claims.claim(previous, for: folder)
    {
      return previous
    }

    // This folder's own first, then a booted one, which saves the boot.
    let own = folder.url.standardizedFileURL.path
    let rank = { (device: SimulatorList.Device) in
      (claims.owner(of: device.udid) == own ? 0 : 1, device.state == "Booted" ? 0 : 1, device.name)
    }
    let named = list.available.filter { $0.name.hasPrefix(prefix) }.sorted { rank($0) < rank($1) }
    for device in named where claims.claim(device.udid, for: folder) {
      return device.udid
    }

    let (type, runtime) = try list.blueprint(like: previous, family: family)
    var name = "\(prefix)\(type.name)"
    let taken = Set(list.all.map(\.name))
    var number = 2
    while taken.contains(name) {
      name = "\(prefix)\(type.name) \(number)"
      number += 1
    }
    let created = try await run(["create", name, type.identifier, runtime], in: environment)
    let udid = created.trimmingCharacters(in: .whitespacesAndNewlines)
    // A new simulator is nobody's yet; only a concurrent `init` that read the same UDID could
    // hold it, and none can.
    _ = claims.claim(udid, for: folder)
    return udid
  }

  /// The first ticket key (`[A-Z][A-Z0-9]+-[0-9]+`) in `branch`, else in `directory`, else
  /// `directory` itself.
  ///
  /// In the branch the match ignores case and the key comes out in upper case, because branch
  /// names often carry it in lower case (`feature/abc-123-login`); a directory needs it in upper
  /// case, so `app-1.2` stays a plain name.
  static func label(branch: String?, directory: String) -> String {
    if let branch, let match = branch.firstMatch(of: /[A-Za-z][A-Za-z0-9]+-[0-9]+/) {
      return match.output.uppercased()
    }
    if let match = directory.firstMatch(of: /[A-Z][A-Z0-9]+-[0-9]+/) { return String(match.output) }
    return directory
  }

  /// Runs `xcrun simctl <arguments>` and returns its stdout.
  static func run(_ arguments: [String], in environment: Environment) async throws(InspectorError) -> String {
    let output = try await environment.runProcess(["/usr/bin/xcrun", "simctl"] + arguments)
    guard output.status == 0 else {
      let text = (output.stderr.isEmpty ? output.stdout : output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
      throw InspectorError(
        code: .badRequest, message: "`simctl \(arguments.first ?? "")` failed: \(text)", detail: text)
    }
    return output.stdout
  }
}

/// `xcrun simctl list -j devices devicetypes runtimes`: what exists and what a new simulator can be.
struct SimulatorList: Decodable {
  struct Device: Decodable {
    var udid: String
    var name: String
    var state: String?
    var isAvailable: Bool?
    var deviceTypeIdentifier: String?
  }

  struct DeviceType: Decodable {
    var identifier: String
    var name: String
    var productFamily: String?
  }

  struct Runtime: Decodable {
    var identifier: String
    var version: String
    var platform: String?
    var isAvailable: Bool?
    var supportedDeviceTypes: [DeviceType]?
  }

  /// Every simulator, by the identifier of its runtime.
  var devices: [String: [Device]]
  var runtimes: [Runtime]

  static func load(in environment: Environment) async throws(InspectorError) -> SimulatorList {
    let text = try await Simulator.run(["list", "-j", "devices", "devicetypes", "runtimes"], in: environment)
    do {
      return try JSONDecoder().decode(SimulatorList.self, from: Data(text.utf8))
    } catch {
      throw InspectorError(code: .badRequest, message: "could not read `simctl list`", detail: "\(error)")
    }
  }

  var all: [Device] { devices.values.flatMap(\.self) }

  /// The simulators that can boot, in a stable order.
  var available: [Device] { all.filter { $0.isAvailable ?? true }.sorted { $0.udid < $1.udid } }

  /// The available simulator `udid`.
  func device(_ udid: String) -> Device? { available.first { $0.udid == udid } }

  /// The simulator `udid`, available or not, with the identifier of its runtime.
  private func runtimeAndDevice(_ udid: String) -> (String, Device)? {
    for (runtime, list) in devices {
      if let device = list.first(where: { $0.udid == udid }) { return (runtime, device) }
    }
    return nil
  }

  /// The device type and runtime for a new simulator: those of `previous` while its runtime is
  /// available, else the first `family` type (`simctl` lists the newest first) of the newest iOS
  /// runtime, the one supporting most types when several share its version.
  func blueprint(like previous: String?, family: Simulator.Family) throws(InspectorError) -> (DeviceType, String) {
    let iOS = runtimes.filter { $0.platform == "iOS" && ($0.isAvailable ?? true) }
    if let previous, let (runtimeID, device) = runtimeAndDevice(previous),
      let runtime = iOS.first(where: { $0.identifier == runtimeID }),
      let type = runtime.supportedDeviceTypes?.first(where: { $0.identifier == device.deviceTypeIdentifier })
    {
      return (type, runtime.identifier)
    }
    let ordered = iOS.sorted {
      let order = $0.version.compare($1.version, options: .numeric)
      if order != .orderedSame { return order == .orderedDescending }
      return ($0.supportedDeviceTypes?.count ?? 0) > ($1.supportedDeviceTypes?.count ?? 0)
    }
    for runtime in ordered {
      if let type = runtime.supportedDeviceTypes?.first(where: { $0.productFamily == family.rawValue }) {
        return (type, runtime.identifier)
      }
    }
    throw InspectorError(
      code: .badRequest,
      message: """
        no iOS runtime with an \(family.rawValue) to create a simulator on; install one in Xcode's \
        Components settings
        """,
      detail: iOS.map(\.identifier).joined(separator: "\n"))
  }
}

/// Which `.inspector/` folder holds which simulator: `<udid>.json` with the folder's path.
struct SimulatorClaims {
  let directory: URL
  let now: Date

  private struct Claim: Codable {
    var owner: String
    var claimedAt: Date
  }

  /// The path of the folder that claimed `udid`, live or not.
  func owner(of udid: String) -> String? {
    guard let data = try? Data(contentsOf: file(udid)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(Claim.self, from: data))?.owner
  }

  /// The folder other than `folder` whose `config.json` still names `udid` and that claimed it.
  func liveOwner(of udid: String, other folder: InspectorFolder) -> URL? {
    guard let owner = owner(of: udid), owner != folder.url.standardizedFileURL.path else { return nil }
    let url = URL(filePath: owner, directoryHint: .isDirectory)
    guard (try? InspectorFolder(url: url).config())?.udid == udid else { return nil }
    return url
  }

  /// Claims `udid` for `folder` unless another live session holds it; `false` when one does or
  /// a concurrent `init` claimed it first.
  func claim(_ udid: String, for folder: InspectorFolder) -> Bool {
    let path = folder.url.standardizedFileURL.path
    let current = owner(of: udid)
    if current != nil, current != path {
      guard liveOwner(of: udid, other: folder) == nil else { return false }
      try? FileManager.default.removeItem(at: file(udid))
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try encoder.encode(Claim(owner: path, claimedAt: now))
      // Without overwriting, so of two `init`s taking a free simulator at once only one wins.
      try data.write(to: file(udid), options: current == path ? .atomic : .withoutOverwriting)
      return true
    } catch {
      return owner(of: udid) == path
    }
  }

  private func file(_ udid: String) -> URL { directory.appending(path: "\(udid).json") }
}
