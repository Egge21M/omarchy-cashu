#!/usr/bin/env python3
"""Deterministic loopback mock for the implemented Cocod Network Interface v1."""

from __future__ import annotations

import argparse
import copy
import hashlib
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
from urllib.parse import parse_qs, quote, urlsplit


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
RECEIVE_MINT = "https://mint.slice4.test"
REGISTRATION_RACE_MINT = "https://registration-race.slice4.test"
TRUST_RACE_MINT = "https://trust-race.slice4.test"
RECEIVE_TOKENS: dict[str, dict[str, str]] = {
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC11bmtub3duLW1pbnQifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "1200",
        "fee": "2",
        "netAmount": "1198",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jYW5jZWwifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "400",
        "fee": "1",
        "netAmount": "399",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC11c2QifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "usd",
        "amount": "12",
        "fee": "1",
        "netAmount": "11",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1taW50LWRvd24ifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "600",
        "fee": "1",
        "netAmount": "599",
        "previewError": "mint_unavailable",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1zcGVudCJ9": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "500",
        "fee": "1",
        "netAmount": "499",
        "createError": "token_already_spent",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jb25mbGljdCJ9": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "700",
        "fee": "1",
        "netAmount": "699",
        "createError": "operation_conflict",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1ub3QtcmVnaXN0ZXJlZCJ9": {
        "mintUrl": REGISTRATION_RACE_MINT,
        "unit": "sat",
        "amount": "800",
        "fee": "1",
        "netAmount": "799",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1ub3QtdHJ1c3RlZCJ9": {
        "mintUrl": TRUST_RACE_MINT,
        "unit": "sat",
        "amount": "900",
        "fee": "1",
        "netAmount": "899",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1ub3QtZm91bmQifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "1000",
        "fee": "1",
        "netAmount": "999",
        "executeError": "operation_not_found",
    },
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
        self.token_preview_requests = 0
        self.mint_registration_requests = 0
        self.mint_trust_requests = 0
        self.receive_create_requests = 0
        self.receive_execute_requests = 0
        self.receive_cancel_requests = 0
        self.receive_operation_sequence = 0
        self.receive_operations: dict[str, dict[str, Any]] = {}
        self.receive_token_keys: dict[str, str] = {}
        self.receive_command_errors: dict[str, str] = {}
        self.spent_receive_token_keys: set[str] = set()
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

    def publish_events(self, events: list[dict[str, Any]]) -> None:
        with self.lock:
            subscribers = list(self.subscribers)
        for event in events:
            payload = ("data: " + json.dumps(event, separators=(",", ":")) + "\n\n").encode()
            for subscriber in subscribers:
                subscriber.put((payload, "whole"))

    def safe_event(self, event_type: str, data: dict[str, str]) -> dict[str, Any]:
        return {"type": event_type, "timestamp": FIXED_TIME, "data": data}

    def token_preview(self, value: object) -> tuple[int, dict[str, Any]]:
        token = value.get("token") if isinstance(value, dict) else None
        accepted_units = value.get("acceptedUnits") if isinstance(value, dict) else None
        with self.lock:
            self.token_preview_requests += 1
            details = copy.deepcopy(RECEIVE_TOKENS.get(token)) if isinstance(token, str) else None
            mints = copy.deepcopy(self.resources["mints"]["items"])
        if details is None:
            return 422, error_document("invalid_token", "The Cashu token is invalid")
        if details.get("previewError") == "mint_unavailable":
            return 503, error_document("mint_unavailable", "The Mint is unavailable", True)
        if accepted_units is not None and (
            not isinstance(accepted_units, list)
            or details["unit"] not in accepted_units
        ):
            return 422, error_document("unsupported_unit", "The token unit is not accepted")
        if details["unit"] != "sat":
            return 422, error_document("unsupported_unit", "The token unit is not supported")
        trusted = any(
            mint.get("mintUrl") == details["mintUrl"] and mint.get("trusted") is True
            for mint in mints
        )
        return 200, {
            "mintUrl": details["mintUrl"],
            "unit": details["unit"],
            "amount": details["amount"],
            "fee": details["fee"],
            "netAmount": details["netAmount"],
            "trusted": trusted,
        }

    def register_mint(self, value: object) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        mint_url = value.get("mintUrl") if isinstance(value, dict) else None
        if not isinstance(mint_url, str) or not re.fullmatch(r"https?://[^\s/]+(?:/[^\s]*)?", mint_url):
            return 400, error_document("invalid_request", "A normalized Mint URL is required"), []
        with self.lock:
            self.mint_registration_requests += 1
            items = self.resources["mints"]["items"]
            for mint in items:
                if mint.get("mintUrl") == mint_url:
                    return 200, copy.deepcopy(mint), []
            mint = {
                "mintUrl": mint_url,
                "name": "Slice 4 Mint" if mint_url == RECEIVE_MINT else "Known Mint",
                "trusted": False,
                "createdAt": FIXED_TIME,
                "updatedAt": FIXED_TIME,
            }
            items.append(mint)
        event = self.safe_event("mint.updated", {"mintUrl": mint_url})
        return 201, copy.deepcopy(mint), [event]

    def trust_mint(self, value: object) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        mint_url = value.get("mintUrl") if isinstance(value, dict) else None
        if not isinstance(mint_url, str):
            return 400, error_document("invalid_request", "A Mint URL is required"), []
        with self.lock:
            self.mint_trust_requests += 1
            if mint_url == REGISTRATION_RACE_MINT:
                self.resources["mints"]["items"] = [
                    mint
                    for mint in self.resources["mints"]["items"]
                    if mint.get("mintUrl") != mint_url
                ]
                return 409, error_document("mint_not_registered", "The Mint is not registered"), []
            for mint in self.resources["mints"]["items"]:
                if mint.get("mintUrl") != mint_url:
                    continue
                mint["trusted"] = True
                mint["updatedAt"] = FIXED_TIME
                result = copy.deepcopy(mint)
                if mint_url == TRUST_RACE_MINT:
                    mint["trusted"] = False
                break
            else:
                return 409, error_document("mint_not_registered", "The Mint is not registered"), []
        event = self.safe_event("mint.updated", {"mintUrl": mint_url})
        return 200, result, [event]

    def receive_operation(self, operation_id: str) -> dict[str, Any] | None:
        with self.lock:
            operation = self.receive_operations.get(operation_id)
            return copy.deepcopy(operation) if operation else None

    def create_receive(
        self, value: object
    ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        token = value.get("token") if isinstance(value, dict) else None
        details = RECEIVE_TOKENS.get(token) if isinstance(token, str) else None
        with self.lock:
            self.receive_create_requests += 1
            mints = copy.deepcopy(self.resources["mints"]["items"])
        if details is None:
            return 422, error_document("invalid_token", "The Cashu token is invalid"), []
        if details["unit"] != "sat":
            return 422, error_document("unsupported_unit", "The token unit is not supported"), []
        known = next((mint for mint in mints if mint.get("mintUrl") == details["mintUrl"]), None)
        if known is None:
            return 409, error_document("mint_not_registered", "The Mint is not registered"), []
        if known.get("trusted") is not True:
            return 409, error_document("mint_not_trusted", "The Mint is not trusted"), []
        create_error = details.get("createError")
        if create_error:
            return 409, error_document(create_error, "The Receive cannot be prepared"), []
        token_key = hashlib.sha256(token.encode()).hexdigest()
        with self.lock:
            if token_key in self.spent_receive_token_keys:
                return 409, error_document("token_already_spent", "The token is already spent"), []
            for operation_id, existing_key in self.receive_token_keys.items():
                if existing_key == token_key and self.receive_operations[operation_id]["state"] in (
                    "init",
                    "prepared",
                    "executing",
                ):
                    return 409, error_document("operation_conflict", "A Receive already exists"), []
            self.receive_operation_sequence += 1
            operation_id = f"receive-{self.receive_operation_sequence}"
            operation = {
                "id": operation_id,
                "type": "receive",
                "state": "prepared",
                "mintUrl": details["mintUrl"],
                "unit": details["unit"],
                "amount": details["amount"],
                "fee": details["fee"],
                "netAmount": details["netAmount"],
                "createdAt": FIXED_TIME,
                "updatedAt": FIXED_TIME,
            }
            self.receive_operations[operation_id] = operation
            self.receive_token_keys[operation_id] = token_key
            if "executeError" in details:
                self.receive_command_errors[operation_id] = details["executeError"]
            self.resources["receivePrepared"]["items"].append(copy.deepcopy(operation))
        event = self.safe_event(
            "operation.updated",
            {"operationType": "receive", "operationId": operation_id, "mintUrl": details["mintUrl"]},
        )
        return 201, copy.deepcopy(operation), [event]

    def command_receive(
        self, operation_id: str, command: str
    ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        with self.lock:
            if command == "execute":
                self.receive_execute_requests += 1
            elif command == "cancel":
                self.receive_cancel_requests += 1
            operation = self.receive_operations.get(operation_id)
            if operation is None:
                return 404, error_document("operation_not_found", "The Receive does not exist"), []
            if operation["state"] != "prepared":
                return 409, error_document("operation_conflict", "The Receive is not prepared"), []
            command_error = self.receive_command_errors.get(operation_id) if command == "execute" else None
            if command_error:
                self.resources["receivePrepared"]["items"] = [
                    item
                    for item in self.resources["receivePrepared"]["items"]
                    if item.get("id") != operation_id
                ]
                del self.receive_operations[operation_id]
                self.receive_token_keys.pop(operation_id, None)
                self.receive_command_errors.pop(operation_id, None)
                return 404, error_document(command_error, "The Receive does not exist"), []
            operation["state"] = "rolled_back" if command == "cancel" else "finalized"
            operation["updatedAt"] = FIXED_TIME
            self.resources["receivePrepared"]["items"] = [
                item
                for item in self.resources["receivePrepared"]["items"]
                if item.get("id") != operation_id
            ]
            events = [
                self.safe_event(
                    "operation.updated",
                    {
                        "operationType": "receive",
                        "operationId": operation_id,
                        "mintUrl": operation["mintUrl"],
                    },
                )
            ]
            if command == "execute":
                token_key = self.receive_token_keys[operation_id]
                self.spent_receive_token_keys.add(token_key)
                balances = self.resources["balances"]["items"]
                balance = next(
                    (
                        item
                        for item in balances
                        if item.get("mintUrl") == operation["mintUrl"]
                        and item.get("unit") == operation["unit"]
                    ),
                    None,
                )
                if balance is None:
                    balance = {
                        "mintUrl": operation["mintUrl"],
                        "unit": operation["unit"],
                        "spendable": "0",
                        "reserved": "0",
                        "total": "0",
                    }
                    balances.append(balance)
                balance["spendable"] = str(
                    int(balance["spendable"]) + int(operation["netAmount"])
                )
                balance["total"] = str(int(balance["spendable"]) + int(balance["reserved"]))
                events.append(
                    self.safe_event("balance.updated", {"mintUrl": operation["mintUrl"]})
                )
            result = copy.deepcopy(operation)
        return 200, result, events

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
                "tokenPreviewRequests": self.token_preview_requests,
                "mintRegistrationRequests": self.mint_registration_requests,
                "mintTrustRequests": self.mint_trust_requests,
                "receiveCreateRequests": self.receive_create_requests,
                "receiveExecuteRequests": self.receive_execute_requests,
                "receiveCancelRequests": self.receive_cancel_requests,
                "receiveOperationCount": len(self.receive_operations),
            }


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-cocod/1"

    @property
    def state(self) -> MockState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: object) -> None:
        return

    def send_json(
        self, status: int, value: object, headers: dict[str, str] | None = None
    ) -> None:
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, header_value in (headers or {}).items():
            self.send_header(name, header_value)
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
        request_url = urlsplit(self.path)
        if request_url.path == "/v1/mints/info":
            if not self.wallet_required():
                return
            mint_url = parse_qs(request_url.query).get("mintUrl", [None])[0]
            if not isinstance(mint_url, str) or not mint_url:
                self.send_json(
                    400,
                    error_document("invalid_request", "A Mint URL is required"),
                )
                return
            with self.state.lock:
                mint = next(
                    (
                        copy.deepcopy(item)
                        for item in self.state.resources["mints"]["items"]
                        if item.get("mintUrl") == mint_url
                    ),
                    None,
                )
            if mint is None:
                self.send_json(
                    404,
                    error_document("mint_not_registered", "The Mint is not registered"),
                )
                return
            self.send_json(200, mint)
            return
        if self.path in COLLECTION_PATHS:
            if not self.wallet_required():
                return
            name = COLLECTION_PATHS[self.path]
            with self.state.lock:
                value = copy.deepcopy(self.state.resources[name])
            self.resource_response(name, value)
            return
        match = re.fullmatch(r"/v1/operations/receive/([^/]+)", self.path)
        if match:
            if not self.wallet_required():
                return
            operation = self.state.receive_operation(match.group(1))
            if operation is None:
                self.send_json(
                    404,
                    error_document("operation_not_found", "The Receive does not exist"),
                )
                return
            self.send_json(200, operation)
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
        if self.path == "/v1/token-previews":
            if not self.wallet_required():
                return
            status, response = self.state.token_preview(value)
            self.send_json(status, response)
            return
        if self.path == "/v1/mints":
            if not self.wallet_required():
                return
            status, response, events = self.state.register_mint(value)
            headers = None
            if status == 201:
                headers = {
                    "Location": "/v1/mints/info?mintUrl="
                    + quote(str(response["mintUrl"]), safe="")
                }
            self.send_json(status, response, headers)
            self.state.publish_events(events)
            return
        if self.path == "/v1/mints/trust":
            if not self.wallet_required():
                return
            status, response, events = self.state.trust_mint(value)
            self.send_json(status, response)
            self.state.publish_events(events)
            return
        if self.path == "/v1/operations/receive":
            if not self.wallet_required():
                return
            status, response, events = self.state.create_receive(value)
            headers = None
            if status == 201:
                headers = {"Location": f"/v1/operations/receive/{response['id']}"}
            self.send_json(status, response, headers)
            self.state.publish_events(events)
            return
        match = re.fullmatch(
            r"/v1/operations/receive/([^/]+)/(execute|cancel|refresh)", self.path
        )
        if match:
            if not self.wallet_required():
                return
            command = match.group(2)
            if command == "refresh":
                operation = self.state.receive_operation(match.group(1))
                if operation is None:
                    self.send_json(
                        404,
                        error_document("operation_not_found", "The Receive does not exist"),
                    )
                else:
                    self.send_json(200, operation)
                return
            status, response, events = self.state.command_receive(match.group(1), command)
            self.send_json(status, response)
            self.state.publish_events(events)
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
