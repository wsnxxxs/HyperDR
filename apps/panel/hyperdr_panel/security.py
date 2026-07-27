"""Access control for a service that is deliberately reachable from the LAN.

The panel binds to 0.0.0.0 by default so a phone on the same network can reach
it, which makes the access token the only thing between a stranger and the
photos. The token is high-entropy, but nothing upstream rate-limits guesses
against it, so a per-source-IP lockout is worth the few lines it costs.
"""
from __future__ import annotations

import hmac
import re
import secrets
import threading
import time

TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{8,128}")

# Sent on every response, including static files and errors.
SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cross-Origin-Resource-Policy": "same-origin",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    "Content-Security-Policy": (
        "default-src 'self'; img-src 'self' blob: data:; "
        "style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
        "object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    ),
}

COOKIE_NAME = "hyperdr_access"


def make_token() -> str:
    return secrets.token_urlsafe(8)


def check_token_format(token: str) -> str:
    if not TOKEN_PATTERN.fullmatch(token):
        raise ValueError(
            "HYPERDR_ACCESS_TOKEN 只能包含 8–128 位字母、数字、下划线或连字符。"
        )
    return token


def tokens_match(supplied: str, expected: str) -> bool:
    # Constant time: the comparison is against a secret.
    return hmac.compare_digest(supplied, expected)


def cookie_attributes(token: str, secure: bool) -> str:
    attributes = [f"{COOKIE_NAME}={token}", "Path=/", "HttpOnly", "SameSite=Strict"]
    if secure:
        attributes.append("Secure")
    return "; ".join(attributes)


class LoginThrottle:
    """Per-source-IP lockout after repeated bad tokens.

    State is process-lifetime and intentionally coarse: the goal is to make
    guessing impractical, not to keep an audit trail.
    """

    def __init__(self, window_seconds: float = 300.0, max_attempts: int = 8,
                 lockout_seconds: float = 60.0) -> None:
        self._window = window_seconds
        self._max_attempts = max_attempts
        self._lockout = lockout_seconds
        self._lock = threading.Lock()
        self._failures: dict[str, list[float]] = {}

    def _prune_locked(self, client_ip: str, now: float) -> list[float]:
        attempts = [t for t in self._failures.get(client_ip, []) if now - t < self._window]
        if attempts:
            self._failures[client_ip] = attempts
        else:
            self._failures.pop(client_ip, None)
        return attempts

    def retry_after(self, client_ip: str) -> float:
        """Seconds the client must wait before another attempt, 0 if none."""
        now = time.monotonic()
        with self._lock:
            attempts = self._prune_locked(client_ip, now)
            if len(attempts) < self._max_attempts:
                return 0.0
            return max(0.0, self._lockout - (now - attempts[-1]))

    def record_failure(self, client_ip: str) -> None:
        now = time.monotonic()
        with self._lock:
            attempts = self._prune_locked(client_ip, now)
            attempts.append(now)
            self._failures[client_ip] = attempts

    def clear(self, client_ip: str) -> None:
        with self._lock:
            self._failures.pop(client_ip, None)
