import sqlite3
import json
import csv
import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CATALOG_TOOLS = Path(__file__).resolve().parents[1]
DATA = CATALOG_TOOLS / "Data"
FIXTURES = Path(__file__).resolve().parent / "Fixtures"
sys.path.insert(0, str(CATALOG_TOOLS))

from build_catalog import CatalogValidationError, build_catalog  # noqa: E402
from surahquran_snapshot import build_fixture_snapshot  # noqa: E402
from surahquran import resolved_reciter_id  # noqa: E402


class SnapshotMergeTests(unittest.TestCase):
    QARI_10_SURAH_NUMBERS = [
        2, 12, 15, 18, 19, 26, 31, 36, 49, 50, 53, 54, 55, 56,
        66, 67, 68, 69, 73, 75, 76, 78, 79,
    ]

    def write_complete_legacy_audit(self, directory):
        with (DATA / "quran_mp3_links.csv").open(
            encoding="utf-8-sig", newline=""
        ) as source:
            urls = sorted({row["MP3_URL"].strip() for row in csv.DictReader(source)})
        path = Path(directory) / "legacy-audit.json"
        path.write_text(json.dumps({
            "available": [{"url": url} for url in urls],
            "format_version": 1,
            "inconclusive": [],
            "source": "qrecs-audio-audit",
            "unavailable": [],
        }), encoding="utf-8")
        return path

    def write_review_tables(self, directory, reciters, aliases=None):
        directory = Path(directory)
        aliases_path = directory / "reviewed-aliases.json"
        localizations_path = directory / "reviewed-localizations.json"
        aliases_path.write_text(json.dumps({
            "format_version": 1,
            "source": "surahquran",
            "aliases": aliases or {},
        }), encoding="utf-8")
        localizations_path.write_text(json.dumps({
            "format_version": 1,
            "source": "surahquran",
            "reciters": reciters,
        }), encoding="utf-8")
        return aliases_path, localizations_path

    def test_confirmed_snapshot_adds_sparse_reciter_and_excludes_zero_track_reciter(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            legacy_audit = self.write_complete_legacy_audit(temporary_directory)
            aliases, localizations = self.write_review_tables(temporary_directory, [
                {"site_id": 999, "name_ru": "Тестовый чтец", "name_en": "Fixture Reciter"},
                {"site_id": 1000, "name_ru": "Нет подтвержденных записей", "name_en": "No Confirmed Tracks"},
            ])
            output = Path(temporary_directory) / "catalog.sqlite"
            build_catalog(
                DATA / "quran_mp3_links.csv",
                DATA / "reciters.csv",
                DATA / "surahs.csv",
                output,
                snapshot_json=FIXTURES / "surahs-sparse-snapshot.json",
                snapshot_aliases_json=aliases,
                snapshot_localizations_json=localizations,
                legacy_audit_json=legacy_audit,
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

    def test_checked_in_qari_10_snapshot_adds_only_its_23_source_page_tracks(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "catalog.sqlite"
            snapshot = DATA / "surahquran_qari_10_snapshot.json"
            self.assertTrue(snapshot.is_file(), "checked-in qari 10 snapshot is missing")
            build_catalog(
                DATA / "quran_mp3_links.csv",
                DATA / "reciters.csv",
                DATA / "surahs.csv",
                output,
                snapshot_json=snapshot,
            )

            with sqlite3.connect(output) as connection:
                self.assertEqual(
                    connection.execute(
                        "SELECT id, source_name_ru, name_ru, name_en FROM reciters "
                        "WHERE id = 'surahquran-qari-10'"
                    ).fetchone(),
                    (
                        "surahquran-qari-10",
                        "Мухаммад Хишам",
                        "Мухаммад Хишам",
                        "Muhammad Hisham",
                    ),
                )
                tracks = connection.execute(
                    "SELECT id, surah_number, url FROM tracks "
                    "WHERE reciter_id = 'surahquran-qari-10' ORDER BY surah_number"
                ).fetchall()
                self.assertEqual([row[1] for row in tracks], self.QARI_10_SURAH_NUMBERS)
                self.assertEqual(
                    tracks,
                    [
                        (
                            f"surahquran-qari-10-{number:03d}",
                            number,
                            "https://ia801405.us.archive.org/31/items/"
                            f"002_20221105_20221105_1355/{number:03d}.mp3",
                        )
                        for number in self.QARI_10_SURAH_NUMBERS
                    ],
                )
                self.assertEqual(
                    connection.execute("SELECT COUNT(*) FROM reciters").fetchone(),
                    (173,),
                )
                self.assertEqual(
                    connection.execute("SELECT COUNT(*) FROM tracks").fetchone(),
                    (19_631,),
                )
                self.assertEqual(
                    dict(connection.execute(
                        "SELECT key, value FROM catalog_meta WHERE key LIKE 'crawler_%'"
                    )),
                    {
                        "crawler_aliases_sha256": hashlib.sha256(
                            (DATA / "surahquran_aliases.json").read_bytes()
                        ).hexdigest(),
                        "crawler_snapshot_audio_audit": "not-performed",
                        "crawler_snapshot_confirmation": "source-page-links",
                        "crawler_localizations_sha256": hashlib.sha256(
                            (DATA / "surahquran_localizations.json").read_bytes()
                        ).hexdigest(),
                        "crawler_snapshot_sha256": hashlib.sha256(
                            snapshot.read_bytes()
                        ).hexdigest(),
                    },
                )

    def test_new_additive_snapshot_cannot_replace_legacy_reciter_without_audit(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_directory = Path(temporary_directory)
            snapshot = temporary_directory / "alias.json"
            snapshot.write_text(json.dumps({
                "format_version": 1,
                "source": "surahquran",
                "confirmed": True,
                "confirmation": "source-page-links",
                "audio_audit": "not-performed",
                "reciters": [{
                    "site_id": 999,
                    "source_name": "Existing alias",
                    "name_ru": "Существующий чтец",
                    "name_en": "Existing Reciter",
                    "tracks": [{
                        "surah_number": 2,
                        "url": "https://audio.example/002.mp3",
                        "status": "source-page-confirmed",
                    }],
                }],
            }), encoding="utf-8")
            aliases, localizations = self.write_review_tables(
                temporary_directory,
                [{
                    "site_id": 999,
                    "name_ru": "Существующий чтец",
                    "name_en": "Existing Reciter",
                }],
                {"surahquran-qari-999": "reciter-001"},
            )
            with self.assertRaisesRegex(
                CatalogValidationError,
                "complete legacy audio audit is required",
            ):
                build_catalog(
                    DATA / "quran_mp3_links.csv",
                    DATA / "reciters.csv",
                    DATA / "surahs.csv",
                    temporary_directory / "catalog.sqlite",
                    snapshot_json=snapshot,
                    snapshot_aliases_json=aliases,
                    snapshot_localizations_json=localizations,
                )

    def test_source_page_confirmation_cannot_replace_alias_even_with_legacy_audit(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_directory = Path(temporary_directory)
            legacy_audit = self.write_complete_legacy_audit(temporary_directory)
            snapshot = temporary_directory / "alias.json"
            snapshot.write_text(json.dumps({
                "format_version": 1,
                "source": "surahquran",
                "confirmed": True,
                "confirmation": "source-page-links",
                "audio_audit": "not-performed",
                "reciters": [{
                    "site_id": 999,
                    "source_name": "Existing alias",
                    "name_ru": "Существующий чтец",
                    "name_en": "Existing Reciter",
                    "tracks": [{
                        "surah_number": 2,
                        "url": "https://audio.example/002.mp3",
                        "status": "source-page-confirmed",
                    }],
                }],
            }), encoding="utf-8")
            aliases, localizations = self.write_review_tables(
                temporary_directory,
                [{
                    "site_id": 999,
                    "name_ru": "Существующий чтец",
                    "name_en": "Existing Reciter",
                }],
                {"surahquran-qari-999": "reciter-001"},
            )
            with self.assertRaisesRegex(
                CatalogValidationError,
                "source-page confirmation can only add a new unaliased reciter",
            ):
                build_catalog(
                    DATA / "quran_mp3_links.csv",
                    DATA / "reciters.csv",
                    DATA / "surahs.csv",
                    temporary_directory / "catalog.sqlite",
                    snapshot_json=snapshot,
                    snapshot_aliases_json=aliases,
                    snapshot_localizations_json=localizations,
                    legacy_audit_json=legacy_audit,
                )

    def test_source_page_confirmation_rejects_available_status_without_audio_audit(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_directory = Path(temporary_directory)
            snapshot = temporary_directory / "unaudited-available.json"
            snapshot.write_text(json.dumps({
                "format_version": 1,
                "source": "surahquran",
                "confirmed": True,
                "confirmation": "source-page-links",
                "audio_audit": "not-performed",
                "reciters": [{
                    "site_id": 999,
                    "source_name": "Unaudited source-page reciter",
                    "name_ru": "Непроверенный чтец",
                    "name_en": "Unaudited Reciter",
                    "tracks": [{
                        "surah_number": 2,
                        "url": "https://example.com/not-audio.html",
                        "status": "available",
                    }],
                }],
            }), encoding="utf-8")
            aliases, localizations = self.write_review_tables(
                temporary_directory,
                [{
                    "site_id": 999,
                    "name_ru": "Непроверенный чтец",
                    "name_en": "Unaudited Reciter",
                }],
            )
            with self.assertRaisesRegex(
                CatalogValidationError,
                "source-page confirmation requires source-page-confirmed or unavailable track status",
            ):
                build_catalog(
                    DATA / "quran_mp3_links.csv",
                    DATA / "reciters.csv",
                    DATA / "surahs.csv",
                    temporary_directory / "catalog.sqlite",
                    snapshot_json=snapshot,
                    snapshot_aliases_json=aliases,
                    snapshot_localizations_json=localizations,
                )

    def test_default_cli_rebuild_includes_checked_in_qari_10_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "catalog.sqlite"
            subprocess.run(
                [sys.executable, str(CATALOG_TOOLS / "build_catalog.py"), "--output", str(output)],
                check=True,
                capture_output=True,
                text=True,
            )
            with sqlite3.connect(output) as connection:
                self.assertEqual(
                    connection.execute("SELECT COUNT(*) FROM reciters").fetchone(),
                    (173,),
                )
                self.assertEqual(
                    connection.execute("SELECT COUNT(*) FROM tracks").fetchone(),
                    (19_631,),
                )

    def test_qari_10_is_new_sparse_reciter_with_reviewed_names_and_urls(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_directory = Path(temporary_directory)
            legacy_audit = self.write_complete_legacy_audit(temporary_directory)
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
                legacy_audit_json=legacy_audit,
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
            legacy_audit = self.write_complete_legacy_audit(temporary_directory)
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
                legacy_audit_json=legacy_audit,
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
            legacy_audit = self.write_complete_legacy_audit(temporary_directory)
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
            aliases, localizations = self.write_review_tables(
                temporary_directory,
                [{
                    "site_id": 999,
                    "name_ru": "Синтетическое точное совпадение",
                    "name_en": "Synthetic Exact Match",
                }],
                {"surahquran-qari-999": "reciter-001"},
            )
            output = temporary_directory / "catalog.sqlite"
            build_catalog(
                DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                DATA / "surahs.csv", output, snapshot_json=snapshot_path,
                snapshot_aliases_json=aliases,
                snapshot_localizations_json=localizations,
                legacy_audit_json=legacy_audit,
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
                legacy_audit = self.write_complete_legacy_audit(temporary_directory)
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
                aliases, localizations = self.write_review_tables(
                    temporary_directory,
                    [{"site_id": 999, "name_ru": "Тестовый чтец", "name_en": "Fixture Reciter"}],
                )
                with self.assertRaisesRegex(CatalogValidationError, "track status"):
                    build_catalog(
                        DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                        DATA / "surahs.csv", temporary_directory / "catalog.sqlite",
                        snapshot_json=snapshot_path,
                        snapshot_aliases_json=aliases,
                        snapshot_localizations_json=localizations,
                        legacy_audit_json=legacy_audit,
                    )

    def test_snapshot_fails_closed_when_reviewed_names_are_missing_or_mismatched(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_directory = Path(temporary_directory)
            legacy_audit = self.write_complete_legacy_audit(temporary_directory)
            snapshot_path = temporary_directory / "snapshot.json"
            snapshot_path.write_text(json.dumps({
                "format_version": 1,
                "source": "surahquran",
                "confirmed": True,
                "reciters": [{
                    "site_id": 321,
                    "source_name": "Unreviewed",
                    "name_ru": "Непроверенный",
                    "name_en": "Unreviewed",
                    "tracks": [{
                        "surah_number": 1,
                        "url": "https://audio.example/321/001.mp3",
                        "status": "available",
                    }],
                }],
            }), encoding="utf-8")
            aliases, localizations = self.write_review_tables(
                temporary_directory,
                [{"site_id": 10, "name_ru": "Мухаммад Хишам", "name_en": "Muhammad Hisham"}],
            )
            with self.assertRaisesRegex(CatalogValidationError, "missing reviewed RU/EN"):
                build_catalog(
                    DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                    DATA / "surahs.csv", temporary_directory / "missing.sqlite",
                    snapshot_json=snapshot_path,
                    snapshot_aliases_json=aliases,
                    snapshot_localizations_json=localizations,
                    legacy_audit_json=legacy_audit,
                )

            _, localizations = self.write_review_tables(
                temporary_directory,
                [{"site_id": 321, "name_ru": "Другое имя", "name_en": "Different Name"}],
            )
            with self.assertRaisesRegex(CatalogValidationError, "reviewed RU/EN localization mismatch"):
                build_catalog(
                    DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                    DATA / "surahs.csv", temporary_directory / "mismatch.sqlite",
                    snapshot_json=snapshot_path,
                    snapshot_aliases_json=aliases,
                    snapshot_localizations_json=localizations,
                    legacy_audit_json=legacy_audit,
                )

    def test_snapshot_resolved_id_must_match_reviewed_alias_table(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_directory = Path(temporary_directory)
            legacy_audit = self.write_complete_legacy_audit(temporary_directory)
            snapshot = build_fixture_snapshot(FIXTURES / "surahquran")
            snapshot["confirmed"] = True
            snapshot["reciters"][0]["resolved_id"] = "reciter-001"
            for track in snapshot["reciters"][0]["tracks"]:
                track["status"] = "available"
            snapshot_path = temporary_directory / "spoofed-alias.json"
            snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
            aliases, localizations = self.write_review_tables(
                temporary_directory,
                [{"site_id": 10, "name_ru": "Мухаммад Хишам", "name_en": "Muhammad Hisham"}],
            )
            with self.assertRaisesRegex(CatalogValidationError, "resolved_id does not match"):
                build_catalog(
                    DATA / "quran_mp3_links.csv", DATA / "reciters.csv",
                    DATA / "surahs.csv", temporary_directory / "spoofed.sqlite",
                    snapshot_json=snapshot_path,
                    snapshot_aliases_json=aliases,
                    snapshot_localizations_json=localizations,
                    legacy_audit_json=legacy_audit,
                )


if __name__ == "__main__":
    unittest.main()
