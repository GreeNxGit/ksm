#!/usr/bin/env bash
# tests/run.sh — bash driver that stubs `security` and `pbcopy` so the
# zsh tests can run against a fake Keychain without touching the host.
#
# Usage:
#   tests/run.sh                 # run all tests/test_*.zsh
#   tests/run.sh tests/test_x.zsh  # run one file

set -eu
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Stub bin dir
STUB="$(mktemp -d -t ksm-test.XXXXXX)"
trap 'rm -rf "$STUB"' EXIT

cat > "$STUB/security" <<'STUB'
#!/usr/bin/env bash
# Fake `security(1)` for tests. Backed by FAKE_KC_FILE (one service per line)
# and FAKE_KC_VALS (`SERVICE<TAB>ACCOUNT<TAB>VALUE` rows).
set -eu
kc="${FAKE_KC_FILE:?}"; vals="${FAKE_KC_VALS:?}"
cmd="${1:-}"; shift || true
case "$cmd" in
  add-generic-password)
    svc=""; acct=""; val=""; update=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) svc="$2"; shift ;;
        -a) acct="$2"; shift ;;
        -w) val="$2"; shift ;;
        -U) update=1 ;;
        -T) shift ;;      # ignore -T path
        -A) shift ;;      # ignore -A (allow-all) flag
      esac; shift || true
    done
    if grep -Fxq "$svc" "$kc"; then
      if [ "$update" = 1 ]; then
        awk -F'\t' -v s="$svc" '$1 != s' "$vals" > "$vals.tmp"
        printf '%s\t%s\t%s\n' "$svc" "$acct" "$val" >> "$vals.tmp"
        mv "$vals.tmp" "$vals"
      else
        echo "duplicate" >&2; exit 1
      fi
    else
      printf '%s\n' "$svc" >> "$kc"
      printf '%s\t%s\t%s\n' "$svc" "$acct" "$val" >> "$vals"
    fi
    ;;
  find-generic-password)
    show_pw=0; svc=""
    while [ $# -gt 0 ]; do
      case "$1" in -w) show_pw=1 ;; -s) svc="$2"; shift ;; -a) shift ;; esac; shift || true
    done
    val="$(awk -F'\t' -v s="$svc" '$1==s { print $3; exit }' "$vals" 2>/dev/null || true)"
    [ -n "$val" ] || exit 44
    [ "$show_pw" = 1 ] && printf '%s' "$val"
    ;;
  delete-generic-password)
    svc=""
    while [ $# -gt 0 ]; do case "$1" in -s) svc="$2"; shift ;; -a) shift ;; esac; shift || true; done
    if ! grep -Fxq "$svc" "$kc"; then exit 44; fi
    grep -Fxv "$svc" "$kc" > "$kc.tmp" || true; mv "$kc.tmp" "$kc"
    awk -F'\t' -v s="$svc" '$1 != s' "$vals" > "$vals.tmp"; mv "$vals.tmp" "$vals"
    ;;
  create-keychain) ;;                    # no-op: the harness touches the fake keychain file
  unlock-keychain) ;;                    # no-op: the stub keychain is never locked
  dump-keychain)
    # Emit one "svce" attribute line per stored service, like the real
    # dump-keychain does for generic passwords (names only, never values).
    while IFS= read -r svc; do
      printf '    "svce"<blob>="%s"\n' "$svc"
    done < "$kc"
    ;;
  *) echo "stub: unsupported $cmd" >&2; exit 2 ;;
esac
STUB
chmod +x "$STUB/security"

cat > "$STUB/pbcopy" <<'STUB'
#!/usr/bin/env bash
# Fake `pbcopy(1)` for tests: appends stdin to FAKE_CLIP.
set -eu
cat >> "${FAKE_CLIP:?}"
STUB
chmod +x "$STUB/pbcopy"

# Per-run scratch
FAKE_KC_FILE="$(mktemp -t ksm-keys.XXXXXX)"
FAKE_KC_VALS="$(mktemp -t ksm-vals.XXXXXX)"
FAKE_CLIP="$(mktemp -t ksm-clip.XXXXXX)"
TMPHOME="$(mktemp -d -t ksm-home.XXXXXX)"
trap 'rm -rf "$STUB" "$TMPHOME" "$FAKE_KC_FILE" "$FAKE_KC_VALS" "$FAKE_CLIP"' EXIT
export FAKE_KC_FILE FAKE_KC_VALS FAKE_CLIP
export PATH="$STUB:$PATH"
export HOME="$TMPHOME"  # ksm doctor uses $HOME
export KSM_KEYCHAIN="ksmtest"
KSM_KEYCHAIN_FILE="$TMPHOME/Library/Keychains/$KSM_KEYCHAIN.keychain-db"
mkdir -p "$(dirname "$KSM_KEYCHAIN_FILE")"
: > "$KSM_KEYCHAIN_FILE"  # _ksm::keys guards on this file existing
export KSM_KEYCHAIN_FILE
export KSM_ACCOUNT="tester"

# Pick tests
if [ $# -gt 0 ]; then
  tests=("$@")
else
  tests=("$REPO_ROOT"/tests/test_*.zsh)
fi

pass=0; fail=0
# Export STUB + other test-only vars so zsh subshells can see them.
export STUB FAKE_KC_FILE FAKE_KC_VALS FAKE_CLIP TMPHOME KSM_KEYCHAIN KSM_KEYCHAIN_FILE KSM_ACCOUNT PATH
for t in "${tests[@]}"; do
  printf '\n=== %s ===\n' "$(basename "$t")"
  if zsh "$t"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
