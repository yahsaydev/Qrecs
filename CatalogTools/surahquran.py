#!/usr/bin/env python3
"""Pure parsers and reviewed identity tables for SurahQuran snapshots."""

import json
import re
from dataclasses import dataclass
from html import unescape
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit


@dataclass(frozen=True)
class ReciterListing:
    site_id: int
    name: str
    profile_url: str


@dataclass(frozen=True)
class ProfileTrack:
    surah_number: int
    page_url: str
    direct_url: str = ""


@dataclass(frozen=True)
class ReciterProfile:
    site_id: int
    name: str
    tracks: tuple


@dataclass(frozen=True)
class Localization:
    name_ru: str
    name_en: str


DATA_DIRECTORY = Path(__file__).resolve().parent / "Data"
DEFAULT_ALIASES_PATH = DATA_DIRECTORY / "surahquran_aliases.json"
DEFAULT_LOCALIZATIONS_PATH = DATA_DIRECTORY / "surahquran_localizations.json"


def stable_reciter_id(site_id):
    number = int(site_id)
    if number <= 0:
        raise ValueError("SurahQuran site ID must be positive")
    return f"surahquran-qari-{number}"


def _load_table_document(path):
    path = Path(path)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{path}: invalid UTF-8 JSON table") from error
    if document.get("format_version") != 1 or document.get("source") != "surahquran":
        raise ValueError(f"{path}: unsupported table format")
    return document


def load_alias_table(path=DEFAULT_ALIASES_PATH):
    """Load the append-only mapping from source IDs to already-shipped IDs."""
    document = _load_table_document(path)
    aliases = document.get("aliases")
    if not isinstance(aliases, dict):
        raise ValueError(f"{path}: aliases must be an object")
    result = {}
    for source_id, target_id in aliases.items():
        if not re.fullmatch(r"surahquran-qari-[1-9][0-9]*", str(source_id)):
            raise ValueError(f"{path}: invalid SurahQuran alias source {source_id!r}")
        if not re.fullmatch(r"reciter-[0-9]{3}", str(target_id)):
            raise ValueError(f"{path}: invalid alias target {target_id!r}")
        result[str(source_id)] = str(target_id)
    return result


def load_localization_table(path=DEFAULT_LOCALIZATIONS_PATH):
    """Load manually reviewed names; incomplete names are always rejected."""
    document = _load_table_document(path)
    entries = document.get("reciters")
    if not isinstance(entries, list):
        raise ValueError(f"{path}: reciters must be a list")
    result = {}
    for index, entry in enumerate(entries):
        location = f"{path}:reciters[{index}]"
        if not isinstance(entry, dict):
            raise ValueError(f"{location}: entry must be an object")
        try:
            site_id = int(entry["site_id"])
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"{location}: invalid site_id") from error
        if site_id <= 0 or site_id in result:
            raise ValueError(f"{location}: site_id must be positive and unique")
        name_ru = str(entry.get("name_ru", "")).strip()
        name_en = str(entry.get("name_en", "")).strip()
        if not name_ru:
            raise ValueError(f"{location}: name_ru is required")
        if not name_en:
            raise ValueError(f"{location}: name_en is required")
        result[site_id] = Localization(name_ru, name_en)
    return result


# These immutable, checked-in tables are the only automatic identity merges.
RECITER_ID_ALIASES = load_alias_table()
REQUIRED_LOCALIZATIONS = load_localization_table()


def resolved_reciter_id(site_id, aliases=None):
    stable_id = stable_reciter_id(site_id)
    return (RECITER_ID_ALIASES if aliases is None else aliases).get(stable_id, stable_id)


class _AnchorParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.anchors = []
        self._anchor = None
        self._text = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "a":
            self._anchor = attributes
            self._text = []

    def handle_data(self, data):
        if self._anchor is not None:
            self._text.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._anchor is not None:
            self.anchors.append((self._anchor, " ".join("".join(self._text).split())))
            self._anchor = None
            self._text = []


def parse_reciter_list(html, base_url):
    parser = _AnchorParser()
    parser.feed(html)
    listings = []
    seen = set()
    for attributes, name in parser.anchors:
        href = attributes.get("href", "")
        match = re.search(r"(?:qari[-/])(\d+)(?:\.html)?(?:[/?#]|$)", href)
        if not match:
            continue
        site_id = int(match.group(1))
        if site_id in seen:
            continue
        seen.add(site_id)
        listings.append(ReciterListing(site_id, name, urljoin(base_url, href)))
    return listings


def parse_reciter_profile(html, page_url, site_id):
    parser = _AnchorParser()
    parser.feed(html)
    tracks = []
    seen = set()
    for attributes, _ in parser.anchors:
        raw_href = attributes.get("href", "")
        direct_attribute = (
            attributes.get("data-mp3")
            or attributes.get("data-src")
            or attributes.get("data-url")
            or ""
        )
        value = (
            attributes.get("data-surah")
            or attributes.get("data-surah-number")
            or attributes.get("data-sura")
            or ""
        )
        if not value.isdigit():
            match = re.search(r"(?:surah|sura)[-/](\d{1,3})(?:\.html)?(?:[/?#]|$)", raw_href, re.I)
            value = match.group(1) if match else ""
        if not value.isdigit():
            direct_candidate = direct_attribute or raw_href
            match = re.search(
                r"(?:^|/)(\d{1,3})\.mp3(?:[?#]|$)", direct_candidate, re.I
            )
            value = match.group(1) if match else ""
        if not value.isdigit():
            continue
        number = int(value)
        if not 1 <= number <= 114 or number in seen:
            continue
        seen.add(number)
        href = urljoin(page_url, raw_href)
        direct_url = direct_attribute
        if not direct_url and ".mp3" in raw_href.lower():
            direct_url = raw_href
        if direct_url:
            direct_url = urljoin(page_url, direct_url)
        tracks.append(ProfileTrack(number, href, direct_url))
    tracks.sort(key=lambda item: item.surah_number)
    title_match = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.I | re.S)
    name = re.sub(r"<[^>]+>", "", title_match.group(1)).strip() if title_match else ""
    return ReciterProfile(int(site_id), name, tuple(tracks))


class _MediaParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag in ("audio", "source", "a"):
            candidate = (
                attributes.get("src")
                or attributes.get("data-src")
                or attributes.get("data-mp3")
                or attributes.get("data-url")
                or attributes.get("href")
            )
            if candidate and ".mp3" in candidate.lower():
                self.urls.append(candidate)


def parse_track_page(html, page_url):
    parser = _MediaParser()
    parser.feed(html)
    for candidate in parser.urls:
        url = urljoin(page_url, candidate)
        parts = urlsplit(url)
        if parts.scheme == "https" and parts.netloc:
            return url
    normalized = unescape(html.replace("\\/", "/"))
    for match in re.finditer(
        r"https://[^\s\"'<>]+?\.mp3(?:\?[^\s\"'<>]+)?", normalized, re.I
    ):
        url = match.group(0)
        parts = urlsplit(url)
        if parts.scheme == "https" and parts.netloc:
            return url
    raise ValueError("track page has no HTTPS direct MP3 URL")
