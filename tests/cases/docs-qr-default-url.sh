#!/usr/bin/env bash
# tests/cases/docs-qr-default-url.sh — scripts/qr.html pre-fills the repository
# URL a QR code points at. Its default must be the repository the marketplace
# entry installs from (.claude-plugin/marketplace.json source url, without
# `.git`), so a code made with the default reaches this project.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN scripts/qr.html %s exit=0\n' "$name" >> "$log"

want="$(jq -r '[.. | objects | .url? // empty | select(test("^https://github.com/"))][0] // empty' "$WV_REPO_ROOT/.claude-plugin/marketplace.json")"
want="${want%.git}"
[ -n "$want" ] || fail "marketplace.json names no github source url"
got="$(command grep -oE 'value="https://github.com/[^"]+"' "$WV_REPO_ROOT/scripts/qr.html" | head -1)"
got="${got#value=\"}"; got="${got%\"}"
[ -n "$got" ] || fail "scripts/qr.html has no github default value"
[ "$got" = "$want" ] || fail "scripts/qr.html defaults to '$got', the marketplace installs from '$want'"

exit $rc
