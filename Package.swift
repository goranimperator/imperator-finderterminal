// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FinderTerminal",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FinderTerminal", targets: ["FinderTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "FinderTerminal",
            dependencies: ["SwiftTerm"],
            path: "Sources/FinderTerminal"
        ),
    ]
)
