#!/usr/bin/env zsh
# Basic round-trip tests for ksm.zsh. No ksm get / ksm reveal. The only
# "lazy load" path is `ksm cache NAME`, which silently fetches and
# exports. Tests verify that `$NAME` works after the appropriate call.

set -e
emulate -L zsh
setopt err_return no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
KSM_LIB="$SCRIPT_DIR/../ksm.zsh"

# Start from an empty keychain regardless of test order.
: > "$FAKE_KC_FILE"
: > "$FAKE_KC_VALS"
source "$KSM_LIB"

# Use `${var:-default}` (with colon) everywhere — under zsh NO_UNSET,
# only the colon form is safe when the var may be unset.
assert() {
  local got="${1:-}" want="${2:-}" msg="${3:-assert}"
  [[ "$got" == "$want" ]] || { print -u2 "FAIL: $msg — got '$got', want '$want'"; exit 1; }
}

print "ksm set round-trips"
ksm set ALPHA aaa >/dev/null
ksm set BETA bbb >/dev/null
ksm cache ALPHA BETA >/dev/null
assert "${ALPHA:-}" "aaa" "\$ALPHA after ksm cache"
assert "${BETA:-}"  "bbb" "\$BETA after ksm cache"

print "ksm set updates existing (-U)"
ksm set ALPHA aaa2 >/dev/null
assert "${ALPHA:-}" "aaa2" "\$ALPHA updated in shell immediately"
unset ALPHA
ksm cache ALPHA
assert "${ALPHA:-}" "aaa2" "\$ALPHA re-fetched with updated value"

print "ksm set exports to current shell immediately (no need to ksm cache)"
ksm set IMMEDIATE 'quick' >/dev/null
assert "${IMMEDIATE:-}" "quick" "\$IMMEDIATE after ksm set"

print "ksm set reads VALUE from stdin when piped"
print -r -- 'piped-secret' | ksm set PIPED >/dev/null
assert "${PIPED:-}" "piped-secret" "\$PIPED set from piped stdin"

print "ksm set rejects empty values"
unset EMPTY
if ksm set EMPTY "" >/dev/null 2>&1; then
  print -u2 "FAIL: ksm set accepted an empty value"; exit 1
fi
assert "${EMPTY:-<unset>}" "<unset>" "\$EMPTY stays unset"

print "ksm set normalizes NAME to uppercase"
ksm set lower_key lk-value-1234 >/dev/null
assert "${LOWER_KEY:-}" "lk-value-1234" "\$LOWER_KEY set (name uppercased)"
assert "${lower_key:-<unset>}" "<unset>" "no lowercase \$lower_key variable"

print "ksm cache is silent (no output)"
out=$(ksm cache ALPHA)
assert "${out:-}" "" "ksm cache should print nothing"

print "ksm cache re-fetches in the calling shell (no subshell)"
unset BETA
ksm set BETA 'cached-value' >/dev/null
unset BETA   # now BETA is genuinely unset
ksm cache BETA
assert "${BETA:-}" "cached-value" "\$BETA restored by ksm cache"

print "ksm cache silently leaves unset vars unset"
unset GHOST
ksm cache GHOST
assert "${GHOST:-<unset>}" "<unset>" "\$GHOST still unset"

print "ksm rm deletes from Keychain"
ksm rm ALPHA >/dev/null
unset ALPHA
ksm cache ALPHA
assert "${ALPHA:-<unset>}" "<unset>" "\$ALPHA still unset after ksm rm + ksm cache"

print "ksm rm unsets the variable in current shell"
ksm set ZED zed-value >/dev/null
assert "${ZED:-}" "zed-value" "\$ZED set"
ksm rm ZED >/dev/null
assert "${ZED:-<unset>}" "<unset>" "\$ZED unset after ksm rm"

print "ksm ls prints masked previews, never raw values"
ksm set LSKEY abcdef-value >/dev/null
ksm set SHORTKEY abc >/dev/null
out=$(ksm ls)
line="$(print -r -- "$out" | grep '^LSKEY' || true)"
assert "$line" "LSKEY"$'\t'"ab****" "preview shows first two chars + ****"
line="$(print -r -- "$out" | grep '^SHORTKEY' || true)"
assert "$line" "SHORTKEY"$'\t'"****" "value shorter than 4 chars shows bare ****"
if print -r -- "$out" | grep -qF 'abcdef-value'; then
  print -u2 "FAIL: ksm ls leaked the raw value"; exit 1
fi

print "ksm rand prints hex secrets of the requested length"
out=$(ksm rand)
assert "${#out}" "32" "default length is 32"
assert "${out//[0-9a-f]/}" "" "rand output is hex"
out=$(ksm rand 16)
assert "${#out}" "16" "custom length is 16"
assert "${out//[0-9a-f]/}" "" "rand output is hex"

print "ksm cp copies the exact value to the clipboard"
: > "$FAKE_CLIP"
ksm set CPKEY exact-value-99 >/dev/null
out=$(ksm cp CPKEY)
assert "$out" "✓ CPKEY copied" "ksm cp prints confirmation"
assert "$(cat "$FAKE_CLIP")" "exact-value-99" "FAKE_CLIP holds the exact value"

print "ALL OK"
