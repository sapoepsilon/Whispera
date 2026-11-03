// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "agent-tmux", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WhisperaTmux", targets: ["WhisperaTmux"])],
    dependencies: [.package(path: "../agent-tui-protocol")],
    targets: [.target(name: "WhisperaTmux", dependencies: [.product(name: "WhisperaAgents", package: "agent-tui-protocol")])])
