// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "FinderTerminal",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FinderTerminal", targets: ["FinderTerminal"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3"),
    ],
    targets: [
        .executableTarget(
            name: "FinderTerminal",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/FinderTerminal",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
