#!/usr/bin/env zsh
# ksm.zsh — store / load env-var secrets in the macOS Keychain, masked
# in the shell.
#
# Mental model:
#   - The Keychain is the only source of truth for secret *values*.
#   - The shell's env is a cache: populated automatically at shell start
#     and on demand by `ksm cache` and on store by `ksm set`.
#   - Masking (echo / env / printenv print ****) is a convenience guard
#     against shoulder-surfing and scrollback leaks, NOT a security
#     boundary. `command echo $KEY` bypasses it.
#   - The keychain file is always ~/Library/Keychains/<name>.keychain-db, name set by KSM_KEYCHAIN, default ksm.
#
# Public commands (one entry point):
#   ksm set NAME [VALUE]   store + export to current shell
#   ksm cache NAME ...     manual re-fetch + cache, silently (no print)
#   ksm rm NAME            delete from Keychain + unset in shell
#   ksm ls                 list managed keys (masked previews only)
#   ksm cp NAME            copy a secret to the clipboard
#   ksm rand [size]        print a random hex secret
#   ksm doctor             check install
#
# There is intentionally NO `ksm get` / `ksm reveal` that prints a raw
# secret to stdout. Lazy loading = call `ksm cache NAME` and read the
# value via `command echo $NAME` (or `${NAME}`); use `ksm cp NAME` for
# the clipboard.
#
# Source from ~/.zshrc — no `ksm load` needed; sourcing auto-caches
# all stored keys (disable with KSM_AUTO_CACHE=0) and installs the
# echo/env/printenv mask wrappers (disable with KSM_MASK=0):
#   source ~/.ksm/ksm.zsh
#
# Strict-mode note: each function opts into `err_return no_unset
# pipe_fail` locally via `emulate -LR zsh; setopt …`. We do NOT set
# those at top level — that would leak into the user's interactive
# shell and break their $VAR references.

# ---- config -------------------------------------------------------------

# Resolve KSM_HOME next to this script unless already set.
if [[ -z "${KSM_HOME:-}" ]]; then
  KSM_HOME="${0:A:h}"
fi
[[ -d "$KSM_HOME" ]] || KSM_HOME="${HOME}/.ksm"

KSM_ACCOUNT="${KSM_ACCOUNT:-$(whoami)}"
# KSM_KEYCHAIN is a NAME, never a path. The keychain file always lives
# in ~/Library/Keychains/<name>.keychain-db (macOS convention). Every
# security call below targets that derived path explicitly — passing a
# bare name to `security` would create <name>-db instead.
KSM_KEYCHAIN="${KSM_KEYCHAIN:-ksm}"
if [[ ! "$KSM_KEYCHAIN" =~ '^[A-Za-z0-9_-]+$' ]]; then
  print -u2 "ksm: KSM_KEYCHAIN must be a name (letters, digits, - or _), not a path — using 'ksm'"
  KSM_KEYCHAIN="ksm"
fi
KSM_KEYCHAIN_FILE="${HOME}/Library/Keychains/${KSM_KEYCHAIN}.keychain-db"

# Session registry of managed key names. Populated at source time from
# the keychain and extended by `ksm set`; drives the mask wrappers and
# `ksm ls`.
typeset -ga _ksm_keys
_ksm_keys=()

# ---- private helpers ----------------------------------------------------

# Create the dedicated keychain once. Idempotent. Empty password + long
# timeout = no unlock prompts. Every `security` call targets this file
# explicitly.
_ksm::ensure_keychain() {
  emulate -LR zsh
  if [[ ! -f "$KSM_KEYCHAIN_FILE" ]]; then
    command mkdir -p "${KSM_KEYCHAIN_FILE:h}"
    command security create-keychain -p "" "$KSM_KEYCHAIN_FILE" 2>/dev/null
    command security set-keychain-settings -lut 86400 "$KSM_KEYCHAIN_FILE" 2>/dev/null
    command security unlock-keychain -p "" "$KSM_KEYCHAIN_FILE" 2>/dev/null
  fi
  return 0
}

# Read a secret from the keychain. Empty on miss. Internal.
_ksm::fetch() {
  emulate -LR zsh
  setopt err_return no_unset pipe_fail
  _ksm::ensure_keychain
  security find-generic-password -w \
    -s "${1:u}" -a "$KSM_ACCOUNT" "$KSM_KEYCHAIN_FILE" 2>/dev/null \
    || true
}

# List stored key names from the keychain (service names, one per line).
# Names only: dump-keychain without -d never prints secret values.
_ksm::keys() {
  emulate -LR zsh
  setopt no_unset pipe_fail
  [[ -f "$KSM_KEYCHAIN_FILE" ]] || return 0
  command security unlock-keychain -p "" "$KSM_KEYCHAIN_FILE" 2>/dev/null
  local line name
  for line in ${(f)"$(command security dump-keychain "$KSM_KEYCHAIN_FILE" 2>/dev/null)"}; do
    [[ "$line" == *'"svce"<blob>="'* ]] || continue
    name="${line##*\"svce\"<blob>=\"}"
    name="${name%%\"*}"
    [[ -n "$name" ]] && print -r -- "$name"
  done
  return 0
}

# Refresh the session registry from the keychain. One dump-keychain
# call. Always succeeds — an unreadable keychain just means no keys.
_ksm::load_registry() {
  emulate -LR zsh
  setopt no_unset pipe_fail
  _ksm_keys=(${(f)"$(_ksm::keys)"})
  return 0
}

# ---- masking ------------------------------------------------------------

# Replace every occurrence of every managed secret value with ****.
# Pure zsh, no subprocess: (b) quotes glob metacharacters so values
# match literally, and the result comes back in $REPLY (zsh idiom) so
# callers avoid a fork per argument. Convenience guard, not a security
# boundary — `command echo $KEY` bypasses it.
_ksm::mask_string() {
  emulate -LR zsh
  setopt no_unset
  local out="$1" key val
  for key in "${_ksm_keys[@]}"; do
    val="${(P)key:-}"
    [[ -n "$val" ]] && out="${out//${(b)val}/****}"
  done
  REPLY="$out"
}

if [[ "${KSM_MASK:-1}" != 0 ]]; then
  echo() {
    if (( ${#_ksm_keys[@]} == 0 )); then
      builtin echo "$@"
      return
    fi
    local arg
    local -a masked
    masked=()
    for arg in "$@"; do
      _ksm::mask_string "$arg"
      masked+=("$REPLY")
    done
    builtin echo "${masked[@]}"
  }

  env() {
    emulate -LR zsh
    setopt no_unset
    if (( $# == 0 )); then
      local -a lines
      local line key
      lines=("${(f)$(command env)}")
      for line in "${lines[@]}"; do
        key="${line%%=*}"
        if [[ -n "${_ksm_keys[(r)${key}]:-}" ]]; then
          print -r -- "$key=****"
        else
          _ksm::mask_string "$line"
          print -r -- "$REPLY"
        fi
      done
    else
      command env "$@"
    fi
  }

  printenv() {
    emulate -LR zsh
    setopt no_unset
    if (( $# == 0 )); then
      env
      return
    fi
    local key
    for key in "$@"; do
      if [[ -n "${_ksm_keys[(r)${key}]:-}" ]]; then
        print -r -- "****"
      else
        command printenv "$key"
      fi
    done
  }
fi

# ---- public dispatch ----------------------------------------------------

ksm() {
  emulate -LR zsh
  setopt no_unset pipe_fail
  local cmd="${1:-help}"
  (( $# )) && shift
  case "$cmd" in
    set)    _ksm::cmd_set "$@" ;;
    cache)  _ksm::cmd_cache "$@" ;;
    rm)     _ksm::cmd_rm "$@" ;;
    ls)     _ksm::cmd_ls "$@" ;;
    cp)     _ksm::cmd_cp "$@" ;;
    rand)   _ksm::cmd_rand "$@" ;;
    doctor) _ksm::cmd_doctor "$@" ;;
    help|*) _ksm::cmd_help ;;
  esac
}

# ksm set NAME [VALUE] — prompts if VALUE is omitted and stdin is a
# terminal; reads one line from stdin when piped (`ksm rand | ksm set X`,
# `pbpaste | ksm set X`). Stores in Keychain AND exports to the current
# shell so `echo $NAME` works immediately. No `-A` flag (default trust
# is enough; -A rewrites the access list on every update and triggers
# a dialog).
_ksm::cmd_set() {
  emulate -LR zsh
  setopt err_return no_unset pipe_fail
  [[ -n "${1:-}" ]] || { print -u2 "ksm set: usage: ksm set NAME [VALUE]"; return 2; }
  local key="${1:u}" val
  if (( $# >= 2 )); then
    val="$2"
  elif [[ ! -t 0 ]]; then
    IFS= read -r val || true
  else
    print -n "Enter value for $key: "
    read -rs val
    print
  fi
  [[ -n "$val" ]] || { print -u2 "ksm: empty value"; return 1; }
  _ksm::ensure_keychain
  security add-generic-password \
    -s "$key" -a "$KSM_ACCOUNT" -w "$val" -U "$KSM_KEYCHAIN_FILE"
  export "$key=$val"
  if [[ -z "${_ksm_keys[(r)${key}]:-}" ]]; then
    _ksm_keys+=("$key")
  fi
  print "✓ $key stored"
}

# ksm cache NAME [NAME...] — silent fetch + export. No output. This is
# the only way to lazily load a stored secret into the current shell;
# after `ksm cache NAME`, `command echo $NAME` is instant.
#
# Note: each call re-fetches from the Keychain (no in-shell "already
# cached" short-circuit). The cost is ~25ms per call on a warm
# keychain — fine for interactive use, predictable for scripts.
_ksm::cmd_cache() {
  emulate -LR zsh
  setopt no_unset pipe_fail
  # Intentionally NO `err_return` — `[[ -n "" ]]` returns 1 when a key is
  # missing from the keychain, and that's not a failure here. We always
  # exit 0 so callers can safely use `out=$(ksm cache NAME)`.
  local key val
  for key in "$@"; do
    key="${key:u}"
    val=$(_ksm::fetch "$key")
    if [[ -n "$val" ]]; then
      export "$key=$val"
    fi
  done
  return 0
}

# ksm rm NAME — delete from Keychain + unset in current shell.
_ksm::cmd_rm() {
  emulate -LR zsh
  setopt err_return no_unset pipe_fail
  [[ -n "${1:-}" ]] || { print -u2 "ksm rm: usage: ksm rm NAME"; return 2; }
  local key="${1:u}"
  _ksm::ensure_keychain
  security delete-generic-password \
    -s "$key" -a "$KSM_ACCOUNT" "$KSM_KEYCHAIN_FILE" >/dev/null 2>&1 \
    || { print -u2 "ksm: '$1' not found in Keychain"; return 1; }
  unset "$key" 2>/dev/null
  _ksm_keys=("${(@)_ksm_keys[@]:#$key}")
  print "✓ $key deleted"
}

# ksm ls — list managed keys with masked previews: first two chars of
# the value then **** (bare **** if the value is shorter than 4 chars
# or empty). Never prints a raw value.
_ksm::cmd_ls() {
  emulate -LR zsh
  setopt no_unset pipe_fail
  local name val preview
  for name in "${_ksm_keys[@]}"; do
    val="${(P)name:-}"
    [[ -n "$val" ]] || val="$(_ksm::fetch "$name")"
    if (( ${#val} >= 4 )); then
      preview="${val:0:2}****"
    else
      preview="****"
    fi
    print -r -- "$name"$'\t'"$preview"
  done
  return 0
}

# ksm cp NAME — copy a secret to the clipboard via pbcopy.
_ksm::cmd_cp() {
  emulate -LR zsh
  setopt err_return no_unset pipe_fail
  [[ -n "${1:-}" ]] || { print -u2 "ksm cp: usage: ksm cp NAME"; return 2; }
  (( $+commands[pbcopy] )) || { print -u2 "ksm: pbcopy not found"; return 1; }
  local key="${1:u}"
  _ksm::fetch "$key" | command pbcopy
  print "✓ $key copied"
}

# ksm rand [size] — print a random hex secret (default 32 chars).
_ksm::cmd_rand() {
  emulate -LR zsh
  setopt err_return no_unset pipe_fail
  local n="${1:-32}" secret
  secret="$(openssl rand -hex $(( (n + 1) / 2 )))"
  print -r -- "${secret:0:$n}"
}

_ksm::cmd_doctor() {
  emulate -LR zsh
  setopt err_return no_unset pipe_fail
  print "== ksm doctor =="
  print -n "backend:  "
  if (( $+commands[security] )); then
    print "OK (security)"
  else
    print "MISSING — macOS required"
    return 1
  fi
  print -n "keychain: "
  if [[ -f "$KSM_KEYCHAIN_FILE" ]]; then
    print "OK ($KSM_KEYCHAIN_FILE)"
  else
    print "NOT FOUND — will be created on first ksm set"
  fi
  print -n "zshrc:    "
  if [[ -f "$HOME/.zshrc" ]] && grep -qF 'ksm.zsh' "$HOME/.zshrc" 2>/dev/null; then
    print "OK (ksm.zsh sourced)"
  else
    print "NOT FOUND — installer should add: source $KSM_HOME/ksm.zsh"
  fi
  print -n "account:  $KSM_ACCOUNT"
  print
  print "keys:     ${#_ksm_keys[@]} managed in this shell"
  print -n "masking:  "
  if [[ "${KSM_MASK:-1}" != 0 ]]; then
    print "on (KSM_MASK=${KSM_MASK:-1})"
  else
    print "off (KSM_MASK=0)"
  fi
}

_ksm::cmd_help() {
  emulate -LR zsh
  setopt no_unset
  print "ksm — shell env secrets in the macOS Keychain, masked by default"
  print
  print "Usage: ksm COMMAND [ARGS]"
  print
  print "  set NAME [VALUE]  store + export to current shell (prompts if VALUE"
  print "                    omitted, reads one line from stdin when piped)"
  print "  cache NAME ...    silent re-fetch + export"
  print "  rm NAME           delete from Keychain + unset in shell"
  print "  ls                list managed keys with masked previews"
  print "  cp NAME           copy a secret to the clipboard (pbcopy)"
  print "  rand [size]       print a random hex secret (default 32 chars)"
  print "  doctor            check install"
  print "  help              this help"
  print
  print "Knobs (set before the source line in ~/.zshrc):"
  print "  KSM_MASK=0        disable echo/env/printenv masking"
  print "  KSM_AUTO_CACHE=0  disable auto-export at shell start"
}

# ---- auto-cache at source time -------------------------------------------
# Every shell that sources this file starts with all stored secrets
# already exported, so tools that read the env (gh, git, editors) work
# with no `ksm cache` call. One dump-keychain lists the names (~12 ms);
# each value fetch is ~25 ms. Disable with KSM_AUTO_CACHE=0 before
# sourcing.
_ksm::auto_cache() {
  emulate -LR zsh
  setopt no_unset pipe_fail
  _ksm::load_registry
  (( ${#_ksm_keys[@]} )) && ksm cache "${_ksm_keys[@]}"
  return 0
}

if [[ "${KSM_AUTO_CACHE:-1}" != 0 ]] && (( $+commands[security] )); then
  _ksm::auto_cache
fi
