#!/usr/bin/env bash
# undelivered-benclose-edges.sh — the 5.4 file predicate on the shapes
# init-delivery-54 does not cover: CRLF line endings, trailing
# whitespace after the verdict, a DIRECTORY at .wave/ben-close.md, and an
# unreadable file.
#
# Decision: a verdict line with trailing whitespace (or a trailing CR) does
# NOT match, exactly as the BEN-CLOSE stop marker would not — both read the
# same anchored ERE, ^BENEFIT: (DELIVERED|UNDELIVERED)$, with no stripping.
# So for those shapes this case asserts BOTH sides agree: the close-time
# verdict is `unverified` AND a BEN-CLOSE closing-role stop against the same
# file is refused W-MARKER. A well-formed file is the control on both sides.
# A directory and an unreadable file are never a verdict either (unverified);
# the unreadable leg is skipped, with a visible SKIP line, when this runs as
# root (root reads a mode-000 file).
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/lib/stop.sh"

ALWAYS="AC ACB TDE-RED TDE-GREEN BC SEA DS BSEA OA TEET-TC TEET BTEET BTEET-X VB COMMIT CL CCP"
done_map() {
  printf '%s\n' $ALWAYS BEN | jq -R . | jq -s 'map({(.): {status:"done", at:"2026-09-09T12:10:00Z", agent:"a0"}}) | add'
}

verdict_for() {
  # verdict_for <label> <writer function> -> GOT_DELIVERY from a bare close.
  local label="$1" writer="$2"
  WV_PROJECT="$(mkproj)"
  : > "$WV_PROJECT/README.md"
  git -C "$WV_PROJECT" add README.md
  git -C "$WV_PROJECT" commit -q -m init
  run_cli scripts/wave-init.sh --wave 1 --mode full --feature x --force
  [ "$CLI_EXIT" = "0" ] || { fail "$label init: exit $CLI_EXIT"; return 1; }
  jq --argjson ph "$(done_map)" '.behaviour_change = true | .phases = $ph' \
    "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
    && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
  "$writer" "$WV_PROJECT/.wave/ben-close.md"
  run_cli scripts/wave-close.sh
  [ "$CLI_EXIT" = "0" ] || fail "$label close: exit $CLI_EXIT, stderr: $CLI_STDERR"
  GOT_DELIVERY="$(jq -r '.delivery // empty' "$WV_PROJECT/.wave/state.json")"
  chmod -R u+rwx "$WV_PROJECT/.wave" 2>/dev/null
}

marker_for() {
  # marker_for <label> <file contents, printf %b> -> runs BEN-CLOSE's closing
  # role (reviewer) stop against that ben-close.md.
  local label="$1" body="$2"
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-state.json" c="$WV_RUN_TMP/$name.json"
  stop_state "$st" ".behaviour_change = true | .phases = $(done_map) | .active = {a1: $(stop_active BEN-CLOSE reviewer opus)}" || return 1
  stop_case "$c" "$(jq -nc --arg st "$st" --arg b "$(printf '%b' "$body")" '{st: $st, b: $b}' | jq -r '"(.seed.state = " + (.st | tojson) + " | .seed.files = {\".wave/ben-close.md\": " + (.b | tojson) + "})"')" || return 1
  run_hook subagent-stop.sh "$c" || fail "$label marker: run_hook: $WV_LAST_STDERR"
}

w_crlf()  { printf 'BENEFIT: DELIVERED\r\nreasons\r\n' > "$1"; }
w_space() { printf 'BENEFIT: DELIVERED \nreasons\n' > "$1"; }
w_good()  { printf 'BENEFIT: DELIVERED\nreasons\n' > "$1"; }
w_dir()   { mkdir -p "$1"; printf 'BENEFIT: DELIVERED\n' > "$1/inner.md"; }
w_unread() { printf 'BENEFIT: DELIVERED\n' > "$1"; chmod 000 "$1"; }

# Control: well-formed on both sides.
verdict_for good w_good
[ "$GOT_DELIVERY" = "delivered" ] || fail "control: well-formed verdict line reads '$GOT_DELIVERY', want delivered"
marker_for good 'BENEFIT: DELIVERED\nreasons\n'
assert_allow || fail "control: a well-formed BEN-CLOSE must not be blocked, got '$WV_LAST_STDOUT'"
assert_state '.phases["BEN-CLOSE"].status == "done"' || fail "control: BEN-CLOSE must be recorded done"

# CRLF: no match on either side.
verdict_for crlf w_crlf
[ "$GOT_DELIVERY" = "unverified" ] || fail "CRLF: verdict reads '$GOT_DELIVERY', want unverified"
marker_for crlf 'BENEFIT: DELIVERED\r\nreasons\r\n'
assert_block W-MARKER || fail "CRLF: the BEN-CLOSE stop marker must also reject the line (both read one ERE)"

# Trailing whitespace: no match on either side.
verdict_for space w_space
[ "$GOT_DELIVERY" = "unverified" ] || fail "trailing space: verdict reads '$GOT_DELIVERY', want unverified"
marker_for space 'BENEFIT: DELIVERED \nreasons\n'
assert_block W-MARKER || fail "trailing space: the BEN-CLOSE stop marker must also reject the line"

# A directory at the path is not a verdict.
verdict_for dir w_dir
[ "$GOT_DELIVERY" = "unverified" ] || fail "directory: verdict reads '$GOT_DELIVERY', want unverified"

# An unreadable file is not a verdict.
if [ "$(id -u)" = "0" ]; then
  printf 'SKIP %s: unreadable-file leg (running as root, which reads a mode-000 file)\n' "$name" | tee -a "$log"
else
  verdict_for unreadable w_unread
  [ "$GOT_DELIVERY" = "unverified" ] || fail "unreadable: verdict reads '$GOT_DELIVERY', want unverified"
fi

exit $rc
