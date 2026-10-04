#!/usr/bin/env bash
#
# Refresh the pinned CC-CEDICT snapshot in Dictionaries/cc-cedict/.
#
# The snapshot is pinned rather than fetched at build time so that builds are
# reproducible and every change to the bundled dictionary arrives as a
# reviewable diff. CC-CEDICT is updated upstream almost daily, so without a pin
# two builds of the same commit could ship different data.
#
#     ./Scripts/update-cedict.sh            # fetch the latest and repin
#     ./Scripts/update-cedict.sh --check    # report drift, change nothing
#
# A scheduled CI job runs this with --check monthly and opens an ISSUE when
# upstream moves. It never commits: a refresh can change the declared licence,
# which requires updating the attribution and legalcode to match.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DICT_DIR="$REPO_ROOT/Dictionaries/cc-cedict"
readonly DATA_FILE="$DICT_DIR/cedict_ts.u8"
readonly SOURCE_FILE="$DICT_DIR/SOURCE.json"
readonly UPSTREAM="https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.zip"

check_only=false
[ "${1:-}" = "--check" ] && check_only=true

log() { printf '  %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else die "neither shasum nor sha256sum is available"
    fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'Fetching CC-CEDICT\n'
# MDBG rate-limits aggressively; be patient rather than failing spuriously.
curl --fail --silent --show-error --location \
    --max-time 900 --retry 3 --retry-delay 5 \
    --output "$tmp/cedict.zip" "$UPSTREAM" \
    || die "download failed. MDBG throttles heavily; try again later."

unzip -q -o "$tmp/cedict.zip" -d "$tmp/extracted"
new_file="$(find "$tmp/extracted" -name 'cedict_ts.u8' -print -quit)"
[ -n "$new_file" ] || die "the archive did not contain cedict_ts.u8"

new_sha="$(sha256 "$new_file")"
new_bytes="$(wc -c < "$new_file" | tr -d ' ')"

# Read the file's own header rather than inferring. The licence in particular
# must come from the data: snapshots differ, and asserting a version the source
# does not claim would be a false licensing statement.
entries="$(grep -m1 '^#! entries=' "$new_file" | cut -d= -f2 | tr -d '\r' || true)"
version="$(grep -m1 '^#! version=' "$new_file" | cut -d= -f2 | tr -d '\r' || true)"
date_field="$(grep -m1 '^#! date=' "$new_file" | cut -d= -f2 | tr -d '\r' || true)"
licence="$(grep -m1 '^#! license=' "$new_file" | cut -d= -f2 | tr -d '\r' || true)"

[ -n "$entries" ] || die "the downloaded file has no '#! entries=' header"
[ -n "$licence" ] || die "the downloaded file has no '#! license=' header"

log "entries:  $entries"
log "licence:  $licence"
log "date:     ${date_field:-unspecified}"
log "sha256:   $new_sha"

old_sha=""
[ -f "$DATA_FILE" ] && old_sha="$(sha256 "$DATA_FILE")"

if [ "$new_sha" = "$old_sha" ]; then
    log "unchanged — the pinned snapshot is current"
    exit 0
fi

if [ "$check_only" = true ]; then
    log "upstream has changed"
    log "  pinned:   ${old_sha:-none}"
    log "  upstream: $new_sha"
    exit 1
fi

mkdir -p "$DICT_DIR"
cp "$new_file" "$DATA_FILE"

cat > "$SOURCE_FILE" <<JSON
{
  "url": "$UPSTREAM",
  "file": "cedict_ts.u8",
  "sha256": "$new_sha",
  "bytes": $new_bytes,
  "entries": $entries,
  "version": "${version:-unknown}",
  "date": "${date_field:-unknown}",
  "license": "$licence",
  "retrieved": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

printf 'Updated the pinned snapshot.\n'
printf 'Review the diff, then regenerate with: make dict\n'

if [ -n "$old_sha" ]; then
    printf '\nIf the licence line above differs from the one quoted in\n'
    printf 'Dictionaries/cc-cedict/README.md, update that too — the attribution\n'
    printf 'must match what the data actually declares.\n'
fi
