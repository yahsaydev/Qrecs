#!/usr/bin/env python3
"""Build Qrecs' bundled, read-only Quran audio catalog without network access."""

import argparse
import csv
import hashlib
import os
import re
import sqlite3
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


EXPECTED_RECITERS = 172
EXPECTED_SURAHS = 114
EXPECTED_TRACKS = 19_608
EXPECTED_REMOVED_DUPLICATES = 5
SCHEMA_VERSION = 1
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
        source = path.open(encoding="utf-8-sig", newline="")
    except UnicodeDecodeError as error:
        raise CatalogValidationError(f"{path}: input must be UTF-8") from error
    with source:
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


def _write_database(
    output_path,
    source_path,
    reciters_path,
    surahs_path,
    reciters,
    surahs,
    tracks,
    removed_duplicates,
):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_name(output_path.name + ".tmp")
    temporary_path.unlink(missing_ok=True)
    try:
        with sqlite3.connect(temporary_path) as connection:
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
        os.replace(temporary_path, output_path)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise


def build_catalog(source_csv, reciters_csv, surahs_csv, output_database):
    source_path = Path(source_csv)
    reciters_path = Path(reciters_csv)
    surahs_path = Path(surahs_csv)
    output_path = Path(output_database)
    reciters, surahs, tracks, removed_duplicates = _validate_and_normalize(
        source_path, reciters_path, surahs_path
    )
    _write_database(
        output_path,
        source_path,
        reciters_path,
        surahs_path,
        reciters,
        surahs,
        tracks,
        removed_duplicates,
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
    arguments = parser.parse_args()
    build_catalog(
        arguments.source, arguments.reciters, arguments.surahs, arguments.output
    )
    print(
        f"Built {arguments.output}: {EXPECTED_RECITERS} reciters, "
        f"{EXPECTED_SURAHS} surahs, {EXPECTED_TRACKS} tracks"
    )


if __name__ == "__main__":
    main()
