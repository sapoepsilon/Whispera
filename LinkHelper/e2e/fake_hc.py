#!/usr/bin/python3
"""Fake herdr-core (hc 0.1.17) socket server for the helper's tests. Stdlib only.

JSON-RPC 2.0, one message per line, errors with a stable `data.kind`, like hc. Never point
the helper at a real hc for anything that writes: this fake answers hello, terminal.list/
get/read/send/keys/run/kill/rm and events.subscribe, and records every request it receives
(method + params) so tests can assert what was sent and what was not.

Terminals (preset "default"):
  t1   claude-code, done, Herdr.app labels, foreground pid 4242 (see --sessions)
  t2   plain zsh, never reported (status null)
  t3   codex, blocked (kind question)
  mbp/t7  on connected machine "mbp" (host "mac-b"): claude-code, working
Machines: "mbp" connected, "dead" unreachable.

Like hc: terminal.read of a working/blocked/error program with lines > 0 answers only the
screen with complete: false and why; terminal.send refuses a blocked program (kind
blocked); terminal.rm refuses a live terminal (kind live); terminal.run assigns the next
address (t4, t5, ...) on this machine or "<machine>/tN" with `on`.

events.subscribe answers {seq, terminals} and then streams `event` notifications
({type, terminal, seq, data}) and a `heartbeat` every --heartbeat seconds (0: never).

Control requests (same socket, method names starting with `_fake.`):
  _fake.set_status   {"terminal", "state", "kind"?, "app"?}  change + emit a status event
  _fake.add          {"address", "app"?, "argv"?}           add a live terminal + emit created
  _fake.finish       {"address"}                            finish it + emit finished
  _fake.missed       {"with_snapshot": bool}                send `missed` to subscribers
  _fake.drop         {}                                     close every subscriber
  _fake.hello        {"generation"?, "methods"?, "features"?}  change what hello says
  _fake.set_text     {"terminal", "text"}                   the screen text
  _fake.requests     {}                                     -> {"requests": [[method, params], ...]}
  _fake.clear        {}                                     forget recorded requests
  _fake.subscribers  {}                                     -> {"count": n}

CLI:
  fake_hc.py --socket PATH [--heartbeat S]
"""

import argparse
import copy
import json
import os
import socket
import threading
import time

METHODS = [
    "hello", "server.status", "server.stop", "server.restart", "terminal.run", "templates.list", "terminal.list",
    "terminal.get", "terminal.kill", "terminal.rm", "terminal.keep", "terminal.label", "terminal.read",
    "terminal.attach", "terminal.send", "terminal.wait", "terminal.keys", "terminal.interrupt", "terminal.put",
    "machine.exec", "file.read", "file.write", "file.edit", "doc.get", "doc.set", "events.subscribe", "machine.add",
    "machine.list", "machine.connect", "machine.rename", "machine.rm", "rpc.discover",
]
FEATURES = ["framed", "attach", "events", "status", "shell", "resize_notifications"]


def terminal(address, argv, cwd, status=None, fg=None, labels=None, pid=100, title="", turn=0):
    return {
        "address": address, "name": None, "labels": labels or {}, "argv": argv, "cwd": cwd, "state": "live",
        "created_ms": 1, "screen": "exact", "cols": 120, "rows": 40, "status": status, "turn": turn, "title": title,
        "pid": pid, "foreground": fg, "reported": status is not None, "template": None, "parent": None,
    }


def default_terminals():
    return [
        terminal("t1", ["/bin/zsh", "-l"], "/Users/me",
                 status={"app": "claude-code", "state": "done", "msg": "all green"},
                 fg={"argv": ["claude", "--resume"], "cwd": "/Users/me/repo", "name": "2.1.317", "pid": 4242},
                 labels={"herdr.space": "spA", "herdr.tab": "tbA", "where": "repo work / 1", "herdr.seen": "3"},
                 pid=4200, title="Fix the parser", turn=3),
        terminal("t2", ["/bin/zsh", "-l"], "/Users/me",
                 fg={"argv": ["/bin/zsh", "-l"], "cwd": "/Users/me", "name": "zsh", "pid": 4300}, pid=4300,
                 title="me@mac:~"),
        terminal("t3", ["codex"], "/Users/me/other",
                 status={"app": "codex", "state": "blocked", "kind": "question"},
                 fg={"argv": ["codex"], "cwd": "/Users/me/other", "name": "codex", "pid": 4400}, pid=4400,
                 title="codex", turn=1),
        terminal("mbp/t7", ["/bin/zsh", "-l"], "/Users/main",
                 status={"app": "claude-code", "state": "working"},
                 fg={"argv": ["claude"], "cwd": "/Users/main/proj", "name": "2.1.317", "pid": 777}, pid=700,
                 title="Remote work", turn=9),
    ]


MACHINES = [
    {"name": "mbp", "host": "mac-b", "id": "m1", "target": "mbp.ts", "version": "0.1.17", "state": "connected",
     "session": None, "temporary": False, "via": False},
    {"name": "dead", "host": "dead-host", "id": "m2", "target": "dead", "version": "0.1.17", "state": "unreachable",
     "session": None, "temporary": False, "via": False, "why": "ssh: connect timed out"},
]


class RPCError(Exception):
    def __init__(self, kind, message=None, code=-32000):
        super().__init__(message or kind)
        self.kind = kind
        self.message = message or kind
        self.code = code


class FakeHC:
    def __init__(self, socket_path, heartbeat=15.0):
        self.socket_path = socket_path
        self.heartbeat = heartbeat
        self.terminals = {t["address"]: t for t in default_terminals()}
        self.texts = {a: "screen of %s\n> " % a for a in self.terminals}
        self.requests = []
        self.subscribers = []
        self.seq = 100
        self.next_local = 4
        self.hello_override = {}
        self._lock = threading.RLock()
        self._stop = threading.Event()

    # -- server --

    def start(self):
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(self.socket_path)
        os.chmod(self.socket_path, 0o600)
        self.sock.listen(32)
        threading.Thread(target=self._accept, daemon=True).start()
        if self.heartbeat > 0:
            threading.Thread(target=self._beat, daemon=True).start()

    def _accept(self):
        while not self._stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _beat(self):
        while not self._stop.wait(self.heartbeat):
            with self._lock:
                seq = self.seq
            self._broadcast({"jsonrpc": "2.0", "method": "heartbeat", "params": {"seq": seq}})

    @staticmethod
    def _send(conn, obj, lock):
        data = (json.dumps(obj) + "\n").encode()
        with lock:
            conn.sendall(data)

    def _serve(self, conn):
        lock = threading.Lock()
        buf = b""
        try:
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if line.strip():
                        self._handle(conn, lock, line)
        except OSError:
            pass
        finally:
            with self._lock:
                self.subscribers = [s for s in self.subscribers if s[0] is not conn]
            try:
                conn.close()
            except OSError:
                pass

    def _handle(self, conn, lock, line):
        try:
            req = json.loads(line)
        except ValueError:
            return
        rid = req.get("id")
        method = req.get("method", "")
        params = req.get("params") or {}
        if not method.startswith("_fake."):
            with self._lock:
                self.requests.append([method, copy.deepcopy(params)])
        try:
            if method == "events.subscribe":
                with self._lock:
                    snapshot = {"seq": self.seq, "terminals": copy.deepcopy(list(self.terminals.values())),
                                "channel": None}
                    self._send(conn, {"jsonrpc": "2.0", "id": rid, "result": snapshot}, lock)
                    self.subscribers.append((conn, lock))
                return
            result = self.dispatch(method, params)
            self._send(conn, {"jsonrpc": "2.0", "id": rid, "result": result}, lock)
        except RPCError as e:
            self._send(conn, {"jsonrpc": "2.0", "id": rid,
                              "error": {"code": e.code, "message": e.message, "data": {"kind": e.kind}}}, lock)

    def _broadcast(self, obj):
        with self._lock:
            subs = list(self.subscribers)
        for conn, lock in subs:
            try:
                self._send(conn, obj, lock)
            except OSError:
                pass

    def _event(self, kind, address, data):
        with self._lock:
            self.seq += 1
            seq = self.seq
        self._broadcast({"jsonrpc": "2.0", "method": "event",
                         "params": {"type": kind, "terminal": address, "seq": seq, "data": data}})

    # -- API --

    def _find(self, address, live=False):
        if address is None:
            raise RPCError("invalid_params", "terminal is required", code=-32602)
        if "/" in address and address.split("/")[0] not in [m["name"] for m in MACHINES]:
            raise RPCError("machine_unknown", "no machine %r" % address.split("/")[0])
        t = self.terminals.get(address)
        if t is None:
            raise RPCError("not_found", 'no terminal "%s"' % address)
        if live and t["state"] != "live":
            raise RPCError("finished", "it has finished")
        return t

    def dispatch(self, method, params):
        with self._lock:
            if method.startswith("_fake."):
                return self._control(method, params)
            if method == "hello":
                if params.get("generation") not in (None, 1):
                    raise RPCError("unsupported_generation", "generation 1 only")
                return {"generation": self.hello_override.get("generation", 1), "version": "0.1.17",
                        "core": {"id": "fakecore", "name": "fake"}, "framed": False,
                        "methods": self.hello_override.get("methods", METHODS),
                        "features": self.hello_override.get("features", FEATURES)}
            if method == "terminal.list":
                live = [copy.deepcopy(t) for t in self.terminals.values() if params.get("all") or t["state"] == "live"]
                return {"terminals": live, "machines": copy.deepcopy(MACHINES),
                        "hidden_finished": sum(1 for t in self.terminals.values() if t["state"] != "live")}
            if method == "terminal.get":
                return copy.deepcopy(self._find(params.get("terminal")))
            if method == "terminal.read":
                t = self._find(params.get("terminal"))
                lines = params.get("lines", 0)
                state = (t.get("status") or {}).get("state")
                text = self.texts.get(t["address"], "")
                if lines and state in ("working", "blocked", "error"):
                    return {"text": text, "complete": False, "how": "screen", "why": state}
                if lines:
                    text = "".join("history %d\n" % i for i in range(min(lines, 5))) + text
                return {"text": text, "complete": True, "how": "history" if lines else "screen", "why": None}
            if method == "terminal.send":
                t = self._find(params.get("terminal"), live=True)
                if (t.get("status") or {}).get("state") == "blocked" and not params.get("force"):
                    raise RPCError("blocked", "it is blocked; read its screen")
                self.texts[t["address"]] = self.texts.get(t["address"], "") + params.get("text", "") + "\n"
                return {"turn": t["turn"], "status": (t.get("status") or {}).get("state"), "started": None}
            if method == "terminal.keys":
                t = self._find(params.get("terminal"), live=True)
                return {"turn": t["turn"], "status": (t.get("status") or {}).get("state")}
            if method == "terminal.run":
                on = params.get("on")
                if on is not None and on not in [m["name"] for m in MACHINES]:
                    raise RPCError("machine_unknown", "no machine %r" % on)
                argv = params.get("argv") or ["/bin/zsh", "-l"]
                n = self.next_local
                self.next_local += 1
                address = ("%s/t%d" % (on, n)) if on else "t%d" % n
                app = {"claude": "claude-code", "codex": "codex"}.get(argv[0])
                t = terminal(address, argv, params.get("cwd") or "/Users/me",
                             status={"app": app, "state": "idle"} if app else None,
                             fg={"argv": argv, "cwd": params.get("cwd") or "/Users/me", "name": argv[0], "pid": 9000 + n},
                             labels=params.get("labels") or {}, pid=9000 + n, title=argv[0])
                self.terminals[address] = t
                self.texts[address] = "started %s\n" % " ".join(argv)
                self._event("created", address, {})
                return copy.deepcopy(t)
            if method == "terminal.kill":
                t = self._find(params.get("terminal"))
                t["state"] = "finished"
                t["status"] = None
                t["foreground"] = None
                t["reason"] = "killed"
                self._event("finished", t["address"], {})
                return copy.deepcopy(t)
            if method == "terminal.rm":
                t = self._find(params.get("terminal"))
                if t["state"] == "live":
                    raise RPCError("live", "it is still running; kill it first")
                del self.terminals[t["address"]]
                self._event("removed", t["address"], {})
                return {"removed": t["address"]}
            raise RPCError("unknown_method", 'unknown method "%s"' % method, code=-32601)

    def _control(self, method, p):
        if method == "_fake.set_status":
            t = self.terminals[p["terminal"]]
            status = {"app": p.get("app", (t.get("status") or {}).get("app") or "claude-code"), "state": p["state"]}
            if p.get("kind"):
                status["kind"] = p["kind"]
            if t.get("status") and t["status"].get("state") == "working" and p["state"] != "working":
                t["turn"] += 1
            t["status"] = status
            t["reported"] = True
            self._event("status", t["address"], {"status": status, "reported": True})
            return {}
        if method == "_fake.add":
            address = p["address"]
            app = p.get("app")
            argv = p.get("argv") or ["/bin/zsh", "-l"]
            self.terminals[address] = terminal(
                address, argv, "/Users/me", status={"app": app, "state": "idle"} if app else None,
                fg={"argv": argv, "cwd": "/Users/me", "name": argv[0], "pid": 5000}, title=address)
            self.texts[address] = "new %s\n" % address
            self._event("created", address, {})
            return {}
        if method == "_fake.finish":
            t = self.terminals[p["address"]]
            t["state"] = "finished"
            t["status"] = None
            self._event("finished", t["address"], {})
            return {}
        if method == "_fake.missed":
            params = {"seq": self.seq}
            if p.get("with_snapshot", True):
                params["terminals"] = copy.deepcopy(list(self.terminals.values()))
            self._broadcast({"jsonrpc": "2.0", "method": "missed", "params": params})
            return {}
        if method == "_fake.drop":
            subs, self.subscribers = self.subscribers, []
            for conn, _ in subs:
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            return {"dropped": len(subs)}
        if method == "_fake.hello":
            self.hello_override = p
            return {}
        if method == "_fake.set_text":
            self.texts[p["terminal"]] = p["text"]
            return {}
        if method == "_fake.requests":
            return {"requests": copy.deepcopy(self.requests)}
        if method == "_fake.clear":
            self.requests = []
            return {}
        if method == "_fake.subscribers":
            return {"count": len(self.subscribers)}
        raise RPCError("unknown_method", method, code=-32601)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--heartbeat", type=float, default=15.0)
    args = parser.parse_args()
    server = FakeHC(args.socket, heartbeat=args.heartbeat)
    server.start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
