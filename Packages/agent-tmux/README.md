# tmux Swift adapter

Independent MIT Swift package using [agent-tui-protocol](https://github.com/sapoepsilon/agent-tui-protocol).

```swift
.package(url: "https://github.com/sapoepsilon/agent-tmux", from: "0.1.0")
// Target dependency: .product(name: "WhisperaTmux", package: "agent-tmux")
```

Import `WhisperaTmux` and register `TmuxTUIProvider()` for transcript rendering and terminal key mapping.
`TmuxClient` implements `AgentSessionTransport`: list existing live panes, capture visible/recent text, paste a literal prompt and send validated navigation keys.

The importing host injects `TmuxClient(run:)`, an argument-array runner for its trusted tmux executable. It must impose a timeout and output limit. For example, prepend `-S` and a private socket path to isolate QA from the owner's sessions. SSH and authentication belong to the host; the package never invokes a shell or creates/kills sessions. Stable `%N` pane IDs are required. Pane state is unknown unless another integration supplies it; terminal text is not a durable chat history.

iOS 17 and macOS 14. All code is Foundation-only; command execution remains on your host. Read `LICENSE` and run `swift test`.
