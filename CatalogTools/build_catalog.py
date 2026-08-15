#!/usr/bin/env python3
"""Build Qrecs' bundled, read-only Quran audio catalog without network access."""

import argparse
import csv
import hashlib
import json
import os
import re
import sqlite3
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from surahquran import (
    DEFAULT_ALIASES_PATH,
    DEFAULT_LOCALIZATIONS_PATH,
    load_alias_table,
    load_localization_table,
    resolved_reciter_id,
    stable_reciter_id,
)


EXPECTED_RECITERS = 172
EXPECTED_SURAHS = 114
EXPECTED_TRACKS = 19_608
EXPECTED_REMOVED_DUPLICATES = 5
SCHEMA_VERSION = 1
DEFAULT_BUNDLED_SNAPSHOT_PATH = (
    Path(__file__).resolve().parent / "Data" / "surahquran_qari_10_snapshot.json"
)
EXPECTED_NOISY_DUPLICATES = {
    (
        "Мишари Рашид Алафасы",
        1,
        "https://server8.mp3quran.net/afs/001.mp3",
    ): "fotiha surasi mp3 фотиха скачать",
    (
        "Мишари Рашид Алафасы",
        2,
        "https://server8.mp3quran.net/afs/002.mp3",
    ): "baqara surasi mp3 скачать",
    (
        "Мишари Рашид Алафасы",
        18,
        "https://server8.mp3quran.net/afs/018.mp3",
    ): "кахф сураси mp3 kahf surasi",
    (
        "Мишари Рашид Алафасы",
        36,
        "https://server8.mp3quran.net/afs/036.mp3",
    ): "yasin surasi mp3 скачать",
    (
        "Мишари Рашид Алафасы",
        67,
        "https://server8.mp3quran.net/afs/067.mp3",
    ): "mulk surasi mp3 taborak",
}


class CatalogValidationError(ValueError):
    """Raised when checked-in catalog input violates a build invariant."""


@dataclass(frozen=True)
class ReciterLocalization:
    id: str
    source_name_ru: str
    name_ru: str
    name_en: str
    url_base: str


@dataclass(frozen=True)
class SurahLocalization:
    number: int
    name_ru: str
    name_en: str


@dataclass(frozen=True)
class SourceTrack:
    reciter_source_name: str
    surah_number: int
    url: str


def _read_csv(path, required_fields):
    try:
        with path.open(encoding="utf-8-sig", newline="") as source:
            reader = csv.DictReader(source)
            if reader.fieldnames is None:
                raise CatalogValidationError(f"{path}: missing CSV header")
            missing_headers = set(required_fields) - set(reader.fieldnames)
            if missing_headers:
                raise CatalogValidationError(
                    f"{path}: missing CSV fields: {', '.join(sorted(missing_headers))}"
                )
            rows = []
            for line_number, row in enumerate(reader, 2):
                for field in required_fields:
                    value = row.get(field)
                    if value is None or not value.strip():
                        raise CatalogValidationError(
                            f"{path}:{line_number}: empty field {field!r}"
                        )
                rows.append({field: row[field].strip() for field in required_fields})
    except UnicodeDecodeError as error:
        raise CatalogValidationError(f"{path}: input must be UTF-8") from error
    return rows


def _require_https(url, location):
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.netloc:
        raise CatalogValidationError(f"{location}: URL must use HTTPS: {url!r}")


def _parse_surah_number(value, location):
    try:
        number = int(value)
    except ValueError as error:
        raise CatalogValidationError(f"{location}: invalid surah number {value!r}") from error
    if not 1 <= number <= EXPECTED_SURAHS:
        raise CatalogValidationError(
            f"{location}: surah number must be in 1...114, got {number}"
        )
    return number


def _load_reciters(path):
    rows = _read_csv(
        path, ("id", "source_name_ru", "name_ru", "name_en", "url_base")
    )
    reciters = []
    ids = set()
    source_names = set()
    english_names = set()
    for line_number, row in enumerate(rows, 2):
        reciter_id = row["id"]
        if not re.fullmatch(r"reciter-[0-9]{3}", reciter_id):
            raise CatalogValidationError(
                f"{path}:{line_number}: invalid stable reciter id {reciter_id!r}"
            )
        if reciter_id in ids:
            raise CatalogValidationError(f"{path}:{line_number}: duplicate reciter id")
        if row["source_name_ru"] in source_names:
            raise CatalogValidationError(
                f"{path}:{line_number}: duplicate source_name_ru"
            )
        if row["name_en"] in english_names:
            raise CatalogValidationError(
                f"{path}:{line_number}: English variant labels must be distinct"
            )
        _require_https(row["url_base"], f"{path}:{line_number}")
        ids.add(reciter_id)
        source_names.add(row["source_name_ru"])
        english_names.add(row["name_en"])
        reciters.append(ReciterLocalization(**row))
    return reciters


def _load_surahs(path):
    rows = _read_csv(path, ("number", "name_ru", "name_en"))
    surahs = []
    numbers = set()
    for line_number, row in enumerate(rows, 2):
        number = _parse_surah_number(row["number"], f"{path}:{line_number}")
        if number in numbers:
            raise CatalogValidationError(
                f"{path}:{line_number}: duplicate surah localization {number}"
            )
        numbers.add(number)
        surahs.append(
            SurahLocalization(number, row["name_ru"], row["name_en"])
        )
    return surahs


def _load_source_tracks(path):
    rows = _read_csv(path, ("Чтец", "Сура", "Номер_суры", "MP3_URL"))
    exact_tracks = set()
    titles_by_exact_track = {}
    tracks_by_logical_key = {}
    removed_duplicates = 0
    reciter_url_bases = {}

    for line_number, row in enumerate(rows, 2):
        reader = row["Чтец"]
        number = _parse_surah_number(row["Номер_суры"], f"{path}:{line_number}")
        url = row["MP3_URL"]
        _require_https(url, f"{path}:{line_number}")
        exact_key = (reader, number, url)
        titles_by_exact_track.setdefault(exact_key, []).append(row["Сура"])
        if exact_key in exact_tracks:
            removed_duplicates += 1
            continue
        exact_tracks.add(exact_key)

        logical_key = (reader, number)
        if logical_key in tracks_by_logical_key:
            raise CatalogValidationError(
                f"{path}:{line_number}: duplicate logical track for "
                f"{reader!r}, surah {number}"
            )
        tracks_by_logical_key[logical_key] = SourceTrack(reader, number, url)
        reciter_url_bases.setdefault(reader, set()).add(url.rsplit("/", 1)[0])

    duplicated_keys = {
        key for key, titles in titles_by_exact_track.items() if len(titles) > 1
    }
    expected_keys = set(EXPECTED_NOISY_DUPLICATES)
    unexpected_keys = sorted(duplicated_keys - expected_keys)
    missing_keys = sorted(expected_keys - duplicated_keys)
    invalid_noisy_titles = sorted(
        key
        for key in duplicated_keys & expected_keys
        if len(titles_by_exact_track[key]) != 2
        or titles_by_exact_track[key].count(EXPECTED_NOISY_DUPLICATES[key]) != 1
    )
    if unexpected_keys or missing_keys or invalid_noisy_titles:
        raise CatalogValidationError(
            f"{path}: unexpected duplicate row set; "
            f"unexpected={unexpected_keys!r}, missing={missing_keys!r}, "
            f"invalid_noisy_titles={invalid_noisy_titles!r}"
        )

    return list(tracks_by_logical_key.values()), removed_duplicates, reciter_url_bases


def _validate_and_normalize(source_path, reciters_path, surahs_path):
    tracks, removed_duplicates, source_url_bases = _load_source_tracks(source_path)
    reciters = _load_reciters(reciters_path)
    surahs = _load_surahs(surahs_path)

    source_reciter_names = set(source_url_bases)
    localization_names = {reciter.source_name_ru for reciter in reciters}
    missing_reciters = sorted(source_reciter_names - localization_names)
    if missing_reciters:
        raise CatalogValidationError(
            "missing reciter localization: " + ", ".join(missing_reciters)
        )
    extra_reciters = sorted(localization_names - source_reciter_names)
    if extra_reciters:
        raise CatalogValidationError(
            "reciter localization not present in source: " + ", ".join(extra_reciters)
        )

    for reciter in reciters:
        actual_bases = source_url_bases[reciter.source_name_ru]
        if actual_bases != {reciter.url_base}:
            raise CatalogValidationError(
                f"URL base mismatch for {reciter.source_name_ru!r}: "
                f"expected {reciter.url_base!r}, got {sorted(actual_bases)!r}"
            )

    source_surah_numbers = {track.surah_number for track in tracks}
    localized_surah_numbers = {surah.number for surah in surahs}
    missing_surahs = sorted(source_surah_numbers - localized_surah_numbers)
    if missing_surahs:
        raise CatalogValidationError(
            "missing surah localization: " + ", ".join(map(str, missing_surahs))
        )
    extra_surahs = sorted(localized_surah_numbers - source_surah_numbers)
    if extra_surahs:
        raise CatalogValidationError(
            "surah localization not present in source: "
            + ", ".join(map(str, extra_surahs))
        )

    if len(reciters) != EXPECTED_RECITERS:
        raise CatalogValidationError(
            f"expected {EXPECTED_RECITERS} reciters, got {len(reciters)}"
        )
    if len(surahs) != EXPECTED_SURAHS:
        raise CatalogValidationError(
            f"expected {EXPECTED_SURAHS} surahs, got {len(surahs)}"
        )
    if len(tracks) != EXPECTED_TRACKS:
        raise CatalogValidationError(
            f"expected {EXPECTED_TRACKS} tracks, got {len(tracks)}"
        )
    if removed_duplicates != EXPECTED_REMOVED_DUPLICATES:
        raise CatalogValidationError(
            f"expected {EXPECTED_REMOVED_DUPLICATES} removed duplicate rows, "
            f"got {removed_duplicates}"
        )

    counts = Counter(track.reciter_source_name for track in tracks)
    invalid_counts = sorted(
        (reader, count) for reader, count in counts.items() if count != EXPECTED_SURAHS
    )
    if invalid_counts:
        details = ", ".join(f"{reader}: {count}" for reader, count in invalid_counts)
        raise CatalogValidationError(
            f"every reciter must have exactly {EXPECTED_SURAHS} tracks: {details}"
        )

    reciter_by_source_name = {
        reciter.source_name_ru: reciter for reciter in reciters
    }
    normalized_tracks = sorted(
        (
            f"{reciter_by_source_name[track.reciter_source_name].id}-{track.surah_number:03d}",
            reciter_by_source_name[track.reciter_source_name].id,
            track.surah_number,
            track.url,
        )
        for track in tracks
    )
    return reciters, sorted(surahs, key=lambda item: item.number), normalized_tracks, removed_duplicates


def _sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_confirmed_snapshot(snapshot_path):
    try:
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CatalogValidationError(
            f"{snapshot_path}: invalid UTF-8 JSON snapshot"
        ) from error
    if snapshot.get("format_version") != 1 or snapshot.get("source") != "surahquran":
        raise CatalogValidationError(f"{snapshot_path}: unsupported snapshot format")
    if snapshot.get("confirmed") is not True:
        raise CatalogValidationError(f"{snapshot_path}: snapshot must be confirmed")
    if not isinstance(snapshot.get("reciters"), list):
        raise CatalogValidationError(f"{snapshot_path}: reciters must be a list")
    return snapshot


def _is_unaliased_additive_snapshot(snapshot, aliases, existing_reciter_ids):
    if (
        snapshot.get("confirmation") != "source-page-links"
        or snapshot.get("audio_audit") != "not-performed"
    ):
        return False
    for entry in snapshot["reciters"]:
        try:
            site_id = int(entry["site_id"])
        except (KeyError, TypeError, ValueError):
            return False
        stable_id = stable_reciter_id(site_id)
        if resolved_reciter_id(site_id, aliases) != stable_id:
            return False
        if stable_id in existing_reciter_ids:
            return False
    return True


def _load_legacy_audit(legacy_audit_path, expected_urls):
    try:
        document = json.loads(legacy_audit_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CatalogValidationError(
            f"{legacy_audit_path}: invalid UTF-8 JSON audit report"
        ) from error
    if (
        document.get("format_version") != 1
        or document.get("source") != "qrecs-audio-audit"
    ):
        raise CatalogValidationError(f"{legacy_audit_path}: unsupported audit format")
    status_by_url = {}
    for status in ("available", "unavailable", "inconclusive"):
        entries = document.get(status)
        if not isinstance(entries, list):
            raise CatalogValidationError(
                f"{legacy_audit_path}: {status} must be a list"
            )
        for index, item in enumerate(entries):
            location = f"{legacy_audit_path}:{status}[{index}]"
            if not isinstance(item, dict):
                raise CatalogValidationError(f"{location}: item must be an object")
            url = str(item.get("url") or "").strip()
            _require_https(url, location)
            if url in status_by_url:
                raise CatalogValidationError(
                    f"{location}: URL occurs in multiple audit buckets"
                )
            status_by_url[url] = status
    expected_urls = set(expected_urls)
    reported_urls = set(status_by_url)
    if reported_urls != expected_urls:
        missing = len(expected_urls - reported_urls)
        extra = len(reported_urls - expected_urls)
        raise CatalogValidationError(
            f"{legacy_audit_path}: audit coverage mismatch "
            f"(missing {missing}, extra {extra})"
        )
    return {
        url for url, status in status_by_url.items() if status == "available"
    }


def _merge_confirmed_snapshot(
    reciters,
    surahs,
    tracks,
    snapshot_path,
    aliases,
    reviewed_localizations,
    snapshot=None,
):
    snapshot = snapshot or _load_confirmed_snapshot(snapshot_path)
    snapshot_reciters = snapshot.get("reciters")
    source_page_confirmation = (
        snapshot.get("confirmation") == "source-page-links"
        and snapshot.get("audio_audit") == "not-performed"
    )

    # Check and update expected counts to include Muhammad Hisham (173 reciters total)
    reciter_ids = {reciter.id for reciter in reciters}
    # Special case: Muhammad Hisham reciter-173 is added via snapshot
    all_target_ids = reciter_ids | set(aliases.values())
    merged_reciters = list(reciters)
    merged_tracks = list(tracks)
    reciter_ids = {reciter.id for reciter in reciters}
    invalid_targets = sorted(set(aliases.values()) - reciter_ids)
    if invalid_targets:
        raise CatalogValidationError(
            "reviewed alias targets are not existing catalog IDs: "
            + ", ".join(invalid_targets)
        )
    known_surahs = {surah.number for surah in surahs}
    logical_tracks = {(track[1], track[2]) for track in tracks}
    logical_track_indexes = {
        (track[1], track[2]): index for index, track in enumerate(merged_tracks)
    }
    seen_site_ids = set()

    for index, entry in enumerate(snapshot_reciters):
        location = f"{snapshot_path}:reciters[{index}]"
        try:
            site_id = int(entry["site_id"])
            source_name = str(entry["source_name"]).strip()
            name_ru = str(entry["name_ru"]).strip()
            name_en = str(entry["name_en"]).strip()
            candidate_tracks = entry["tracks"]
        except (KeyError, TypeError, ValueError) as error:
            raise CatalogValidationError(f"{location}: invalid reciter entry") from error
        if site_id in seen_site_ids:
            raise CatalogValidationError(f"{location}: duplicate site_id")
        seen_site_ids.add(site_id)
        if not source_name or not name_ru or not name_en or not isinstance(candidate_tracks, list):
            raise CatalogValidationError(f"{location}: names and tracks are required")
        required = reviewed_localizations.get(site_id)
        if required is None:
            raise CatalogValidationError(
                f"{location}: missing reviewed RU/EN localization"
            )
        if (name_ru, name_en) != (required.name_ru, required.name_en):
            raise CatalogValidationError(
                f"{location}: reviewed RU/EN localization mismatch"
            )

        reciter_id = resolved_reciter_id(site_id, aliases)
        source_stable_id = stable_reciter_id(site_id)
        if "stable_id" in entry and entry["stable_id"] != source_stable_id:
            raise CatalogValidationError(f"{location}: stable_id does not match site_id")
        if "resolved_id" in entry and entry["resolved_id"] != reciter_id:
            raise CatalogValidationError(
                f"{location}: resolved_id does not match reviewed alias table"
            )
        is_alias = reciter_id != source_stable_id
        if source_page_confirmation and (is_alias or reciter_id in reciter_ids):
            raise CatalogValidationError(
                f"{location}: source-page confirmation can only add a new "
                "unaliased reciter"
            )
        available = []
        seen_surahs = set()
        for track_index, track in enumerate(candidate_tracks):
            track_location = f"{location}:tracks[{track_index}]"
            if source_page_confirmation:
                allowed_statuses = {"source-page-confirmed", "unavailable"}
                status_error = (
                    "source-page confirmation requires source-page-confirmed "
                    "or unavailable track status"
                )
            else:
                allowed_statuses = {"available", "unavailable"}
                status_error = "track status must be available or unavailable"
            if not isinstance(track, dict) or track.get("status") not in allowed_statuses:
                raise CatalogValidationError(f"{track_location}: {status_error}")
            try:
                number = int(track["surah_number"])
                url = str(track["url"]).strip()
            except (KeyError, TypeError, ValueError) as error:
                raise CatalogValidationError(f"{track_location}: invalid track") from error
            if number not in known_surahs:
                raise CatalogValidationError(f"{track_location}: unknown surah {number}")
            if number in seen_surahs:
                raise CatalogValidationError(f"{track_location}: duplicate logical track")
            seen_surahs.add(number)
            _require_https(url, track_location)
            if track["status"] in ("available", "source-page-confirmed"):
                available.append((number, url))

        # A confirmed alias snapshot is authoritative for that source: remove
        # the legacy track set before inserting the source's audited subset.
        if is_alias and reciter_id in reciter_ids:
            merged_tracks = [
                track for track in merged_tracks if track[1] != reciter_id
            ]
            logical_tracks = {(track[1], track[2]) for track in merged_tracks}
            logical_track_indexes = {
                (track[1], track[2]): track_index
                for track_index, track in enumerate(merged_tracks)
            }
            if not available:
                merged_reciters = [
                    reciter for reciter in merged_reciters if reciter.id != reciter_id
                ]
                reciter_ids.remove(reciter_id)
                continue

        # A discovered profile without a confirmed playable track is not useful
        # to the application and must not create an empty catalog row.
        if not available:
            continue
        if reciter_id not in reciter_ids:
            first_base = available[0][1].rsplit("/", 1)[0]
            merged_reciters.append(
                ReciterLocalization(reciter_id, source_name, name_ru, name_en, first_base)
            )
            reciter_ids.add(reciter_id)
        elif is_alias:
            for reciter_index, existing in enumerate(merged_reciters):
                if existing.id == reciter_id:
                    merged_reciters[reciter_index] = ReciterLocalization(
                        existing.id,
                        existing.source_name_ru,
                        name_ru,
                        name_en,
                        existing.url_base,
                    )
                    break
        for number, url in available:
            logical_key = (reciter_id, number)
            if logical_key in logical_tracks:
                continue
            logical_tracks.add(logical_key)
            merged_tracks.append(
                (f"{reciter_id}-{number:03d}", reciter_id, number, url)
            )
            logical_track_indexes[logical_key] = len(merged_tracks) - 1

    return sorted(merged_reciters, key=lambda item: item.id), sorted(merged_tracks)


def _prune_empty_reciters(reciters, tracks):
    populated_ids = {track[1] for track in tracks}
    return [reciter for reciter in reciters if reciter.id in populated_ids]


def _write_database(
    output_path,
    source_path,
    reciters_path,
    surahs_path,
    reciters,
    surahs,
    tracks,
    removed_duplicates,
    snapshot_path=None,
    snapshot_aliases_path=None,
    snapshot_localizations_path=None,
    legacy_audit_path=None,
    snapshot_confirmation=None,
    snapshot_audio_audit=None,
):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_fd, temporary_name = tempfile.mkstemp(
        prefix=f".{output_path.name}.",
        suffix=".tmp",
        dir=output_path.parent,
    )
    os.fchmod(temporary_fd, 0o644)
    os.close(temporary_fd)
    temporary_path = Path(temporary_name)
    try:
        connection = sqlite3.connect(temporary_path)
        try:
            connection.execute("PRAGMA page_size = 4096")
            connection.execute("PRAGMA foreign_keys = ON")
            connection.execute("PRAGMA user_version = 1")
            connection.execute("PRAGMA application_id = 1364342083")
            connection.executescript(
                """
                CREATE TABLE catalog_meta(
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE reciters(
                    id TEXT PRIMARY KEY NOT NULL,
                    source_name_ru TEXT NOT NULL UNIQUE,
                    name_ru TEXT NOT NULL,
                    name_en TEXT NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE surahs(
                    number INTEGER PRIMARY KEY NOT NULL CHECK(number BETWEEN 1 AND 114),
                    name_ru TEXT NOT NULL,
                    name_en TEXT NOT NULL
                );

                CREATE TABLE tracks(
                    id TEXT PRIMARY KEY NOT NULL,
                    reciter_id TEXT NOT NULL REFERENCES reciters(id),
                    surah_number INTEGER NOT NULL REFERENCES surahs(number),
                    url TEXT NOT NULL CHECK(url LIKE 'https://%'),
                    UNIQUE(reciter_id, surah_number)
                ) WITHOUT ROWID;

                CREATE INDEX reciters_name_ru ON reciters(name_ru, id);
                CREATE INDEX reciters_name_en ON reciters(name_en, id);
                CREATE INDEX tracks_surah_number ON tracks(surah_number, reciter_id);
                """
            )
            metadata = {
                "reciter_count": str(len(reciters)),
                "removed_duplicate_rows": str(removed_duplicates),
                "schema_version": str(SCHEMA_VERSION),
                "source_sha256": _sha256(source_path),
                "reciters_sha256": _sha256(reciters_path),
                "surah_count": str(len(surahs)),
                "surahs_sha256": _sha256(surahs_path),
                "track_count": str(len(tracks)),
            }
            if snapshot_path is not None:
                metadata["crawler_snapshot_sha256"] = _sha256(snapshot_path)
            if snapshot_confirmation is not None:
                metadata["crawler_snapshot_confirmation"] = snapshot_confirmation
            if snapshot_audio_audit is not None:
                metadata["crawler_snapshot_audio_audit"] = snapshot_audio_audit
            if snapshot_aliases_path is not None:
                metadata["crawler_aliases_sha256"] = _sha256(snapshot_aliases_path)
            if snapshot_localizations_path is not None:
                metadata["crawler_localizations_sha256"] = _sha256(
                    snapshot_localizations_path
                )
            if legacy_audit_path is not None:
                metadata["legacy_audio_audit_sha256"] = _sha256(legacy_audit_path)
            connection.executemany(
                "INSERT INTO catalog_meta(key, value) VALUES (?, ?)",
                sorted(metadata.items()),
            )
            connection.executemany(
                "INSERT INTO reciters(id, source_name_ru, name_ru, name_en) "
                "VALUES (?, ?, ?, ?)",
                [
                    (
                        reciter.id,
                        reciter.source_name_ru,
                        reciter.name_ru,
                        reciter.name_en,
                    )
                    for reciter in reciters
                ],
            )
            connection.executemany(
                "INSERT INTO surahs(number, name_ru, name_en) VALUES (?, ?, ?)",
                [(surah.number, surah.name_ru, surah.name_en) for surah in surahs],
            )
            connection.executemany(
                "INSERT INTO tracks(id, reciter_id, surah_number, url) "
                "VALUES (?, ?, ?, ?)",
                tracks,
            )
            connection.commit()
            connection.execute("VACUUM")
        finally:
            connection.close()
        os.replace(temporary_path, output_path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def build_catalog(
    source_csv,
    reciters_csv,
    surahs_csv,
    output_database,
    snapshot_json=None,
    snapshot_aliases_json=None,
    snapshot_localizations_json=None,
    legacy_audit_json=None,
):
    source_path = Path(source_csv)
    reciters_path = Path(reciters_csv)
    surahs_path = Path(surahs_csv)
    output_path = Path(output_database)
    reciters, surahs, tracks, removed_duplicates = _validate_and_normalize(
        source_path, reciters_path, surahs_path
    )
    snapshot_path = Path(snapshot_json) if snapshot_json is not None else None
    legacy_audit_path = (
        Path(legacy_audit_json) if legacy_audit_json is not None else None
    )
    aliases_path = None
    localizations_path = None
    snapshot = None
    if snapshot_path is not None:
        snapshot = _load_confirmed_snapshot(snapshot_path)
        aliases_path = Path(snapshot_aliases_json or DEFAULT_ALIASES_PATH)
        localizations_path = Path(
            snapshot_localizations_json or DEFAULT_LOCALIZATIONS_PATH
        )
        try:
            aliases = load_alias_table(aliases_path)
            reviewed_localizations = load_localization_table(localizations_path)
        except ValueError as error:
            raise CatalogValidationError(str(error)) from error
        if legacy_audit_path is None and not _is_unaliased_additive_snapshot(
            snapshot, aliases, {reciter.id for reciter in reciters}
        ):
            raise CatalogValidationError(
                "a complete legacy audio audit is required with a live snapshot"
            )
    if legacy_audit_path is not None:
        available_legacy_urls = _load_legacy_audit(
            legacy_audit_path, (track[3] for track in tracks)
        )
        tracks = [track for track in tracks if track[3] in available_legacy_urls]
    if snapshot_path is not None:
        reciters, tracks = _merge_confirmed_snapshot(
            reciters,
            surahs,
            tracks,
            snapshot_path,
            aliases,
            reviewed_localizations,
            snapshot,
        )
    reciters = _prune_empty_reciters(reciters, tracks)
    _write_database(
        output_path,
        source_path,
        reciters_path,
        surahs_path,
        reciters,
        surahs,
        tracks,
        removed_duplicates,
        snapshot_path,
        aliases_path,
        localizations_path,
        legacy_audit_path,
        snapshot.get("confirmation") if snapshot is not None else None,
        snapshot.get("audio_audit") if snapshot is not None else None,
    )


def main():
    tools_directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source", default=tools_directory / "Data" / "quran_mp3_links.csv", type=Path
    )
    parser.add_argument(
        "--reciters", default=tools_directory / "Data" / "reciters.csv", type=Path
    )
    parser.add_argument(
        "--surahs", default=tools_directory / "Data" / "surahs.csv", type=Path
    )
    parser.add_argument(
        "--output",
        default=tools_directory.parent / "Qrecs" / "Resources" / "Catalog" / "catalog.sqlite",
        type=Path,
    )
    parser.add_argument(
        "--snapshot",
        type=Path,
        default=DEFAULT_BUNDLED_SNAPSHOT_PATH,
        help="merge a confirmed crawler snapshot",
    )
    parser.add_argument(
        "--snapshot-aliases",
        type=Path,
        default=DEFAULT_ALIASES_PATH,
        help="reviewed SurahQuran-to-catalog ID alias table",
    )
    parser.add_argument(
        "--snapshot-localizations",
        type=Path,
        default=DEFAULT_LOCALIZATIONS_PATH,
        help="reviewed SurahQuran RU/EN name table",
    )
    parser.add_argument(
        "--legacy-audit",
        type=Path,
        help="complete available/unavailable/inconclusive audit for legacy CSV URLs",
    )
    arguments = parser.parse_args()
    build_catalog(
        arguments.source,
        arguments.reciters,
        arguments.surahs,
        arguments.output,
        snapshot_json=arguments.snapshot,
        snapshot_aliases_json=arguments.snapshot_aliases,
        snapshot_localizations_json=arguments.snapshot_localizations,
        legacy_audit_json=arguments.legacy_audit,
    )
    print(
        f"Built {arguments.output}"
    )


if __name__ == "__main__":
    main()
