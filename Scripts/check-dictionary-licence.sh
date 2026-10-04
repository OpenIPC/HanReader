#!/usr/bin/env bash
#
# Assert that every statement about the bundled dictionary's licence agrees
# with what the data itself declares.
#
# The licence version lives in four places, and they drift silently:
#
#   1. the data's own `#! license=` header      (the authority)
#   2. Dictionaries/cc-cedict/SOURCE.json
#   3. the attribution quoted in that directory's README
#   4. the committed legalcode in that directory's LICENSE
#
# Getting this wrong means publishing a false licensing statement, which for a
# project whose whole data story rests on correct attribution is the worst
# available mistake. Pinning a fixed version in the check instead would just
# move the problem: a refreshed snapshot would then fail for being correct.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DICT_DIR="$REPO_ROOT/Dictionaries/cc-cedict"
readonly DATA="$DICT_DIR/cedict_ts.u8"
readonly RECORD="$DICT_DIR/SOURCE.json"
readonly README="$DICT_DIR/README.md"
readonly LEGALCODE="$DICT_DIR/LICENSE"

fail() { printf '::error file=%s::%s\n' "${2:-$RECORD}" "$1" >&2; exit 1; }

for file in "$DATA" "$RECORD" "$README" "$LEGALCODE"; do
    [ -f "$file" ] || fail "missing: ${file#"$REPO_ROOT"/}" "${file#"$REPO_ROOT"/}"
done

# 1. The authority.
declared="$(grep -m1 '^#! license=' "$DATA" | cut -d= -f2- | tr -d '\r')"
[ -n "$declared" ] || fail "the data has no '#! license=' header" "${DATA#"$REPO_ROOT"/}"

# Extract the version number, e.g. 3.0, from the URL.
version="$(printf '%s' "$declared" | sed -nE 's#.*/licenses/[a-z-]+/([0-9]+\.[0-9]+)/?.*#\1#p')"
[ -n "$version" ] || fail "could not read a version from the declared licence: $declared"

printf 'Bundled dictionary licence\n'
printf '  data declares:  %s (version %s)\n' "$declared" "$version"

# 2. SOURCE.json.
recorded="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['license'])" "$RECORD")"
if [ "$recorded" != "$declared" ]; then
    fail "SOURCE.json records '$recorded' but the data declares '$declared'"
fi
printf '  SOURCE.json:    agrees\n'

# 3. The attribution quoted for end users.
if ! grep -qF "$version" "$README"; then
    fail "the attribution in README.md does not mention version $version" \
         "${README#"$REPO_ROOT"/}"
fi
# And must not still claim a different version. Written with explicit `if`
# rather than `grep ... && fail`: under `set -e` a failing && list is the last
# command in the loop body, and bash versions disagree about whether that
# aborts the script.
for other in 1.0 2.0 2.5 3.0 4.0; do
    if [ "$other" != "$version" ]; then
        if grep -qE "Attribution-ShareAlike \*{0,2}$other" "$README"; then
            fail "README.md still quotes version $other; the data declares $version" \
                 "${README#"$REPO_ROOT"/}"
        fi
    fi
done
printf '  README.md:      agrees\n'

# 4. The committed legalcode must be the licence the data is actually under.
if ! grep -qE "Attribution-ShareAlike $version" "$LEGALCODE"; then
    fail "the committed legalcode is not Attribution-ShareAlike $version" \
         "${LEGALCODE#"$REPO_ROOT"/}"
fi
printf '  LICENSE:        agrees\n'

# The required attribution fields, which CC BY-SA obliges us to carry.
for field in "Creator:" "Source:" "License:" "Changes made:"; do
    if ! grep -qF "$field" "$README"; then
        fail "the attribution is missing the '$field' field" "${README#"$REPO_ROOT"/}"
    fi
done
printf '  attribution:    complete\n'
