# Agent TUI Protocol

`WhisperaAgents` is a Foundation-only Swift library for apps that display agent terminals.
Adapters are independent Swift packages: [agent-herdr](https://github.com/sapoepsilon/agent-herdr) and [agent-tmux](https://github.com/sapoepsilon/agent-tmux). All support iOS 17 and macOS 14;
no Whispera account, UIKit, AppKit, process launcher or credential is required.

```swift
import WhisperaAgents
import WhisperaHerdr

let providers = AgentTUIRegistry([HerdrTUIProvider()])
let adapter = providers.provider("herdr")
let conversation = adapter.transcript(from: terminalSnapshot)
let keys = adapter.keys(for: .nextTab)
// The host sends keys only after an explicit user action.
```

To add a provider such as OpenCode, implement `AgentTUIProvider` and register it.
The adapter owns terminal interpretation and key mapping. The host owns its
transport, permissions, launch policy and UI. Unregistered providers retain raw
text through `PlainTerminalProvider`; the raw terminal should remain available
for every provider because terminal snapshots are not complete chat histories.

This is the public Swift adapter interface, not a new HERDR socket protocol.
HERDR's existing `agent.read` and `agent.send_keys` APIs remain the transport.
Licensed under MIT; see [LICENSE](LICENSE).

## Install

Add the package to Xcode or Swift Package Manager:

```swift
.package(url: "https://github.com/sapoepsilon/agent-tui-protocol", from: "0.2.0")
```

Use `.product(name: "WhisperaAgents", package: "agent-tui-protocol")` for the interface,
Add `agent-herdr` and `.product(name: "WhisperaHerdr", package: "agent-herdr")` for HERDR, or `agent-tmux` with `WhisperaTmux` for tmux. Version 0.2 moves the old bundled HERDR product into its own package.
Run `swift test` to verify the parser, key mapping, raw fallback and snapshot fallback. The provider packages test their transport and metadata projection.

## Provider contract

A provider is a pure, Sendable value: `id`, `displayName`,
`transcript(from:)`, and `keys(for:)`. Register instances explicitly with
`AgentTUIRegistry`. No executable discovery or automatic keystrokes occur.
An OpenCode adapter can implement the same interface in another package without
modifying the interface or host UI. OpenCode is not implemented in this release.

The included parser understands common transcript markers and terminal question boxes.
Its output is a best-effort view of one snapshot; keep the original terminal available.
Hosts own authentication, connectivity, user confirmation, and dispatching returned keys.

`AgentSessionTransport` defines discovery, bounded snapshots, literal prompt sending and validated keys. `TerminalSession` carries stable pane identity and display metadata. Hosts supply their own process runner, authentication and network path.

## Interactive asks

`AgentAsk` describes a question an agent is waiting on, whatever drew it: Claude Code's
AskUserQuestion form (1–4 tabbed questions, single or multi-select, "Type something", a
review step), Codex's request_user_input (numbered questions with notes), a permission
confirm or a numbered menu (`ChoiceMenu`). Answers are semantic, never keys:

```swift
let driver = AgentAskDriver(terminal: HerdrAskTerminal(target: "w1:p1", call: herdrCall))
if var ask = try driver.current() {
    if !ask.complete { ask = try driver.discover(ask) }   // visits unread tabs, answers nothing
    try driver.submit(ask, answers: [AgentAskAnswer(question: 0, optionIDs: ["2"]),
                                     AgentAskAnswer(question: 1, optionIDs: ["1", "3"], other: "Profiling")])
}
```

A harness adapter implements `AgentAskTerminal` (`read`, `send(keys:)`, `type`, `blocked`).
`AgentAskDriver` plans every key batch from a fresh read and confirms its effect before the
next one, so a changed or answered ask stops it (`AgentAskError.changed` / `.stuck`) instead
of receiving blind keys. Parsers are tested against screens captured from Claude Code
2.1.312 and Codex 0.164.0 (`Tests/WhisperaAgentsTests/Fixtures`).

Asks can also come from a structured transport. `AgentAskSource` (`pending`, `answer`) is the
seam: `TerminalAskSource` wraps the screen driver, and an ACP client adapter maps
`session/request_permission` with `ACPAsk` (ACP option ids, no keys). Each source can live in
its own package (`agent-herdr`, `agent-tmux`, a future `agent-acp`) on top of this core.
