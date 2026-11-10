# Notes for AI agents (and humans) working on this plugin

## Never work on the live plugin

The copy installed at `~/.config/omarchy/plugins/gusthx.gdrive/` is the one the user's Omarchy
shell is running. Saving a file there hot-reloads the plugin in the user's bar, and
`omarchy restart shell` restarts the whole bar. Doing that over and over while developing
is disruptive.

- **Edit only this repository** (the working copy in `~/Work/`).
- **Do not** edit, copy into, or `git` anything under `~/.config/omarchy/plugins/`.
- **Do not** run `omarchy restart shell`, `omarchy refresh shell`, `omarchy theme set`,
  or IPC calls (`omarchy-shell gusthx.gdrive ...`) to test a change.
- **Do not** take screenshots of the user's desktop (`grim`) to check your work.

## Test and capture in isolation

`dev/run.sh` starts a **separate** Quickshell instance with Omarchy's `Commons`/`Ui`
libraries and this repo. It never touches the running shell, never runs the CLI and never
calls rclone: the popup (`DriveView.qml`) is fed by `dev/MockDrive.qml`. Captures render
offscreen (Qt's offscreen platform) and save images straight to `docs/`.

```bash
dev/run.sh preview   # the popup in a window, mock data
dev/run.sh docs      # docs/panel.png, panel-shared, panel-error, panel-setup, bar, panel-pt-BR
dev/run.sh check     # compile every type, Panel.qml included (deploy runs this too)
dev/run.sh test      # Model.js + i18n catalog tests, the client-secret writer test,
                     # the ask-before-sudo test (stubbed sudo), bash -n
```

Also run `omarchy plugin validate .`. What can't be rendered in isolation (live data in
the real bar) is checked by the user after deploying, not by you on their live shell.

**Never** run the CLI's `setup`, `status`, `quota`, `doctor` or any `rclone` command
against the user's real remotes or `~/.config/rclone` to test a change. Tests that need a
config use a throwaway `RCLONE_CONFIG` in a temp dir (see `dev/tests/secret.test.sh`).

## Deploy once, at the end, and restart the bar

When ALL the requested work is finished, tested in the harness and committed:

```bash
dev/deploy.sh   # validates, compiles, fast-forwards the live checkout to HEAD, restarts the shell once
```

The live plugin is a git checkout of this repo; deploy fast-forwards it (uncommitted edits
there are dropped only when they are an exact copy of a commit HEAD already contains). The shell's hot
reload is not reliable for plugins (the old version can stay on screen), so the deploy
always ends with one `omarchy restart shell`. Do not tell the user something is done before
this ran. Never use `omarchy refresh shell` (it resets the bar layout). Never deploy or
restart in the middle of a task.

## Other conventions

- Repo root = plugin root (the layout `omarchy plugin add <url>` expects). Dev tooling
  lives in `dev/`, screenshots in `docs/`.
- Widget strings go through the plugin's own catalog in `i18n/` (`Commons.Translations`,
  reached through `drive.t()`), never through `Commons.I18n` keys, which Omarchy may
  rename. CLI strings live in `i18n/cli/`. Add every new key to every catalog (a test
  checks this).
- `DriveView.qml` reads everything from its `drive` object. A property or action added to
  `Panel.qml` for the view must be added to `dev/MockDrive.qml` too.
- Secrets (client secret, tokens) never go on a command line, into logs, into
  `status --json` or into the UI.
- Mock data only in the harness, tests and screenshots: never the user's email, Drive
  contents, quota or config.
