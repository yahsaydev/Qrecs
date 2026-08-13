import csv
import concurrent.futures
import hashlib
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


CATALOG_TOOLS = Path(__file__).resolve().parents[1]
DATA = CATALOG_TOOLS / "Data"
sys.path.insert(0, str(CATALOG_TOOLS))

from build_catalog import CatalogValidationError, build_catalog  # noqa: E402


class CatalogBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.temp = Path(self.temporary_directory.name)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def build(self, source=None, reciters=None, surahs=None, output=None):
        output = output or self.temp / "catalog.sqlite"
        build_catalog(
            source or DATA / "quran_mp3_links.csv",
            reciters or DATA / "reciters.csv",
            surahs or DATA / "surahs.csv",
            output,
        )
        return output

    def copy_csv(self, filename):
        destination = self.temp / filename
        shutil.copyfile(DATA / filename, destination)
        return destination

    def rewrite_rows(self, path, transform):
        with path.open(encoding="utf-8-sig", newline="") as source:
            reader = csv.DictReader(source)
            fieldnames = reader.fieldnames
            rows = list(reader)
        rows = transform(rows)
        with path.open("w", encoding="utf-8", newline="") as destination:
            writer = csv.DictWriter(destination, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)

    def assert_validation_error(self, expected_message, **paths):
        with self.assertRaisesRegex(CatalogValidationError, expected_message):
            self.build(**paths)

    def test_builds_expected_catalog_and_removes_known_noisy_duplicates(self):
        database = self.build()
        with sqlite3.connect(database) as connection:
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM reciters").fetchone()[0],
                172,
            )
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM surahs").fetchone()[0],
                114,
            )
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM tracks").fetchone()[0],
                19_608,
            )
            self.assertEqual(
                connection.execute(
                    "SELECT MIN(track_count), MAX(track_count) FROM "
                    "(SELECT COUNT(*) AS track_count FROM tracks GROUP BY reciter_id)"
                ).fetchone(),
                (114, 114),
            )
            self.assertEqual(
                connection.execute(
                    "SELECT id FROM reciters WHERE source_name_ru = ?",
                    ("Мишари Рашид Алафасы",),
                ).fetchone()[0],
                "reciter-113",
            )
            self.assertEqual(
                connection.execute(
                    "SELECT id FROM tracks WHERE reciter_id = ? AND surah_number = 1",
                    ("reciter-113",),
                ).fetchone()[0],
                "reciter-113-001",
            )
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)
            self.assertEqual(
                connection.execute(
                    "SELECT value FROM catalog_meta WHERE key = 'removed_duplicate_rows'"
                ).fetchone()[0],
                "5",
            )

    def test_build_is_byte_for_byte_deterministic(self):
        first = self.build(output=self.temp / "first.sqlite")
        second = self.build(output=self.temp / "second.sqlite")
        self.assertEqual(
            hashlib.sha256(first.read_bytes()).digest(),
            hashlib.sha256(second.read_bytes()).digest(),
        )

    def test_build_output_is_world_readable(self):
        database = self.build()
        self.assertEqual(database.stat().st_mode & 0o777, 0o644)

    def test_parallel_builds_share_output_safely(self):
        output = self.temp / "catalog.sqlite"

        def run_build(_):
            return self.build(output=output)

        errors = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            futures = [executor.submit(run_build, index) for index in range(8)]
            for future in futures:
                try:
                    future.result()
                except Exception as error:
                    errors.append(f"{type(error).__name__}: {error}")

        self.assertEqual(errors, [])
        with sqlite3.connect(output) as connection:
            self.assertEqual(
                connection.execute("PRAGMA integrity_check").fetchone(),
                ("ok",),
            )
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone(), (1,))
            self.assertEqual(connection.execute("PRAGMA foreign_key_check").fetchall(), [])
            self.assertEqual(
                [
                    row[0]
                    for row in connection.execute(
                        "SELECT name FROM sqlite_schema "
                        "WHERE type = 'table' ORDER BY name"
                    )
                ],
                ["catalog_meta", "reciters", "surahs", "tracks"],
            )
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM reciters").fetchone()[0],
                172,
            )
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM surahs").fetchone()[0],
                114,
            )
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM tracks").fetchone()[0],
                19_608,
            )
        self.assertEqual(
            sorted(path.name for path in self.temp.iterdir()),
            ["catalog.sqlite"],
        )

    def test_tajwid_minshawi_keeps_source_key_and_has_cyrillic_display_name(self):
        database = self.build()
        with sqlite3.connect(database) as connection:
            self.assertEqual(
                connection.execute(
                    "SELECT source_name_ru, name_ru FROM reciters WHERE id = 'reciter-055'"
                ).fetchone(),
                (
                    "Sıddık el-Minşavi",
                    "Мухаммад Сиддик аль-Миншави — Таджвид",
                ),
            )

    def test_salah_bukhatir_uses_reviewed_english_spelling(self):
        database = self.build()
        with sqlite3.connect(database) as connection:
            self.assertEqual(
                connection.execute(
                    "SELECT name_en FROM reciters WHERE id = 'reciter-155'"
                ).fetchone()[0],
                "Salah Bukhatir",
            )

    def test_mustafa_raad_al_azawi_uses_readable_english_spelling(self):
        database = self.build()
        with sqlite3.connect(database) as connection:
            self.assertEqual(
                connection.execute(
                    "SELECT name_en FROM reciters WHERE id = 'reciter-118'"
                ).fetchone()[0],
                "Mustafa Raad Al-Azawi",
            )

    def test_checked_in_csv_eol_policy_preserves_source_bytes(self):
        source_bytes = (DATA / "quran_mp3_links.csv").read_bytes()
        self.assertEqual(
            hashlib.sha256(source_bytes).hexdigest(),
            "0379a8112a8d170359aaeb6a517c555cd9d9d684a8cb0831e3b571e95f349584",
        )
        self.assertGreater(source_bytes.count(b"\r\n"), 0)
        self.assertEqual(source_bytes.count(b"\n"), source_bytes.count(b"\r\n"))
        for mapping_name in ("reciters.csv", "surahs.csv"):
            mapping_bytes = (DATA / mapping_name).read_bytes()
            self.assertNotIn(b"\r\n", mapping_bytes)

        attributes_path = CATALOG_TOOLS.parent / ".gitattributes"
        attributes = (
            attributes_path.read_text(encoding="utf-8")
            if attributes_path.exists()
            else ""
        )
        self.assertIn("CatalogTools/Data/quran_mp3_links.csv -text", attributes)
        self.assertIn("CatalogTools/Data/reciters.csv text eol=lf", attributes)
        self.assertIn("CatalogTools/Data/surahs.csv text eol=lf", attributes)

    def test_rejects_empty_source_field(self):
        source = self.copy_csv("quran_mp3_links.csv")
        self.rewrite_rows(source, lambda rows: [{**rows[0], "MP3_URL": ""}, *rows[1:]])
        self.assert_validation_error("empty field", source=source)

    def test_rejects_non_https_url(self):
        source = self.copy_csv("quran_mp3_links.csv")
        self.rewrite_rows(
            source,
            lambda rows: [
                {**rows[0], "MP3_URL": rows[0]["MP3_URL"].replace("https://", "http://")},
                *rows[1:],
            ],
        )
        self.assert_validation_error("HTTPS", source=source)

    def test_rejects_malformed_utf8_as_catalog_validation_error(self):
        source = self.copy_csv("quran_mp3_links.csv")
        source_bytes = bytearray(source.read_bytes())
        source_bytes[source_bytes.index(b"\n") + 1] = 0xFF
        source.write_bytes(source_bytes)

        caught_error = None
        try:
            self.build(source=source)
        except Exception as error:
            caught_error = error

        self.assertIsInstance(caught_error, CatalogValidationError)
        self.assertRegex(str(caught_error), "input must be UTF-8")

    def test_rejects_surah_number_outside_canonical_range(self):
        source = self.copy_csv("quran_mp3_links.csv")
        self.rewrite_rows(source, lambda rows: [{**rows[0], "Номер_суры": "0"}, *rows[1:]])
        self.assert_validation_error("1...114", source=source)

    def test_rejects_missing_reciter_localization(self):
        reciters = self.copy_csv("reciters.csv")
        self.rewrite_rows(reciters, lambda rows: rows[1:])
        self.assert_validation_error("missing reciter localization", reciters=reciters)

    def test_rejects_empty_english_localization(self):
        reciters = self.copy_csv("reciters.csv")
        self.rewrite_rows(reciters, lambda rows: [{**rows[0], "name_en": ""}, *rows[1:]])
        self.assert_validation_error("empty field", reciters=reciters)

    def test_rejects_missing_surah_localization(self):
        surahs = self.copy_csv("surahs.csv")
        self.rewrite_rows(surahs, lambda rows: rows[:-1])
        self.assert_validation_error("missing surah localization", surahs=surahs)

    def test_rejects_duplicate_logical_track_with_different_url(self):
        source = self.copy_csv("quran_mp3_links.csv")

        def corrupt_duplicate(rows):
            for index, row in enumerate(rows):
                if row["Чтец"] == "Мишари Рашид Алафасы" and row["Сура"].startswith("fotiha"):
                    rows[index] = {**row, "MP3_URL": row["MP3_URL"] + "?alternate=1"}
                    break
            return rows

        self.rewrite_rows(source, corrupt_duplicate)
        self.assert_validation_error("duplicate logical track", source=source)

    def test_rejects_replacing_allowed_mishary_duplicate_with_other_duplicate(self):
        source = self.copy_csv("quran_mp3_links.csv")

        def replace_allowed_duplicate(rows):
            rows = [
                row
                for row in rows
                if not (
                    row["Чтец"] == "Мишари Рашид Алафасы"
                    and row["Сура"] == "fotiha surasi mp3 фотиха скачать"
                )
            ]
            rows.append({**rows[0], "Сура": "unexpected duplicate title"})
            return rows

        self.rewrite_rows(source, replace_allowed_duplicate)
        self.assert_validation_error("unexpected duplicate row", source=source)

    def test_rejects_wrong_track_totals(self):
        source = self.copy_csv("quran_mp3_links.csv")
        self.rewrite_rows(source, lambda rows: rows[:-1])
        self.assert_validation_error("expected 19608 tracks", source=source)


if __name__ == "__main__":
    unittest.main()
