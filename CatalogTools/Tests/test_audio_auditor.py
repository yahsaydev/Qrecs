import socket
import io
import json
import sys
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stderr
from pathlib import Path


CATALOG_TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CATALOG_TOOLS))

from audio_auditor import (  # noqa: E402
    AudioAuditor,
    HTTPResponse,
    audit_url_manifest,
    main,
)


class ScriptedTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def request(self, method, url, headers, timeout):
        self.requests.append((method, url, headers, timeout))
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


def response(
    status,
    content_type="audio/mpeg",
    body=b"ID3\x04\x00\x00\x00\x00\x00\x00",
    final_url=None,
    headers=None,
):
    response_headers = {"content-type": content_type, "content-length": str(len(body))}
    response_headers.update(headers or {})
    return HTTPResponse(status, response_headers, body, final_url)


class AudioAuditorTests(unittest.TestCase):
    url = "https://audio.example/001.mp3"

    def test_head_success_is_available_and_redirect_final_url_is_reported(self):
        transport = ScriptedTransport([
            response(200, final_url="https://cdn.example/001.mp3"),
            response(206, final_url="https://cdn.example/001.mp3"),
        ])
        report = AudioAuditor(transport).audit([self.url])
        self.assertEqual(report.available[0].final_url, "https://cdn.example/001.mp3")
        self.assertEqual([request[0] for request in transport.requests], ["HEAD", "GET"])

    def test_head_rejection_falls_back_to_range_get_and_accepts_206(self):
        transport = ScriptedTransport([response(405), response(206)])
        report = AudioAuditor(transport).audit([self.url])
        self.assertEqual([item.url for item in report.available], [self.url])
        self.assertEqual([request[0] for request in transport.requests], ["HEAD", "GET"])
        self.assertEqual(transport.requests[1][2]["Range"], "bytes=0-1023")

    def test_head_without_length_falls_back_to_range_get(self):
        transport = ScriptedTransport([
            HTTPResponse(200, {"content-type": "audio/mpeg"}, b""),
            response(206),
        ])
        report = AudioAuditor(transport).audit([self.url])
        self.assertEqual(len(report.available), 1)
        self.assertEqual([request[0] for request in transport.requests], ["HEAD", "GET"])

    def test_head_with_explicit_zero_length_is_unavailable(self):
        transport = ScriptedTransport([
            HTTPResponse(200, {"content-type": "audio/mpeg", "content-length": "0"}, b"")
        ])
        report = AudioAuditor(transport).audit([self.url])
        self.assertEqual(len(report.unavailable), 1)

    def test_404_and_410_are_unavailable(self):
        report = AudioAuditor(ScriptedTransport([response(404), response(410)])).audit(
            [self.url, "https://audio.example/002.mp3"]
        )
        self.assertEqual([item.status for item in report.unavailable], [404, 410])

    def test_timeout_429_and_5xx_remain_inconclusive_after_two_passes(self):
        for scripted in (
            [socket.timeout(), socket.timeout()],
            [response(429), response(429)],
            [response(503), response(503)],
        ):
            transport = ScriptedTransport(scripted)
            report = AudioAuditor(transport, passes=2, max_attempts=3).audit([self.url])
            self.assertEqual([item.url for item in report.inconclusive], [self.url])
            self.assertEqual(len(transport.requests), 2)

    def test_html_and_empty_success_responses_are_unavailable(self):
        html = AudioAuditor(ScriptedTransport([response(200, "text/html", b"<html>")])).audit([self.url])
        empty = AudioAuditor(ScriptedTransport([response(200, body=b"")])).audit([self.url])
        self.assertEqual(len(html.unavailable), 1)
        self.assertEqual(len(empty.unavailable), 1)

    def test_range_get_requires_mp3_signature_and_audio_compatible_mime(self):
        invalid_signature = AudioAuditor(ScriptedTransport([
            response(200), response(206, body=b"plain text payload"),
        ])).audit([self.url])
        wrong_mime = AudioAuditor(ScriptedTransport([
            response(200), response(206, content_type="image/png", body=b"ID3audio"),
        ])).audit([self.url])
        octet_stream = AudioAuditor(ScriptedTransport([
            response(200), response(206, content_type="application/octet-stream", body=b"\xff\xfbdata"),
        ])).audit([self.url])
        aac = AudioAuditor(ScriptedTransport([
            response(200), response(206, content_type="audio/aac", body=b"\xff\xf1data"),
        ])).audit([self.url])
        self.assertEqual(invalid_signature.unavailable[0].reason, "invalid MP3 signature")
        self.assertEqual(wrong_mime.unavailable[0].reason, "non-audio content type")
        self.assertEqual(len(octet_stream.available), 1)
        self.assertEqual(aac.unavailable[0].reason, "non-audio content type")

    def test_mp3_signature_rejects_truncated_headers(self):
        invalid_bodies = (
            b"ID3",
            b"ID3\x04\x00\x00\x00\x00\x00\x80",
            b"\xff\xfb\x90",
        )
        for body in invalid_bodies:
            with self.subTest(body=body):
                report = AudioAuditor(ScriptedTransport([
                    response(200), response(206, body=body),
                ])).audit([self.url])
                self.assertEqual(
                    report.unavailable[0].reason,
                    "invalid MP3 signature",
                )

        valid_headers = (
            b"ID3\x04\x00\x00\x00\x00\x00\x00",
            b"\xff\xfb\x90\x64",
        )
        for body in valid_headers:
            with self.subTest(body=body):
                report = AudioAuditor(ScriptedTransport([
                    response(200), response(206, body=body),
                ])).audit([self.url])
                self.assertEqual(len(report.available), 1)

    def test_non_https_input_and_redirect_fail_before_insecure_request(self):
        transport = ScriptedTransport([
            response(200, final_url="http://cdn.example/001.mp3"),
        ])
        report = AudioAuditor(transport).audit([self.url])
        self.assertEqual(report.unavailable[0].reason, "non-HTTPS redirect")
        self.assertEqual([request[0] for request in transport.requests], ["HEAD"])

        untouched = ScriptedTransport([])
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            AudioAuditor(untouched).audit(["http://audio.example/001.mp3"])
        self.assertEqual(untouched.requests, [])

    def test_report_is_deterministic_and_duplicate_urls_are_audited_once(self):
        second = "https://audio.example/002.mp3"
        transport = ScriptedTransport([
            response(200), response(206),
            response(404),
        ])
        report = AudioAuditor(transport).audit([second, self.url, second])
        self.assertEqual([item.url for item in report.available], [self.url])
        self.assertEqual([item.url for item in report.unavailable], [second])
        self.assertEqual(len(transport.requests), 3)

    def test_legacy_url_manifest_is_validated_and_audited_once(self):
        document = {
            "format_version": 1,
            "source": "qrecs-legacy-audio-candidates",
            "urls": [self.url],
        }

        class CountingAuditor:
            calls = 0

            def audit(self, urls):
                self.calls += 1
                self.urls = urls
                return "report"

        auditor = CountingAuditor()
        self.assertEqual(audit_url_manifest(document, auditor), "report")
        self.assertEqual(auditor.calls, 1)
        self.assertEqual(auditor.urls, [self.url])

        document["urls"] = ["http://audio.example/001.mp3"]
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            audit_url_manifest(document, auditor)

    def test_cli_routes_legacy_manifest_through_one_audit_into_build_report(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            candidates = root / "legacy-candidates.json"
            report_path = root / "legacy-audit.json"
            candidates.write_text(json.dumps({
                "format_version": 1,
                "source": "qrecs-legacy-audio-candidates",
                "urls": [self.url],
            }), encoding="utf-8")
            transport = ScriptedTransport([response(200), response(206)])
            argv = [
                "audio_auditor.py",
                "--urls", str(candidates),
                "--report", str(report_path),
                "--workers", "1",
            ]
            with patch("audio_auditor.URLTransport", return_value=transport), patch.object(sys, "argv", argv):
                main()
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["source"], "qrecs-audio-audit")
            self.assertEqual([item["url"] for item in report["available"]], [self.url])
            self.assertEqual([request[0] for request in transport.requests], ["HEAD", "GET"])

    def test_snapshot_cli_requires_paired_audit_report(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            candidates = root / "candidates.json"
            output = root / "confirmed.json"
            candidates.write_text(json.dumps({
                "confirmed": False,
                "format_version": 1,
                "reciters": [],
                "source": "surahquran",
            }), encoding="utf-8")
            argv = [
                "audio_auditor.py",
                str(candidates),
                "--output", str(output),
            ]
            with redirect_stderr(io.StringIO()):
                with patch.object(sys, "argv", argv), self.assertRaises(SystemExit):
                    main()
            self.assertFalse(output.exists())

    def test_attempts_never_exceed_three(self):
        transport = ScriptedTransport([response(405), response(503), response(405)])
        report = AudioAuditor(transport, passes=2, max_attempts=3).audit([self.url])
        self.assertEqual(len(transport.requests), 3)
        self.assertEqual(len(report.inconclusive), 1)


if __name__ == "__main__":
    unittest.main()
