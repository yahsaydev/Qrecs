#!/usr/bin/env python3
"""Audit candidate audio URLs with an injectable HTTP transport."""

import argparse
import json
import socket
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


@dataclass(frozen=True)
class HTTPResponse:
    status: int
    headers: dict
    body: bytes
    final_url: str = None


@dataclass(frozen=True)
class AuditItem:
    url: str
    status: int = None
    final_url: str = None
    reason: str = ""
    attempts: int = 0


@dataclass(frozen=True)
class AuditReport:
    available: tuple
    unavailable: tuple
    inconclusive: tuple


class URLTransport:
    """Small urllib adapter; tests inject a deterministic transport instead."""

    def request(self, method, url, headers, timeout):
        request = Request(url, method=method, headers=headers)
        try:
            with urlopen(request, timeout=timeout) as response:
                return HTTPResponse(
                    response.status,
                    dict(response.headers.items()),
                    response.read(1024) if method == "GET" else b"",
                    response.geturl(),
                )
        except HTTPError as error:
            return HTTPResponse(error.code, dict(error.headers.items()), error.read(1024), error.geturl())


class AudioAuditor:
    def __init__(self, transport, passes=2, max_attempts=3, timeout=10):
        self.transport = transport
        self.passes = passes
        self.max_attempts = max_attempts
        self.timeout = timeout

    def audit(self, urls):
        buckets = {"available": [], "unavailable": [], "inconclusive": []}
        for url in urls:
            category, item = self._audit_one(url)
            buckets[category].append(item)
        return AuditReport(*(tuple(buckets[name]) for name in ("available", "unavailable", "inconclusive")))

    def _request(self, method, url, headers):
        try:
            return self.transport.request(method, url, headers, self.timeout), ""
        except (socket.timeout, TimeoutError, URLError) as error:
            return None, type(error).__name__

    def _audit_one(self, url):
        attempts = 0
        last = AuditItem(url, reason="not attempted")
        for _ in range(self.passes):
            if attempts >= self.max_attempts:
                break
            head, error = self._request("HEAD", url, {})
            attempts += 1
            if head is None:
                last = AuditItem(url, reason=error, attempts=attempts)
                continue
            category, reason = self._classify(head, method="HEAD")
            last = AuditItem(url, head.status, head.final_url, reason, attempts)
            if category in ("available", "unavailable"):
                return category, last
            if (
                category == "inconclusive"
                and head.status in (200, 206, 400, 403, 405, 501)
                and attempts < self.max_attempts
            ):
                get, error = self._request("GET", url, {"Range": "bytes=0-1023"})
                attempts += 1
                if get is None:
                    last = AuditItem(url, reason=error, attempts=attempts)
                    continue
                category, reason = self._classify(get, method="GET")
                last = AuditItem(url, get.status, get.final_url, reason, attempts)
                if category in ("available", "unavailable"):
                    return category, last
        return "inconclusive", last

    @staticmethod
    def _classify(response, method="GET"):
        headers = {str(key).lower(): str(value).lower() for key, value in response.headers.items()}
        if response.status in (404, 410):
            return "unavailable", f"HTTP {response.status}"
        if response.status == 429 or 500 <= response.status <= 599:
            return "inconclusive", f"HTTP {response.status}"
        if response.status in (301, 302, 303, 307, 308) and response.final_url:
            return "available", "redirect"
        if response.status in (200, 206):
            content_type = headers.get("content-type", "")
            if "html" in content_type:
                return "unavailable", "HTML response"
            if method == "HEAD":
                content_length = headers.get("content-length")
                if content_length == "0":
                    return "unavailable", "empty response"
                if content_length and content_length.isdigit():
                    return "available", f"HTTP {response.status}"
                return "inconclusive", "HEAD has no content length"
            if not response.body:
                return "unavailable", "empty response"
            return "available", f"HTTP {response.status}"
        return "inconclusive", f"HTTP {response.status}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    snapshot = json.loads(arguments.snapshot.read_text(encoding="utf-8"))
    from surahquran_snapshot import confirm_snapshot
    document = confirm_snapshot(snapshot, AudioAuditor(URLTransport()))
    arguments.output.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
