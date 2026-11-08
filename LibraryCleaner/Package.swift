// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LibraryCleaner",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LibraryCleaner",
            path: "Sources/LibraryCleaner"
        )
    ]
)
