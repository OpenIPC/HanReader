#!/usr/bin/env bash
#
# Install the pinned developer tooling listed in Scripts/tools.lock into
# .tools/, verifying each download's SHA-256 before extracting it.
#
# The point of this script is that `git clone && make run` works for someone who
# has nothing but Xcode installed. No Homebrew, no Mint, no source builds, and
# no dependence on whatever versions happen to be on their PATH.
#
# Idempotent: a tool whose recorded version is already installed is skipped, so
# re-running costs nothing.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LOCK_FILE="$REPO_ROOT/Scripts/tools.lock"
readonly TOOLS_DIR="$REPO_ROOT/.tools"
readonly BIN_DIR="$TOOLS_DIR/bin"
readonly STAMP_DIR="$TOOLS_DIR/.stamps"

log()  { printf '  %s\n' "$*"; }
warn() { printf '  warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------

[ -f "$LOCK_FILE" ] || die "missing $LOCK_FILE"

if [ "$(uname -s)" != "Darwin" ]; then
    # The pinned archives are macOS builds. The Linux CI job needs none of them,
    # so this is a clean skip rather than a failure.
    log "not macOS — skipping macOS-only developer tooling"
    exit 0
fi

sha256() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else die "neither shasum nor sha256sum is available"
    fi
}

mkdir -p "$BIN_DIR" "$STAMP_DIR"

# --- install one tool --------------------------------------------------------

install_tool() {
    local name="$1" version="$2" layout="$3" url="$4" want_sha="$5"
    local stamp="$STAMP_DIR/$name-$version"

    if [ -f "$stamp" ] && [ -x "$BIN_DIR/$name" ]; then
        log "$name $version already installed"
        return 0
    fi

    log "installing $name $version"

    local tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand tmp now, deliberately
    trap "rm -rf '$tmp'" RETURN

    local archive="$tmp/download.zip"
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --output "$archive" "$url" \
        || die "failed to download $name from $url"

    # Verify before extracting. Unpacking an unverified archive and checking
    # afterwards would already have written attacker-controlled paths to disk.
    local got_sha
    got_sha="$(sha256 "$archive")"
    if [ "$got_sha" != "$want_sha" ]; then
        die "$name checksum mismatch — refusing to install
  expected: $want_sha
  actual:   $got_sha
  url:      $url
If you intentionally bumped the version, update the checksum in Scripts/tools.lock."
    fi

    unzip -q -o "$archive" -d "$tmp/extracted" || die "failed to unpack $name"

    case "$layout" in
        flat)
            # Binary sits at the archive root.
            local found
            found="$(find "$tmp/extracted" -maxdepth 2 -type f -name "$name" -perm -u+x | awk 'NR==1')"
            [ -n "$found" ] || found="$(find "$tmp/extracted" -maxdepth 2 -type f -name "$name" | awk 'NR==1')"
            [ -n "$found" ] || die "$name: no binary named '$name' inside the archive"
            install -m 0755 "$found" "$BIN_DIR/$name"
            ;;
        tree)
            # The directory must be kept intact: the binary resolves resources
            # relative to its own location. XcodeGen needs
            # share/xcodegen/SettingPresets as a sibling of bin/.
            local root
            root="$(find "$tmp/extracted" -maxdepth 1 -mindepth 1 -type d | awk 'NR==1')"
            [ -n "$root" ] || die "$name: expected a directory inside the archive"
            rm -rf "$TOOLS_DIR/$name"
            mkdir -p "$TOOLS_DIR/$name"
            cp -R "$root/." "$TOOLS_DIR/$name/"
            local binary="$TOOLS_DIR/$name/bin/$name"
            [ -f "$binary" ] || die "$name: no bin/$name inside the extracted tree"
            chmod +x "$binary"
            # Relative symlink so .tools stays relocatable.
            ln -sf "../$name/bin/$name" "$BIN_DIR/$name"
            ;;
        *)
            die "$name: unknown layout '$layout' in tools.lock (expected flat or tree)"
            ;;
    esac

    # Gatekeeper quarantines downloaded binaries, which would make every tool
    # invocation fail with a dialog. Strip it; we verified the checksum above.
    xattr -d com.apple.quarantine "$BIN_DIR/$name" 2>/dev/null || true
    if [ "$layout" = "tree" ]; then
        xattr -rd com.apple.quarantine "$TOOLS_DIR/$name" 2>/dev/null || true
    fi

    "$BIN_DIR/$name" --version >/dev/null 2>&1 \
        || warn "$name installed but did not respond to --version"

    rm -f "$STAMP_DIR/$name-"*
    touch "$stamp"
}

# --- read the lock file ------------------------------------------------------

printf 'Bootstrapping developer tooling into .tools/\n'

while read -r name version layout url sha || [ -n "${name:-}" ]; do
    case "${name:-}" in
        ''|'#'*) continue ;;
    esac
    [ -n "$sha" ] || die "malformed line in tools.lock for '$name' (expected 5 fields)"
    install_tool "$name" "$version" "$layout" "$url" "$sha"
done < "$LOCK_FILE"

# --- advisory checks ---------------------------------------------------------

if [ -f "$REPO_ROOT/.xcode-version" ]; then
    pinned="$(tr -d '[:space:]' < "$REPO_ROOT/.xcode-version")"
    if command -v xcodebuild >/dev/null 2>&1; then
        # One awk pass, consuming all input: piping to `head` would close the
        # pipe early, and under `set -o pipefail` the resulting SIGPIPE (141)
        # would kill the script via `set -e`.
        actual="$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}')"
        case "$actual" in
            "$pinned"*)
                ;;
            *)
                # Informational, not a problem. .xcode-version is the toolchain
                # CI builds with, so it is the version a failure will be
                # reproduced against; a newer local Xcode is normally fine and
                # is what most contributors will have.
                log "note: local Xcode is $actual; CI builds with $pinned (see .xcode-version)"
                ;;
        esac
    else
        warn "xcodebuild not found — install Xcode $pinned or newer to build the apps"
    fi
fi

# Surface the missing iOS runtime now rather than as an opaque xcodebuild
# "Unable to find a destination" error during `make run-ios`. Xcode ships the
# iOS SDK but not its simulator runtimes, and the download is around 10 GB.
if command -v xcrun >/dev/null 2>&1; then
    # Captured rather than piped into `grep -q`: an early-exiting grep would
    # SIGPIPE simctl, and pipefail would turn that into a spurious "no runtime"
    # warning on machines that do have one.
    runtimes="$(xcrun simctl list runtimes 2>/dev/null || true)"
    if ! printf '%s\n' "$runtimes" | grep -q "^iOS "; then
        warn "no iOS simulator runtime installed — \`make run-ios\` will fail.
           Install one with:  xcodebuild -downloadPlatform iOS   (~10 GB)
           Not needed if you are only working on macOS."
    fi
fi

printf 'Done. Tools are in .tools/bin (not on your PATH; the Makefile uses them directly).\n'
