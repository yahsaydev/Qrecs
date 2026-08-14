#!/usr/bin/env python3
"""Create a reproducible, unaudited SurahQuran candidate snapshot."""

import argparse
import hashlib
import json
import os
import shutil
import socket
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

from surahquran import (
    DEFAULT_ALIASES_PATH,
    DEFAULT_LOCALIZATIONS_PATH,
    load_alias_table,
    load_localization_table,
    parse_reciter_list,
    parse_reciter_profile,
    parse_track_page,
    resolved_reciter_id,
    stable_reciter_id,
)


@dataclass(frozen=True)
class HTTPPage:
    status: int
    headers: dict
    body: bytes
    final_url: str


class CrawlError(RuntimeError):
    pass


class MissingLocalizationError(CrawlError):
    pass


class URLPageTransport:
    def get(self, url, timeout):
        request = Request(url, headers={
            "Accept": "text/html,application/xhtml+xml",
            "User-Agent": "Qrecs-CatalogBuilder/0.1.1",
        })
        try:
            with urlopen(request, timeout=timeout) as response:
                return HTTPPage(
                    response.status,
                    dict(response.headers.items()),
                    response.read(),
                    response.geturl(),
                )
        except HTTPError as error:
            return HTTPPage(
                error.code,
                dict(error.headers.items()),
                error.read(),
                error.geturl(),
            )


def _canonical_bytes(document):
    return (json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        Path(temporary_name).unlink(missing_ok=True)
        raise


def _https_url(url, location):
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.netloc:
        raise CrawlError(f"{location}: expected an HTTPS URL")
    return url


class SurahQuranLiveCrawler:
    def __init__(self, transport, workers=6, timeout=15, max_attempts=3):
        if workers < 1:
            raise ValueError("workers must be positive")
        if max_attempts < 1:
            raise ValueError("max_attempts must be positive")
        self.transport = transport
        self.workers = workers
        self.timeout = timeout
        self.max_attempts = max_attempts

    def _fetch(self, url):
        _https_url(url, "crawl")
        last_error = None
        for _ in range(self.max_attempts):
            try:
                response = self.transport.get(url, self.timeout)
            except (socket.timeout, TimeoutError, URLError) as error:
                last_error = type(error).__name__
                continue
            content_type = ""
            for key, value in response.headers.items():
                if str(key).lower() == "content-type":
                    content_type = str(value).lower()
                    break
            if response.status == 429 or 500 <= response.status <= 599:
                last_error = f"HTTP {response.status}"
                continue
            if not 200 <= response.status <= 299:
                raise CrawlError(f"{url}: HTTP {response.status}")
            if "html" not in content_type and "xhtml" not in content_type:
                raise CrawlError(f"{url}: non-HTML content type {content_type!r}")
            if not response.body:
                raise CrawlError(f"{url}: empty HTML response")
            _https_url(response.final_url or url, "redirect")
            return response
        raise CrawlError(f"{url}: {last_error or 'request failed'} after {self.max_attempts} attempts")

    @staticmethod
    def _decode(response):
        content_type = next(
            (str(value) for key, value in response.headers.items() if str(key).lower() == "content-type"),
            "",
        )
        charset = "utf-8"
        for field in content_type.split(";")[1:]:
            if field.strip().lower().startswith("charset="):
                charset = field.split("=", 1)[1].strip().strip('"')
        try:
            return response.body.decode(charset)
        except (LookupError, UnicodeDecodeError) as error:
            raise CrawlError(f"{response.final_url}: invalid {charset} HTML") from error

    @staticmethod
    def _page_record(kind, url, response, path, site_id=None, surah_number=None):
        record = {
            "final_url": response.final_url or url,
            "kind": kind,
            "path": path.as_posix(),
            "sha256": hashlib.sha256(response.body).hexdigest(),
            "url": url,
        }
        if site_id is not None:
            record["site_id"] = site_id
        if surah_number is not None:
            record["surah_number"] = surah_number
        return record

    def crawl(self, list_url, output_directory, aliases_path=DEFAULT_ALIASES_PATH,
              localizations_path=DEFAULT_LOCALIZATIONS_PATH):
        output = Path(output_directory)
        output.mkdir(parents=True, exist_ok=True)
        # A rerun must never leave any previous candidate or raw page looking
        # current; only artifacts written by this run may remain below.
        for name in (
            "aliases.json",
            "candidates.json",
            "localizations.json",
            "manifest.json",
            "missing-localizations.json",
        ):
            (output / name).unlink(missing_ok=True)
        raw_directory = output / "raw"
        if raw_directory.is_symlink() or raw_directory.is_file():
            raw_directory.unlink()
        elif raw_directory.is_dir():
            shutil.rmtree(raw_directory)
        aliases = load_alias_table(aliases_path)
        localizations = load_localization_table(localizations_path)
        pages = []

        list_response = self._fetch(list_url)
        list_path = Path("raw/list.html")
        _atomic_write(output / list_path, list_response.body)
        pages.append(self._page_record("list", list_url, list_response, list_path))
        listings = sorted(
            parse_reciter_list(self._decode(list_response), list_response.final_url or list_url),
            key=lambda item: item.site_id,
        )
        if not listings:
            raise CrawlError(f"{list_url}: no reciter profiles found")

        missing = [listing for listing in listings if listing.site_id not in localizations]
        if missing:
            template = {
                "format_version": 1,
                "reciters": [
                    {
                        "name_en": "",
                        "name_ru": "",
                        "site_id": item.site_id,
                        "source_name": item.name,
                    }
                    for item in missing
                ],
                "source": "surahquran",
            }
            _atomic_write(output / "missing-localizations.json", _canonical_bytes(template))
            numbers = ", ".join(str(item.site_id) for item in missing)
            raise MissingLocalizationError(f"missing reviewed RU/EN names for site IDs: {numbers}")

        with ThreadPoolExecutor(max_workers=self.workers) as executor:
            profile_responses = list(executor.map(
                lambda listing: self._fetch(listing.profile_url), listings
            ))

        profiles = []
        unresolved_tracks = []
        for listing, response in zip(listings, profile_responses):
            profile_path = Path(f"raw/profiles/qari-{listing.site_id}.html")
            _atomic_write(output / profile_path, response.body)
            pages.append(self._page_record(
                "profile", listing.profile_url, response, profile_path, listing.site_id
            ))
            profile = parse_reciter_profile(
                self._decode(response), response.final_url or listing.profile_url, listing.site_id
            )
            profiles.append((listing, profile))
            for track in profile.tracks:
                if not track.direct_url:
                    unresolved_tracks.append((listing.site_id, track))

        with ThreadPoolExecutor(max_workers=self.workers) as executor:
            track_responses = list(executor.map(
                lambda pair: self._fetch(pair[1].page_url), unresolved_tracks
            ))
        resolved_urls = {}
        for (site_id, track), response in zip(unresolved_tracks, track_responses):
            track_path = Path(f"raw/tracks/qari-{site_id}-surah-{track.surah_number:03d}.html")
            _atomic_write(output / track_path, response.body)
            pages.append(self._page_record(
                "track", track.page_url, response, track_path, site_id, track.surah_number
            ))
            resolved_urls[(site_id, track.surah_number)] = parse_track_page(
                self._decode(response), response.final_url or track.page_url
            )

        reciters = []
        for listing, profile in profiles:
            localization = localizations[listing.site_id]
            tracks = []
            for track in profile.tracks:
                direct_url = track.direct_url or resolved_urls[(listing.site_id, track.surah_number)]
                _https_url(direct_url, f"qari {listing.site_id} surah {track.surah_number}")
                tracks.append({
                    "status": "pending",
                    "surah_number": track.surah_number,
                    "url": direct_url,
                })
            reciters.append({
                "name_en": localization.name_en,
                "name_ru": localization.name_ru,
                "resolved_id": resolved_reciter_id(listing.site_id, aliases),
                "site_id": listing.site_id,
                "source_name": profile.name or listing.name,
                "stable_id": stable_reciter_id(listing.site_id),
                "tracks": tracks,
            })

        alias_document = _load_and_canonicalize_table(aliases_path)
        localization_document = _load_and_canonicalize_table(localizations_path)
        candidates = {
            "confirmed": False,
            "format_version": 1,
            "reciters": reciters,
            "source": "surahquran",
        }
        manifest = {
            "format_version": 1,
            "pages": sorted(pages, key=lambda item: item["path"]),
            "source": "surahquran",
        }
        _atomic_write(output / "aliases.json", _canonical_bytes(alias_document))
        _atomic_write(output / "localizations.json", _canonical_bytes(localization_document))
        _atomic_write(output / "candidates.json", _canonical_bytes(candidates))
        _atomic_write(output / "manifest.json", _canonical_bytes(manifest))
        return candidates


def _load_and_canonicalize_table(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CrawlError(f"{path}: invalid table") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list-url", default="https://surahquran.com/qura.html")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--aliases", default=DEFAULT_ALIASES_PATH, type=Path)
    parser.add_argument("--localizations", default=DEFAULT_LOCALIZATIONS_PATH, type=Path)
    parser.add_argument("--workers", default=6, type=int)
    parser.add_argument("--timeout", default=15, type=float)
    arguments = parser.parse_args()
    SurahQuranLiveCrawler(
        URLPageTransport(), workers=arguments.workers, timeout=arguments.timeout
    ).crawl(
        arguments.list_url,
        arguments.output,
        aliases_path=arguments.aliases,
        localizations_path=arguments.localizations,
    )


if __name__ == "__main__":
    main()
