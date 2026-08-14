import hashlib
import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path


CATALOG_TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CATALOG_TOOLS))

from surahquran import (  # noqa: E402
    load_alias_table,
    load_localization_table,
    parse_reciter_list,
    parse_reciter_profile,
)
from surahquran_live import (  # noqa: E402
    CrawlError,
    HTTPPage,
    MissingLocalizationError,
    SurahQuranLiveCrawler,
)


LIST_URL = "https://surahquran.example/qura.html"
PROFILE_10 = "https://surahquran.example/quran-mp3-qari-10.html"
PROFILE_11 = "https://surahquran.example/quran-mp3-qari-11.html"
TRACK_11_7 = "https://surahquran.example/quran-mp3-qari-11-surah-7.html"


def page(url, body, status=200, content_type="text/html; charset=utf-8"):
    return HTTPPage(
        status=status,
        headers={"content-type": content_type},
        body=body.encode("utf-8"),
        final_url=url,
    )


class ScriptedPageTransport:
    def __init__(self, pages):
        self.pages = dict(pages)
        self.requests = []
        self._lock = threading.Lock()
        self.active = 0
        self.maximum_active = 0

    def get(self, url, timeout):
        with self._lock:
            self.requests.append((url, timeout))
            self.active += 1
            self.maximum_active = max(self.maximum_active, self.active)
        try:
            response = self.pages[url]
            if isinstance(response, BaseException):
                raise response
            return response
        finally:
            with self._lock:
                self.active -= 1


def write_tables(root, include_site_11=True):
    aliases = root / "aliases.json"
    localizations = root / "localizations.json"
    aliases.write_text(json.dumps({
        "format_version": 1,
        "source": "surahquran",
        "aliases": {
            "surahquran-qari-11": "reciter-001",
        },
    }), encoding="utf-8")
    reciters = [{
        "site_id": 10,
        "name_ru": "Мухаммад Хишам",
        "name_en": "Muhammad Hisham",
    }]
    if include_site_11:
        reciters.append({
            "site_id": 11,
            "name_ru": "Другой чтец",
            "name_en": "Another Qari",
        })
    localizations.write_text(json.dumps({
        "format_version": 1,
        "source": "surahquran",
        "reciters": reciters,
    }), encoding="utf-8")
    return aliases, localizations


class SurahQuranLiveCrawlerTests(unittest.TestCase):
    def transport(self):
        return ScriptedPageTransport({
            LIST_URL: page(LIST_URL, """
                <a href='/quran-mp3-qari-11.html'>Another Qari</a>
                <a href='/quran-mp3-qari-10.html'>Muhammad Hisham</a>
                <a href='/quran-mp3-qari-10.html'>duplicate</a>
            """),
            PROFILE_10: page(PROFILE_10, """
                <h1>Muhammad Hisham</h1>
                <a data-surah='2' data-mp3='https://cdn.example/10/002.mp3'
                   href='/quran-mp3-qari-10-surah-2.html'>Al-Baqarah</a>
            """),
            PROFILE_11: page(PROFILE_11, """
                <h1>Another Qari</h1>
                <a data-surah-number='7'
                   href='/quran-mp3-qari-11-surah-7.html'>Al-Araf</a>
            """),
            TRACK_11_7: page(TRACK_11_7, """
                <audio data-src='https://cdn.example/11/007.mp3'></audio>
            """),
        })

    def test_crawl_writes_reproducible_raw_pages_tables_manifest_and_candidates(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            aliases, localizations = write_tables(root)
            first = root / "first"
            second = root / "second"
            for destination in (first, second):
                crawler = SurahQuranLiveCrawler(self.transport(), workers=2)
                crawler.crawl(
                    LIST_URL,
                    destination,
                    aliases_path=aliases,
                    localizations_path=localizations,
                )

            self.assertEqual(
                (first / "candidates.json").read_bytes(),
                (second / "candidates.json").read_bytes(),
            )
            self.assertEqual(
                (first / "manifest.json").read_bytes(),
                (second / "manifest.json").read_bytes(),
            )
            snapshot = json.loads((first / "candidates.json").read_text(encoding="utf-8"))
            self.assertFalse(snapshot["confirmed"])
            self.assertEqual([item["site_id"] for item in snapshot["reciters"]], [10, 11])
            self.assertEqual(snapshot["reciters"][1]["resolved_id"], "reciter-001")
            self.assertEqual(snapshot["reciters"][1]["tracks"], [{
                "status": "pending",
                "surah_number": 7,
                "url": "https://cdn.example/11/007.mp3",
            }])
            raw_track = first / "raw" / "tracks" / "qari-11-surah-007.html"
            self.assertTrue(raw_track.is_file())
            manifest = json.loads((first / "manifest.json").read_text(encoding="utf-8"))
            track_entry = next(item for item in manifest["pages"] if item["path"].endswith("surah-007.html"))
            self.assertEqual(track_entry["sha256"], hashlib.sha256(raw_track.read_bytes()).hexdigest())
            self.assertNotIn("fetched_at", manifest)
            self.assertEqual(
                json.loads((first / "aliases.json").read_text(encoding="utf-8"))["aliases"],
                {"surahquran-qari-11": "reciter-001"},
            )

    def test_missing_reviewed_name_fails_closed_and_writes_review_template(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            aliases, localizations = write_tables(root, include_site_11=False)
            output = root / "snapshot"
            crawler = SurahQuranLiveCrawler(self.transport(), workers=2)
            with self.assertRaisesRegex(MissingLocalizationError, "site IDs: 11"):
                crawler.crawl(
                    LIST_URL,
                    output,
                    aliases_path=aliases,
                    localizations_path=localizations,
                )
            missing = json.loads((output / "missing-localizations.json").read_text(encoding="utf-8"))
            self.assertEqual(missing["reciters"], [{
                "name_en": "",
                "name_ru": "",
                "site_id": 11,
                "source_name": "Another Qari",
            }])
            self.assertFalse((output / "candidates.json").exists())
            self.assertTrue((output / "raw" / "list.html").is_file())

    def test_failed_rerun_invalidates_previous_final_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            aliases, localizations = write_tables(root)
            output = root / "snapshot"
            SurahQuranLiveCrawler(self.transport()).crawl(
                LIST_URL,
                output,
                aliases_path=aliases,
                localizations_path=localizations,
            )
            self.assertTrue((output / "candidates.json").exists())
            self.assertTrue((output / "manifest.json").exists())

            _, incomplete_localizations = write_tables(root, include_site_11=False)
            with self.assertRaises(MissingLocalizationError):
                SurahQuranLiveCrawler(self.transport()).crawl(
                    LIST_URL,
                    output,
                    aliases_path=aliases,
                    localizations_path=incomplete_localizations,
                )
            for stale_name in (
                "aliases.json",
                "candidates.json",
                "localizations.json",
                "manifest.json",
            ):
                self.assertFalse((output / stale_name).exists(), stale_name)

    def test_successful_shrinking_rerun_replaces_the_complete_raw_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            aliases, localizations = write_tables(root)
            output = root / "snapshot"
            SurahQuranLiveCrawler(self.transport()).crawl(
                LIST_URL,
                output,
                aliases_path=aliases,
                localizations_path=localizations,
            )
            old_profile = output / "raw" / "profiles" / "qari-11.html"
            old_track = output / "raw" / "tracks" / "qari-11-surah-007.html"
            self.assertTrue(old_profile.exists())
            self.assertTrue(old_track.exists())

            smaller = self.transport()
            smaller.pages[LIST_URL] = page(
                LIST_URL,
                "<a href='/quran-mp3-qari-10.html'>Muhammad Hisham</a>",
            )
            SurahQuranLiveCrawler(smaller).crawl(
                LIST_URL,
                output,
                aliases_path=aliases,
                localizations_path=localizations,
            )
            self.assertFalse(old_profile.exists())
            self.assertFalse(old_track.exists())
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertNotIn("qari-11", json.dumps(manifest))

    def test_non_html_or_unsuccessful_page_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            aliases, localizations = write_tables(root)
            transport = self.transport()
            transport.pages[PROFILE_10] = page(PROFILE_10, "not found", status=404)
            with self.assertRaisesRegex(CrawlError, "HTTP 404"):
                SurahQuranLiveCrawler(transport).crawl(
                    LIST_URL,
                    root / "snapshot",
                    aliases_path=aliases,
                    localizations_path=localizations,
                )

    def test_realistic_quran_mp3_links_and_surah_attributes_are_parsed(self):
        listings = parse_reciter_list(
            "<a href='/quran-mp3-qari-10.html'> Muhammad  Hisham </a>",
            "https://surahquran.example/qura.html",
        )
        self.assertEqual(listings[0].profile_url, PROFILE_10)
        profile = parse_reciter_profile(
            """
            <h1>Muhammad Hisham</h1>
            <a data-surah-number='7' href='/quran-mp3-qari-10-surah-7.html'>7</a>
            <a data-surah='2' data-src='https://cdn.example/10/002.MP3?download=1'>2</a>
            """,
            PROFILE_10,
            10,
        )
        self.assertEqual([track.surah_number for track in profile.tracks], [2, 7])
        self.assertEqual(profile.tracks[0].direct_url, "https://cdn.example/10/002.MP3?download=1")

    def test_tables_reject_empty_names_duplicate_site_ids_and_invalid_alias_targets(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            aliases, localizations = write_tables(root)
            self.assertEqual(load_alias_table(aliases)["surahquran-qari-11"], "reciter-001")
            self.assertEqual(load_localization_table(localizations)[10].name_en, "Muhammad Hisham")

            aliases.write_text(json.dumps({
                "format_version": 1,
                "source": "surahquran",
                "aliases": {"surahquran-qari-11": "not-a-catalog-id"},
            }), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "alias target"):
                load_alias_table(aliases)

            localizations.write_text(json.dumps({
                "format_version": 1,
                "source": "surahquran",
                "reciters": [
                    {"site_id": 10, "name_ru": "", "name_en": "Muhammad Hisham"},
                    {"site_id": 10, "name_ru": "Имя", "name_en": "Duplicate"},
                ],
            }), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "name_ru"):
                load_localization_table(localizations)


if __name__ == "__main__":
    unittest.main()
