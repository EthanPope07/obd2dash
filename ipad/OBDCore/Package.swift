// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "OBDCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "OBDCore", targets: ["OBDCore"])],
    targets: [.target(name: "OBDCore"), .testTarget(name: "OBDCoreTests", dependencies: ["OBDCore"])]
)
