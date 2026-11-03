# HERDR Swift adapter

Independent MIT Swift package for HERDR, using [agent-tui-protocol](https://github.com/sapoepsilon/agent-tui-protocol).

```swift
.package(url: "https://github.com/sapoepsilon/agent-herdr", from: "0.1.0")
// Target dependency: .product(name: "WhisperaHerdr", package: "agent-herdr")
```

Import `WhisperaHerdr` and register `HerdrTUIProvider()` with `AgentTUIRegistry`.
`HerdrTUIProvider.named(_:workspaces:tabs:)` enriches metadata from HERDR's read-only workspace/tab lists.
`agent(_:)` produces a safe projection: explicit agent name, custom tab label, workspace label, then terminal title. Numeric default tabs do not mask the workspace's name. Tokens, agent sessions and terminal IDs are excluded.

iOS 17 and macOS 14. Foundation only; the host owns HERDR's socket/SSH transport, credentials, permissions and UI. No agent management happens by importing this package.
