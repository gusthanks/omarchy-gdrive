# Changelog

All notable changes to this plugin. Versions follow the `version` field in
`manifest.json` (the CLI's `--version` reports the same number).

## 0.4.0 (2026-11-23)

### Added
- **Login guard.** When Google refuses the login, the mount turns itself off
  instead of retrying: retrying can never fix a refused login, it only costs CPU
  and battery (on a 2-core laptop the old loop restarted rclone every 10 s). The
  unit gets three lines: `ExecStopPost` runs the new internal `auth-guard`
  command, which recognises the refusal in that run's log, writes
  `~/.config/omarchy-gdrive/<service>.login-refused` and stops the unit;
  `ExecCondition` skips every start (boot included) while that file exists;
  `ExecStartPost` deletes it once a mount comes up. `reconnect` deletes it too, and
  a newer `rclone.conf` (a `rclone config reconnect` made by hand) lifts it. Any
  other failure, like no network, keeps the normal restart with backoff.
- The popup shows the refused login with its **Reconnect** button while the mount
  is off; `start` explains why it will not start; `doctor` checks the guard and
  `doctor --fix` adds it to an adopted unit as a drop-in
  (`rclone-gdrive.service.d/60-omarchy-login-guard.conf`). `remove` deletes both
  drop-ins.

### Fixed
- The last error (in `status` and the popup) was systemd's own "Failed to start …"
  line instead of rclone's message, so a refused login was never recognised as one.
  It now reads only rclone's lines.

## 0.3.0 (2026-11-20)

### Fixed
- The guide said Google's 7-day login limit for apps in *Testing* mode no longer
  applied to Desktop clients. It does: every Testing app with the Drive scope is
  signed out after 7 days and the mount stops with `invalid_grant`. Step 4 of
  [docs/own-client-id.md](docs/own-client-id.md) now says to **Publish app**, and
  a new FAQ entry explains what to do when it already happened.
- A mount that kept failing was shown as "Starting…" forever. Waiting between two
  failed starts (`auto-restart`) is now reported as a problem.

### Added
- `omarchy-gdrive reconnect`: sign in to Google again (the browser opens once),
  verify the token, clear the failure and remount.
- When Google refused the login, `status --json` carries `authExpired: true` and
  the popup says so in plain words, with a **Reconnect** button.
- `doctor` explains a refused login (and the 7-day Testing cause, for your own
  client) and points to `reconnect`.

### Changed
- Restart backoff: failed starts are retried with a wait that grows from 10 s to
  1 h (`RestartSteps=8`, `RestartMaxDelaySec=1h`) instead of every 10 s forever.
  New units from the template carry it; for an adopted unit `doctor --fix` adds it
  as a drop-in (`rclone-gdrive.service.d/50-omarchy-backoff.conf`) and leaves your
  own file untouched.

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
