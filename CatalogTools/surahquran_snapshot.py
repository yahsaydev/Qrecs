#!/usr/bin/env python3
"""Create a canonical crawler snapshot from checked-in SurahQuran fixtures."""

import argparse
import json
import copy
from pathlib import Path

from surahquran import parse_reciter_profile, resolved_reciter_id, stable_reciter_id


def build_fixture_snapshot(fixture_root):
    fixture_root = Path(fixture_root)
    manifest = json.loads((fixture_root / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("format_version") != 1 or manifest.get("source") != "surahquran":
        raise ValueError("unsupported fixture manifest")
    reciters = []
    for entry in sorted(manifest["profiles"], key=lambda item: int(item["site_id"])):
        site_id = int(entry["site_id"])
        page_url = manifest["base_url"].rstrip("/") + "/" + entry["page"]
        profile = parse_reciter_profile(
            (fixture_root / entry["page"]).read_text(encoding="utf-8"),
            page_url,
            site_id,
        )
        reciters.append(
            {
                "site_id": site_id,
                "stable_id": stable_reciter_id(site_id),
                "resolved_id": resolved_reciter_id(site_id),
                "source_name": profile.name,
                "name_ru": entry["name_ru"],
                "name_en": entry["name_en"],
                "tracks": [
                    {
                        "surah_number": track.surah_number,
                        "url": track.direct_url,
                        "status": "pending",
                    }
                    for track in profile.tracks
                ],
            }
        )
    return {
        "format_version": 1,
        "source": "surahquran",
        "confirmed": False,
        "reciters": reciters,
    }


def apply_audit_report(snapshot, report):
    """Apply one already-computed report to a candidate snapshot."""
    confirmed = copy.deepcopy(snapshot)
    tracks = [
        track
        for reciter in confirmed["reciters"]
        for track in reciter["tracks"]
    ]
    status_by_url = {}
    for status in ("available", "unavailable", "inconclusive"):
        for item in getattr(report, status):
            status_by_url[item.url] = status
    for track in tracks:
        track["status"] = status_by_url.get(track["url"], "inconclusive")
    confirmed["confirmed"] = all(
        track["status"] != "inconclusive" for track in tracks
    )
    return confirmed


def audit_snapshot(snapshot, auditor):
    """Audit every unique candidate URL once and return both derived artifacts."""
    urls = [
        track["url"]
        for reciter in snapshot["reciters"]
        for track in reciter["tracks"]
    ]
    report = auditor.audit(urls)
    return apply_audit_report(snapshot, report), report


def confirm_snapshot(snapshot, auditor):
    """Backward-compatible helper returning only the confirmed candidate document."""
    return audit_snapshot(snapshot, auditor)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    snapshot = build_fixture_snapshot(arguments.fixture_root)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
