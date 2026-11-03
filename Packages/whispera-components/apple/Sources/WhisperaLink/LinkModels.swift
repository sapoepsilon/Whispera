import Foundation

// JSON bodies of the whispera-link daemon API (PROTOCOL §5). Property names are the
// snake_case wire names on purpose: these types are decoded with a plain
// `JSONDecoder`, and a reader comparing them with the protocol document sees the same
// words.

/// `GET /v1/health` (§5.1).
public struct LinkHealth: Codable, Sendable {
	public var ok: Bool
	public var service: String?
	public var version: String?
	public var `protocol`: Int?
	public var daemon_fp: String
	public var server_time: Int
	public var herdr: String?
	public var broker: String?
	public var apns: String?
	public var stt: String?
}

/// `POST /v1/pair` response (§3.3).
public struct PairResponse: Codable, Sendable {
	public var device_id: String
	public var daemon_pubkey: String
	public var daemon_fp: String
	public var approve_fp: String
	public var stt_key: String
	public var stt_base_url: String
	public var server_time: Int
}

/// `POST /v1/pair/commit` response (§3.3, pairing v2). Signed by the daemon key in
/// `X-WL-Server-Signature` over `WL1-PAIR-COMMIT-ACK`.
public struct PairCommitAck: Codable, Sendable, Equatable {
	public var v: Int
	public var pair_id: String
	/// The commitment the daemon stored, echoed so a phone never reveals its code to an
	/// acknowledgement of somebody else's commitment.
	public var commitment: String
	public var daemon_pubkey: String
	public var daemon_fp: String
	public var expires_at: Int
}

/// A paired device as the daemon reports it (§5.3).
public struct LinkDevice: Codable, Sendable, Equatable {
	public struct APNs: Codable, Sendable, Equatable {
		public var token: String?
		public var env: String?
	}

	public var device_id: String
	public var name: String
	public var link_fp: String?
	public var approve_fp: String?
	public var apns: APNs?
	public var created_at: Int?
	public var last_seen_at: Int?
	public var revoked_at: Int?
}

public enum AgentStatus: String, Sendable, CaseIterable {
	case blocked, working, idle, done, unknown

	public var sortRank: Int {
		switch self {
		case .blocked: return 0
		case .working: return 1
		case .idle: return 2
		case .done: return 3
		case .unknown: return 4
		}
	}
}

/// One herdr agent pane (§5.4).
public struct LinkAgent: Codable, Sendable, Identifiable, Equatable {
	public var id: String
	public var agent: String?
	public var display_agent: String?
	public var provider: String?
	public var workspace_label: String?
	public var tab_label: String?
	public var name: String?
	public var title: String?
	public var status: String
	public var cwd: String?
	public var workspace_id: String?
	public var tab_id: String?
	public var focused: Bool?
	public var revision: Int?
	/// Which herdr machine runs it; nil from a Mac that predates multi-machine agents.
	public var machine: AgentMachine?

	public init(
		id: String, agent: String? = nil, display_agent: String? = nil, name: String? = nil, title: String? = nil,
		status: String, cwd: String? = nil, workspace_id: String? = nil, tab_id: String? = nil, focused: Bool? = nil,
		revision: Int? = nil, machine: AgentMachine? = nil, provider: String? = nil, workspace_label: String? = nil, tab_label: String? = nil
	) {
		self.id = id
		self.provider = provider
		self.workspace_label = workspace_label
		self.tab_label = tab_label
		self.agent = agent
		self.display_agent = display_agent
		self.name = name
		self.title = title
		self.status = status
		self.cwd = cwd
		self.workspace_id = workspace_id
		self.tab_id = tab_id
		self.focused = focused
		self.revision = revision
		self.machine = machine
	}

	public var agentStatus: AgentStatus { AgentStatus(rawValue: status) ?? .unknown }

	public var label: String {
		if let name, !name.isEmpty { return name }
		if let tab_label, !tab_label.isEmpty, Int(tab_label) == nil { return tab_label }
		if let workspace_label, !workspace_label.isEmpty { return workspace_label }
		if let title, !title.isEmpty { return title }
		return display_agent ?? agent ?? id
	}

	public var workspace: String { workspace_id ?? "—" }
}

/// `"machine":{"id":"local"|"<machine id>","label":"This Mac"|"<label>"}` on every agent.
public struct AgentMachine: Codable, Sendable, Equatable, Hashable {
	public var id: String
	public var label: String

	public static let localID = "local"

	public init(id: String, label: String) {
		self.id = id
		self.label = label
	}

	public var isLocal: Bool { id == Self.localID }
}

/// One herdr machine in `GET /v1/agents`'s `machines`.
public struct MachineStatus: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var label: String
	/// `"ok"` | `"unreachable"`.
	public var status: String
	public var error: String?

	public init(id: String, label: String, status: String, error: String? = nil) {
		self.id = id
		self.label = label
		self.status = status
		self.error = error
	}

	public var isReachable: Bool { status == "ok" }
}

public struct AgentList: Codable, Sendable {
	public var agents: [LinkAgent]
	public var herdr_version: String?
	/// Nil from a Mac that predates multi-machine agents.
	public var machines: [MachineStatus]?

	public init(agents: [LinkAgent], herdr_version: String? = nil, machines: [MachineStatus]? = nil) {
		self.agents = agents
		self.herdr_version = herdr_version
		self.machines = machines
	}
}

/// `POST /v1/agents` body. Without `pane_id` the Mac opens a new tab for it.
public struct StartAgentRequest: Codable, Sendable, Equatable {
	public var name: String
	/// `"claude"` | `"codex"` | any kind the Mac's herdr supports.
	public var kind: String
	/// `"local"` or a herdr machine id; nil = local.
	public var machine: String?
	public var pane_id: String?
	public var workspace_id: String?
	public var cwd: String?
	public var args: [String]?
	public var timeout_ms: Int?

	public init(
		name: String, kind: String, machine: String? = nil, pane_id: String? = nil, workspace_id: String? = nil,
		cwd: String? = nil, args: [String]? = nil, timeout_ms: Int? = nil
	) {
		self.name = name
		self.kind = kind
		self.machine = machine
		self.pane_id = pane_id
		self.workspace_id = workspace_id
		self.cwd = cwd
		self.args = args
		self.timeout_ms = timeout_ms
	}
}

/// `POST /v1/agents/{id}/keys` and `/interrupt`.
public struct KeysResult: Codable, Sendable, Equatable {
	public var id: String
	/// How many keys were sent.
	public var keys: Int?
}

/// `POST /v1/agents/{id}/stop`.
public struct StopResult: Codable, Sendable, Equatable {
	public var id: String
	public var stopped: Bool
}

/// What the phone's approval pushes say (`PUT /v1/devices/me/push`).
public enum PushTextMode: String, Codable, Sendable, CaseIterable {
	/// The request's text, sealed with WLP1 for the phone's extension.
	case named
	/// "Approval requested" — nothing about the request.
	case generic
}

/// The keys `LinkClient.interrupt` may send.
public enum InterruptKey: String, Sendable, CaseIterable {
	case esc
	case ctrlC = "ctrl+c"
}

public struct AgentEnvelope: Codable, Sendable {
	public var agent: LinkAgent
}

public struct AgentOutput: Codable, Sendable, Equatable {
	public var id: String
	public var source: String
	public var text: String
	public var revision: Int?
	public var truncated: Bool?
}

public struct PromptResult: Codable, Sendable {
	public var agent: LinkAgent
	public var waited: Bool
}

/// A row of `GET /v1/approvals/pending` (§5.6).
public struct PendingApproval: Codable, Sendable, Identifiable, Equatable {
	public var request_id: String
	public var created_at: Int
	public var expires_at: Int
	public var op: String
	public var summary: String

	public init(request_id: String, created_at: Int, expires_at: Int, op: String, summary: String) {
		self.request_id = request_id
		self.created_at = created_at
		self.expires_at = expires_at
		self.op = op
		self.summary = summary
	}

	public var id: String { request_id }
}

public struct PendingApprovals: Codable, Sendable {
	public var approvals: [PendingApproval]
}

/// What the Mac says the request is. Must agree with the signed canonical bytes field
/// for field before the phone will sign — see `CanonicalApproval.validate`.
public struct ApprovalDisplay: Codable, Sendable, Equatable {
	public var op: String
	public var summary: String
	public var key: String
	public var project: String
	public var token: String
	public var host: String
	public var caller: String
	public var via: String
	public var broker: String

	public init(
		op: String, summary: String, key: String, project: String, token: String, host: String, caller: String,
		via: String, broker: String
	) {
		self.op = op
		self.summary = summary
		self.key = key
		self.project = project
		self.token = token
		self.host = host
		self.caller = caller
		self.via = via
		self.broker = broker
	}
}

/// `GET /v1/approvals/{id}` (§5.6).
public struct ApprovalDetail: Codable, Sendable, Equatable {
	public var request_id: String
	public var status: String
	public var created_at: Int
	public var expires_at: Int
	public var canonical_b64: String
	public var display: ApprovalDisplay
	public var decided_by: String?

	public init(
		request_id: String, status: String, created_at: Int, expires_at: Int, canonical_b64: String,
		display: ApprovalDisplay, decided_by: String? = nil
	) {
		self.request_id = request_id
		self.status = status
		self.created_at = created_at
		self.expires_at = expires_at
		self.canonical_b64 = canonical_b64
		self.display = display
		self.decided_by = decided_by
	}
}

public struct DecisionResult: Codable, Sendable, Equatable {
	public var request_id: String
	public var status: String
	public var broker_outcome: String?
}

/// What `LinkClient.events()` yields (§5.5), plus `.connected` / `.disconnected` so a
/// caller can switch to its poll fallback.
public enum LinkEvent: Sendable, Equatable {
	case connected
	case hello(lastSeq: Int?, serverTime: Int?)
	case agentStatus(id: String, status: String)
	case agentsChanged
	case approvalPending(requestID: String, expiresAt: Int?)
	case approvalResolved(requestID: String, status: String)
	case herdrDown
	case herdrUp
	case resync
	case disconnected(String)
}

/// Read-only repository patch for an agent’s working directory.
public struct AgentDiff: Codable, Sendable, Equatable {
	public var patch: String
	public var staged: Bool
}
