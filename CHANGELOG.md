# Changelog

All notable changes to this plugin. Versions follow the `version` field in
`manifest.json` (the CLI's `--version` reports the same number).

## 0.2.0 (2026-11-10)

### Changed
- Display name is now **Drive for Google** (manifest, bar widget list, popup title,
  tooltip, CLI `--help`), and the docs and `--help` say it is not affiliated with
  Google. "Google Drive" stays where it names the service itself (the bookmark, the
  systemd unit description, messages about your files). Manifest author: Gustavo
  Costa (gusthx), license MIT.
- `setup` asks before the one command that runs as root. When `rclone`, `fuse3` or
  `jq` are missing it shows the exact `sudo pacman -S --needed --noconfirm …` line and
  asks first; `--yes` answers for you, and without a terminal and without `--yes`
  nothing is installed.
- The bar's `status --json` poll is much lighter: rclone's config is read only when
  `rclone.conf` changed, and two yes/no facts (remote exists, own client) are kept in
  `$XDG_RUNTIME_DIR` (mode 600, never a token). The widget polls every 15 s, every 4 s
  while the menu is open.
- The popup content lives in `DriveView.qml`, fed by a `drive` object, so it can be
  rendered with mock data.

### Security
- The client secret never reaches a command line: it is passed to the config writer
  through the environment, values with newlines are refused, and the temp file is
  created private and removed on failure.
- OAuth tokens and client secrets are scrubbed from the last journal error shown in the
  popup and in `status --json`, and from `doctor`'s token line.
- After `setup` reads a downloaded `client_secret_*.json`, it reminds you that the file
  still holds a copy of the secret.

### Docs
- README in English with a Brazilian Portuguese translation in `README.pt-BR.md`, a
  demo GIF, and a Privacy and security section (what is stored where, permissions, how
  the secret is handled, hosts contacted).
- Screenshots and the demo are rendered from mock data by the dev harness, never from a
  real account.

### Development
- `dev/run.sh`: an isolated Quickshell harness with mock data (`preview`, offscreen
  captures, `gif`, `check` compile mode, `test`). It never runs the CLI or rclone.
- Tests: `Model.js`, i18n catalogs (same keys everywhere, every key used exists), the
  client-secret writer on a throwaway `rclone.conf`, ask-before-sudo with a stubbed
  `sudo`, and the version being the same in the manifest, the CLI and this file.
- `dev/deploy.sh` fast-forwards the installed checkout to `HEAD` and restarts the shell
  once. `AGENTS.md` describes how to work on the plugin without touching the live bar.

## 0.1.0 (2026-11-08)

First version.

- `omarchy-gdrive setup`: guided, idempotent install. Installs missing tools with
  pacman, walks you through creating your own Google OAuth client, signs you in, writes
  a systemd user unit with VFS-cache defaults, mounts `~/GoogleDrive` and adds a file
  manager bookmark. Adopts a unit you wrote by hand.
- `doctor [--fix]`, `status [--json]`, `start`, `stop`, `restart`, `logs`, `quota`,
  `open`, `remove`.
- Bar widget: mount state, pending uploads, cache usage, Drive quota, pause/resume,
  logs and doctor.
- English and Portuguese, following the Omarchy language setting.
