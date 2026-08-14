# Qrecs catalog pipeline

The application never crawls catalog sites at runtime. The commands below create reviewable build artifacts; only a fully audited snapshot can be merged into the bundled database.

## 1. Review identity tables

`Data/surahquran_localizations.json` must contain non-empty reviewed Russian and English names for every discovered SurahQuran site ID. `Data/surahquran_aliases.json` is an explicit append-only mapping from a SurahQuran stable ID to an already shipped `reciter-NNN` ID. Omit an alias when a recitation, riwaya, or style must remain separate.

The crawler stops after the list page and writes `missing-localizations.json` if any name is missing. It never invents or transliterates names automatically.

## 2. Create the candidate snapshot

```sh
python3 CatalogTools/surahquran_live.py \
  --list-url https://surahquran.com/qura.html \
  --aliases CatalogTools/Data/surahquran_aliases.json \
  --localizations CatalogTools/Data/surahquran_localizations.json \
  --output /path/to/surahquran-candidate
```

The output contains exact raw HTML pages plus canonical `manifest.json`, `aliases.json`, `localizations.json`, and `candidates.json`. It deliberately contains no fetch timestamp, so identical source bytes produce identical metadata. The crawler uses bounded concurrency and accepts only HTTPS profile, track, and MP3 URLs.

## 3. Audit new and legacy audio

```sh
python3 CatalogTools/audio_auditor.py \
  /path/to/surahquran-candidate/candidates.json \
  --output /path/to/surahquran-confirmed.json \
  --report /path/to/surahquran-audit.json

python3 CatalogTools/legacy_audio_candidates.py \
  --output /path/to/legacy-candidates.json

python3 CatalogTools/audio_auditor.py \
  --urls /path/to/legacy-candidates.json \
  --report /path/to/legacy-audit.json
```

Each URL is checked with `HEAD` and, when content must be inspected, a `Range: bytes=0-1023` request. The auditor allows at most three requests across two passes, follows only conclusive results, and verifies non-empty audio-compatible content with an MP3 signature. Its deterministic report separates `available`, `unavailable`, and `inconclusive`. A SurahQuran snapshot is marked confirmed only when no URL remains inconclusive.

## 4. Build the database

```sh
python3 CatalogTools/build_catalog.py \
  --snapshot /path/to/surahquran-confirmed.json \
  --snapshot-aliases CatalogTools/Data/surahquran_aliases.json \
  --snapshot-localizations CatalogTools/Data/surahquran_localizations.json \
  --legacy-audit /path/to/legacy-audit.json
```

The builder requires exact legacy audit coverage. Unmatched legacy reciters retain only `available` tracks, and empty reciters are removed. An explicitly aliased SurahQuran profile is authoritative and replaces that existing reciter's legacy tracks. New IDs remain `surahquran-qari-<siteID>`, and sparse published surah sets are preserved without filling gaps.

Run the offline regression suite with:

```sh
python3 -m unittest discover -s CatalogTools/Tests -v
```
