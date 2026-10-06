#!/usr/bin/python3
"""Fake herdr 0.9.1 socket server for the helper's tests and e2e runs. Stdlib only.

Never point the helper at a real herdr for anything that writes: this fake answers
ping, agent.list/get/read/prompt/send_keys/start, tab.create and events.subscribe, and
records every request it receives (method + params) so tests can assert what was sent.

Agents: three by default (w1:p1 codex idle, w1:p2 codex blocked, w2:p1 gemini working);
`--preset remote` gives another machine's set (w9:p1 codex idle, w9:p2 gemini working).
`tab.create` adds a tab whose root pane is a plain shell; `agent.start` turns such a pane
into an agent (it refuses a pane that already runs one).

Control requests (same socket, method names starting with `_fake.`):
  _fake.emit_status   {"pane_id", "status"}         change status + emit pane.agent_status_changed
  _fake.set_status    same as emit_status
  _fake.add_pane      {"pane_id", "agent"}           add an agent pane + emit pane.created
  _fake.remove_pane   {"pane_id"}                    remove + emit pane.closed
  _fake.events_lost   {}                             send error events_lost to subscribers, close them
  _fake.set_delay     {"seconds"}                    delay every normal response
  _fake.set_shape     {"shape": "envelope"|"flat"}   event line shape
  _fake.requests      {}                             -> {"requests": [[method, params], ...]}
  _fake.clear         {}                             forget recorded requests
  _fake.subscribers   {}                             -> {"count": n, "subscriptions": [...]}

CLI:
  fake_herdr.py --socket PATH [--preset local|remote] [--record FILE.jsonl]
  fake_herdr.py --socket PATH ctl '{"method":"_fake.emit_status","params":{"pane_id":"w1:p1","status":"done"}}'
"""

import argparse
import copy
import json
import os
import socket
import sys
import threading
import time

BLOCKED_PANE = "w1:p2"


def make_agent(pane, ws, tab, agent, status, rev, cwd, name=None):
    return {
        "pane_id": pane, "workspace_id": ws, "tab_id": tab, "terminal_id": "term-" + pane,
        "agent": agent, "display_agent": None, "name": name, "title": None,
        "agent_status": status, "cwd": cwd, "foreground_cwd": None, "focused": False,
        "revision": rev, "state_labels": {}, "tokens": {"secret_token": "must-not-leak"},
        "agent_session": {"id": "sess-1"}, "interactive_ready": True, "launch_pending": False,
    }


def default_agents(preset="local"):
    if preset == "remote":
        agents = [
            make_agent("w9:p1", "w9", "w9:t1", "codex", "idle", 4, "/Users/fake/remote/a"),
            make_agent("w9:p2", "w9", "w9:t1", "gemini", "working", 2, "/Users/fake/remote/b"),
        ]
    else:
        agents = [
            make_agent("w1:p1", "w1", "w1:t1", "codex", "idle", 12, "/Users/fake/Developer/x"),
            make_agent(BLOCKED_PANE, "w1", "w1:t1", "codex", "blocked", 7, "/Users/fake/Developer/y"),
            make_agent("w2:p1", "w2", "w2:t1", "gemini", "working", 3, "/Users/fake/Developer/z"),
        ]
        agents[2]["foreground_cwd"] = "/Users/fake/Developer/z/sub"
    return {x["pane_id"]: x for x in agents}


class FakeHerdr:
    def __init__(self, socket_path, agents=None, shape="envelope", version="0.9.1", preset="local", record=None):
        self.socket_path = socket_path
        self.agents = agents if agents is not None else default_agents(preset)
        self.shells = {}               # pane_id -> pane info for plain shell panes (from tab.create)
        self.shape = shape
        self.version = version
        self.delay = 0.0
        self.requests = []
        self.record = record
        self.subscribers = []          # list of [conn, subscriptions, lock]
        self.texts = {}
        self.next_tab = 1
        self._lock = threading.RLock()
        self._srv = None
        self._stop = threading.Event()

    # ------------------------------------------------------------------ lifecycle

    def start(self):
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(self.socket_path)
        os.chmod(self.socket_path, 0o600)
        s.listen(32)
        s.settimeout(0.2)
        self._srv = s
        threading.Thread(target=self._accept, daemon=True).start()
        return self

    def stop(self):
        self._stop.set()
        try:
            self._srv.close()
        except OSError:
            pass
        with self._lock:
            for sub in self.subscribers:
                try:
                    sub[0].close()
                except OSError:
                    pass
            self.subscribers = []
        try:
            os.unlink(self.socket_path)
        except OSError:
            pass

    def _accept(self):
        while not self._stop.is_set():
            try:
                c, _ = self._srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    # ------------------------------------------------------------------ protocol

    @staticmethod
    def _send(conn, obj, lock=None):
        data = (json.dumps(obj) + "\n").encode()
        if lock:
            with lock:
                conn.sendall(data)
        else:
            conn.sendall(data)

    def _serve(self, conn):
        buf = b""
        sub_lock = threading.Lock()
        try:
            while not self._stop.is_set():
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        req = json.loads(line)
                    except ValueError:
                        continue
                    self._handle(conn, req, sub_lock)
        except OSError:
            pass
        finally:
            with self._lock:
                self.subscribers = [s for s in self.subscribers if s[0] is not conn]
            try:
                conn.close()
            except OSError:
                pass

    def _err(self, rid, code, message):
        return {"id": rid, "error": {"code": code, "message": message}}

    def _record(self, method, params):
        with self._lock:
            self.requests.append([method, copy.deepcopy(params)])
            if self.record:
                with open(self.record, "a") as f:
                    f.write(json.dumps({"ts": time.time(), "method": method, "params": params}) + "\n")

    def _handle(self, conn, req, sub_lock):
        rid = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        if isinstance(method, str) and method.startswith("_fake."):
            return self._send(conn, {"id": rid, "result": self._control(method, params)}, sub_lock)
        self._record(method, params)
        if self.delay:
            time.sleep(self.delay)
        result = self.dispatch(method, params)
        if isinstance(result, tuple):
            return self._send(conn, self._err(rid, result[0], result[1]), sub_lock)
        if method == "events.subscribe":
            self._send(conn, {"id": rid, "result": result}, sub_lock)
            with self._lock:
                self.subscribers.append([conn, params.get("subscriptions") or [], sub_lock])
            return None
        return self._send(conn, {"id": rid, "result": result}, sub_lock)

    def dispatch(self, method, params):
        """One API call: a result dict, or (code, message) for an error."""
        if method == "ping":
            return {"type": "pong", "version": self.version, "protocol": 22, "capabilities": None}
        if method == "agent.list":
            with self._lock:
                agents = [copy.deepcopy(a) for a in self.agents.values()]
            return {"type": "agent_list", "agents": agents}
        if method == "events.subscribe":
            return {"type": "subscription_started"}
        if method == "tab.create":
            return self._tab_create(params)
        if method == "agent.start":
            return self._agent_start(params)
        if method in ("agent.get", "agent.read", "agent.prompt", "agent.send_keys"):
            target = params.get("target")
            with self._lock:
                agent = copy.deepcopy(self.agents.get(target))
            if agent is None:
                return ("agent_not_found", "agent target %s not found" % target)
            if method == "agent.get":
                return {"type": "agent_info", "agent": agent}
            if method == "agent.read":
                if params.get("source") not in ("visible", "recent", "recent_unwrapped", "detection"):
                    return ("invalid_params", "bad source")
                n = params.get("lines") or 50
                text = self.texts.get(target) or "\n".join("%s line %d" % (target, i) for i in range(1, 301))
                lines = text.split("\n")
                return {"type": "pane_read", "read": {
                    "pane_id": target, "workspace_id": agent["workspace_id"], "tab_id": agent["tab_id"],
                    "source": params["source"], "format": params.get("format", "text"),
                    "text": "\n".join(lines[-n:]), "revision": agent["revision"], "truncated": len(lines) > n}}
            if method == "agent.send_keys":
                keys = params.get("keys") or []
                if not keys or not all(isinstance(k, str) and k for k in keys):
                    return ("invalid_params", "keys must list key names")
                if "ctrl+c" in keys and keys.count("ctrl+c") >= 2:
                    threading.Timer(0.1, self._set_status, args=(target, "done")).start()
                return {"type": "keys_sent", "pane_id": target, "count": len(keys)}
            # agent.prompt
            if agent["agent_status"] == "blocked":
                return ("agent_blocked", "agent %s is blocked" % target)
            self._set_status(target, "working")
            if params.get("wait"):
                time.sleep(0.2)
                self._set_status(target, "idle")
            else:
                threading.Timer(0.2, self._set_status, args=(target, "idle")).start()
            with self._lock:
                agent = copy.deepcopy(self.agents[target])
            return {"type": "agent_prompted", "agent": agent}
        return ("unknown_method", "fake does not implement %s" % method)

    def _tab_create(self, params):
        with self._lock:
            ws = params.get("workspace_id") or "w1"
            n = self.next_tab
            self.next_tab += 1
            tab_id = "%s:t%d" % (ws, 100 + n)
            pane_id = "%s:p%d" % (ws, 100 + n)
            pane = {
                "pane_id": pane_id, "workspace_id": ws, "tab_id": tab_id, "terminal_id": "term-" + pane_id,
                "agent": None, "agent_status": "unknown", "cwd": params.get("cwd") or "/Users/fake",
                "focused": bool(params.get("focus")), "revision": 0, "label": params.get("label"),
            }
            self.shells[pane_id] = pane
            tab = {"tab_id": tab_id, "workspace_id": ws, "number": 100 + n, "label": params.get("label") or "",
                   "focused": bool(params.get("focus")), "pane_count": 1, "agent_status": "unknown"}
        self._broadcast("pane.created", {"pane": {"pane_id": pane_id, "workspace_id": ws}})
        return {"type": "tab_created", "tab": tab, "root_pane": copy.deepcopy(pane)}

    def _agent_start(self, params):
        pane_id = params.get("pane_id")
        timeout = params.get("timeout_ms")
        if timeout is not None and not (3000 < timeout <= 300000):
            return ("invalid_params", "timeout_ms must be > 3000 and <= 300000")
        with self._lock:
            if pane_id in self.agents:
                return ("pane_not_at_shell", "pane %s already runs an agent" % pane_id)
            shell = self.shells.pop(pane_id, None)
            if shell is None:
                return ("pane_not_found", "pane %s not found" % pane_id)
            agent = make_agent(pane_id, shell["workspace_id"], shell["tab_id"], params.get("kind"), "idle", 1,
                               shell["cwd"], name=params.get("name"))
            self.agents[pane_id] = agent
            out = copy.deepcopy(agent)
        self._broadcast("pane.agent_detected", {"pane_id": pane_id, "agent": params.get("kind")})
        return {"type": "agent_started", "agent": out, "argv": [params.get("kind")] + list(params.get("args") or [])}

    # ------------------------------------------------------------------ events

    def _event_line(self, name, data):
        if self.shape == "flat":
            d = dict(data)
            d["type"] = name
            return d
        if name == "pane.agent_status_changed":
            return {"event": name, "data": data}
        # herdr's general event stream uses underscore names with a typed payload
        under = name.replace(".", "_")
        d = dict(data)
        d["type"] = under
        return {"event": under, "data": d}

    def _broadcast(self, name, data, pane_id=None):
        with self._lock:
            subs = list(self.subscribers)
        sent = 0
        for conn, subscriptions, lock in subs:
            ok = False
            for s in subscriptions:
                if s.get("type") != name:
                    continue
                if name == "pane.agent_status_changed" and s.get("pane_id") != pane_id:
                    continue
                ok = True
            if ok:
                try:
                    self._send(conn, self._event_line(name, data), lock)
                    sent += 1
                except OSError:
                    pass
        return sent

    def _set_status(self, pane_id, status):
        with self._lock:
            a = self.agents.get(pane_id)
            if a is None:
                return 0
            a["agent_status"] = status
            a["revision"] += 1
            data = {"pane_id": pane_id, "workspace_id": a["workspace_id"], "agent_status": status,
                    "agent": a["agent"], "display_agent": a["display_agent"], "title": a["title"],
                    "state_labels": a["state_labels"]}
        return self._broadcast("pane.agent_status_changed", data, pane_id)

    # public helpers (Python tests)
    def emit_status(self, pane_id, status):
        return self._set_status(pane_id, status)

    def add_pane(self, pane_id, agent="codex", status="idle"):
        ws = pane_id.split(":")[0]
        with self._lock:
            self.agents[pane_id] = make_agent(pane_id, ws, ws + ":t1", agent, status, 1, "/Users/fake/Developer")
        return self._broadcast("pane.created", {"pane": {"pane_id": pane_id, "workspace_id": ws}})

    def remove_pane(self, pane_id):
        with self._lock:
            a = self.agents.pop(pane_id, None)
        return self._broadcast("pane.closed", {"pane_id": pane_id,
                                               "workspace_id": (a or {}).get("workspace_id", "")})

    def events_lost(self):
        with self._lock:
            subs, self.subscribers = list(self.subscribers), []
        for conn, _, lock in subs:
            try:
                self._send(conn, {"id": "events", "error": {"code": "events_lost", "message": "lagged"}}, lock)
                conn.shutdown(socket.SHUT_RDWR)
                conn.close()
            except OSError:
                pass
        return len(subs)

    def subscriber_info(self):
        with self._lock:
            return {"count": len(self.subscribers), "subscriptions": [s[1] for s in self.subscribers]}

    def _control(self, method, p):
        op = method[len("_fake."):]
        if op in ("emit_status", "set_status"):
            return {"type": "fake", "sent": self.emit_status(p["pane_id"], p["status"])}
        if op == "add_pane":
            return {"type": "fake", "sent": self.add_pane(p["pane_id"], p.get("agent", "codex"))}
        if op == "remove_pane":
            return {"type": "fake", "sent": self.remove_pane(p["pane_id"])}
        if op == "events_lost":
            return {"type": "fake", "closed": self.events_lost()}
        if op == "set_delay":
            self.delay = float(p.get("seconds", 0))
            return {"type": "fake"}
        if op == "set_shape":
            self.shape = p.get("shape", "envelope")
            return {"type": "fake"}
        if op == "requests":
            with self._lock:
                return {"type": "fake", "requests": list(self.requests)}
        if op == "clear":
            with self._lock:
                self.requests = []
            return {"type": "fake"}
        if op == "subscribers":
            info = self.subscriber_info()
            info["type"] = "fake"
            return info
        return {"type": "fake", "error": "unknown control op"}


def call(socket_path, method, params=None, timeout=5):
    """One request to a running fake; returns the whole response object."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(socket_path)
    s.sendall((json.dumps({"id": "ctl", "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.split(b"\n", 1)[0])


def ctl(socket_path, method, params=None, timeout=5):
    """Send one control request to a running fake and return its result."""
    return call(socket_path, method, params, timeout)["result"]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--socket", required=True)
    ap.add_argument("--shape", default="envelope", choices=("envelope", "flat"))
    ap.add_argument("--preset", default="local", choices=("local", "remote"))
    ap.add_argument("--record", default=None, help="append every request as a JSON line to this file")
    ap.add_argument("cmd", nargs="?", default="serve", choices=("serve", "ctl"))
    ap.add_argument("payload", nargs="?", default=None, help='ctl: {"method":"_fake.…","params":{…}}')
    a = ap.parse_args(argv)
    if a.cmd == "ctl":
        req = json.loads(a.payload)
        print(json.dumps(ctl(a.socket, req["method"], req.get("params"))))
        return 0
    fh = FakeHerdr(a.socket, shape=a.shape, preset=a.preset, record=a.record).start()
    print("fake_herdr listening socket=%s" % a.socket, flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        fh.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
