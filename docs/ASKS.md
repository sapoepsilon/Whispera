# Interactive asks

Agents stop and ask the owner things: Claude Code's AskUserQuestion form, Codex's
request_user_input, permission confirms, numbered menus. This layer shows them on the
phone and enters the owner's answer on the Mac, so they no longer have to be answered at the
terminal.

## Design

```
agent-tui-protocol (WhisperaAgents)        harness-neutral core
  AgentAsk / AgentAskAnswer                 the model: questions, options, semantic answers
  AgentAskParser                            Claude Code + Codex question forms, ChoiceMenu fallback
  ChoiceMenu / ChoiceMenuParser             permission prompts and numbered menus (moved from R1)
  AgentAskDriver                            key planning with a re-read-and-verify loop
  AgentAskTerminal                          harness seam: read, send(keys:), type, blocked
  AgentAskSource, TerminalAskSource, ACPAsk structured-source seam (ACP, a future herdr API)
agent-herdr  HerdrAskTerminal               agent.read (text + ansi), agent.send_keys, agent.get
agent-tmux   TmuxAskTerminal                capture-pane -p [-e] -J, send-keys, send-keys -l
LinkHelper   AskTracker (AgentAsks.swift)   cache, push, routes; PermissionTracker unchanged
iOS          AgentAsk.swift, AgentAskCard   model, signed client, the card
```

**Model.** `AgentAsk` has a `prompt_id` (digest of the source, headers, question texts and
option labels, never the cursor or step), `kind` (`confirm`, `single`, `multi`, `form`,
`free_text`), `source` (`claude`, `codex`, `menu`, `acp`), `questions[{header, text,
options[{id, label, description, kind}], multi_select, allows_other, other_label,
answered}]`, `step` (the question on screen; `questions.count` is the review step),
`has_submit_step` and `complete`. Answers are `{question, option_ids, other}`. The phone never
sends keys.

**Parsing.** The core parses plain screen text, plus the ANSI copy when the harness has it:
Claude Code draws every tab header the same in plain text and marks the active tab only with a
background colour. Without colours the question text resolves the step. A Claude form shows one
question at a time, so a fresh read knows the headers of every tab but only the current
question (`complete: false`). `GET /v1/agents/{id}/ask` runs `AgentAskDriver.discover`, which
tabs through the unread questions and back. It sends navigation keys only and never answers.
Question forms are excluded from the permission parser, so a Codex question is never shown as
a permission.

**Driving.** `AgentAskDriver.submit` plans each key batch from a fresh read and confirms
its effect by reading again (cursor on the row, box checked, text shown, step advanced) before
the next batch. Before anything is sent the screen must merge with the answered ask, so a
different ask, one answered at the Mac or one that is gone stops it with nothing typed
(`changed`/`unparsed` → 409 `ask_changed`/`ask_gone`). A key without its effect stops it at
that point (`stuck` → 409 `ask_stuck`). Frames caught mid-redraw (the plain and ANSI captures
are two reads) are retried until the timeout (3 s). Rules learned from real screens:

| UI | rule |
|---|---|
| Claude, any question | the "Type something" row is a text field: Tab and arrows do nothing there, so the driver steps up off it before changing tabs |
| Claude, single-select | Enter on an option or on typed text answers and advances (a lone question submits) |
| Claude, multi-select | Space or Enter toggles; typing in "Type something" checks it; "Next"/"Submit" row + Enter moves on |
| Claude, typed text | `ctrl+u` clears the field before retyping |
| Claude, review | the driver checks each answer line contains the labels it entered, then presses "Submit answers" |
| Claude, navigation | `tab` / `shift+tab` between tabs (no wrap); revisiting a single-select resets the cursor to 1 and marks the answer with ✔ |
| Codex | `←/→` between questions; Enter answers one question and advances, then "submit all" on the last; Tab opens notes on the cursor row ("None of the above" + notes = the Other answer); Tab again clears them |
| Menus | `ChoiceMenu.keys(for:)` (arrows from the cursor, Enter), as in R1 |

**Mac API** (all WL1-signed, capability `agent_asks`):

- `GET /v1/agents/{id}/ask` → `{id, status, ask, screen}`, discovering unread tabs.
- `POST /v1/agents/{id}/ask` `{prompt_id, answers:[{question, option_ids, other}]}` →
  `{id, prompt_id, source, steps, keys}`. A permission prompt id goes through
  `PermissionTracker.answer`.
- `GET /v1/asks` → every pending question form and permission prompt (as `confirm` asks).
- Agent objects carry `ask` when one is pending. `agent.ask` and `approval.resolved` events fire,
  and a new ask goes through the approval push path (`ApprovalPush`, key "your answer"). That
  path is ready, but APNs is blocked on signing.
- OpsLog events: `ask.pending`, `ask.push`, `ask.discovered`, `ask.answered`, `ask.failed`,
  `ask.resolved`.

**iOS.** `AgentAskCard(ask:onSubmit:)` is the single entry point (see "Mounting").
`AgentAskModel` loads and submits. `AgentAskDraft` holds the selection logic and is unit-tested.
The demo daemon serves the captured three-question form on `w5:p2`. `-WLAskPreview
q0|q1|other|q2|review|stale|sent` opens the card alone in debug builds.

## Mounting (Agents redesign)

```swift
// Inbox: list pending asks.
let asks = try await session.permissionClient?.pendingAsks()      // GET /v1/asks
// Detail: one agent's ask, complete (reads every tab on the Mac).
let model = AgentAskModel(agentID: agent.id, api: { session.permissionClient },
                          onAnswered: { await reload() })
await model.refresh()
if let ask = model.ask {
    AgentAskCard(ask: ask) { replies in await model.submit(replies) }
}
```

- `onSubmit` returns `.sent` (the card shows "Sent to your Mac"), `.stale(message)` (answered on
  the Mac or the ask changed; nothing was typed; reload) or `.failed(message)`.
- A `confirm` ask from `/v1/asks` is a permission prompt. The existing `AgentPermissionCard`
  still fits it, or `AgentAskCard` renders it as one question.
- An ask with `complete == false` (from a list) shows a loading line. Call `model.refresh()`.
- The card is keyed by `prompt_id`, so a new ask resets its draft.

## What herdr and tmux expose

| | herdr 0.9.1 | tmux 3.7 |
|---|---|---|
| screen | `agent.read` `visible`/`recent`/`detection`, `format: text\|ansi` | `capture-pane -p` (`-e` colours, `-J` joins wraps) |
| keys | `agent.send_keys`: named keys and any single character (`a`, `-`, `é`, `space`, `backspace`, `ctrl+u`, `shift+tab`) | `send-keys` named keys; `send-keys -l` literal text |
| text | per-character `agent.send_keys` (`pane.send_text` exists, but the helper keeps `pane.*` closed) | `send-keys -l -- text` |
| waiting signal | `agent_status: blocked` with `agent explain` naming the rule (`live_blocked_form`, region after the last rule) | none: `pane_current_command` is Claude's version (`2_1_312`), `pane_title` is the session name, and bell/activity/silence flags do not change |
| events | `events.subscribe` `agent.status` | control mode (`-C`) streams output, not state |
| structured question API | none | none |

## Gaps

- **No structured question API**, so asks are screen-scraped and any change to Claude Code's
  or Codex's layout can break the parsers. The fixtures pin Claude Code 2.1.312 and Codex
  0.164.0. A parse failure is safe: no ask, and the terminal keys remain.
- **herdr `blocked` fires for AskUserQuestion and request_user_input**, but Claude Code reports
  `idle` while its "Type something" row has focus (the footer changes to `-- INSERT --`). The
  tracker therefore re-reads on every status change of an agent with a pending ask, rather
  than clearing on "not blocked". Codex's `/model` and effort pickers report `done`, not
  `blocked`.
- **tmux has no blocked signal**, so asks are found by reading. `GET /v1/agents` peeks at up to 8
  tmux panes (reads only). There is no push for tmux asks unless something lists agents.
- **Discovery sends navigation keys** (Tab / ←→) when the phone opens a multi-question ask. They
  answer nothing and return to the original tab, but they are visible at the Mac.
- **Remote herdr machines** go through the CLI, which treats a key starting with `-` as an option,
  so free text containing `-` cannot be typed on another machine.
- **Codex** in default mode has request_user_input only behind the
  `default_mode_request_user_input` feature (Plan mode has it). Codex questions are single-select
  in the captured UI. Free-text-only questions (`free_text`) are modelled but no screen was
  captured.
- **Claude's "Chat about this"** row is never used.
- **Builds:** LinkHelper and the Xcode project pin the new agent-tui-protocol, agent-herdr and
  agent-tmux commits by revision. Push those package branches before building elsewhere.
  Locally, SwiftPM mirrors point the URLs at `~/Developer/agent-*`.

## Upstream herdr feature request (sketch)

A structured question API would replace the scraping and the key planning:

- `agent.question.get {target}` returns the pending question as data: `{id, source, questions:
  [{header, text, options:[{id,label,description}], multi_select, allows_other}], step}`.
  Integrations (Claude Code hooks, Codex app-server, ACP `session/request_permission`)
  already know this before drawing it.
- `agent.question.answer {target, id, answers:[{question, option_ids, other}]}` delivers the
  answer through the agent's own channel, not keys, and returns `stale` if `id` moved on.
- An `agent.question` event alongside `agent.status`, plus `blocked_reason: question |
  permission | menu` on `agent_info`.
- Keep `blocked` while a question's text field has focus.

`AgentAskSource` is the seam such an API (or an ACP adapter, see `ACPAsk`) plugs into, with no
change to the Mac routes or the phone.

## Evidence

- Fixtures: `agent-tui-protocol/Tests/WhisperaAgentsTests/Fixtures` (Claude Code in herdr and
  tmux, Codex in herdr: every step, plain + ANSI).
- E2E: `/tmp/asks-sandbox/e2e.sh` runs an isolated helper on its own port and state against
  throwaway herdr session `asktest` and tmux server `-L asktest`. A soft phone answers over WL1,
  and the agents echoed exactly the chosen answers (Claude Code in herdr and tmux, Codex in
  herdr).
