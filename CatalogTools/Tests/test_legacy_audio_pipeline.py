import csv
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


CATALOG_TOOLS = Path(__file__).resolve().parents[1]
DATA = CATALOG_TOOLS / "Data"
FIXTURES = Path(__file__).resolve().parent / "Fixtures" / "surahquran"
sys.path.insert(0, str(CATALOG_TOOLS))

from build_catalog import build_catalog  # noqa: E402
from legacy_audio_candidates import build_candidate_document  # noqa: E402
from surahquran_snapshot import build_fixture_snapshot  # noqa: E402


class LegacyAudioPipelineTests(unittest.TestCase):
    def test_candidate_manifest_is_sorted_deduplicated_and_https_only(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = Path(temporary_directory) / "tracks.csv"
            source.write_text(
                "Чтец,Сура,Номер_суры,MP3_URL\n"
                "Reader,Two,2,https://audio.example/002.mp3\n"
                "Reader,One,1,https://audio.example/001.mp3\n"
                "Reader,Duplicate,1,https://audio.example/001.mp3\n",
                encoding="utf-8",
            )
            self.assertEqual(build_candidate_document(source), {
                "format_version": 1,
                "source": "qrecs-legacy-audio-candidates",
                "urls": [
                    "https://audio.example/001.mp3",
                    "https://audio.example/002.mp3",
                ],
            })

            source.write_text(
                "Чтец,Сура,Номер_суры,MP3_URL\n"
                "Reader,One,1,http://audio.example/001.mp3\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "HTTPS"):
                build_candidate_document(source)

    def test_unmatched_legacy_reciters_keep_only_available_audited_tracks(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            baseline = root / "baseline.sqlite"
            build_catalog(
                DATA / "quran_mp3_links.csv",
                DATA / "reciters.csv",
                DATA / "surahs.csv",
                baseline,
            )
            with sqlite3.connect(baseline) as connection:
                urls_by_reciter = {
                    reciter_id: [row[0] for row in connection.execute(
                        "SELECT url FROM tracks WHERE reciter_id = ? ORDER BY surah_number",
                        (reciter_id,),
                    )]
                    for reciter_id in ("reciter-002", "reciter-003")
                }
                all_urls = [row[0] for row in connection.execute("SELECT url FROM tracks")]

            status_by_url = {url: "available" for url in all_urls}
            for url in urls_by_reciter["reciter-002"][1:]:
                status_by_url[url] = "unavailable"
            for url in urls_by_reciter["reciter-003"]:
                status_by_url[url] = "inconclusive"
            report = {
                "available": [{"url": url} for url, status in status_by_url.items() if status == "available"],
                "format_version": 1,
                "inconclusive": [{"url": url} for url, status in status_by_url.items() if status == "inconclusive"],
                "source": "qrecs-audio-audit",
                "unavailable": [{"url": url} for url, status in status_by_url.items() if status == "unavailable"],
            }
            report_path = root / "legacy-audit.json"
            report_path.write_text(json.dumps(report), encoding="utf-8")

            snapshot = build_fixture_snapshot(FIXTURES)
            snapshot["confirmed"] = True
            for track in snapshot["reciters"][0]["tracks"]:
                track["status"] = "available"
            snapshot_path = root / "snapshot.json"
            snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")

            output = root / "catalog.sqlite"
            build_catalog(
                DATA / "quran_mp3_links.csv",
                DATA / "reciters.csv",
                DATA / "surahs.csv",
                output,
                snapshot_json=snapshot_path,
                legacy_audit_json=report_path,
            )
            with sqlite3.connect(output) as connection:
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM tracks WHERE reciter_id = 'reciter-002'"
                    ).fetchone(),
                    (1,),
                )
                self.assertIsNone(connection.execute(
                    "SELECT id FROM reciters WHERE id = 'reciter-003'"
                ).fetchone())
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM tracks WHERE reciter_id = 'surahquran-qari-10'"
                    ).fetchone(),
                    (23,),
                )


if __name__ == "__main__":
    unittest.main()
