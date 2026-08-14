import sqlite3
import json
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


CATALOG_TOOLS = Path(__file__).resolve().parents[1]
DATA = CATALOG_TOOLS / "Data"
FIXTURES = Path(__file__).resolve().parent / "Fixtures"
sys.path.insert(0, str(CATALOG_TOOLS))

from build_catalog import CatalogValidationError, build_catalog  # noqa: E402
from surahquran_snapshot import build_fixture_snapshot  # noqa: E402
from surahquran import resolved_reciter_id  # noqa: E402


class SnapshotMergeTests(unittest.TestCase):
    def test_confirmed_snapshot_adds_sparse_reciter_and_excludes_zero_track_reciter(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "catalog.sqlite"
            build_catalog(
                DATA / "quran_mp3_links.csv",
                DATA / "reciters.csv",
                DATA / "surahs.csv",
                output,
                snapshot_json=FIXTURES / "surahs-sparse-snapshot.json",
            )
            with sqlite3.connect(output) as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM reciters").fetchone(), (173,))
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM tracks").fetchone(), (19_610,))
                self.assertEqual(
                    connection.execute(
                        "SELECT id, name_ru, name_en FROM reciters WHERE id = ?",
                        ("surahquran-qari-999",),
                    ).fetchone(),
                    ("surahquran-qari-999", "Тестовый чтец", "Fixture Reciter"),
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT surah_number FROM tracks WHERE reciter_id = ? ORDER BY surah_number",
                        ("surahquran-qari-999",),
                    ).fetchall(),
                    [(2,), (12,)],
                )
                self.assertIsNone(
                    connection.execute(
                        "SELECT id FROM reciters WHERE id = 'surahquran-qari-1000'"
                    ).fetchone()
                )

    def test_unconfirmed_snapshot_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            snapshot = Path(temporary_directory) / "snapshot.json"
            snapshot.write_text(
                '{"format_version":1,"source":"surahquran","confirmed":false,"reciters":[]}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(CatalogValidationError, "confirmed"):
                build_catalog(
                    DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                    DATA / "surahs.csv", Path(temporary_directory) / "catalog.sqlite",
                    snapshot_json=snapshot,
                )

    def test_qari_10_is_new_sparse_reciter_with_reviewed_names_and_urls(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_directory = Path(temporary_directory)
            snapshot = build_fixture_snapshot(FIXTURES / "surahquran")
            snapshot["confirmed"] = True
            for track in snapshot["reciters"][0]["tracks"]:
                track["status"] = "available"
            snapshot_path = temporary_directory / "qari-10.json"
            snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
            output = temporary_directory / "catalog.sqlite"
            build_catalog(
                DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                DATA / "surahs.csv", output, snapshot_json=snapshot_path,
            )
            with sqlite3.connect(output) as connection:
                qari_id = resolved_reciter_id(10)
                self.assertEqual(
                    connection.execute(
                        "SELECT id, name_ru, name_en FROM reciters WHERE id = ?",
                        (qari_id,),
                    ).fetchone(),
                    (qari_id, "Мухаммад Хишам", "Muhammad Hisham"),
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT url FROM tracks WHERE reciter_id = ? AND surah_number = 2",
                        (qari_id,),
                    ).fetchone(),
                    ("https://cdn.surahquran.example/qari/10/002.mp3",),
                )

    def test_qari_10_contains_only_its_23_published_surahs(self):
        expected_surahs = [
            2, 12, 15, 18, 19, 26, 31, 36, 49, 50, 53, 54, 55, 56,
            66, 67, 68, 69, 73, 75, 76, 78, 79,
        ]
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_directory = Path(temporary_directory)
            snapshot = build_fixture_snapshot(FIXTURES / "surahquran")
            snapshot["confirmed"] = True
            for track in snapshot["reciters"][0]["tracks"]:
                track["status"] = "available"
            snapshot_path = temporary_directory / "qari-10.json"
            snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
            output = temporary_directory / "catalog.sqlite"
            build_catalog(
                DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                DATA / "surahs.csv", output, snapshot_json=snapshot_path,
            )
            with sqlite3.connect(output) as connection:
                qari_id = resolved_reciter_id(10)
                self.assertEqual(
                    [row[0] for row in connection.execute(
                        "SELECT surah_number FROM tracks WHERE reciter_id = ? ORDER BY surah_number",
                        (qari_id,),
                    )],
                    expected_surahs,
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM tracks WHERE reciter_id = 'reciter-001'"
                    ).fetchone(),
                    (114,),
                )
                self.assertEqual(
                    connection.execute("SELECT COUNT(*) FROM tracks").fetchone(),
                    (19_631,),
                )

    def test_synthetic_alias_snapshot_authoritatively_replaces_prior_tracks(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_directory = Path(temporary_directory)
            snapshot_path = temporary_directory / "synthetic-alias.json"
            snapshot_path.write_text(json.dumps({
                "format_version": 1,
                "source": "surahquran",
                "confirmed": True,
                "reciters": [{
                    "site_id": 999,
                    "source_name": "Synthetic exact match",
                    "name_ru": "Синтетическое точное совпадение",
                    "name_en": "Synthetic Exact Match",
                    "tracks": [
                        {"surah_number": 2, "url": "https://audio.example/999/002.mp3", "status": "available"},
                        {"surah_number": 12, "url": "https://audio.example/999/012.mp3", "status": "available"},
                    ],
                }],
            }), encoding="utf-8")
            output = temporary_directory / "catalog.sqlite"
            with patch("build_catalog.resolved_reciter_id", return_value="reciter-001"):
                build_catalog(
                    DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                    DATA / "surahs.csv", output, snapshot_json=snapshot_path,
                )
            with sqlite3.connect(output) as connection:
                self.assertEqual(
                    connection.execute(
                        "SELECT surah_number FROM tracks WHERE reciter_id = 'reciter-001' ORDER BY surah_number"
                    ).fetchall(),
                    [(2,), (12,)],
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM tracks WHERE reciter_id = 'reciter-002'"
                    ).fetchone(),
                    (114,),
                )
                self.assertEqual(
                    connection.execute("SELECT COUNT(*) FROM tracks").fetchone(),
                    (19_496,),
                )

    def test_confirmed_snapshot_rejects_unaudited_or_malformed_track_status(self):
        invalid_tracks = [
            {"surah_number": 2, "url": "https://audio.example/002.mp3", "status": "pending"},
            {"surah_number": 2, "url": "https://audio.example/002.mp3", "status": "inconclusive"},
            {"surah_number": 2, "url": "https://audio.example/002.mp3", "status": "typo"},
            {"surah_number": 2, "url": "https://audio.example/002.mp3"},
            "not-a-track-object",
        ]
        for invalid_track in invalid_tracks:
            with self.subTest(track=invalid_track), tempfile.TemporaryDirectory() as temporary_directory:
                temporary_directory = Path(temporary_directory)
                snapshot = {
                    "format_version": 1,
                    "source": "surahquran",
                    "confirmed": True,
                    "reciters": [{
                        "site_id": 999,
                        "source_name": "Fixture Reciter",
                        "name_ru": "Тестовый чтец",
                        "name_en": "Fixture Reciter",
                        "tracks": [invalid_track],
                    }],
                }
                snapshot_path = temporary_directory / "invalid.json"
                snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
                with self.assertRaisesRegex(CatalogValidationError, "track status"):
                    build_catalog(
                        DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                        DATA / "surahs.csv", temporary_directory / "catalog.sqlite",
                        snapshot_json=snapshot_path,
                    )


if __name__ == "__main__":
    unittest.main()
