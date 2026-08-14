import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CATALOG_TOOLS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "Fixtures" / "surahquran"
sys.path.insert(0, str(CATALOG_TOOLS))

from surahquran import (  # noqa: E402
    RECITER_ID_ALIASES,
    REQUIRED_LOCALIZATIONS,
    parse_reciter_list,
    parse_reciter_profile,
    parse_track_page,
    resolved_reciter_id,
    stable_reciter_id,
)
from audio_auditor import AuditItem, AuditReport  # noqa: E402
from surahquran_snapshot import audit_snapshot, confirm_snapshot  # noqa: E402


class SurahQuranParserTests(unittest.TestCase):
    def fixture(self, name):
        return (FIXTURES / name).read_text(encoding="utf-8")

    def test_parses_qari_10_from_list_page(self):
        listings = parse_reciter_list(
            self.fixture("list.html"), "https://surahquran.example/"
        )
        qari = next(item for item in listings if item.site_id == 10)
        self.assertEqual(qari.name, "Muhammad Hisham")
        self.assertEqual(qari.profile_url, "https://surahquran.example/qari-10.html")

    def test_qari_10_profile_has_exact_sparse_surah_set(self):
        profile = parse_reciter_profile(
            self.fixture("qari-10.html"),
            "https://surahquran.example/qari-10.html",
            site_id=10,
        )
        self.assertEqual(
            [track.surah_number for track in profile.tracks],
            [2, 12, 15, 18, 19, 26, 31, 36, 49, 50, 53, 54, 55, 56,
             66, 67, 68, 69, 73, 75, 76, 78, 79],
        )

    def test_track_page_yields_https_direct_mp3(self):
        url = parse_track_page(
            self.fixture("qari-10-surah-2.html"),
            "https://surahquran.example/qari-10-surah-2.html",
        )
        self.assertEqual(url, "https://cdn.surahquran.example/qari/10/002.mp3")

    def test_profile_infers_surah_number_from_direct_mp3_filename(self):
        profile = parse_reciter_profile(
            """
            <h1>Reader</h1>
            <a href='https://cdn.example/reader/007.mp3?download=1'>Al-Araf</a>
            """,
            "https://surahquran.example/quran-mp3-qari-10.html",
            site_id=10,
        )
        self.assertEqual(len(profile.tracks), 1)
        self.assertEqual(profile.tracks[0].surah_number, 7)
        self.assertEqual(
            profile.tracks[0].direct_url,
            "https://cdn.example/reader/007.mp3?download=1",
        )

    def test_track_page_finds_https_mp3_embedded_in_script(self):
        url = parse_track_page(
            '<script>window.player={"file":"https:\\/\\/cdn.example\\/010\\/002.mp3?x=1"}</script>',
            "https://surahquran.example/quran-mp3-qari-10-surah-2.html",
        )
        self.assertEqual(url, "https://cdn.example/010/002.mp3?x=1")

    def test_ids_are_namespaced_and_aliases_preserve_existing_catalog_ids(self):
        self.assertEqual(stable_reciter_id(321), "surahquran-qari-321")
        self.assertNotIn("surahquran-qari-10", RECITER_ID_ALIASES)
        self.assertEqual(resolved_reciter_id(10), "surahquran-qari-10")
        self.assertEqual(resolved_reciter_id(321), "surahquran-qari-321")

    def test_required_qari_localizations_are_present(self):
        localization = REQUIRED_LOCALIZATIONS[10]
        self.assertEqual(localization.name_ru, "Мухаммад Хишам")
        self.assertEqual(localization.name_en, "Muhammad Hisham")

    def test_reviewed_localizations_cover_the_live_surahquran_profile_set(self):
        expected_site_ids = {
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
            18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
            33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 48,
            49, 50, 58, 59, 60, 61, 62,
        }
        self.assertEqual(set(REQUIRED_LOCALIZATIONS), expected_site_ids)
        for localization in REQUIRED_LOCALIZATIONS.values():
            self.assertTrue(localization.name_ru.strip())
            self.assertTrue(localization.name_en.strip())

    def test_fixture_snapshot_cli_is_byte_reproducible(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            first = Path(temporary_directory) / "first.json"
            second = Path(temporary_directory) / "second.json"
            for output in (first, second):
                subprocess.run(
                    [sys.executable, str(CATALOG_TOOLS / "surahquran_snapshot.py"),
                     "--fixture-root", str(FIXTURES), "--output", str(output)],
                    check=True,
                )
            self.assertEqual(first.read_bytes(), second.read_bytes())
            snapshot = json.loads(first.read_text(encoding="utf-8"))
            self.assertEqual(snapshot["format_version"], 1)
            self.assertFalse(snapshot["confirmed"])
            self.assertEqual(snapshot["reciters"][0]["site_id"], 10)
            self.assertEqual(len(snapshot["reciters"][0]["tracks"]), 23)
            self.assertEqual({track["status"] for track in snapshot["reciters"][0]["tracks"]}, {"pending"})

    def test_audit_report_produces_confirmed_mergeable_snapshot(self):
        snapshot = {
            "format_version": 1,
            "source": "surahquran",
            "confirmed": False,
            "reciters": [{"tracks": [
                {"surah_number": 2, "url": "https://audio.example/2.mp3", "status": "pending"},
                {"surah_number": 3, "url": "https://audio.example/3.mp3", "status": "pending"},
            ]}],
        }
        class Auditor:
            def audit(self, urls):
                self.urls = urls
                return AuditReport(
                    (AuditItem(urls[0]),), (AuditItem(urls[1]),), ()
                )
        auditor = Auditor()
        confirmed = confirm_snapshot(snapshot, auditor)
        self.assertTrue(confirmed["confirmed"])
        self.assertEqual(auditor.urls, ["https://audio.example/2.mp3", "https://audio.example/3.mp3"])
        self.assertEqual(
            [track["status"] for track in confirmed["reciters"][0]["tracks"]],
            ["available", "unavailable"],
        )

    def test_snapshot_and_report_are_created_from_one_auditor_pass(self):
        snapshot = {
            "format_version": 1,
            "source": "surahquran",
            "confirmed": False,
            "reciters": [{"tracks": [{
                "surah_number": 1,
                "url": "https://audio.example/001.mp3",
                "status": "pending",
            }]}],
        }

        class CountingAuditor:
            calls = 0

            def audit(self, urls):
                self.calls += 1
                return AuditReport((AuditItem(urls[0]),), (), ())

        auditor = CountingAuditor()
        confirmed, report = audit_snapshot(snapshot, auditor)
        self.assertEqual(auditor.calls, 1)
        self.assertTrue(confirmed["confirmed"])
        self.assertEqual(report.available[0].url, "https://audio.example/001.mp3")


if __name__ == "__main__":
    unittest.main()
