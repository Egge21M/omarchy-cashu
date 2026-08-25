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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit


RECOVERY_PHRASE = (
    "abandon abandon abandon abandon abandon abandon abandon abandon "
    "abandon abandon abandon about"
)
FIXED_TIME = "2026-08-20T12:00:00.000Z"
OPENAPI_PATHS = [
    "/v1/openapi.json",
    "/v1/status",
    "/v1/balances",
    "/v1/events",
    "/v1/mints",
    "/v1/operations/receive",
    "/v1/operations/receive/{operationId}",
    "/v1/operations/receive/prepared",
    "/v1/operations/receive/in-flight",
    "/v1/operations/receive/{operationId}/execute",
    "/v1/operations/receive/{operationId}/cancel",
    "/v1/operations/receive/{operationId}/refresh",
    "/v1/operations/send",
    "/v1/operations/send/{operationId}",
    "/v1/operations/send/prepared",
    "/v1/operations/send/in-flight",
    "/v1/operations/send/{operationId}/execute",
    "/v1/operations/send/{operationId}/result",
    "/v1/operations/send/{operationId}/cancel",
    "/v1/operations/send/{operationId}/refresh",
    "/v1/operations/send/{operationId}/reclaim",
    "/v1/admin/wallet/initialize",
    "/v1/admin/wallet/recovery-material",
]
COLLECTION_PATHS = {
    "/v1/balances": "balances",
    "/v1/mints": "mints",
    "/v1/operations/receive/prepared": "receivePrepared",
    "/v1/operations/receive/in-flight": "receiveInFlight",
    "/v1/operations/send/prepared": "sendPrepared",
    "/v1/operations/send/in-flight": "sendInFlight",
}
BODYLESS_COMMAND_PATH = re.compile(
    r"/v1/operations/(?:receive|send)/[^/]+/(?:execute|cancel|refresh|reclaim)"
)
RECEIVE_MINT = "https://mint.slice4.test"
REGISTRATION_RACE_MINT = "https://registration-race.slice4.test"
TRUST_RACE_MINT = "https://trust-race.slice4.test"
RECEIVE_TOKENS: dict[str, dict[str, str]] = {
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC11bmtub3duLW1pbnQifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "1200",
        "fee": "2",
        "creditedAmount": "1198",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jYW5jZWwifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "400",
        "fee": "1",
        "creditedAmount": "399",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNi1wZW5kaW5nIn0": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "250",
        "fee": "1",
        "creditedAmount": "249",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNi1yb3RhdGlvbiJ9": {
        "mintUrl": "https://mint.one",
        "unit": "sat",
        "amount": "80",
        "fee": "1",
        "creditedAmount": "79",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNi1jb25jdXJyZW50In0": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "350",
        "fee": "1",
        "creditedAmount": "349",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC11c2QifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "usd",
        "amount": "12",
        "fee": "1",
        "creditedAmount": "11",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1taW50LWRvd24ifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "600",
        "fee": "1",
        "creditedAmount": "599",
        "previewError": "mint_unavailable",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1zcGVudCJ9": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "500",
        "fee": "1",
        "creditedAmount": "499",
        "createError": "token_already_spent",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jb25mbGljdCJ9": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "700",
        "fee": "1",
        "creditedAmount": "699",
        "createError": "operation_conflict",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1ub3QtcmVnaXN0ZXJlZCJ9": {
        "mintUrl": REGISTRATION_RACE_MINT,
        "unit": "sat",
        "amount": "800",
        "fee": "1",
        "creditedAmount": "799",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1ub3QtdHJ1c3RlZCJ9": {
        "mintUrl": TRUST_RACE_MINT,
        "unit": "sat",
        "amount": "900",
        "fee": "1",
        "creditedAmount": "899",
    },
    "cashuAeyJ0ZXN0Ijoic2xpY2UtNC1ub3QtZm91bmQifQ": {
        "mintUrl": RECEIVE_MINT,
        "unit": "sat",
        "amount": "1000",
        "fee": "1",
        "creditedAmount": "999",
        "executeError": "not_found",
    },
}


def error_document(code: str, message: str, retryable: bool = False) -> dict[str, Any]:
    return {"error": {"code": code, "message": message, "retryable": retryable}}


def operation_error(
    code: str, message: str, retryable: bool = False
) -> tuple[int, dict[str, Any]]:
    if code in ("operation_not_found", "not_found"):
        return 404, error_document("not_found", message)
    if code in ("operation_conflict", "invalid_operation_state"):
        return 409, error_document("invalid_operation_state", message)
    if code == "operation_in_progress":
        return 409, error_document("operation_in_progress", message, True)
    if code in ("result_not_available", "operation_result_not_available"):
        return 409, error_document(
            "operation_result_not_available", message, retryable
        )
    return 500, error_document("coco_error", message)


class MockState:
    def __init__(self, state_root: Path) -> None:
        self.lock = threading.RLock()
        self.state_root = state_root
        self.wallet_configured = False
        self.status = self._status_document()
        self.resources: dict[str, dict[str, Any]] = {
            "balances": {"items": []},
            "mints": {"items": []},
            "receivePrepared": {"items": [], "offset": 0, "limit": 20},
            "receiveInFlight": {"items": [], "offset": 0, "limit": 20},
            "sendPrepared": {"items": [], "offset": 0, "limit": 20},
            "sendInFlight": {"items": [], "offset": 0, "limit": 20},
        }
        self.resource_requests = {
            "openapi": 0,
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
        self.create_session_polls = 0
        self.remaining_session_start_polls = 0
        self.recovery_material_requests = 0
        self.recovery_material_responses = 0
        self.recovery_delay_ms = 0
        self.mint_registration_requests = 0
        self.mint_trust_requests = 0
        self.receive_delay_ms = 0
        self.receive_create_requests = 0
        self.receive_execute_requests = 0
        self.receive_cancel_requests = 0
        self.receive_refresh_requests = 0
        self.receive_lookup_requests = 0
        self.receive_lookup_responses = 0
        self.receive_lookup_requests_active = 0
        self.receive_lookup_delay_ms = 0
        self.receive_prepared_failures = 0
        self.receive_prepare_reconcile_failures = 0
        self.receive_operation_sequence = 0
        self.receive_operations: dict[str, dict[str, Any]] = {}
        self.receive_token_keys: dict[str, str] = {}
        self.receive_command_errors: dict[str, str] = {}
        self.receive_recovery_outcomes: dict[str, str] = {}
        self.receive_interruption = "none"
        self.receive_create_interruption = "none"
        self.receive_create_dropped_responses = 0
        self.receive_refresh_error = ""
        self.send_create_requests = 0
        self.send_idempotency_unique_keys = 0
        self.send_idempotency_replays = 0
        self.send_idempotency_conflicts = 0
        self.send_idempotency_cache: dict[str, dict[str, Any]] = {}
        self.send_create_delay_ms = 0
        self.send_execute_requests = 0
        self.send_cancel_requests = 0
        self.send_reclaim_requests = 0
        self.send_reclaim_operation_ids: list[str] = []
        self.send_refresh_requests = 0
        self.send_lookup_requests = 0
        self.send_result_requests = 0
        self.send_result_operation_ids: list[str] = []
        self.send_result_delay_ms = 0
        self.send_result_unavailable_responses = 0
        self.send_operation_sequence = 0
        self.send_operations: dict[str, dict[str, Any]] = {}
        self.send_results: dict[str, str] = {}
        self.send_create_error = ""
        self.send_create_empty_id = False
        self.send_create_interruption = "none"
        self.send_command_error = ""
        self.send_cancel_error = ""
        self.send_reclaim_outcome = "success"
        self.send_refresh_error = ""
        self.send_refresh_unavailable_responses = 0
        self.send_execute_interruption = "none"
        self.send_command_delay_ms = 0
        self.send_prepared_failures = 0
        self.suppress_next_send_events = False
        self.suppress_next_send_execute_events = False
        self.spent_receive_token_keys: set[str] = set()
        self.subscribers: list[queue.Queue[object]] = []
        self._load_persisted_state()

    @property
    def persisted_state_path(self) -> Path:
        return self.state_root / "mock-runtime-state.json"

    def _load_persisted_state(self) -> None:
        try:
            value = json.loads(self.persisted_state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return
        if not isinstance(value, dict):
            return
        self.wallet_configured = value.get("walletConfigured") is True
        resources = value.get("resources")
        if isinstance(resources, dict):
            for key in self.resources:
                if isinstance(resources.get(key), dict):
                    self.resources[key] = copy.deepcopy(resources[key])
        operations = value.get("receiveOperations")
        if isinstance(operations, dict):
            self.receive_operations = copy.deepcopy(operations)
        send_operations = value.get("sendOperations")
        if isinstance(send_operations, dict):
            self.send_operations = copy.deepcopy(send_operations)
        send_results = value.get("sendResults")
        if isinstance(send_results, dict):
            self.send_results = {
                str(operation_id): token
                for operation_id, token in send_results.items()
                if str(operation_id) in self.send_operations
                and isinstance(token, str)
                and token
            }
        input_digests = value.get("receiveInputDigests")
        if isinstance(input_digests, dict):
            self.receive_token_keys = {
                str(operation_id): str(digest)
                for operation_id, digest in input_digests.items()
                if re.fullmatch(r"[0-9a-f]{64}", str(digest))
            }
        spent_digests = value.get("spentReceiveInputDigests")
        if isinstance(spent_digests, list):
            self.spent_receive_token_keys = {
                str(digest)
                for digest in spent_digests
                if re.fullmatch(r"[0-9a-f]{64}", str(digest))
            }
        outcomes = value.get("receiveRecoveryOutcomes")
        if isinstance(outcomes, dict):
            self.receive_recovery_outcomes = {
                str(key): str(state) for key, state in outcomes.items()
                if state in ("finalized", "rolled_back")
            }
        sequence = value.get("receiveOperationSequence")
        if isinstance(sequence, int) and sequence >= 0:
            self.receive_operation_sequence = sequence
        send_sequence = value.get("sendOperationSequence")
        if isinstance(send_sequence, int) and send_sequence >= 0:
            self.send_operation_sequence = send_sequence
        self.status = self._status_document()

    def _persist_locked(self) -> None:
        self.state_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        value = {
            "walletConfigured": self.wallet_configured,
            "resources": self.resources,
            "receiveOperations": self.receive_operations,
            "receiveOperationSequence": self.receive_operation_sequence,
            "sendOperations": self.send_operations,
            "sendOperationSequence": self.send_operation_sequence,
            # This private mode-0600 state models the result retained by Coco's
            # durable Operation. Safe resources and diagnostics never expose it.
            "sendResults": self.send_results,
            "receiveRecoveryOutcomes": self.receive_recovery_outcomes,
            # One-way fixture digests preserve replay behavior without retaining
            # encoded Cashu token material.
            "receiveInputDigests": self.receive_token_keys,
            "spentReceiveInputDigests": sorted(self.spent_receive_token_keys),
        }
        temporary = self.persisted_state_path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        temporary.replace(self.persisted_state_path)

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
                "state": "starting" if self.remaining_session_start_polls > 0 else "running",
                "startedAt": None if self.remaining_session_start_polls > 0 else FIXED_TIME,
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
            return False, "unauthenticated"
        if credential is None or authorization != f"Bearer {credential}":
            with self.lock:
                self.authorization_failures += 1
            return False, "unauthenticated"
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
            self.remaining_session_start_polls = self.create_session_polls
            self.status = self._status_document()
            self._persist_locked()
        return True

    def lifecycle_status(self) -> dict[str, Any]:
        with self.lock:
            status = copy.deepcopy(self.status)
            if self.remaining_session_start_polls > 0:
                self.remaining_session_start_polls -= 1
                if self.remaining_session_start_polls == 0:
                    self.status = self._status_document()
            return status

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
                    resource = copy.deepcopy(value[key])
                    if key in (
                        "receivePrepared",
                        "receiveInFlight",
                        "sendPrepared",
                        "sendInFlight",
                    ):
                        resource.setdefault("offset", 0)
                        resource.setdefault("limit", 20)
                    self.resources[key] = resource
            if "status" in value:
                self.status = copy.deepcopy(value["status"])
                self.wallet_configured = self.status.get("wallet") is not None
            self._persist_locked()
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

    def wait_for_receive_transition(self) -> None:
        with self.lock:
            delay_ms = self.receive_delay_ms
        if delay_ms > 0:
            time.sleep(delay_ms / 1000)

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
            self._persist_locked()
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
                return 500, error_document("coco_error", "Coco could not trust the Mint"), []
            for mint in self.resources["mints"]["items"]:
                if mint.get("mintUrl") != mint_url:
                    continue
                mint["trusted"] = True
                mint["updatedAt"] = FIXED_TIME
                result = copy.deepcopy(mint)
                if mint_url == TRUST_RACE_MINT:
                    mint["trusted"] = False
                self._persist_locked()
                break
            else:
                return 500, error_document("coco_error", "Coco could not trust the Mint"), []
        event = self.safe_event("mint.updated", {"mintUrl": mint_url})
        return 200, result, [event]

    def send_operation(self, operation_id: str) -> dict[str, Any] | None:
        with self.lock:
            self.send_lookup_requests += 1
            operation = self.send_operations.get(operation_id)
            return copy.deepcopy(operation) if operation else None

    @staticmethod
    def _send_token(operation_id: str) -> str:
        return "cashuAeyJ0ZXN0Ijoic2xpY2UtNSIsIm9wIjoi" + operation_id + "In0"

    def send_result(self, operation_id: str) -> tuple[int, dict[str, Any]]:
        with self.lock:
            self.send_result_requests += 1
            self.send_result_operation_ids.append(operation_id)
            delay_ms = self.send_result_delay_ms
        if delay_ms > 0:
            time.sleep(delay_ms / 1000)
        with self.lock:
            operation = self.send_operations.get(operation_id)
            if operation is None:
                return operation_error("not_found", "The Send does not exist")
            if self.send_result_unavailable_responses > 0:
                self.send_result_unavailable_responses -= 1
                return operation_error(
                    "operation_result_not_available",
                    "The Send result is not available yet",
                    operation["state"] == "executing",
                )
            token = self.send_results.get(operation_id)
            if token is None:
                return operation_error(
                    "operation_result_not_available",
                    "The Send result is not available yet",
                    operation["state"] == "executing",
                )
            return 200, {"token": token}

    def create_send(
        self, value: object, idempotency_key: str | None = None
    ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        mint_url = value.get("mintUrl") if isinstance(value, dict) else None
        unit = value.get("unit") if isinstance(value, dict) else None
        amount = value.get("amount") if isinstance(value, dict) else None
        canonical_request = json.dumps(value, separators=(",", ":"), sort_keys=True)

        def respond(
            status: int, response: dict[str, Any], events: list[dict[str, Any]]
        ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
            if idempotency_key:
                with self.lock:
                    self.send_idempotency_cache.setdefault(
                        idempotency_key,
                        {
                            "request": canonical_request,
                            "status": status,
                            "response": copy.deepcopy(response),
                        },
                    )
            return status, response, events

        with self.lock:
            self.send_create_requests += 1
            if idempotency_key:
                cached = self.send_idempotency_cache.get(idempotency_key)
                if cached is not None:
                    if cached["request"] != canonical_request:
                        self.send_idempotency_conflicts += 1
                        return 409, error_document(
                            "idempotency_key_conflict",
                            "The Idempotency-Key was already used for another request",
                        ), []
                    self.send_idempotency_replays += 1
                    return int(cached["status"]), copy.deepcopy(cached["response"]), []
                self.send_idempotency_unique_keys += 1
            mints = copy.deepcopy(self.resources["mints"]["items"])
        if not isinstance(mint_url, str) or not mint_url:
            return respond(
                400, error_document("invalid_request", "A Mint URL is required"), []
            )
        if unit != "sat":
            return respond(
                400, error_document("invalid_request", "Only sat is supported"), []
            )
        if not isinstance(amount, str) or not re.fullmatch(r"[1-9][0-9]*", amount):
            return respond(
                400,
                error_document("invalid_request", "A positive decimal amount is required"),
                [],
            )
        mint = next((item for item in mints if item.get("mintUrl") == mint_url), None)
        if mint is None:
            status, response = operation_error(
                "coco_error", "Coco could not prepare the Send Operation"
            )
            return respond(status, response, [])
        if mint.get("trusted") is not True:
            status, response = operation_error(
                "coco_error", "Coco could not prepare the Send Operation"
            )
            return respond(status, response, [])
        with self.lock:
            forced_error = self.send_create_error
            self.send_create_error = ""
            if forced_error:
                status, response = operation_error(
                    forced_error, "Coco could not prepare the Send Operation"
                )
                return respond(status, response, [])
            if self.send_create_empty_id:
                self.send_create_empty_id = False
                return respond(201, {
                    "id": "",
                    "type": "send",
                    "state": "prepared",
                    "mintUrl": mint_url,
                    "unit": "sat",
                    "method": "default",
                    "requestedAmount": amount,
                    "fee": "0",
                    "inputAmount": amount,
                    "needsSwap": False,
                    "createdAt": FIXED_TIME,
                    "updatedAt": FIXED_TIME,
                }, [])
            balance = next(
                (
                    item
                    for item in self.resources["balances"]["items"]
                    if item.get("mintUrl") == mint_url and item.get("unit") == "sat"
                ),
                None,
            )
            spendable = int(str(balance.get("spendable", "0"))) if balance else 0
            requested = int(amount)
            exact_match = requested == spendable
            input_amount = requested if exact_match else requested + 10
            if balance is None or input_amount > spendable:
                status, response = operation_error(
                    "coco_error", "Coco could not prepare the Send Operation"
                )
                return respond(status, response, [])
            self.send_operation_sequence += 1
            operation_id = f"send-{self.send_operation_sequence}"
            operation = {
                "id": operation_id,
                "type": "send",
                "state": "prepared",
                "mintUrl": mint_url,
                "unit": "sat",
                "method": "default",
                "requestedAmount": amount,
                "fee": "0" if exact_match else "2",
                "inputAmount": str(input_amount),
                "needsSwap": not exact_match,
                "createdAt": FIXED_TIME,
                "updatedAt": FIXED_TIME,
            }
            balance["spendable"] = str(spendable - input_amount)
            balance["reserved"] = str(int(str(balance["reserved"])) + input_amount)
            balance["total"] = str(int(balance["spendable"]) + int(balance["reserved"]))
            self.send_operations[operation_id] = operation
            self.resources["sendPrepared"]["items"].append(copy.deepcopy(operation))
            if idempotency_key:
                self.send_idempotency_cache[idempotency_key] = {
                    "request": canonical_request,
                    "status": 201,
                    "response": copy.deepcopy(operation),
                }
            self._persist_locked()
        events = [
            self.safe_event(
                "operation.updated",
                {"operationType": "send", "operationId": operation_id, "mintUrl": mint_url},
            ),
            self.safe_event("balance.updated", {"mintUrl": mint_url}),
        ]
        with self.lock:
            suppress_events = self.suppress_next_send_events
            self.suppress_next_send_events = False
            interruption = self.send_create_interruption
            self.send_create_interruption = "none"
        if interruption == "after_commit":
            return 0, {}, []
        if interruption == "malformed_after_commit":
            return 201, {"id": "", "type": "send", "state": "prepared"}, []
        return 201, copy.deepcopy(operation), [] if suppress_events else events

    def command_send(
        self, operation_id: str, command: str
    ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        with self.lock:
            if command == "execute":
                self.send_execute_requests += 1
            elif command == "cancel":
                self.send_cancel_requests += 1
            elif command == "reclaim":
                self.send_reclaim_requests += 1
                self.send_reclaim_operation_ids.append(operation_id)
            operation = self.send_operations.get(operation_id)
            if operation is None:
                status, response = operation_error(
                    "not_found", "The Send does not exist"
                )
                return status, response, []
            if command == "reclaim" and operation["state"] == "finalized":
                status, response = operation_error(
                    "invalid_operation_state", "The Send is already finalized"
                )
                return status, response, []
            expected_state = "pending" if command == "reclaim" else "prepared"
            if operation["state"] != expected_state:
                status, response = operation_error(
                    "invalid_operation_state", f"The Send is not {expected_state}"
                )
                return status, response, []
            forced_error = (
                self.send_command_error
                if command == "execute"
                else self.send_cancel_error
            )
            if command == "execute":
                self.send_command_error = ""
            if forced_error == "operation_conflict":
                status, response = operation_error(
                    "invalid_operation_state", "The Send changed before execution"
                )
                return status, response, []
            if forced_error == "operation_not_found":
                self.resources["sendPrepared"]["items"] = [
                    item
                    for item in self.resources["sendPrepared"]["items"]
                    if item.get("id") != operation_id
                ]
                balance = next(
                    (
                        item
                        for item in self.resources["balances"]["items"]
                        if item.get("mintUrl") == operation["mintUrl"]
                        and item.get("unit") == operation["unit"]
                    ),
                    None,
                )
                if balance is not None:
                    released = int(operation["inputAmount"])
                    balance["spendable"] = str(int(balance["spendable"]) + released)
                    balance["reserved"] = str(int(balance["reserved"]) - released)
                    balance["total"] = str(
                        int(balance["spendable"]) + int(balance["reserved"])
                    )
                del self.send_operations[operation_id]
                self._persist_locked()
                status, response = operation_error(
                    "not_found", "The Send does not exist"
                )
                return status, response, []
            if command == "reclaim":
                reclaim_outcome = self.send_reclaim_outcome
                self.send_reclaim_outcome = "success"
                if reclaim_outcome == "reclaim_inconclusive":
                    status, response = operation_error(
                        "coco_error", "Coco could not reclaim the Send Operation"
                    )
                    return status, response, []
                if reclaim_outcome == "operation_conflict":
                    status, response = operation_error(
                        "invalid_operation_state", "The Send changed before Reclaim"
                    )
                    return status, response, []
                if reclaim_outcome == "operation_not_found":
                    self.resources["sendInFlight"]["items"] = [
                        item
                        for item in self.resources["sendInFlight"]["items"]
                        if item.get("id") != operation_id
                    ]
                    balance = next(
                        (
                            item
                            for item in self.resources["balances"]["items"]
                            if item.get("mintUrl") == operation["mintUrl"]
                            and item.get("unit") == operation["unit"]
                        ),
                        None,
                    )
                    if balance is not None:
                        released = int(operation["inputAmount"])
                        balance["spendable"] = str(
                            int(balance["spendable"]) + released
                        )
                        balance["reserved"] = str(
                            int(balance["reserved"]) - released
                        )
                        balance["total"] = str(
                            int(balance["spendable"]) + int(balance["reserved"])
                        )
                    self.send_operations.pop(operation_id, None)
                    self.send_results.pop(operation_id, None)
                    self._persist_locked()
                    status, response = operation_error(
                        "not_found", "The Send does not exist"
                    )
                    return status, response, []
            collection = "sendInFlight" if command == "reclaim" else "sendPrepared"
            self.resources[collection]["items"] = [
                item
                for item in self.resources[collection]["items"]
                if item.get("id") != operation_id
            ]
            balance = next(
                (
                    item
                    for item in self.resources["balances"]["items"]
                    if item.get("mintUrl") == operation["mintUrl"]
                    and item.get("unit") == operation["unit"]
                ),
                None,
            )
            events = [
                self.safe_event(
                    "operation.updated",
                    {
                        "operationType": "send",
                        "operationId": operation_id,
                        "mintUrl": operation["mintUrl"],
                    },
                )
            ]
            if command == "reclaim" and reclaim_outcome == "recipient_won":
                operation["state"] = "finalized"
                operation["updatedAt"] = FIXED_TIME
                if balance is not None:
                    spent = int(operation["inputAmount"])
                    balance["reserved"] = str(int(balance["reserved"]) - spent)
                    balance["total"] = str(
                        int(balance["spendable"]) + int(balance["reserved"])
                    )
                events.append(
                    self.safe_event("balance.updated", {"mintUrl": operation["mintUrl"]})
                )
                self._persist_locked()
                status, response = operation_error(
                    "coco_error", "Coco could not reclaim the Send Operation"
                )
                return status, response, events
            if command in ("cancel", "reclaim"):
                operation["state"] = "rolled_back"
                if balance is not None:
                    released = int(operation["inputAmount"])
                    balance["spendable"] = str(int(balance["spendable"]) + released)
                    balance["reserved"] = str(int(balance["reserved"]) - released)
                    balance["total"] = str(
                        int(balance["spendable"]) + int(balance["reserved"])
                    )
                response: dict[str, Any] = copy.deepcopy(operation)
            else:
                operation["state"] = "pending"
                self.resources["sendInFlight"]["items"].append(copy.deepcopy(operation))
                token = self._send_token(operation_id)
                self.send_results[operation_id] = token
                response = {
                    "operation": copy.deepcopy(operation),
                    "result": {"token": token},
                }
            operation["updatedAt"] = FIXED_TIME
            events.append(self.safe_event("balance.updated", {"mintUrl": operation["mintUrl"]}))
            self._persist_locked()
            suppress_events = command == "execute" and self.suppress_next_send_execute_events
            if suppress_events:
                self.suppress_next_send_execute_events = False
            interruption = self.send_execute_interruption if command == "execute" else "none"
            if command == "execute":
                self.send_execute_interruption = "none"
        if interruption == "after_commit":
            return 0, {}, []
        return 200, response, [] if suppress_events else events

    def refresh_send(
        self, operation_id: str
    ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        with self.lock:
            self.send_refresh_requests += 1
            operation = self.send_operations.get(operation_id)
            if operation is None:
                status, response = operation_error(
                    "not_found", "The Send does not exist"
                )
                return status, response, []
            forced_error = self.send_refresh_error
            self.send_refresh_error = ""
            if self.send_refresh_unavailable_responses > 0:
                self.send_refresh_unavailable_responses -= 1
                forced_error = "mint_unavailable"
            if forced_error:
                status, response = operation_error(
                    forced_error, "Coco could not reconcile the Send Operation"
                )
                return status, response, []
            result = copy.deepcopy(operation)
        event = self.safe_event(
            "operation.updated",
            {
                "operationType": "send",
                "operationId": operation_id,
                "mintUrl": result["mintUrl"],
            },
        )
        return 200, result, [event]

    def redeem_send(
        self, operation_id: object
    ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        if not isinstance(operation_id, str) or not operation_id:
            return 400, error_document(
                "invalid_request", "A Send Operation ID is required"
            ), []
        with self.lock:
            operation = self.send_operations.get(operation_id)
            if operation is None:
                return 404, error_document(
                    "not_found", "The Send does not exist"
                ), []
            if operation["state"] != "pending":
                return 409, error_document(
                    "invalid_operation_state", "The Send is not pending"
                ), []
            operation["state"] = "finalized"
            operation["updatedAt"] = FIXED_TIME
            self.resources["sendInFlight"]["items"] = [
                item
                for item in self.resources["sendInFlight"]["items"]
                if item.get("id") != operation_id
            ]
            balance = next(
                (
                    item
                    for item in self.resources["balances"]["items"]
                    if item.get("mintUrl") == operation["mintUrl"]
                    and item.get("unit") == operation["unit"]
                ),
                None,
            )
            if balance is not None:
                balance["reserved"] = str(
                    int(balance["reserved"]) - int(operation["inputAmount"])
                )
                balance["total"] = str(
                    int(balance["spendable"]) + int(balance["reserved"])
                )
            self._persist_locked()
            result = copy.deepcopy(operation)
        events = [
            self.safe_event(
                "operation.updated",
                {
                    "operationType": "send",
                    "operationId": operation_id,
                    "mintUrl": result["mintUrl"],
                },
            ),
            self.safe_event("balance.updated", {"mintUrl": result["mintUrl"]}),
        ]
        return 200, result, events

    def remove_send_for_test(
        self, operation_id: object
    ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        if not isinstance(operation_id, str) or not operation_id:
            return 400, error_document(
                "invalid_request", "A Send Operation ID is required"
            ), []
        with self.lock:
            operation = self.send_operations.pop(operation_id, None)
            if operation is None:
                return 404, error_document(
                    "not_found", "The Send does not exist"
                ), []
            self.resources["sendPrepared"]["items"] = [
                item
                for item in self.resources["sendPrepared"]["items"]
                if item.get("id") != operation_id
            ]
            self.resources["sendInFlight"]["items"] = [
                item
                for item in self.resources["sendInFlight"]["items"]
                if item.get("id") != operation_id
            ]
            balance = next(
                (
                    item
                    for item in self.resources["balances"]["items"]
                    if item.get("mintUrl") == operation["mintUrl"]
                    and item.get("unit") == operation["unit"]
                ),
                None,
            )
            if balance is not None and operation["state"] == "prepared":
                released = int(operation["inputAmount"])
                balance["spendable"] = str(int(balance["spendable"]) + released)
                balance["reserved"] = str(int(balance["reserved"]) - released)
                balance["total"] = str(
                    int(balance["spendable"]) + int(balance["reserved"])
                )
            self._persist_locked()
        events = [
            self.safe_event(
                "operation.updated",
                {
                    "operationType": "send",
                    "operationId": operation_id,
                    "mintUrl": operation["mintUrl"],
                },
            ),
            self.safe_event("balance.updated", {"mintUrl": operation["mintUrl"]}),
        ]
        return 200, {"removed": True}, events

    def receive_operation(self, operation_id: str) -> dict[str, Any] | None:
        with self.lock:
            self.receive_lookup_requests += 1
            self.receive_lookup_requests_active += 1
            delay_ms = self.receive_lookup_delay_ms
            operation = self.receive_operations.get(operation_id)
            result = self.safe_receive_operation(operation) if operation else None
        if delay_ms > 0:
            time.sleep(delay_ms / 1000)
        with self.lock:
            self.receive_lookup_requests_active -= 1
            self.receive_lookup_responses += 1
        return result

    @staticmethod
    def safe_receive_operation(operation: dict[str, Any]) -> dict[str, Any]:
        return {
            key: copy.deepcopy(value)
            for key, value in operation.items()
            if key != "creditedAmount"
        }

    def create_receive(
        self, value: object
    ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        token = value.get("token") if isinstance(value, dict) else None
        details = RECEIVE_TOKENS.get(token) if isinstance(token, str) else None
        with self.lock:
            self.receive_create_requests += 1
            mints = copy.deepcopy(self.resources["mints"]["items"])
        if details is None:
            return 500, error_document("coco_error", "Coco could not prepare the Receive Operation"), []
        if details.get("previewError"):
            return 500, error_document("coco_error", "Coco could not prepare the Receive Operation"), []
        known = next((mint for mint in mints if mint.get("mintUrl") == details["mintUrl"]), None)
        if known is None:
            return 500, error_document("coco_error", "Coco could not prepare the Receive Operation"), []
        if known.get("trusted") is not True:
            return 500, error_document("coco_error", "Coco could not prepare the Receive Operation"), []
        create_error = details.get("createError")
        if create_error:
            return 500, error_document("coco_error", "Coco could not prepare the Receive Operation"), []
        token_key = hashlib.sha256(token.encode()).hexdigest()
        with self.lock:
            if token_key in self.spent_receive_token_keys:
                return 500, error_document("coco_error", "Coco could not prepare the Receive Operation"), []
            for operation_id, existing_key in self.receive_token_keys.items():
                if existing_key == token_key and self.receive_operations[operation_id]["state"] in (
                    "init",
                    "prepared",
                    "executing",
                ):
                    return 500, error_document("coco_error", "Coco could not prepare the Receive Operation"), []
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
                "creditedAmount": details["creditedAmount"],
                "createdAt": FIXED_TIME,
                "updatedAt": FIXED_TIME,
            }
            self.receive_operations[operation_id] = operation
            self.receive_token_keys[operation_id] = token_key
            if "executeError" in details:
                self.receive_command_errors[operation_id] = details["executeError"]
            safe_operation = self.safe_receive_operation(operation)
            self.resources["receivePrepared"]["items"].append(safe_operation)
            self._persist_locked()
        event = self.safe_event(
            "operation.updated",
            {"operationType": "receive", "operationId": operation_id, "mintUrl": details["mintUrl"]},
        )
        with self.lock:
            interruption = self.receive_create_interruption
            self.receive_create_interruption = "none"
            if interruption in ("after_commit", "malformed_after_commit"):
                self.receive_create_dropped_responses += 1
        if interruption == "after_commit":
            return 0, {}, []
        if interruption == "malformed_after_commit":
            return 201, {"id": "", "type": "receive", "state": "prepared"}, []
        return 201, self.safe_receive_operation(operation), [event]

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
                return 404, error_document("not_found", "The Receive does not exist"), []
            if operation["state"] != "prepared":
                return 409, error_document("invalid_operation_state", "The Receive is not prepared"), []
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
                self._persist_locked()
                return 404, error_document("not_found", "The Receive does not exist"), []
            if command == "execute" and self.receive_interruption in (
                "before_commit",
                "after_commit",
            ):
                operation["state"] = "executing"
                operation["updatedAt"] = FIXED_TIME
                self.resources["receivePrepared"]["items"] = [
                    item
                    for item in self.resources["receivePrepared"]["items"]
                    if item.get("id") != operation_id
                ]
                self.resources["receiveInFlight"]["items"].append(
                    self.safe_receive_operation(operation)
                )
                outcome = (
                    "finalized"
                    if self.receive_interruption == "after_commit"
                    else "rolled_back"
                )
                self.receive_recovery_outcomes[operation_id] = outcome
                if self.receive_interruption == "after_commit":
                    self.spent_receive_token_keys.add(
                        self.receive_token_keys[operation_id]
                    )
                    self._credit_receive_locked(operation)
                self._persist_locked()
                event = self.safe_event(
                    "operation.updated",
                    {
                        "operationType": "receive",
                        "operationId": operation_id,
                        "mintUrl": operation["mintUrl"],
                    },
                )
                return 0, {}, [event]
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
                self._credit_receive_locked(operation)
                events.append(
                    self.safe_event("balance.updated", {"mintUrl": operation["mintUrl"]})
                )
            result = self.safe_receive_operation(operation)
            self._persist_locked()
        return 200, result, events

    def _credit_receive_locked(self, operation: dict[str, Any]) -> None:
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
            int(balance["spendable"]) + int(operation["creditedAmount"])
        )
        balance["total"] = str(int(balance["spendable"]) + int(balance["reserved"]))

    def refresh_receive(
        self, operation_id: str
    ) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        with self.lock:
            self.receive_refresh_requests += 1
            operation = self.receive_operations.get(operation_id)
            if operation is None:
                return 404, error_document("not_found", "The Receive does not exist"), []
            if self.receive_refresh_error:
                code = self.receive_refresh_error
                status, response = operation_error(
                    code, "Coco could not reconcile the Receive Operation"
                )
                return status, response, []
            outcome = self.receive_recovery_outcomes.get(operation_id)
            if operation["state"] == "executing" and outcome:
                operation["state"] = outcome
                operation["updatedAt"] = FIXED_TIME
                self.resources["receiveInFlight"]["items"] = [
                    item
                    for item in self.resources["receiveInFlight"]["items"]
                    if item.get("id") != operation_id
                ]
                self.receive_recovery_outcomes.pop(operation_id, None)
                self._persist_locked()
            result = self.safe_receive_operation(operation)
        event = self.safe_event(
            "operation.updated",
            {
                "operationType": "receive",
                "operationId": operation_id,
                "mintUrl": result["mintUrl"],
            },
        )
        return 200, result, [event]

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
                "createSessionPolls": self.create_session_polls,
                "remainingSessionStartPolls": self.remaining_session_start_polls,
                "recoveryMaterialRequests": self.recovery_material_requests,
                "recoveryMaterialResponses": self.recovery_material_responses,
                "recoveryDelayMs": self.recovery_delay_ms,
                "mintRegistrationRequests": self.mint_registration_requests,
                "mintTrustRequests": self.mint_trust_requests,
                "receiveDelayMs": self.receive_delay_ms,
                "receiveCreateRequests": self.receive_create_requests,
                "receiveCreateDroppedResponses": self.receive_create_dropped_responses,
                "receiveExecuteRequests": self.receive_execute_requests,
                "receiveCancelRequests": self.receive_cancel_requests,
                "receiveRefreshRequests": self.receive_refresh_requests,
                "receiveLookupRequests": self.receive_lookup_requests,
                "receiveLookupResponses": self.receive_lookup_responses,
                "receiveLookupRequestsActive": self.receive_lookup_requests_active,
                "receiveLookupDelayMs": self.receive_lookup_delay_ms,
                "receivePrepareReconcileFailures": self.receive_prepare_reconcile_failures,
                "receiveOperationCount": len(self.receive_operations),
                "sendCreateRequests": self.send_create_requests,
                "sendIdempotencyUniqueKeys": self.send_idempotency_unique_keys,
                "sendIdempotencyReplays": self.send_idempotency_replays,
                "sendIdempotencyConflicts": self.send_idempotency_conflicts,
                "sendCreateDelayMs": self.send_create_delay_ms,
                "sendExecuteRequests": self.send_execute_requests,
                "sendCancelRequests": self.send_cancel_requests,
                "sendReclaimRequests": self.send_reclaim_requests,
                "sendReclaimOperationIds": list(self.send_reclaim_operation_ids),
                "sendRefreshRequests": self.send_refresh_requests,
                "sendLookupRequests": self.send_lookup_requests,
                "sendResultRequests": self.send_result_requests,
                "sendResultOperationIds": list(self.send_result_operation_ids),
                "sendResultDelayMs": self.send_result_delay_ms,
                "sendRefreshUnavailableResponses": self.send_refresh_unavailable_responses,
                "sendOperationCount": len(self.send_operations),
                "sendCommandDelayMs": self.send_command_delay_ms,
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
        self.send_json(401, error_document(code, "A valid Client Credential is required"))
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
        with self.state.lock:
            forced_receive_failure = name == "receivePrepared" and (
                self.state.receive_prepared_failures > 0
            )
            if forced_receive_failure:
                self.state.receive_prepared_failures -= 1
                self.state.receive_prepare_reconcile_failures += 1
            forced_send_failure = name == "sendPrepared" and (
                self.state.send_prepared_failures > 0
            )
            if forced_send_failure:
                self.state.send_prepared_failures -= 1
        if forced_receive_failure or forced_send_failure:
            self.send_json(
                500,
                error_document("internal_error", "Resource unavailable"),
            )
        elif mode == "unavailable":
            self.send_json(
                500,
                error_document("internal_error", "Resource unavailable"),
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

        if self.path == "/v1/openapi.json":
            with self.state.lock:
                mode = self.state.resource_mode
            interface_version = "99" if mode == "incompatible" else "1"
            self.resource_response(
                "openapi",
                {
                    "openapi": "3.1.0",
                    "x-cocod-interface-version": interface_version,
                    "info": {"title": "mock cocod v1", "version": "0.0.17"},
                    "paths": {path: {} for path in OPENAPI_PATHS},
                    "components": {},
                },
            )
            return
        if self.path == "/v1/status":
            status = self.state.lifecycle_status()
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
                    error_document("not_found", "The Mint is not registered"),
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
        match = re.fullmatch(r"/v1/operations/send/([^/]+)/result", self.path)
        if match:
            if not self.wallet_required():
                return
            status, response = self.state.send_result(match.group(1))
            self.send_json(status, response)
            return
        match = re.fullmatch(r"/v1/operations/receive/([^/]+)", self.path)
        if match:
            if not self.wallet_required():
                return
            operation = self.state.receive_operation(match.group(1))
            if operation is None:
                self.send_json(
                    404,
                    error_document("not_found", "The Receive does not exist"),
                )
                return
            self.send_json(200, operation)
            return
        match = re.fullmatch(r"/v1/operations/send/([^/]+)", self.path)
        if match:
            if not self.wallet_required():
                return
            operation = self.state.send_operation(match.group(1))
            if operation is None:
                self.send_json(
                    404,
                    error_document("not_found", "The Send does not exist"),
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
        if BODYLESS_COMMAND_PATH.fullmatch(self.path):
            try:
                content_length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                content_length = -1
            if content_length != 0 or self.headers.get("Transfer-Encoding") is not None:
                if content_length > 0:
                    self.rfile.read(content_length)
                self.send_json(
                    400,
                    error_document(
                        "invalid_request",
                        "This command does not accept a request body",
                    ),
                )
                return
            value: object = {}
        else:
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
                if "createSessionPolls" in value:
                    self.state.create_session_polls = max(
                        0, min(100, int(value["createSessionPolls"]))
                    )
                if "recoveryDelayMs" in value:
                    self.state.recovery_delay_ms = max(0, min(5000, int(value["recoveryDelayMs"])))
                if "receiveDelayMs" in value:
                    self.state.receive_delay_ms = max(0, min(5000, int(value["receiveDelayMs"])))
                if "receiveLookupDelayMs" in value:
                    self.state.receive_lookup_delay_ms = max(
                        0, min(5000, int(value["receiveLookupDelayMs"]))
                    )
                if "receiveInterruption" in value:
                    interruption = str(value["receiveInterruption"])
                    if interruption not in ("none", "before_commit", "after_commit"):
                        self.send_json(
                            400,
                            error_document("invalid_request", "Invalid Receive interruption"),
                        )
                        return
                    self.state.receive_interruption = interruption
                if "receiveCreateInterruption" in value:
                    interruption = str(value["receiveCreateInterruption"])
                    if interruption not in (
                        "none",
                        "after_commit",
                        "malformed_after_commit",
                    ):
                        self.send_json(
                            400,
                            error_document(
                                "invalid_request",
                                "Invalid Receive create interruption",
                            ),
                        )
                        return
                    self.state.receive_create_interruption = interruption
                if value.get("receivePrepareReconcileError") is True:
                    self.state.receive_prepared_failures = 1
                if "receiveRefreshError" in value:
                    refresh_error = str(value["receiveRefreshError"])
                    if refresh_error not in (
                        "",
                        "mint_unavailable",
                        "operation_conflict",
                        "operation_not_found",
                    ):
                        self.send_json(
                            400,
                            error_document("invalid_request", "Invalid Receive refresh error"),
                        )
                        return
                    self.state.receive_refresh_error = refresh_error
                if "sendCreateError" in value:
                    create_error = str(value["sendCreateError"])
                    if create_error not in (
                        "",
                        "mint_not_registered",
                        "mint_not_trusted",
                        "mint_unavailable",
                    ):
                        self.send_json(
                            400,
                            error_document("invalid_request", "Invalid Send create error"),
                        )
                        return
                    self.state.send_create_error = create_error
                if "sendCreateDelayMs" in value:
                    self.state.send_create_delay_ms = max(
                        0, min(5000, int(value["sendCreateDelayMs"]))
                    )
                if "sendCreateEmptyId" in value:
                    self.state.send_create_empty_id = value["sendCreateEmptyId"] is True
                if "sendCreateInterruption" in value:
                    interruption = str(value["sendCreateInterruption"])
                    if interruption not in (
                        "none",
                        "after_commit",
                        "malformed_after_commit",
                    ):
                        self.send_json(
                            400,
                            error_document("invalid_request", "Invalid Send create interruption"),
                        )
                        return
                    self.state.send_create_interruption = interruption
                    if interruption in ("after_commit", "malformed_after_commit"):
                        self.state.suppress_next_send_events = True
                if "sendCommandError" in value:
                    command_error = str(value["sendCommandError"])
                    if command_error not in (
                        "",
                        "operation_not_found",
                        "operation_conflict",
                    ):
                        self.send_json(
                            400,
                            error_document("invalid_request", "Invalid Send command error"),
                        )
                        return
                    self.state.send_command_error = command_error
                if "sendCancelError" in value:
                    cancel_error = str(value["sendCancelError"])
                    if cancel_error not in ("", "operation_conflict"):
                        self.send_json(
                            400,
                            error_document("invalid_request", "Invalid Send cancel error"),
                        )
                        return
                    self.state.send_cancel_error = cancel_error
                if "sendReclaimOutcome" in value:
                    reclaim_outcome = str(value["sendReclaimOutcome"])
                    if reclaim_outcome not in (
                        "success",
                        "reclaim_inconclusive",
                        "recipient_won",
                        "operation_conflict",
                        "operation_not_found",
                    ):
                        self.send_json(
                            400,
                            error_document("invalid_request", "Invalid Reclaim outcome"),
                        )
                        return
                    self.state.send_reclaim_outcome = reclaim_outcome
                if "sendRefreshError" in value:
                    refresh_error = str(value["sendRefreshError"])
                    if refresh_error not in (
                        "",
                        "mint_unavailable",
                        "operation_conflict",
                        "operation_not_found",
                    ):
                        self.send_json(
                            400,
                            error_document("invalid_request", "Invalid Send refresh error"),
                        )
                        return
                    self.state.send_refresh_error = refresh_error
                if "sendRefreshUnavailableResponses" in value:
                    try:
                        refresh_unavailable = int(
                            value["sendRefreshUnavailableResponses"]
                        )
                    except (TypeError, ValueError):
                        refresh_unavailable = -1
                    if refresh_unavailable < 0 or refresh_unavailable > 10:
                        self.send_json(
                            400,
                            error_document(
                                "invalid_request", "Invalid Send refresh unavailable count"
                            ),
                        )
                        return
                    self.state.send_refresh_unavailable_responses = refresh_unavailable
                if "sendCommandDelayMs" in value:
                    self.state.send_command_delay_ms = max(
                        0, min(5000, int(value["sendCommandDelayMs"]))
                    )
                if "sendExecuteInterruption" in value:
                    interruption = str(value["sendExecuteInterruption"])
                    if interruption not in ("none", "after_commit"):
                        self.send_json(
                            400,
                            error_document(
                                "invalid_request", "Invalid Send execute interruption"
                            ),
                        )
                        return
                    self.state.send_execute_interruption = interruption
                if "sendResultUnavailableResponses" in value:
                    try:
                        unavailable_responses = int(
                            value["sendResultUnavailableResponses"]
                        )
                    except (TypeError, ValueError):
                        unavailable_responses = -1
                    if unavailable_responses < 0 or unavailable_responses > 10:
                        self.send_json(
                            400,
                            error_document(
                                "invalid_request", "Invalid unavailable result count"
                            ),
                        )
                        return
                    self.state.send_result_unavailable_responses = unavailable_responses
                if "sendResultDelayMs" in value:
                    self.state.send_result_delay_ms = max(
                        0, min(5000, int(value["sendResultDelayMs"]))
                    )
                if value.get("sendPrepareReconcileError") is True:
                    self.state.send_prepared_failures = 1
                    self.state.suppress_next_send_events = True
                if "sendExecuteSuppressEvents" in value:
                    self.state.suppress_next_send_execute_events = (
                        value["sendExecuteSuppressEvents"] is True
                    )
            self.send_json(200, self.state.diagnostics())
            return
        if self.path == "/__test__/disconnect":
            self.state.disconnect_streams()
            self.send_json(200, {"disconnected": True})
            return
        if self.path == "/__test__/redeem-send":
            operation_id = value.get("operationId") if isinstance(value, dict) else None
            status, response, events = self.state.redeem_send(operation_id)
            self.send_json(status, response)
            if not (isinstance(value, dict) and value.get("suppressEvents") is True):
                self.state.publish_events(events)
            return
        if self.path == "/__test__/remove-send":
            operation_id = value.get("operationId") if isinstance(value, dict) else None
            status, response, events = self.state.remove_send_for_test(operation_id)
            self.send_json(status, response)
            self.state.publish_events(events)
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
        if self.path == "/v1/mints":
            if not self.wallet_required():
                return
            self.state.wait_for_receive_transition()
            status, response, events = self.state.register_mint(value)
            self.send_json(status, response)
            self.state.publish_events(events)
            return
        if self.path == "/v1/mints/trust":
            if not self.wallet_required():
                return
            self.state.wait_for_receive_transition()
            status, response, events = self.state.trust_mint(value)
            self.send_json(status, response)
            self.state.publish_events(events)
            return
        if self.path == "/v1/operations/receive":
            if not self.wallet_required():
                return
            self.state.wait_for_receive_transition()
            status, response, events = self.state.create_receive(value)
            if status == 0:
                self.close_connection = True
                return
            self.send_json(status, response)
            self.state.publish_events(events)
            return
        if self.path == "/v1/operations/send":
            if not self.wallet_required():
                return
            with self.state.lock:
                send_create_delay_ms = self.state.send_create_delay_ms
            if send_create_delay_ms > 0:
                time.sleep(send_create_delay_ms / 1000)
            idempotency_key = self.headers.get("Idempotency-Key")
            status, response, events = self.state.create_send(value, idempotency_key)
            if status == 0:
                self.close_connection = True
                return
            self.send_json(status, response)
            self.state.publish_events(events)
            return
        match = re.fullmatch(
            r"/v1/operations/send/([^/]+)/(execute|cancel|refresh|reclaim)",
            self.path,
        )
        if match:
            if not self.wallet_required():
                return
            if match.group(2) == "refresh":
                status, response, events = self.state.refresh_send(match.group(1))
                self.send_json(status, response)
                return
            with self.state.lock:
                command_delay_ms = self.state.send_command_delay_ms
            if command_delay_ms > 0:
                time.sleep(command_delay_ms / 1000)
            status, response, events = self.state.command_send(
                match.group(1), match.group(2)
            )
            if status == 0:
                self.close_connection = True
                self.state.publish_events(events)
                return
            self.send_json(status, response)
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
                self.state.wait_for_receive_transition()
                status, response, events = self.state.refresh_receive(match.group(1))
                self.send_json(status, response)
                self.state.publish_events(events)
                return
            self.state.wait_for_receive_transition()
            status, response, events = self.state.command_receive(match.group(1), command)
            if status == 0:
                self.close_connection = True
                self.state.publish_events(events)
                return
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
