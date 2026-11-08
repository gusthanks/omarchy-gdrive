# Why (and how) to create your own Google `client_id`

> 🇧🇷 [Versão em português](own-client-id.pt-BR.md)

## Why

When rclone talks to Google Drive it has to say *which application* is asking.
That identity is an OAuth **client_id**. Out of the box, every copy of rclone
on the planet uses the **same shared client_id** that the rclone project
registered years ago.

Two problems come with that:

1. **It is slow.** Google gives each client_id a quota. One client_id shared
   by millions of users means constant `rateLimitExceeded` errors, slow
   directory listings and stalled uploads.
2. **It is going away.** Google is retiring that shared client during **2026**.
   rclone already prints a notice on every command. When it stops working,
   mounts that still depend on it stop working too.

Creating your own takes about five minutes, is free, and gives you a private
lane with your own quota. You do not need to know how OAuth works.

### What you end up with

| Value | What it is | Where it lives |
|---|---|---|
| `client_id` | A public identifier for "your rclone", ends in `.apps.googleusercontent.com` | `~/.config/rclone/rclone.conf` |
| `client_secret` | A password for that identifier | `~/.config/rclone/rclone.conf` (mode 600) |
| token | Your actual login, created when you sign in | `~/.config/rclone/rclone.conf` (mode 600) |

omarchy-gdrive never prints, logs or uploads any of these. The secret is
written into `rclone.conf` directly, so it never appears on a command line
either.

## How

The steps below follow the English Google Cloud Console; the
same screens exist in every language.

### 1. Create a project

1. Open <https://console.cloud.google.com/projectcreate> and sign in with the
   Google account whose Drive you want to mount.
2. **Project name:** anything, e.g. `Omarchy Drive`.
3. **Organization:** leave *No organization* (that is the default for personal
   `@gmail.com` accounts).
4. Click **Create** and wait for the notification, then make sure the new
   project is selected in the project picker at the top.

<!-- screenshot: img/01-create-project.png — Create project -->

### 2. Enable the Google Drive API

1. Open <https://console.cloud.google.com/apis/library/drive.googleapis.com>.
2. Make sure your new project is selected at the top.
3. Click **Enable**.

<!-- screenshot: img/02-enable-drive-api.png — Enable Drive API -->

### 3. Configure the consent screen (Google Auth Platform)

1. Open <https://console.cloud.google.com/auth/overview> and click **Get started**.
2. **App information:** app name `Omarchy Drive`, support e-mail = your e-mail.
3. **Audience:** choose **External**.
4. **Contact information:** your e-mail again. Agree to the policy, **Create**.

<!-- screenshot: img/03-consent-screen.png — Consent screen -->

### 4. Add yourself as a test user

The app stays in *Testing* mode, which is exactly what you want: nobody but
the accounts you list here can use it, and Google asks for no verification.

1. In the left menu open **Audience**.
2. Under **Test users** click **+ Add users**, type your Google e-mail, **Save**.

<!-- screenshot: img/04-test-users.png — Test users -->

> Tokens of apps in Testing mode used to expire after 7 days. That limit no
> longer applies to the *Desktop app* client type used below, and rclone
> refreshes the token automatically in the background.

### 5. Create the OAuth client

1. In the left menu open **Clients** and click **+ Create client**.
2. **Application type:** **Desktop app**.
3. **Name:** `rclone` (or anything).
4. Click **Create**.
5. In the dialog click **Download JSON**. A file named
   `client_secret_<numbers>.json` lands in `~/Downloads`.

<!-- screenshot: img/05-create-client.png — Create OAuth client -->
<!-- screenshot: img/06-download-json.png — Download JSON -->

Leave *"Use this client for an AI-powered agent"* unchecked if you see it.

### 6. Hand it to omarchy-gdrive

```bash
omarchy-gdrive setup
```

setup finds the newest `client_secret_*.json` in `~/Downloads` by itself and
asks you to confirm. If you already have a working mount it offers to switch
it to your new client:

```bash
omarchy-gdrive setup --client
```

Your browser opens on Google's consent screen once. If Google shows **"Google
hasn't verified this app"**, click **Advanced → Go to Omarchy Drive (unsafe)**.
It is *your* app; the warning only means you did not go through Google's
verification process, which is unnecessary for a private tool.

Afterwards you can delete the JSON from `~/Downloads`: the values are now in
`rclone.conf`.

### 7. Check

```bash
omarchy-gdrive doctor
```

should print `Remote 'gdrive' uses your own OAuth client_id`.

## FAQ

**Does this cost anything?** No. The Drive API is free for personal use and
this project never needs billing enabled.

**Can I reuse the client for other machines?** Yes. Copy the same
`client_id`/`client_secret` (or the JSON) to the other machine and run
`omarchy-gdrive setup --credentials <file>`. Each machine signs in separately
and gets its own token.

**I lost the JSON.** In the console open **Clients**, click your client, and
use **Download JSON** again, or copy the id and secret from that page and pick
*Paste client_id and client_secret by hand* in `omarchy-gdrive setup --client`.

**I want to revoke everything.** <https://myaccount.google.com/permissions>
lists the app; removing it invalidates every token. Deleting the project in
the Cloud Console removes the client itself.
