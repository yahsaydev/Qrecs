import socket
import sys
import unittest
from pathlib import Path


CATALOG_TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CATALOG_TOOLS))

from audio_auditor import AudioAuditor, HTTPResponse  # noqa: E402


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


def response(status, content_type="audio/mpeg", body=b"audio", final_url=None, headers=None):
    response_headers = {"content-type": content_type, "content-length": str(len(body))}
    response_headers.update(headers or {})
    return HTTPResponse(status, response_headers, body, final_url)


class AudioAuditorTests(unittest.TestCase):
    url = "https://audio.example/001.mp3"

    def test_head_success_is_available_and_redirect_final_url_is_reported(self):
        transport = ScriptedTransport([
            response(200, final_url="https://cdn.example/001.mp3")
        ])
        report = AudioAuditor(transport).audit([self.url])
        self.assertEqual(report.available[0].final_url, "https://cdn.example/001.mp3")
        self.assertEqual([request[0] for request in transport.requests], ["HEAD"])

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

    def test_attempts_never_exceed_three(self):
        transport = ScriptedTransport([response(405), response(503), response(405)])
        report = AudioAuditor(transport, passes=2, max_attempts=3).audit([self.url])
        self.assertEqual(len(transport.requests), 3)
        self.assertEqual(len(report.inconclusive), 1)


if __name__ == "__main__":
    unittest.main()
