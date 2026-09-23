#!/usr/bin/env zsh
# Masking: the echo/env/printenv wrappers print **** for managed
# secrets, `command …` bypasses them, and KSM_MASK=0 disables them
# entirely.

set -e
emulate -L zsh
setopt err_return no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
KSM_LIB="$SCRIPT_DIR/../ksm.zsh"

assert() {
  local got="${1:-}" want="${2:-}" msg="${3:-assert}"
  [[ "$got" == "$want" ]] || { print -u2 "FAIL: $msg — got '$got', want '$want'"; exit 1; }
}

print "sourcing with stored keys exports them and installs the wrappers"
printf 'GITHUB_TOKEN\nOPENAI_API_KEY\n' > "$FAKE_KC_FILE"
printf 'GITHUB_TOKEN\ttester\tghp_secret123\nOPENAI_API_KEY\ttester\tsk_secret456\n' > "$FAKE_KC_VALS"
touch "$KSM_KEYCHAIN_FILE"
unset GITHUB_TOKEN OPENAI_API_KEY
source "$KSM_LIB"
assert "${GITHUB_TOKEN:-}" "ghp_secret123" "\$GITHUB_TOKEN exported at source time"
assert "${OPENAI_API_KEY:-}" "sk_secret456" "\$OPENAI_API_KEY exported at source time"
(( $+functions[echo] )) || { print -u2 "FAIL: echo wrapper not installed"; exit 1 }
(( $+functions[env] )) || { print -u2 "FAIL: env wrapper not installed"; exit 1 }
(( $+functions[printenv] )) || { print -u2 "FAIL: printenv wrapper not installed"; exit 1 }

print "echo masks a secret embedded in a larger string"
out=$(echo "prefix $GITHUB_TOKEN suffix")
assert "$out" "prefix **** suffix" "inline secret masked"

print "echo masks a bare secret"
out=$(echo $GITHUB_TOKEN)
assert "$out" "****" "bare secret masked"

print "echo leaves unrelated text alone"
out=$(echo hello)
assert "$out" "hello" "plain text untouched"

print "env masks managed vars, leaves non-managed vars raw"
export PLAIN_VAR=plainvalue
out="$(env | grep '^GITHUB_TOKEN=' || true)"
assert "$out" "GITHUB_TOKEN=****" "env line masked"
out="$(env | grep '^OPENAI_API_KEY=' || true)"
assert "$out" "OPENAI_API_KEY=****" "second env line masked"
out="$(env | grep '^PLAIN_VAR=' || true)"
assert "$out" "PLAIN_VAR=plainvalue" "non-managed var still raw"

print "env passes arguments through to the real env"
out="$(env PLAIN2=1 command printenv PLAIN2)"
assert "$out" "1" "env VAR=x command passthrough"

print "printenv masks managed keys"
out=$(printenv GITHUB_TOKEN)
assert "$out" "****" "printenv NAME masked"
out=$(printenv)
[[ "$out" == *"GITHUB_TOKEN=****"* ]] || { print -u2 "FAIL: bare printenv missing masked line"; exit 1 }

print "command bypasses the wrappers"
out=$(command echo $GITHUB_TOKEN)
assert "$out" "ghp_secret123" "command echo prints the raw value"

print "KSM_MASK=0 installs no wrappers at all"
out="$(KSM_MASK=0 zsh -c 'source "$1"; echo "$GITHUB_TOKEN"' _ "$KSM_LIB")"
assert "$out" "ghp_secret123" "KSM_MASK=0: echo prints the raw value"
out="$(KSM_MASK=0 zsh -c 'source "$1"; (( $+functions[echo] )) && print yes || print no' _ "$KSM_LIB")"
assert "$out" "no" "KSM_MASK=0: echo is not a function"

print "keys stored after source are masked too"
ksm set LATER_KEY later-secret-val >/dev/null
out=$(echo "x$LATER_KEY")
assert "$out" "x****" "later key masked in echo"
out=$(printenv LATER_KEY)
assert "$out" "****" "later key masked in printenv"

print "ALL OK"
