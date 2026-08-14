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
from surahquran_snapshot import confirm_snapshot  # noqa: E402


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

    def test_ids_are_namespaced_and_aliases_preserve_existing_catalog_ids(self):
        self.assertEqual(stable_reciter_id(321), "surahquran-qari-321")
        self.assertNotIn("surahquran-qari-10", RECITER_ID_ALIASES)
        self.assertEqual(resolved_reciter_id(10), "surahquran-qari-10")
        self.assertEqual(resolved_reciter_id(321), "surahquran-qari-321")

    def test_required_qari_localizations_are_present(self):
        localization = REQUIRED_LOCALIZATIONS[10]
        self.assertEqual(localization.name_ru, "Мухаммад Хишам")
        self.assertEqual(localization.name_en, "Muhammad Hisham")

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


if __name__ == "__main__":
    unittest.main()
