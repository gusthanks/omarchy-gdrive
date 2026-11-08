# ☁️ omarchy-gdrive

<p align="center">
  <b>Google Drive on <a href="https://omarchy.org">Omarchy</a>, done right: your own OAuth client, an rclone mount that survives reboots, a <code>doctor</code> that tells you what is wrong, and a bar widget to watch it.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Omarchy-Shell%20Plugin-blue?style=flat-square" alt="Omarchy Plugin" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License" />
  <img src="https://img.shields.io/badge/rclone-%E2%89%A5%201.70-orange?style=flat-square" alt="rclone" />
  <img src="https://img.shields.io/badge/root-only%20pacman-brightgreen?style=flat-square" alt="No root" />
  <img src="https://img.shields.io/badge/i18n-en%20%7C%20pt--BR-purple?style=flat-square" alt="i18n" />
</p>

> 🇧🇷 [Resumo em português](#-em-português) · 📖 [Why your own `client_id`](docs/own-client-id.md)

---

## What you get

- **`omarchy-gdrive setup`** — one guided, idempotent command. Installs `rclone` if missing (the only thing that ever runs as root), walks you through creating **your own Google OAuth client**, signs you in, writes a systemd *user* unit with sane VFS-cache defaults, mounts `~/GoogleDrive` and adds it to the file manager sidebar. Run it again any time; it only changes what differs.
- **Adopts what you already have.** Mounted Drive by hand with your own `rclone-gdrive.service`? `setup` detects it and offers to *adopt* it untouched (default) or replace it with the template.
- **`omarchy-gdrive doctor`** — tools, config permissions, remote, own vs. shared `client_id`, network, token, unit, mount, cache, pending uploads, bookmark. Says what to run to fix each thing. `--fix` applies the safe ones.
- **`status`, `start`, `stop`, `restart`, `logs`, `quota`, `open`, `remove`** — and `status --json` for machines.
- **Bar widget** — state icon (mounted / paused / problem), pending-upload badge, popup with cache usage, Drive quota, pause/resume switch, logs and doctor buttons. Follows the Omarchy theme live. Click opens `~/GoogleDrive`.
- **No secrets in the wrong place.** The `client_secret` is written straight into `~/.config/rclone/rclone.conf` (mode 600), never passed on a command line, never logged, never shown in the widget.
- **English and Portuguese**, following the Omarchy language setting (falls back to `$LANG`).

<p align="center">
  <img src="assets/panel.png" alt="Google Drive popup: state, cache, quota, actions" width="70%" />
</p>
<p align="center">
  <img src="assets/bar.png" alt="Bar pill" />
</p>

## Install

```bash
omarchy plugin add https://github.com/gusthanks/omarchy-gdrive --enable
~/.config/omarchy/plugins/gusthx.gdrive/bin/omarchy-gdrive setup
```

`setup` links the CLI into `~/.local/bin`, so from then on it is just `omarchy-gdrive …`. Pick **right** when the plugin asks where to place the widget.

Don't want the widget? Clone the repo anywhere and run `bin/omarchy-gdrive setup`; the CLI has no dependency on the shell.

### What `setup` does, step by step

1. `pacman -S rclone fuse3` if they are missing (asks first).
2. Looks for an existing `~/.config/systemd/user/rclone-gdrive.service`. If you wrote one, it offers **Adopt** (nothing changes, nothing restarts) or **Replace**.
3. Creates (or reuses) the rclone remote `gdrive`. If you downloaded a `client_secret_*.json` from Google it finds it in `~/Downloads` and asks to use it. Otherwise it explains [why you want your own client](docs/own-client-id.md) and lets you paste the id and secret, or continue with rclone's shared client for now.
4. Opens the browser once for Google's consent screen (`rclone config reconnect`).
5. Writes the unit from [`templates/rclone-gdrive.service`](templates/rclone-gdrive.service):
   `--vfs-cache-mode full`, cache capped at 10 % of the free space on the cache disk (2–50 GiB), `--vfs-cache-max-age 72h`, `--dir-cache-time 72h`, `--poll-interval 1m`, `--umask 022`, `After=network-online.target`, auto-restart.
6. `systemctl --user enable --now`, waits for the mount, adds the GTK bookmark, `chmod 600 rclone.conf`.

Everything is recorded in `~/.config/omarchy-gdrive/config` (remote, mount point, unit name, adopted or managed).

## Why your own `client_id`

rclone ships with one shared Google `client_id` used by every rclone user on Earth. Google throttles it (hello `rateLimitExceeded`) and is **retiring it during 2026**. Creating your own takes five minutes, is free, and gives you a private quota. The guide walks through the Google Cloud Console click by click:

➡️ **[docs/own-client-id.md](docs/own-client-id.md)** · 🇧🇷 [em português](docs/own-client-id.pt-BR.md)

Already mounted with the shared client? `omarchy-gdrive setup --client` upgrades the existing remote in place.

## Commands

| Command | What it does |
|---|---|
| `setup` | Guided install / repair. `--client`, `--credentials FILE`, `--shared-client`, `--adopt`, `--replace`, `--remote`, `--mountpoint`, `--service`, `--yes` |
| `status [--json]` | One screen: state, service, remote, cache, pending uploads |
| `doctor [--fix]` | Full health check with fixes to run; exit 1 only on real failures |
| `start` / `stop` / `restart` | Mount, unmount (warns about pending uploads), remount |
| `logs [-n N] [--no-follow]` | `journalctl --user -u rclone-gdrive -f` |
| `quota [--json]` | Drive usage (`rclone about`) |
| `open` | Open the mount in the file manager |
| `remove [--keep-remote] [--purge-cache]` | Undo everything on this machine. **Never touches files on Drive.** |

## Bar widget

| Action | Result |
|---|---|
| Left click | Open `~/GoogleDrive` |
| Right click | Open the menu |
| Middle click | Pause / resume the mount |
| Keys in the menu | `o` open · `p` pause/resume · `l` logs · `d` doctor · `r` refresh · `Esc` close |

Prefer the menu on left click? In `~/.config/omarchy/shell.json`:

```json
{ "id": "gusthx.gdrive", "leftClick": "panel" }
```

IPC: `quickshell -p /usr/share/omarchy/shell ipc call gusthx.gdrive toggle` (also `open`, `close`, `refresh`, `openFolder`, `toggleMount`).

## Layout

| Path | Purpose |
|---|---|
| `bin/omarchy-gdrive` | CLI entry point and `setup` flow |
| `lib/common.sh` | Everything that is *not* Google-specific: systemd unit, mount, cache, bookmark, doctor, remove |
| `lib/gdrive.sh` | Google Drive: OAuth client handling, shared-client detection, quota |
| `lib/i18n.sh`, `i18n/cli/*.json` | CLI messages (en, pt-BR) |
| `templates/rclone-gdrive.service` | The unit `setup` renders |
| `Panel.qml`, `Model.js`, `i18n/*.json` | Bar widget |
| `docs/` | The `client_id` guide in both languages |

The split is deliberate: `common.sh` only knows about "an rclone remote mounted by a user unit", so a `omarchy-cloud-drive` for OneDrive, Dropbox or S3 is a second provider module away.

## Testing

```bash
node --test Model.test.js        # widget helpers
bash -n bin/omarchy-gdrive lib/*.sh
```

## Uninstall

```bash
omarchy-gdrive remove
omarchy plugin remove gusthx.gdrive
```

---

## 🇧🇷 Em português

**omarchy-gdrive** monta o seu Google Drive no Omarchy com `rclone`, do jeito reproduzível: um comando `setup` guiado e idempotente (instala o rclone se faltar, te leva a criar o **seu próprio client_id OAuth** no Google, faz o login, escreve a unit de usuário do systemd com cache VFS bem configurado, monta `~/GoogleDrive` e cria o favorito no gerenciador de arquivos), um `doctor` que diz exatamente o que está errado e como corrigir, e um widget de barra com ícone de estado, uso do cache, cota do Drive, pausar/retomar e logs.

Se você já montou o Drive à mão com a sua própria `rclone-gdrive.service`, o `setup` detecta e oferece **adotar** sem mexer em nada (padrão) ou substituir pelo template.

```bash
omarchy plugin add https://github.com/gusthanks/omarchy-gdrive --enable
~/.config/omarchy/plugins/gusthx.gdrive/bin/omarchy-gdrive setup
```

Por que o seu próprio `client_id`? O rclone vem com um client_id compartilhado por todos os usuários do mundo: o Google limita a velocidade dele e vai **aposentá-lo em 2026**. Criar o seu leva cinco minutos e é grátis: **[guia passo a passo em português](docs/own-client-id.pt-BR.md)**. Já tem o mount com o cliente compartilhado? `omarchy-gdrive setup --client` troca no lugar.

A interface (CLI e widget) segue o idioma do Omarchy (`omarchy language`), com fallback para `$LANG`. Nenhum segredo passa pela linha de comando, pelos logs ou pelo widget: o `client_secret` vai direto para `~/.config/rclone/rclone.conf` (modo 600).

## License

[MIT](LICENSE) © Gustavo Costa
