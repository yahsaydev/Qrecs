#!/usr/bin/env python3
"""Pure, offline parsers for saved SurahQuran HTML pages."""

import re
from dataclasses import dataclass
from html.parser import HTMLParser
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


# Catalog aliases are append-only: discovered source identities may map to an
# already-shipped catalog identity, but old IDs are never renamed.
RECITER_ID_ALIASES = {}

REQUIRED_LOCALIZATIONS = {
    10: Localization("Мухаммад Хишам", "Muhammad Hisham"),
}


def stable_reciter_id(site_id):
    number = int(site_id)
    if number <= 0:
        raise ValueError("SurahQuran site ID must be positive")
    return f"surahquran-qari-{number}"


def resolved_reciter_id(site_id):
    stable_id = stable_reciter_id(site_id)
    return RECITER_ID_ALIASES.get(stable_id, stable_id)


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
        value = attributes.get("data-surah", "")
        if not value.isdigit():
            continue
        number = int(value)
        if not 1 <= number <= 114 or number in seen:
            continue
        seen.add(number)
        href = urljoin(page_url, attributes.get("href", ""))
        direct_url = attributes.get("data-mp3", "")
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
            candidate = attributes.get("src") or attributes.get("href")
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
    raise ValueError("track page has no HTTPS direct MP3 URL")
