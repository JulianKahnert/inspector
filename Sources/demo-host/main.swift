import Foundation
import InspectorKit

/// Simulates the app side on the Mac, so the inspector can be exercised without an iOS build.
actor Counter {
  var value = 0
  func increment() { value += 1 }
  func set(_ newValue: Int) { value = newValue }
}

let counter = Counter()
let inspector = Inspector.shared

inspector.state("counter") { await counter.value }
inspector.state("device") {
  ["name": ProcessInfo.processInfo.hostName, "pid": "\(ProcessInfo.processInfo.processIdentifier)"]
}
inspector.action("counter.increment") { await counter.increment() }
inspector.action("counter.set") { (value: Int) in await counter.set(value) }

print("demo-host advertising \(BonjourTransport.serviceType) …")
try await inspector.serve(app: "DemoHost")
