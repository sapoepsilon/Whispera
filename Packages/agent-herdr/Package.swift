// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "agent-herdr", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WhisperaHerdr", targets: ["WhisperaHerdr"])],
    dependencies: [.package(path: "../agent-tui-protocol")],
    targets: [.target(name: "WhisperaHerdr", dependencies: [.product(name: "WhisperaAgents", package: "agent-tui-protocol")])])
