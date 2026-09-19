// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "FinderTerminal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FinderTerminal", targets: ["FinderTerminal"]),
    ],
    targets: [
        // SwiftTerm is vendored so the reverse-video fix can be applied: it sits
        // in the library's internals and cannot be patched from outside its
        // module. See Vendor/SwiftTerm/README.md for the patch list and how to
        // move to a newer upstream release.
        .target(
            name: "SwiftTerm",
            path: "Vendor/SwiftTerm/Sources",
            exclude: ["Mac/README.md"],
            // The Metal renderer loads its shader through Bundle.module, which
            // only exists once the target declares a resource.
            resources: [.process("Apple/Metal/Shaders.metal")],
            // Swift 6 language mode is a separate migration: upstream SwiftTerm
            // predates strict concurrency and fails on it.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FinderTerminal",
            dependencies: ["SwiftTerm"],
            path: "Sources/FinderTerminal",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
