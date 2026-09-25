// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "inspector",
    platforms: [.macOS(.v26), .iOS(.v18)],
    products: [
        .library(name: "InspectorKit", targets: ["InspectorKit"]),
        .executable(name: "inspector", targets: ["inspector"]),
    ],
    targets: [
        .target(name: "InspectorKit", swiftSettings: .standard),
        .executableTarget(name: "inspector", dependencies: ["InspectorKit"], swiftSettings: .standard),
        .executableTarget(name: "demo-host", dependencies: ["InspectorKit"], swiftSettings: .standard),
        .testTarget(name: "InspectorKitTests", dependencies: ["InspectorKit"], swiftSettings: .standard),
    ]
)

extension [SwiftSetting] {
    /// Concurrency profile applied uniformly to every target.
    ///
    /// Default isolation deliberately stays `nonisolated` (no `.defaultIsolation(MainActor.self)`),
    /// so nothing is imposed on consumers and the meaning of a declaration never depends on an
    /// invisible module flag — UI types are annotated `@MainActor` explicitly instead.
    /// The usability features implied by Swift 6 language mode (RegionBasedIsolation,
    /// GlobalActorIsolatedTypesUsability, …) are already on and intentionally not repeated.
    static var standard: [SwiftSetting] {
        [
            // SE-0461: a `nonisolated async` function inherits the caller's actor instead of
            // hopping to the global executor, removing most spurious "sending risks data races"
            // errors. Background work is opted into per function with `@concurrent`.
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),

            // SE-0470: a `@MainActor` type conforming to a non-isolated protocol (Equatable,
            // Hashable, Identifiable, …) gets an inferred isolated conformance instead of an error.
            .enableUpcomingFeature("InferIsolatedConformances")
        ]
    }
}
