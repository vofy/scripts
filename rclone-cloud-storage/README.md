# rclone cloud storage for Linux

Google Drive and OneDrive on Linux with rclone. It works like the official Windows clients (**Google Drive for Desktop** and **OneDrive**), with both of their modes:

| Mode | Like Windows… | What it does | Disk use | Offline |
|---|---|---|---|---|
| **stream** | Drive: "Stream files" · OneDrive: "Files On-Demand" (both the default) | The drive appears as a folder. Files download when opened and stay cached. Changes upload within ~5 s. | Only the cache (default max 20 GiB) | Only files already in the cache |
| **mirror** | Drive: "Mirror files" · OneDrive: "Always keep on this device" | A full local copy, synced both ways every 5 min | Your whole drive | Yes |

| Provider | `--provider` | Remote name | Local folder |
|---|---|---|---|
| Google Drive | `gdrive` | `gdrive` | `~/GoogleDrive` |
| OneDrive (personal or work/school) | `onedrive` | `onedrive` | `~/OneDrive` |

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/rclone-cloud-storage/main/setup.sh | bash
```

With options (everything after `--` goes to the script):

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/rclone-cloud-storage/main/setup.sh | bash -s -- --provider onedrive --mode mirror
```

> Replace the URL with wherever you host `setup.sh` (a GitHub repo or Gist "Raw" link).
> Pipe it to **`bash`**, not `sh`, because the script uses bash features.
> The script asks for `sudo` only to install packages, and its prompts still work when it's piped.

Or from a local copy:

```bash
chmod +x setup.sh
./setup.sh                                       # asks provider and mode
./setup.sh --provider gdrive --mode stream
./setup.sh --provider onedrive --mode mirror --interval 10min
```

To use both services, run the script once per provider. Each provider gets its own remote, folder and systemd units.

### Options

| Option | Default | Meaning |
|---|---|---|
| `--provider gdrive\|onedrive` | asks | Cloud service. It's detected automatically when `--remote` names an existing remote |
| `--mode stream\|mirror` | asks | Sync mode |
| `--remote NAME` | provider name | rclone remote name |
| `--remote-path PATH` | whole drive | Sync only one folder, e.g. `"02_Dokumenty"` |
| `--path DIR` | `~/GoogleDrive` / `~/OneDrive` | Local folder |
| `--cache-size SIZE` | `20G` | stream: maximum cache size |
| `--interval TIME` | `5min` | mirror: time between syncs |
| `--client-id ID` / `--client-secret S` | none | Your own OAuth client. **Recommended for Google Drive**, see below. Optional for OneDrive |
| `--token JSON` | none | Sign-in token for machines without a browser |
| `--uninstall` | | Remove the systemd units (files and config are kept) |
| `-y` | | Skip confirmations |

You can rerun the script at any time, for example to switch modes. It reuses the existing remote, so you won't have to sign in again.

### What the script does

1. Installs rclone with dnf, apt, pacman or zypper. If the distro version is older than 1.66, it uses the official installer instead. For stream mode it also installs FUSE.
2. Creates the remote and opens a browser for the Google or Microsoft sign-in.
3. **stream:** creates `~/.config/systemd/user/rclone-<remote>.service`, which runs `rclone mount` with a full VFS cache.
   **mirror:** creates `rclone-<remote>-bisync.service` and `.timer`, runs the first full `rclone bisync --resync` while you watch, then turns on the timer.
4. Adds a "Google Drive" or "OneDrive" shortcut to the sidebar of GNOME Files, Nautilus and other GTK file managers.

## Own Google client ID (do this for Google Drive)

rclone's built-in Google client ID is shared by every user. Google throttles it, and **it is being retired in 2026**. Make your own (free, about 5 minutes):

1. Go to <https://console.cloud.google.com/> and create a project.
2. Open **APIs & Services → Library → Google Drive API → Enable**.
3. Open **Google Auth Platform → Branding**. Fill in an app name and your email. Choose audience **External**.
4. Open **Audience** and add your Google account under **Test users**.
5. Open **Data access → Add or remove scopes**. Add `https://www.googleapis.com/auth/drive`.
6. Open **Clients → Create client** and choose type **Desktop app**. Copy the client ID and secret.
7. Open **Audience → Publish app** (to "In production"). This step matters: while the app is in testing mode, tokens expire every 7 days.
   You'll see an "unverified app" screen when you sign in. Click **Advanced → Go to … (unsafe)**. This is expected, because it's your own app.

Then run:

```bash
./setup.sh --provider gdrive --mode stream --client-id 'XXXX.apps.googleusercontent.com' --client-secret 'YYYY'
```

On a machine that is already set up, this switches the remote to your client and asks you to sign in again. You can reuse the same client ID on all your machines.

Details: <https://rclone.org/drive/#making-your-own-client-id>

OneDrive works fine with rclone's built-in client. If you get throttled a lot, you can register your own app: <https://rclone.org/onedrive/#getting-your-own-client-id-and-key>.

## Machines without a browser (servers, SSH)

On any computer with a browser and rclone installed, run:

```bash
rclone authorize drive                         # Google Drive; or: rclone authorize drive "CLIENT_ID" "CLIENT_SECRET"
rclone authorize onedrive                      # OneDrive
```

Copy the JSON it prints, `{"access_token":...}`, and pass it to the server:

```bash
./setup.sh --provider onedrive --mode mirror --token '{"access_token":...}'
```

Stream mode on a server also needs the user's services to keep running after logout: `sudo loginctl enable-linger $USER`.

## Everyday use

The examples below use `gdrive`. For OneDrive, replace it with `onedrive` (or your `--remote` name).

**stream**

```bash
systemctl --user status rclone-gdrive          # is it mounted?
systemctl --user restart rclone-gdrive         # remount
tail -f ~/.cache/rclone/gdrive-mount.log
du -sh ~/.cache/rclone/vfs                     # cache size
```

**mirror**

```bash
systemctl --user list-timers rclone-gdrive-bisync.timer   # next run
systemctl --user start rclone-gdrive-bisync.service       # sync now
journalctl --user -u rclone-gdrive-bisync -n 50
tail -f ~/.cache/rclone/gdrive-bisync.log
```

## Provider notes

### Google Docs/Sheets/Slides

- **stream:** each one appears as a small `.html` file that opens the document in your browser, similar to `.gdoc` files on Windows.
- **mirror:** they are skipped (`--drive-skip-gdocs`). Native Google files can't be synced both ways. Open them at drive.google.com.

### OneDrive

- Office files are ordinary files on OneDrive, so they sync normally in both modes.
- OneNote notebooks are hidden, because they can't be downloaded as files. Open them in OneNote or at onedrive.com.
- The script signs in to your account's main OneDrive. To use a SharePoint library instead, create the remote with `rclone config` and pass its name with `--remote`.

## Differences from the Windows clients

- There's no tray icon or per-file sync status. Use the log and the `systemctl` commands above.
- There's no "Make available offline" option for single files in stream mode. Files you've opened stay cached for 30 days. To keep a folder offline, use mirror mode with `--remote-path` and a separate `--remote` name.
- Mirror mode syncs on a timer rather than instantly.
- Google shared drives and files that others shared with you on OneDrive aren't included. Add a second remote with `rclone config` if you need them.

## Manual setup (without the script)

```bash
sudo dnf install rclone fuse3                  # or apt/pacman
rclone config create gdrive drive scope=drive  # Google Drive, browser sign-in
rclone config create onedrive onedrive         # OneDrive, browser sign-in
mkdir -p ~/GoogleDrive ~/.cache/rclone
```

**stream:** save as `~/.config/systemd/user/rclone-gdrive.service`. For OneDrive, change the remote, folder and log names, and drop the two `--drive-*` flags:

```ini
[Unit]
Description=Google Drive stream mount
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStartPre=-/usr/bin/fusermount3 -uz %h/GoogleDrive
ExecStart=/usr/bin/rclone mount gdrive: %h/GoogleDrive \
    --vfs-cache-mode full --vfs-cache-max-size 20G --vfs-cache-max-age 720h \
    --vfs-cache-min-free-space 10G --vfs-write-back 5s --vfs-read-ahead 128M \
    --dir-cache-time 1000h --poll-interval 15s \
    --volname "Google Drive" --umask 077 \
    --log-level NOTICE --log-file %h/.cache/rclone/gdrive-mount.log \
    --drive-export-formats link.html --drive-acknowledge-abuse
ExecStop=/usr/bin/fusermount3 -uz %h/GoogleDrive
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now rclone-gdrive
```

**mirror:** run the first sync once, then put the same command without `--resync` in a oneshot service with a timer. For OneDrive, drop `--drive-skip-gdocs`:

```bash
rclone bisync gdrive: ~/GoogleDrive --resync --resync-mode newer \
    --create-empty-src-dirs --resilient --recover --max-lock 2m \
    --conflict-resolve newer --drive-skip-gdocs --progress
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `Time may be set wrong` / sign-in errors | See **Clock** below |
| stream: `directory not empty` | The mount folder must be empty. Move its files out or use a different `--path` |
| stream: `Transport endpoint is not connected` | `fusermount3 -uz ~/GoogleDrive; systemctl --user restart rclone-gdrive` |
| mirror: `too many deletes` | Safety stop: more than 50% of files would be deleted. Check the log; if the deletes are intended, run the bisync command once with `--force` |
| mirror: `must run --resync` | Run the bisync command above once with `--resync` (this also applies after you edit the filters file) |
| mirror: files named `*.conflict1` | The file changed on both sides. The newer copy keeps the name; check the other one and delete it |
| `invalid_grant` / token expired | `rclone config reconnect gdrive:` (for Google, if it keeps happening, publish your OAuth app, see step 7) |
| OneDrive work/school: Office files keep re-syncing or show size/hash errors | SharePoint changes Office files after upload. Add `--ignore-size --ignore-checksum` to the bisync command in the service file |
| `Remote '…' is of type …` | A remote with that name already exists for the other provider. Pass a different `--remote` |

### Clock

Google and Microsoft reject requests when the computer's clock is wrong. Check it with `timedatectl`. `System clock synchronized` should say `yes`.

On a **dual-boot machine with Windows**, Linux often keeps the hardware clock in local time, which makes the clock drift by your UTC offset. Fix both systems:

```bash
sudo timedatectl set-local-rtc 0          # Linux: hardware clock = UTC
```

On Windows, in an admin terminal:

```
reg add "HKLM\System\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

## Uninstall

```bash
./setup.sh --remote gdrive --uninstall     # stop and remove the services (or --remote onedrive)
rclone config delete gdrive                # forget the account
rm -rf ~/.cache/rclone                     # cache, logs and bisync state (all providers)
```

Then remove access to the app:

- Google: <https://myaccount.google.com/permissions>
- Microsoft personal account: <https://account.live.com/consent/Manage>
- Microsoft work or school account: <https://myapps.microsoft.com>
