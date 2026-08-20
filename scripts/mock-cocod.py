#!/usr/bin/env python3
"""Deterministic loopback mock for the implemented Cocod Network Interface v1."""

from __future__ import annotations

import argparse
import copy
import json
import os
import queue
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


RECOVERY_PHRASE = (
    "abandon abandon abandon abandon abandon abandon abandon abandon "
    "abandon abandon abandon about"
)
FIXED_TIME = "2026-08-20T12:00:00Z"
CAPABILITIES = [
    "wallet.lifecycle",
    "wallet.balances",
    "wallet.mints",
    "wallet.receive-preview",
    "wallet.receive-operations",
    "wallet.send-max",
    "wallet.send-operations",
    "wallet.events",
]
COLLECTION_PATHS = {
    "/v1/balances": "balances",
    "/v1/mints": "mints",
    "/v1/operations/receive/prepared": "receivePrepared",
    "/v1/operations/receive/in-flight": "receiveInFlight",
    "/v1/operations/send/prepared": "sendPrepared",
    "/v1/operations/send/in-flight": "sendInFlight",
}


def error_document(code: str, message: str, retryable: bool = False) -> dict[str, Any]:
    return {"error": {"code": code, "message": message, "retryable": retryable}}


class MockState:
    def __init__(self, state_root: Path) -> None:
        self.lock = threading.Lock()
        self.state_root = state_root
        self.instance_id = str(uuid.uuid5(uuid.NAMESPACE_URL, str(state_root.resolve())))
        self.wallet_configured = False
        self.status = self._status_document()
        self.resources: dict[str, dict[str, Any]] = {
            "balances": {"items": []},
            "mints": {"items": []},
            "receivePrepared": {"items": []},
            "receiveInFlight": {"items": []},
            "sendPrepared": {"items": []},
            "sendInFlight": {"items": []},
        }
        self.resource_requests = {
            "capabilities": 0,
            "status": 0,
            **{key: 0 for key in self.resources},
        }
        self.resource_requests_active = 0
        self.resource_delay_ms = 0
        self.resource_mode = "ok"
        self.authenticated_v1_requests = 0
        self.authorization_failures = 0
        self.stream_connections = 0
        self.create_requests = 0
        self.create_delay_ms = 0
        self.recovery_material_requests = 0
        self.recovery_material_responses = 0
        self.recovery_delay_ms = 0
        self.subscribers: list[queue.Queue[object]] = []

    def _status_document(self) -> dict[str, Any]:
        if not self.wallet_configured:
            return {
                "daemon": {"version": "0.0.17", "interfaceVersion": "1"},
                "wallet": None,
                "seedAccess": None,
                "cocoSession": {
                    "state": "stopped",
                    "startedAt": None,
                    "lastFailure": None,
                },
            }
        return {
            "daemon": {"version": "0.0.17", "interfaceVersion": "1"},
            "wallet": {"configuredAt": FIXED_TIME},
            "seedAccess": {"state": "available", "requiresPassphrase": False},
            "cocoSession": {
                "state": "running",
                "startedAt": FIXED_TIME,
                "lastFailure": None,
            },
        }

    @property
    def credential_path(self) -> Path:
        return self.state_root / "credentials" / "current" / "client"

    def credential(self) -> str | None:
        try:
            value = self.credential_path.read_text(encoding="utf-8")
        except OSError:
            return None
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}\n", value):
            return None
        return value[:-1]

    def authenticate(self, authorization: str) -> tuple[bool, str]:
        credential = self.credential()
        if not authorization:
            with self.lock:
                self.authorization_failures += 1
            return False, "authentication_required"
        if credential is None or authorization != f"Bearer {credential}":
            with self.lock:
                self.authorization_failures += 1
            return False, "invalid_client_credential"
        with self.lock:
            self.authenticated_v1_requests += 1
        return True, ""

    def begin_resource(self, name: str) -> tuple[str, int]:
        with self.lock:
            self.resource_requests[name] += 1
            self.resource_requests_active += 1
            return self.resource_mode, self.resource_delay_ms

    def finish_resource(self) -> None:
        with self.lock:
            self.resource_requests_active -= 1

    def initialize_wallet(self) -> bool:
        with self.lock:
            self.create_requests += 1
            if self.wallet_configured:
                return False
            delay_ms = self.create_delay_ms
        if delay_ms > 0:
            time.sleep(delay_ms / 1000)
        with self.lock:
            if self.wallet_configured:
                return False
            self.wallet_configured = True
            self.status = self._status_document()
        return True

    def recovery_material(self) -> str | None:
        with self.lock:
            self.recovery_material_requests += 1
            if not self.wallet_configured:
                return None
            delay_ms = self.recovery_delay_ms
        if delay_ms > 0:
            time.sleep(delay_ms / 1000)
        with self.lock:
            self.recovery_material_responses += 1
        return RECOVERY_PHRASE

    def subscribe(self) -> queue.Queue[object]:
        subscriber: queue.Queue[object] = queue.Queue()
        with self.lock:
            self.stream_connections += 1
            self.subscribers.append(subscriber)
        return subscriber

    def unsubscribe(self, subscriber: queue.Queue[object]) -> None:
        with self.lock:
            if subscriber in self.subscribers:
                self.subscribers.remove(subscriber)
                self.stream_connections -= 1

    def update_resources(self, value: dict[str, Any]) -> None:
        with self.lock:
            for key in self.resources:
                if key in value:
                    self.resources[key] = copy.deepcopy(value[key])
            if "status" in value:
                self.status = copy.deepcopy(value["status"])
                self.wallet_configured = self.status.get("wallet") is not None
            subscribers = list(self.subscribers)
        raw_event = value.get("rawEvent")
        event = value.get("event")
        if isinstance(raw_event, str):
            payload = ("data: " + raw_event + "\n\n").encode()
        elif isinstance(event, dict):
            payload = ("data: " + json.dumps(event, separators=(",", ":")) + "\n\n").encode()
        else:
            return
        delivery = str(value.get("delivery", "whole"))
        for subscriber in subscribers:
            subscriber.put((payload, delivery))

    def disconnect_streams(self) -> None:
        with self.lock:
            subscribers = list(self.subscribers)
        for subscriber in subscribers:
            subscriber.put(None)

    def diagnostics(self) -> dict[str, Any]:
        with self.lock:
            return {
                "authenticatedV1Requests": self.authenticated_v1_requests,
                "authorizationFailures": self.authorization_failures,
                "streamConnections": self.stream_connections,
                "resourceRequests": copy.deepcopy(self.resource_requests),
                "resourceRequestsActive": self.resource_requests_active,
                "resourceMode": self.resource_mode,
                "resourceDelayMs": self.resource_delay_ms,
                "createRequests": self.create_requests,
                "createDelayMs": self.create_delay_ms,
                "recoveryMaterialRequests": self.recovery_material_requests,
                "recoveryMaterialResponses": self.recovery_material_responses,
                "recoveryDelayMs": self.recovery_delay_ms,
            }


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-cocod/1"

    @property
    def state(self) -> MockState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: object) -> None:
        return

    def send_json(self, status: int, value: object) -> None:
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_invalid_json(self) -> None:
        body = b"{not-json"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def require_authentication(self) -> bool:
        authenticated, code = self.state.authenticate(self.headers.get("Authorization", ""))
        if authenticated:
            return True
        if code == "authentication_required":
            self.send_json(401, error_document(code, "A Client Credential is required"))
        else:
            self.send_json(401, error_document(code, "The Client Credential is invalid"))
        return False

    def wallet_required(self) -> bool:
        with self.state.lock:
            configured = self.state.wallet_configured
        if configured:
            return True
        self.send_json(
            409,
            error_document("wallet_not_configured", "No Wallet is configured"),
        )
        return False

    def resource_response(self, name: str, value: object) -> None:
        mode, delay_ms = self.state.begin_resource(name)
        if delay_ms > 0:
            time.sleep(delay_ms / 1000)
        self.state.finish_resource()
        if mode == "unavailable":
            self.send_json(
                503,
                error_document("temporarily_unavailable", "Resource unavailable", True),
            )
        elif mode == "invalid":
            self.send_invalid_json()
        else:
            self.send_json(200, value)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "interfaceVersion": "1"})
            return
        if self.path == "/__test__/status":
            self.send_json(200, self.state.diagnostics())
            return
        if not self.path.startswith("/v1/"):
            self.send_json(404, error_document("not_found", "Resource not found"))
            return
        if not self.require_authentication():
            return

        if self.path == "/v1/capabilities":
            with self.state.lock:
                mode = self.state.resource_mode
            interface_version = "99" if mode == "incompatible" else "1"
            self.resource_response(
                "capabilities",
                {
                    "interfaceVersion": interface_version,
                    "daemonVersion": "0.0.17",
                    "instanceId": self.state.instance_id,
                    "capabilities": CAPABILITIES,
                },
            )
            return
        if self.path == "/v1/status":
            with self.state.lock:
                status = copy.deepcopy(self.state.status)
            self.resource_response("status", status)
            return
        if self.path in COLLECTION_PATHS:
            if not self.wallet_required():
                return
            name = COLLECTION_PATHS[self.path]
            with self.state.lock:
                value = copy.deepcopy(self.state.resources[name])
            self.resource_response(name, value)
            return
        if self.path == "/v1/events":
            if not self.wallet_required():
                return
            subscriber = self.state.subscribe()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            try:
                self.wfile.write(b"retry: 3000\n: connected\n\n")
                self.wfile.flush()
                while True:
                    try:
                        item = subscriber.get(timeout=0.25)
                    except queue.Empty:
                        self.wfile.write(b": heartbeat\n\n")
                        self.wfile.flush()
                        continue
                    if item is None:
                        return
                    payload, delivery = item
                    if delivery == "partial":
                        cut_one = max(1, len(payload) // 3)
                        cut_two = max(cut_one + 1, len(payload) * 2 // 3)
                        chunks = (payload[:cut_one], payload[cut_one:cut_two], payload[cut_two:])
                    else:
                        chunks = (payload,)
                    for chunk in chunks:
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        if delivery == "partial":
                            time.sleep(0.015)
            except (BrokenPipeError, ConnectionResetError):
                return
            finally:
                self.state.unsubscribe(subscriber)
            return
        self.send_json(404, error_document("not_found", "Resource not found"))

    def read_json(self) -> object | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            return json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, error_document("invalid_request", "Malformed JSON"))
            return None

    def do_POST(self) -> None:
        if self.path.startswith("/v1/") and not self.require_authentication():
            return
        value = self.read_json()
        if value is None:
            return
        if self.path == "/__test__/resources":
            if not isinstance(value, dict):
                self.send_json(400, error_document("invalid_request", "Expected an object"))
                return
            self.state.update_resources(value)
            self.send_json(200, {"updated": True})
            return
        if self.path == "/__test__/mode":
            if not isinstance(value, dict):
                self.send_json(400, error_document("invalid_request", "Expected an object"))
                return
            mode = str(value.get("resources", "ok"))
            if mode not in ("ok", "unavailable", "invalid", "incompatible"):
                self.send_json(400, error_document("invalid_request", "Invalid resource mode"))
                return
            with self.state.lock:
                self.state.resource_mode = mode
                if "delayMs" in value:
                    self.state.resource_delay_ms = max(0, min(5000, int(value["delayMs"])))
                if "createDelayMs" in value:
                    self.state.create_delay_ms = max(0, min(5000, int(value["createDelayMs"])))
                if "recoveryDelayMs" in value:
                    self.state.recovery_delay_ms = max(0, min(5000, int(value["recoveryDelayMs"])))
            self.send_json(200, self.state.diagnostics())
            return
        if self.path == "/__test__/disconnect":
            self.state.disconnect_streams()
            self.send_json(200, {"disconnected": True})
            return
        if not self.path.startswith("/v1/"):
            self.send_json(404, error_document("not_found", "Resource not found"))
            return
        if self.path == "/v1/admin/wallet/initialize":
            if value != {}:
                self.send_json(400, error_document("invalid_request", "Passphrases are not supported by this mock"))
                return
            if not self.state.initialize_wallet():
                self.send_json(
                    409,
                    error_document("wallet_already_configured", "A Wallet already exists"),
                )
                return
            self.send_json(202, {"generatedMnemonic": RECOVERY_PHRASE})
            return
        if self.path == "/v1/admin/wallet/recovery-material":
            if value != {}:
                self.send_json(400, error_document("invalid_request", "Passphrases are not supported by this mock"))
                return
            mnemonic = self.state.recovery_material()
            if mnemonic is None:
                self.send_json(
                    409,
                    error_document("wallet_not_configured", "No Wallet is configured"),
                )
                return
            self.send_json(200, {"mnemonic": mnemonic})
            return
        self.send_json(404, error_document("not_found", "Resource not found"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=62626)
    args = parser.parse_args()

    configured_root = os.environ.get("COCOD_STATE_DIR", "")
    if configured_root and os.path.isabs(configured_root):
        state_root = Path(configured_root)
    else:
        state_root = Path.home() / ".cocod"

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.state = MockState(state_root)  # type: ignore[attr-defined]
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
