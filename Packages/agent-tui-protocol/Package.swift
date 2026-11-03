// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "agent-tui-protocol", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WhisperaAgents", targets: ["WhisperaAgents"])],
    targets: [.target(name: "WhisperaAgents")])
