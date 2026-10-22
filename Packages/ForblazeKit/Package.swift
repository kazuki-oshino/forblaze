// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ForblazeKit",
    platforms: [.macOS("26.0")],
    products: ["ForblazeCore", "ForblazeApplication", "ForblazeMacOS"].map { .library(name: $0, targets: [$0]) },
    targets: [
        .target(name: "ForblazeCore"),
        .target(name: "ForblazeApplication", dependencies: ["ForblazeCore"]),
        .target(name: "ForblazeMacOS", dependencies: ["ForblazeApplication", "ForblazeCore"]),
        .target(name: "ForblazeTestSupport", path: "Tests/Support"),
        .testTarget(name: "ForblazeCoreTests", dependencies: ["ForblazeCore", "ForblazeTestSupport"]),
        .testTarget(name: "ForblazeApplicationTests", dependencies: ["ForblazeApplication", "ForblazeCore", "ForblazeTestSupport"]),
        .testTarget(name: "ForblazeMacOSTests", dependencies: ["ForblazeMacOS", "ForblazeApplication", "ForblazeCore", "ForblazeTestSupport"])
    ], swiftLanguageModes: [.v6])
