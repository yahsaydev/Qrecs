#!/usr/bin/env python3
"""Create a deterministic URL manifest for auditing the legacy CSV catalog."""

import argparse
import csv
import json
from pathlib import Path
from urllib.parse import urlsplit


def build_candidate_document(source_csv):
    source_csv = Path(source_csv)
    try:
        with source_csv.open(encoding="utf-8-sig", newline="") as source:
            reader = csv.DictReader(source)
            if reader.fieldnames is None or "MP3_URL" not in reader.fieldnames:
                raise ValueError(f"{source_csv}: missing MP3_URL field")
            urls = set()
            for line_number, row in enumerate(reader, 2):
                url = str(row.get("MP3_URL") or "").strip()
                parts = urlsplit(url)
                if parts.scheme != "https" or not parts.netloc:
                    raise ValueError(
                        f"{source_csv}:{line_number}: audio URL must use HTTPS"
                    )
                urls.add(url)
    except UnicodeDecodeError as error:
        raise ValueError(f"{source_csv}: input must be UTF-8") from error
    return {
        "format_version": 1,
        "source": "qrecs-legacy-audio-candidates",
        "urls": sorted(urls),
    }


def main():
    tools_directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        default=tools_directory / "Data" / "quran_mp3_links.csv",
        type=Path,
    )
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    document = build_candidate_document(arguments.source)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
