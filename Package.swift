// swift-tools-version: 6.0
import PackageDescription

// NOTE: Swift 5 language mode for now. CGEventTap uses C function pointers that
// fight strict concurrency, and getting the pipeline running matters more than
// winning that argument today. Revisit once things are stable.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "MurmurCore", swiftSettings: mode),

        .target(name: "MurmurStore", dependencies: ["MurmurCore"], swiftSettings: mode),

        .target(
            name: "MurmurAudio",
            dependencies: ["MurmurCore"],
            swiftSettings: mode
        ),

        .target(
            name: "MurmurASR",
            dependencies: ["MurmurCore", "MurmurAudio"],
            swiftSettings: mode
        ),

        .target(name: "MurmurCleanup", dependencies: ["MurmurCore"], swiftSettings: mode),

        .target(name: "MurmurUI", dependencies: ["MurmurCore", "MurmurStore", "MurmurCleanup"], swiftSettings: mode),

        // Dev tool — transcribe a file through the real engine, no mic needed.
        .executableTarget(
            name: "murmur-cli",
            dependencies: ["MurmurASR", "MurmurAudio", "MurmurStore", "MurmurCleanup"],
            swiftSettings: mode
        ),

        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore", "MurmurAudio", "MurmurASR", "MurmurStore", "MurmurUI"],
            swiftSettings: mode
        ),
    ]
)
