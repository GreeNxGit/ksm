# 🔑 ksm

> Keychain secrets for your shell: stored in the macOS Keychain, exported in every new shell, and masked in `echo`, `env`, and `printenv`.

## Highlights

- 🔐 Secrets live in a dedicated keychain, not in dotfiles or plain-text files
- 🚀 Zero setup per shell: every new shell exports all stored secrets at startup
- 🙈 Masked by default: `echo $GITHUB_TOKEN` prints `****`
- 💬 No prompts: no password, no Touch ID, no "Allow modify?" dialog
- 📦 One zsh file with no dependencies beyond the tools macOS already ships

## Install

ksm needs macOS and zsh.

```sh
curl -fsSL https://raw.githubusercontent.com/GreeNxGit/ksm/main/install | bash
```

The installer does three things:

1. copies `ksm.zsh` to `~/.ksm/`
2. creates a dedicated keychain at `~/Library/Keychains/ksm.keychain-db` with an empty password and a 24-hour lock timeout
3. adds `source ~/.ksm/ksm.zsh` to `~/.zshrc`

To load ksm, start a new shell or run `exec zsh`.

## Usage

```sh
# Store a secret (ksm prompts for the value if you omit it)
ksm set GITHUB_TOKEN ghp_xxxx

# Generate and store a random hex secret in one pipe
ksm rand | ksm set API_SECRET

# List keys with masked previews (no raw values)
ksm ls

# Copy a secret to the clipboard
ksm cp GITHUB_TOKEN

# Fetch stored secrets and export them in the current shell (no output)
ksm cache GITHUB_TOKEN

# Delete a secret
ksm rm GITHUB_TOKEN

# Check the install
ksm doctor
```

Every new shell exports all stored secrets at startup, so `gh`, `git`, and your editor just read `$GITHUB_TOKEN`.

> [!NOTE]
> ksm has no `get` command and never prints a raw secret to stdout. Copy a secret with `ksm cp`, or print one with `ksm cache NAME` and then `command echo $NAME`.

## Masked by default

`ksm` wraps `echo`, `env`, and `printenv` so stored secrets print as `****`:

```sh
echo $GITHUB_TOKEN           # ****
echo "token: $GITHUB_TOKEN"  # token: ****
env | grep GITHUB_TOKEN      # GITHUB_TOKEN=****
printenv GITHUB_TOKEN        # ****
ksm ls                       # GITHUB_TOKEN    gh****
```

> [!TIP]
> Need the real value in the shell? `command echo $GITHUB_TOKEN` bypasses the wrapper.

> [!WARNING]
> Masking guards against shoulder-surfing and scrollback leaks. It is not a security boundary. `printf`, `command echo`, and any program that reads the environment get the real value.

## Configuration

Set these before the `source` line in `~/.zshrc`:

```sh
# in ~/.zshrc, before the source line:
KSM_KEYCHAIN=work
source ~/.ksm/ksm.zsh
```

| Variable         | Default | Effect                                                  |
| ---------------- | ------- | ------------------------------------------------------- |
| `KSM_MASK`       | `1`     | `0` disables the `echo`, `env`, and `printenv` wrappers |
| `KSM_AUTO_CACHE` | `1`     | `0` disables the export at shell start                  |
| `KSM_KEYCHAIN`   | `ksm`   | Keychain name (letters, digits, `-`, and `_`)           |
| `KSM_ACCOUNT`    | `$USER` | Account name recorded with each entry                   |

## How secrets are stored

Secrets live in a dedicated keychain at `~/Library/Keychains/<name>.keychain-db`. The installer creates it with an empty password and a 24-hour lock timeout. The password is empty, so ksm unlocks it silently and you never see a prompt.

`KSM_KEYCHAIN` picks the name. Every `security` call targets the full derived path, so a custom name needs no other setup:

- ksm never passes the `-A` flag, so macOS never shows the "Allow modify?" prompt, even on updates.
- The keychain stays unlocked, so macOS never asks for Touch ID.
- ksm does not touch your login keychain. Entries stay in the dedicated keychain.

ksm writes no secret to disk in plain text. Key names and values live only in the dedicated keychain.

| Path                                  | Purpose                              |
| ------------------------------------- | ------------------------------------ |
| `~/.ksm/ksm.zsh`                      | the library file, sourced from `~/.zshrc` |
| `~/Library/Keychains/ksm.keychain-db` | the dedicated keychain               |

## Update

Run the installer again. It replaces `~/.ksm/ksm.zsh` with the current version and leaves the keychain and `~/.zshrc` unchanged.

## Uninstall

> [!WARNING]
> Uninstalling deletes every stored secret.

```sh
rm -rf ~/.ksm ~/Library/Keychains/ksm.keychain-db
```

Then remove the `ksm` block from `~/.zshrc`. If you set a custom `KSM_KEYCHAIN` name, also remove `~/Library/Keychains/<name>.keychain-db`.

> [!NOTE]
> Old versions kept the keychain at `~/.ksm.keychain-db`. The installer moves that file to `~/Library/Keychains/` when you update.

## Development

```sh
make test             # run the zsh test suite
make lint             # shellcheck the installer and the test runner
make install-local    # install from this checkout (no download)
```
