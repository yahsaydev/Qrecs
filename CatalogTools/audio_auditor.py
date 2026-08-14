#!/usr/bin/env python3
"""Audit candidate audio URLs with an injectable HTTP transport."""

import argparse
import json
import socket
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
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
    def __init__(self, transport, passes=2, max_attempts=3, timeout=10, workers=1):
        if passes < 1 or max_attempts < 1 or workers < 1:
            raise ValueError("passes, max_attempts, and workers must be positive")
        self.transport = transport
        self.passes = passes
        self.max_attempts = max_attempts
        self.timeout = timeout
        self.workers = workers

    def audit(self, urls):
        buckets = {"available": [], "unavailable": [], "inconclusive": []}
        unique_urls = sorted(set(str(url).strip() for url in urls))
        for url in unique_urls:
            if not _is_https_url(url):
                raise ValueError(f"audio URL must use HTTPS: {url!r}")
        if self.workers == 1:
            results = map(self._audit_one, unique_urls)
        else:
            executor = ThreadPoolExecutor(max_workers=self.workers)
            results = executor.map(self._audit_one, unique_urls)
        try:
            for category, item in results:
                buckets[category].append(item)
        finally:
            if self.workers != 1:
                executor.shutdown(wait=True)
        for name in buckets:
            buckets[name].sort(key=lambda item: item.url)
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
            if head.final_url and not _is_https_url(head.final_url):
                return "unavailable", AuditItem(
                    url,
                    head.status,
                    head.final_url,
                    "non-HTTPS redirect",
                    attempts,
                )
            category, reason = self._classify(head, method="HEAD")
            last = AuditItem(url, head.status, head.final_url, reason, attempts)
            if category == "unavailable":
                return category, last
            if (
                category == "inconclusive"
                and head.status in (200, 206, 301, 302, 303, 307, 308, 400, 403, 405, 501)
                and attempts < self.max_attempts
            ):
                get_url = head.final_url or url
                get, error = self._request("GET", get_url, {"Range": "bytes=0-1023"})
                attempts += 1
                if get is None:
                    last = AuditItem(url, reason=error, attempts=attempts)
                    continue
                if get.final_url and not _is_https_url(get.final_url):
                    return "unavailable", AuditItem(
                        url,
                        get.status,
                        get.final_url,
                        "non-HTTPS redirect",
                        attempts,
                    )
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
        if response.status in (301, 302, 303, 307, 308):
            return "inconclusive", "redirect requires content validation"
        if response.status in (200, 206):
            content_type = headers.get("content-type", "").split(";", 1)[0].strip()
            if "html" in content_type:
                return "unavailable", "HTML response"
            if content_type and not (
                content_type in (
                    "audio/mpeg",
                    "audio/mp3",
                    "audio/x-mp3",
                    "application/octet-stream",
                    "binary/octet-stream",
                    "application/mp3",
                    "application/mpeg",
                )
            ):
                return "unavailable", "non-audio content type"
            if method == "HEAD":
                content_length = headers.get("content-length")
                if content_length == "0":
                    return "unavailable", "empty response"
                return "inconclusive", "HEAD requires MP3 signature validation"
            if not response.body:
                return "unavailable", "empty response"
            if not _has_mp3_signature(response.body):
                return "unavailable", "invalid MP3 signature"
            return "available", f"HTTP {response.status}"
        return "inconclusive", f"HTTP {response.status}"


def _has_mp3_signature(body):
    if body.startswith(b"ID3"):
        if len(body) < 10:
            return False
        major_version = body[3]
        revision = body[4]
        size_bytes = body[6:10]
        return (
            major_version in (2, 3, 4)
            and revision != 0xFF
            and all(byte < 0x80 for byte in size_bytes)
        )
    if len(body) < 4 or body[0] != 0xFF or (body[1] & 0xE0) != 0xE0:
        return False
    version = (body[1] >> 3) & 0x03
    layer = (body[1] >> 1) & 0x03
    bitrate_index = (body[2] >> 4) & 0x0F
    sample_rate_index = (body[2] >> 2) & 0x03
    return (
        version != 0x01
        and layer != 0x00
        and bitrate_index != 0x0F
        and sample_rate_index != 0x03
    )


def _is_https_url(url):
    parts = urlsplit(str(url))
    return parts.scheme == "https" and bool(parts.netloc)


def audit_report_document(report):
    def serialize(item):
        return {
            "attempts": item.attempts,
            "final_url": item.final_url,
            "reason": item.reason,
            "status": item.status,
            "url": item.url,
        }
    return {
        "available": [serialize(item) for item in report.available],
        "format_version": 1,
        "inconclusive": [serialize(item) for item in report.inconclusive],
        "source": "qrecs-audio-audit",
        "unavailable": [serialize(item) for item in report.unavailable],
    }


def audit_url_manifest(document, auditor):
    if (
        document.get("format_version") != 1
        or document.get("source") != "qrecs-legacy-audio-candidates"
    ):
        raise ValueError("unsupported legacy audio candidate format")
    urls = document.get("urls")
    if not isinstance(urls, list):
        raise ValueError("legacy audio candidate URLs must be a list")
    normalized = []
    seen = set()
    for index, value in enumerate(urls):
        url = str(value).strip()
        parts = urlsplit(url)
        if parts.scheme != "https" or not parts.netloc:
            raise ValueError(f"urls[{index}]: audio URL must use HTTPS")
        if url in seen:
            raise ValueError(f"urls[{index}]: duplicate URL")
        seen.add(url)
        normalized.append(url)
    if normalized != sorted(normalized):
        raise ValueError("legacy audio candidate URLs must be sorted")
    return auditor.audit(normalized)


def _write_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", nargs="?", type=Path)
    parser.add_argument("--urls", type=Path, help="legacy URL candidate manifest")
    parser.add_argument("--output", type=Path, help="confirmed SurahQuran snapshot")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--workers", default=6, type=int)
    arguments = parser.parse_args()
    auditor = AudioAuditor(URLTransport(), workers=arguments.workers)
    if (arguments.snapshot is None) == (arguments.urls is None):
        parser.error("provide exactly one snapshot or --urls manifest")
    if arguments.urls is not None:
        if arguments.report is None:
            parser.error("--urls requires --report")
        candidates = json.loads(arguments.urls.read_text(encoding="utf-8"))
        report = audit_url_manifest(candidates, auditor)
        _write_json(arguments.report, audit_report_document(report))
        return
    if arguments.output is None:
        parser.error("a snapshot audit requires --output")
    if arguments.report is None:
        parser.error("a snapshot audit requires --report")
    snapshot = json.loads(arguments.snapshot.read_text(encoding="utf-8"))
    from surahquran_snapshot import audit_snapshot
    document, report = audit_snapshot(snapshot, auditor)
    _write_json(arguments.output, document)
    if arguments.report is not None:
        _write_json(arguments.report, audit_report_document(report))


if __name__ == "__main__":
    main()
