#!/usr/bin/env python3
"""Deterministic loopback mock for the provisional cocod v1 contract."""

from __future__ import annotations

import argparse
import copy
import json
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


INITIAL_SNAPSHOT = {
    "apiVersion": "1",
    "revision": 1,
    "wallet": {
        "state": "uninitialized",
        "detail": "Create a Wallet Instance to get started",
        "balances": {"spendable": 0, "reserved": 0, "unit": "sat"},
        "activeTransfers": [],
        "trustedMints": [],
    },
}

CREATED_WALLET = {
    "state": "unlocked",
    "detail": "Mock Wallet Instance",
    "balances": {"spendable": 0, "reserved": 0, "unit": "sat"},
    "activeTransfers": [],
    "trustedMints": [],
}

RECOVERY_PHRASE = (
    "abandon abandon abandon abandon abandon abandon abandon abandon "
    "abandon abandon abandon about"
)


class MockState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.snapshot = copy.deepcopy(INITIAL_SNAPSHOT)
        self.snapshot_requests = 0
        self.snapshot_requests_active = 0
        self.snapshot_delay_ms = 0
        self.stream_connections = 0
        self.last_event_id = ""
        self.snapshot_mode = "ok"
        self.create_requests = 0
        self.create_delay_ms = 0
        self.create_in_progress = False
        self.create_event_delivery = "whole"
        self.recovery_phrase_reveal_requests = 0
        self.recovery_phrase_reveal_responses = 0
        self.recovery_phrase_reveal_delay_ms = 0
        self.subscribers: list[queue.Queue[object]] = []
        self.events: list[tuple[int, bytes, str]] = []

    def subscribe(self, last_event_id: str) -> queue.Queue[object]:
        subscriber: queue.Queue[object] = queue.Queue()
        with self.lock:
            self.stream_connections += 1
            self.last_event_id = last_event_id
            self.subscribers.append(subscriber)
            try:
                revision = int(last_event_id or "0")
            except ValueError:
                revision = 0
            for event_revision, payload, delivery in self.events:
                if event_revision > revision:
                    subscriber.put((payload, delivery))
        return subscriber

    def unsubscribe(self, subscriber: queue.Queue[object]) -> None:
        with self.lock:
            if subscriber in self.subscribers:
                self.subscribers.remove(subscriber)
                self.stream_connections -= 1

    def advance(self, value: dict[str, object]) -> dict[str, object]:
        wallet_patch = value.get("wallet", {})
        delivery = str(value.get("delivery", "whole"))
        with self.lock:
            wallet = copy.deepcopy(self.snapshot["wallet"])
            if isinstance(wallet_patch, dict):
                for key, item in wallet_patch.items():
                    wallet[key] = item
            revision = int(self.snapshot["revision"]) + 1
            self.snapshot = {"apiVersion": "1", "revision": revision, "wallet": wallet}
            data = {
                "apiVersion": "1",
                "revision": revision,
                "kind": "wallet-state-changed",
            }
            payload = (
                f"id: {revision}\n"
                "event: wallet.changed\n"
                f"data: {json.dumps(data, separators=(',', ':'))}\n\n"
            ).encode()
            self.events.append((revision, payload, delivery))
            subscribers = list(self.subscribers)
        for subscriber in subscribers:
            subscriber.put((payload, delivery))
        return copy.deepcopy(self.snapshot)

    def create_wallet(self) -> bool:
        with self.lock:
            self.create_requests += 1
            wallet = self.snapshot["wallet"]
            if (
                not isinstance(wallet, dict)
                or wallet.get("state") != "uninitialized"
                or self.create_in_progress
            ):
                return False
            self.create_in_progress = True
            delay_ms = self.create_delay_ms
        if delay_ms > 0:
            time.sleep(delay_ms / 1000)
        with self.lock:
            wallet = self.snapshot["wallet"]
            if not isinstance(wallet, dict) or wallet.get("state") != "uninitialized":
                self.create_in_progress = False
                return False
            revision = int(self.snapshot["revision"]) + 1
            self.snapshot = {
                "apiVersion": "1",
                "revision": revision,
                "wallet": copy.deepcopy(CREATED_WALLET),
            }
            data = {
                "apiVersion": "1",
                "revision": revision,
                "kind": "wallet-state-changed",
            }
            payload = (
                f"id: {revision}\n"
                "event: wallet.changed\n"
                f"data: {json.dumps(data, separators=(',', ':'))}\n\n"
            ).encode()
            subscribers = list(self.subscribers)
            event_delivery = self.create_event_delivery
            if event_delivery == "whole":
                self.events.append((revision, payload, "whole"))
            self.create_in_progress = False
        if event_delivery == "whole":
            for subscriber in subscribers:
                subscriber.put((payload, "whole"))
        return True

    def reveal_recovery_phrase(self) -> str | None:
        with self.lock:
            self.recovery_phrase_reveal_requests += 1
            wallet = self.snapshot["wallet"]
            if not isinstance(wallet, dict) or wallet.get("state") != "unlocked":
                return None
            delay_ms = self.recovery_phrase_reveal_delay_ms
        if delay_ms > 0:
            time.sleep(delay_ms / 1000)
        with self.lock:
            self.recovery_phrase_reveal_responses += 1
        return RECOVERY_PHRASE

    def disconnect_streams(self) -> None:
        with self.lock:
            subscribers = list(self.subscribers)
        for subscriber in subscribers:
            subscriber.put(None)


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

    def do_GET(self) -> None:
        if self.path == "/v1/wallet/snapshot":
            with self.state.lock:
                self.state.snapshot_requests += 1
                self.state.snapshot_requests_active += 1
                snapshot = copy.deepcopy(self.state.snapshot)
                mode = self.state.snapshot_mode
                delay_ms = self.state.snapshot_delay_ms
            if delay_ms > 0:
                time.sleep(delay_ms / 1000)
            with self.state.lock:
                self.state.snapshot_requests_active -= 1
            if mode == "unavailable":
                self.send_json(503, {"error": "temporarily-unavailable"})
                return
            if mode == "incompatible":
                snapshot["apiVersion"] = "99"
            if mode == "stale":
                snapshot["revision"] = max(0, int(snapshot["revision"]) - 1)
            if mode == "invalid":
                body = b"{not-json"
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_json(200, snapshot)
            return

        if self.path == "/__test__/status":
            with self.state.lock:
                status = {
                    "snapshotRequests": self.state.snapshot_requests,
                    "snapshotRequestsActive": self.state.snapshot_requests_active,
                    "streamConnections": self.state.stream_connections,
                    "lastEventId": self.state.last_event_id,
                    "revision": self.state.snapshot["revision"],
                    "snapshotMode": self.state.snapshot_mode,
                    "snapshotDelayMs": self.state.snapshot_delay_ms,
                    "createRequests": self.state.create_requests,
                    "createDelayMs": self.state.create_delay_ms,
                    "createEventDelivery": self.state.create_event_delivery,
                    "recoveryPhraseRevealRequests": self.state.recovery_phrase_reveal_requests,
                    "recoveryPhraseRevealResponses": self.state.recovery_phrase_reveal_responses,
                    "revealDelayMs": self.state.recovery_phrase_reveal_delay_ms,
                }
            self.send_json(200, status)
            return

        if self.path == "/v1/events":
            last_event_id = self.headers.get("Last-Event-ID", "")
            subscriber = self.state.subscribe(last_event_id)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                self.wfile.write(b": connected\n\n")
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

        self.send_json(404, {"error": "not-found"})

    def do_POST(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            value = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid-json"})
            return

        if self.path == "/v1/wallet/create":
            if value != {}:
                self.send_json(400, {"error": "invalid-command"})
                return
            if not self.state.create_wallet():
                self.send_json(409, {"error": "wallet-already-initialized"})
                return
            self.send_json(202, {"accepted": True})
            return

        if self.path == "/v1/wallet/recovery-phrase/reveal":
            if value != {}:
                self.send_json(400, {"error": "invalid-command"})
                return
            phrase = self.state.reveal_recovery_phrase()
            if phrase is None:
                self.send_json(409, {"error": "wallet-not-initialized"})
                return
            self.send_json(200, {"recoveryPhrase": phrase})
            return

        if self.path == "/__test__/snapshot":
            if not isinstance(value, dict):
                self.send_json(400, {"error": "invalid-snapshot"})
                return
            self.send_json(200, self.state.advance(value))
            return

        if self.path == "/__test__/mode":
            mode = str(value.get("snapshot", "ok")) if isinstance(value, dict) else ""
            if mode not in ("ok", "unavailable", "incompatible", "invalid", "stale"):
                self.send_json(400, {"error": "invalid-mode"})
                return
            with self.state.lock:
                self.state.snapshot_mode = mode
                if isinstance(value, dict) and "delayMs" in value:
                    delay_ms = int(value["delayMs"])
                    if delay_ms < 0 or delay_ms > 5000:
                        self.send_json(400, {"error": "invalid-delay"})
                        return
                    self.state.snapshot_delay_ms = delay_ms
                if isinstance(value, dict) and "createDelayMs" in value:
                    create_delay_ms = int(value["createDelayMs"])
                    if create_delay_ms < 0 or create_delay_ms > 5000:
                        self.send_json(400, {"error": "invalid-create-delay"})
                        return
                    self.state.create_delay_ms = create_delay_ms
                if isinstance(value, dict) and "createEventDelivery" in value:
                    create_event_delivery = str(value["createEventDelivery"])
                    if create_event_delivery not in ("whole", "none"):
                        self.send_json(400, {"error": "invalid-create-event-delivery"})
                        return
                    self.state.create_event_delivery = create_event_delivery
                if isinstance(value, dict) and "revealDelayMs" in value:
                    reveal_delay_ms = int(value["revealDelayMs"])
                    if reveal_delay_ms < 0 or reveal_delay_ms > 5000:
                        self.send_json(400, {"error": "invalid-reveal-delay"})
                        return
                    self.state.recovery_phrase_reveal_delay_ms = reveal_delay_ms
                delay_ms = self.state.snapshot_delay_ms
                create_delay_ms = self.state.create_delay_ms
                create_event_delivery = self.state.create_event_delivery
                reveal_delay_ms = self.state.recovery_phrase_reveal_delay_ms
            self.send_json(
                200,
                {
                    "snapshot": mode,
                    "delayMs": delay_ms,
                    "createDelayMs": create_delay_ms,
                    "createEventDelivery": create_event_delivery,
                    "revealDelayMs": reveal_delay_ms,
                },
            )
            return

        if self.path == "/__test__/disconnect":
            self.state.disconnect_streams()
            self.send_json(200, {"disconnected": True})
            return

        self.send_json(404, {"error": "not-found"})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=38421)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.state = MockState()  # type: ignore[attr-defined]
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
