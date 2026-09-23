#!/usr/bin/env zsh
# KSM_KEYCHAIN is a name; the file is always derived under
# ~/Library/Keychains/<name>.keychain-db. Invalid names fall back to
# 'ksm' with a warning.

set -e
emulate -L zsh
setopt err_return no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
KSM_LIB="$SCRIPT_DIR/../ksm.zsh"

assert() {
  local got="${1:-}" want="${2:-}" msg="${3:-assert}"
  [[ "$got" == "$want" ]] || { print -u2 "FAIL: $msg — got '$got', want '$want'"; exit 1; }
}

print "a custom name reads from its derived file"
mkdir -p "$HOME/Library/Keychains"
printf 'CFG_KEY\n' > "$FAKE_KC_FILE"
printf 'CFG_KEY\ttester\tcfg-secret\n' > "$FAKE_KC_VALS"
: > "$HOME/Library/Keychains/cfgprobe.keychain-db"
out="$(KSM_KEYCHAIN=cfgprobe zsh -f -c 'source "$1"; print -r -- "${CFG_KEY:-<unset>}"' _ "$KSM_LIB")"
assert "$out" "cfg-secret" "auto-cache reads ~/Library/Keychains/cfgprobe.keychain-db"

print "the default name derives to ~/Library/Keychains/ksm.keychain-db"
out="$(zsh -f -c 'unset KSM_KEYCHAIN KSM_KEYCHAIN_FILE; source "$1"; print -r -- "$KSM_KEYCHAIN_FILE"' _ "$KSM_LIB")"
assert "$out" "$HOME/Library/Keychains/ksm.keychain-db" "default derived path"

print "an invalid name falls back to ksm with a warning"
out="$(KSM_KEYCHAIN=../evil zsh -f -c 'source "$1"; print -r -- "$KSM_KEYCHAIN_FILE"' _ "$KSM_LIB" 2>/dev/null)"
assert "$out" "$HOME/Library/Keychains/ksm.keychain-db" "path-like value rejected, fell back"
warn="$(KSM_KEYCHAIN=../evil zsh -f -c 'source "$1"' _ "$KSM_LIB" 2>&1 >/dev/null)"
[[ "$warn" == *"using 'ksm'"* ]] || { print -u2 "FAIL: no fallback warning on stderr"; exit 1; }

print "ALL OK"
