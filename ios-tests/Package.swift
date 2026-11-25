// swift-tools-version: 6.3
import PackageDescription

// Runs InspectorKit's UIKit tests (`Tests/InspectorKitTests/InterfaceInspectionTests.swift`, linked
// in) on an iOS simulator: the root package's scheme also builds the Mac-only CLI, which fails for
// iOS. From this folder:
//   xcodebuild test -scheme ios-tests -destination 'platform=iOS Simulator,id=<udid>'
let package = Package(
  name: "ios-tests",
  platforms: [.iOS(.v18)],
  products: [.library(name: "Host", targets: ["Host"])],
  dependencies: [.package(name: "inspector", path: "..")],
  targets: [
    .target(name: "Host"),
    .testTarget(name: "InterfaceTests", dependencies: [.product(name: "InspectorKit", package: "inspector")]),
  ]
)
