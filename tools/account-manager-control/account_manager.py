import json
import os
import queue
import threading
import time
import tkinter as tk
from datetime import datetime
from tkinter import messagebox, ttk
from urllib import error, request

API_BASE = os.getenv("ACCOUNT_MANAGER_API_BASE", "https://meowz.up.railway.app").rstrip("/")
ALT_USER_ID = os.getenv("ACCOUNT_MANAGER_ALT_USER_ID", "9039839654")
PC_TOKEN = os.getenv("ACCOUNT_MANAGER_PC_TOKEN", "")
POLL_SECONDS = 1.0


class ApiClient:
    def __init__(self, base, token, alt_user_id):
        self.base = base
        self.token = token
        self.alt_user_id = str(alt_user_id)

    def _call(self, method, path, payload=None):
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with request.urlopen(req, timeout=8) as response:
                body = response.read().decode("utf-8")
                return response.status, json.loads(body) if body else {}
        except error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                parsed = {"error": body or str(exc)}
            return exc.code, parsed

    def state(self):
        return self._call("GET", f"/api/account-manager/remote/state/{self.alt_user_id}")

    def command(self, command):
        return self._call("POST", "/api/account-manager/remote/command", {
            "altUserId": self.alt_user_id,
            "command": command,
        })


class ControlCenter(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Account Manager Control Center")
        self.geometry("1000x650")
        self.minsize(820, 520)
        self.client = ApiClient(API_BASE, PC_TOKEN, ALT_USER_ID)
        self.events = queue.Queue()
        self.polling = True
        self.last_log_signature = None
        self.status_vars = {
            key: tk.StringVar(value="—")
            for key in ("connection", "version", "alt", "mode", "target", "effects", "health", "server", "host", "pending")
        }
        self._build()
        self.after(100, self._drain_events)
        threading.Thread(target=self._poll_loop, daemon=True).start()

    def _build(self):
        style = ttk.Style(self)
        if "vista" in style.theme_names():
            style.theme_use("vista")

        outer = ttk.Frame(self, padding=14)
        outer.pack(fill="both", expand=True)

        header = ttk.Frame(outer)
        header.pack(fill="x")
        ttk.Label(header, text="Account Manager", font=("Segoe UI", 18, "bold")).pack(side="left")
        ttk.Label(header, text=f"ALT {ALT_USER_ID}").pack(side="right")

        notebook = ttk.Notebook(outer)
        notebook.pack(fill="both", expand=True, pady=(12, 0))
        dashboard = ttk.Frame(notebook, padding=12)
        console = ttk.Frame(notebook, padding=12)
        settings = ttk.Frame(notebook, padding=12)
        notebook.add(dashboard, text="Dashboard")
        notebook.add(console, text="Console")
        notebook.add(settings, text="Settings")

        info = ttk.LabelFrame(dashboard, text="ALT Status", padding=12)
        info.pack(fill="x")
        labels = [
            ("Connection", "connection"), ("Version", "version"), ("ALT", "alt"),
            ("Mode", "mode"), ("Target", "target"), ("Effects", "effects"),
            ("Health", "health"), ("Server", "server"), ("Host present", "host"),
            ("Pending commands", "pending"),
        ]
        for index, (label, key) in enumerate(labels):
            row, col = divmod(index, 2)
            ttk.Label(info, text=label + ":", width=18).grid(row=row, column=col * 2, sticky="w", pady=3)
            ttk.Label(info, textvariable=self.status_vars[key]).grid(row=row, column=col * 2 + 1, sticky="w", padx=(0, 25), pady=3)

        command_box = ttk.LabelFrame(dashboard, text="Command", padding=12)
        command_box.pack(fill="x", pady=(12, 0))
        self.command_var = tk.StringVar()
        entry = ttk.Entry(command_box, textvariable=self.command_var)
        entry.pack(side="left", fill="x", expand=True)
        entry.bind("<Return>", lambda _event: self.send_command())
        ttk.Button(command_box, text="Send", command=self.send_command).pack(side="left", padx=(8, 0))

        quick = ttk.Frame(dashboard)
        quick.pack(fill="x", pady=(10, 0))
        for command in (",status", ",bring", ",follow me", ",unfollow", ",stand", ",sit", ",unsit"):
            ttk.Button(quick, text=command, command=lambda c=command: self.send_command(c)).pack(side="left", padx=(0, 6))

        self.console = tk.Text(console, wrap="word", state="disabled", font=("Consolas", 10))
        self.console.pack(fill="both", expand=True)
        ttk.Button(console, text="Clear local view", command=self.clear_console).pack(anchor="e", pady=(8, 0))

        ttk.Label(settings, text="API base").grid(row=0, column=0, sticky="w", pady=4)
        ttk.Label(settings, text=API_BASE).grid(row=0, column=1, sticky="w", padx=10)
        ttk.Label(settings, text="ALT UserId").grid(row=1, column=0, sticky="w", pady=4)
        ttk.Label(settings, text=ALT_USER_ID).grid(row=1, column=1, sticky="w", padx=10)
        ttk.Label(settings, text="PC token").grid(row=2, column=0, sticky="w", pady=4)
        ttk.Label(settings, text="Loaded from ACCOUNT_MANAGER_PC_TOKEN" if PC_TOKEN else "NOT SET").grid(row=2, column=1, sticky="w", padx=10)
        ttk.Label(settings, text="Secrets are read from environment variables and are never stored in this file.", wraplength=700).grid(row=3, column=0, columnspan=2, sticky="w", pady=(16, 0))

        self.protocol("WM_DELETE_WINDOW", self._close)

    def log(self, message):
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.console.configure(state="normal")
        self.console.insert("end", f"[{timestamp}] {message}\n")
        self.console.see("end")
        self.console.configure(state="disabled")

    def clear_console(self):
        self.console.configure(state="normal")
        self.console.delete("1.0", "end")
        self.console.configure(state="disabled")

    def send_command(self, command=None):
        command = (command or self.command_var.get()).strip()
        if not command:
            return
        if not PC_TOKEN:
            messagebox.showerror("Missing token", "Set ACCOUNT_MANAGER_PC_TOKEN before sending commands.")
            return
        if not command.startswith(","):
            command = "," + command
        self.command_var.set("")
        self.log("→ " + command)
        threading.Thread(target=self._send_worker, args=(command,), daemon=True).start()

    def _send_worker(self, command):
        try:
            status, data = self.client.command(command)
            self.events.put(("command", status, data, command))
        except Exception as exc:
            self.events.put(("error", f"Command request failed: {exc}"))

    def _poll_loop(self):
        while self.polling:
            if PC_TOKEN:
                try:
                    status, data = self.client.state()
                    self.events.put(("state", status, data))
                except Exception as exc:
                    self.events.put(("error", f"State request failed: {exc}"))
            else:
                self.events.put(("missing_token",))
            time.sleep(POLL_SECONDS)

    def _drain_events(self):
        try:
            while True:
                event = self.events.get_nowait()
                kind = event[0]
                if kind == "state":
                    self._apply_state(event[1], event[2])
                elif kind == "command":
                    status, data, command = event[1:]
                    if 200 <= status < 300:
                        command_data = data.get("command") or {}
                        self.log(f"Queued {command} | id={command_data.get('id', 'unknown')}")
                    else:
                        self.log(f"Command rejected ({status}): {data}")
                elif kind == "error":
                    self.status_vars["connection"].set("ERROR")
                    self.log(event[1])
                elif kind == "missing_token":
                    self.status_vars["connection"].set("TOKEN NOT SET")
        except queue.Empty:
            pass
        if self.polling:
            self.after(100, self._drain_events)

    def _apply_state(self, status, data):
        if status != 200:
            self.status_vars["connection"].set(f"HTTP {status}")
            return
        telemetry = data.get("telemetry") or {}
        online = bool(data.get("online"))
        self.status_vars["connection"].set("ONLINE" if online else "OFFLINE")
        self.status_vars["version"].set(str(telemetry.get("version") or "—"))
        self.status_vars["alt"].set(str(telemetry.get("alt") or ALT_USER_ID))
        self.status_vars["mode"].set(str(telemetry.get("mode") or "none"))
        self.status_vars["target"].set(str(telemetry.get("target") or "—"))
        effects = telemetry.get("effects") or {}
        self.status_vars["effects"].set(", ".join(k for k, v in effects.items() if v) or "none")
        self.status_vars["health"].set(str(telemetry.get("health") if telemetry.get("health") is not None else "—"))
        place, job = telemetry.get("placeId"), telemetry.get("jobId")
        self.status_vars["server"].set(f"{place or '—'} / {job or '—'}")
        self.status_vars["host"].set(str(bool(telemetry.get("hostPresent"))))
        self.status_vars["pending"].set(str(len(data.get("pendingCommands") or [])))

        logs = data.get("logs") or []
        signature = tuple((x.get("timestamp"), x.get("level"), x.get("message")) for x in logs[-20:])
        if signature and signature != self.last_log_signature:
            previous = set(self.last_log_signature or ())
            for item in signature:
                if item not in previous:
                    timestamp, level, message = item
                    self.log(f"ALT {level or 'INFO'} | {message or ''}")
            self.last_log_signature = signature

    def _close(self):
        self.polling = False
        self.destroy()


if __name__ == "__main__":
    ControlCenter().mainloop()
