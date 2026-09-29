// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NetworkPortEval", platforms: [.macOS("26.0")], products: [.executable(name: "NetworkPortEval", targets: ["NetworkPortEval"])], targets: [.executableTarget(name: "NetworkPortEval"), .testTarget(name: "NetworkPortEvalTests", dependencies: ["NetworkPortEval"])])
