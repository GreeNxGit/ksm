#!/usr/bin/env zsh
# Auto-cache: sourcing the library warm-exports every stored key, so no
# manual `ksm cache` call is needed. KSM_AUTO_CACHE=0 restores manual-only.

set -e
emulate -L zsh
setopt err_return no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
KSM_LIB="$SCRIPT_DIR/../ksm.zsh"

assert() {
  local got="${1:-}" want="${2:-}" msg="${3:-assert}"
  [[ "$got" == "$want" ]] || { print -u2 "FAIL: $msg — got '$got', want '$want'"; exit 1; }
}

print "sourcing auto-caches every stored key"
printf 'GITHUB_TOKEN\nOPENAI_API_KEY\n' > "$FAKE_KC_FILE"
printf 'GITHUB_TOKEN\ttester\tghp_secret\nOPENAI_API_KEY\ttester\tsk_secret\n' > "$FAKE_KC_VALS"
touch "$KSM_KEYCHAIN_FILE"
unset GITHUB_TOKEN OPENAI_API_KEY
source "$KSM_LIB"
assert "${GITHUB_TOKEN:-}" "ghp_secret" "\$GITHUB_TOKEN exported at source time"
assert "${OPENAI_API_KEY:-}" "sk_secret" "\$OPENAI_API_KEY exported at source time"

print "KSM_AUTO_CACHE=0 keeps shells manual"
(
  export KSM_AUTO_CACHE=0
  unset GITHUB_TOKEN OPENAI_API_KEY
  source "$KSM_LIB"
  assert "${GITHUB_TOKEN:-<unset>}" "<unset>" "no auto-cache with KSM_AUTO_CACHE=0"
  assert "${OPENAI_API_KEY:-<unset>}" "<unset>" "no auto-cache with KSM_AUTO_CACHE=0"
)

print "empty keychain: source is a silent no-op"
: > "$FAKE_KC_FILE"
: > "$FAKE_KC_VALS"
unset GITHUB_TOKEN OPENAI_API_KEY
source "$KSM_LIB"
assert "${GITHUB_TOKEN:-<unset>}" "<unset>" "nothing exported from an empty keychain"

print "ksm rm wins over auto-cache on re-source"
printf 'GONE_KEY\n' > "$FAKE_KC_FILE"
printf 'GONE_KEY\ttester\tbye\n' > "$FAKE_KC_VALS"
source "$KSM_LIB"
assert "${GONE_KEY:-}" "bye" "\$GONE_KEY exported at source time"
ksm rm GONE_KEY >/dev/null
source "$KSM_LIB"
assert "${GONE_KEY:-<unset>}" "<unset>" "deleted key stays unset after re-source"

print "ALL OK"
