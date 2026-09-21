// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BMSlicer", platforms: [.macOS(.v13)], products: [.executable(name: "BMSlicer", targets: ["BMSlicer"])], targets: [
    .target(name: "CVorbis", publicHeadersPath: "include"),
    .target(name: "BMSlicerCore", dependencies: ["CVorbis"]),
    .executableTarget(name: "BMSlicer", dependencies: ["BMSlicerCore"]),
    .executableTarget(name: "BMSlicerCheck", dependencies: ["BMSlicerCore"], path: "Tests/BMSlicerCoreTests")
])
