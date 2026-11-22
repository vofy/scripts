# rclone cloud storage for Linux

Google Drive or OneDrive on Linux with rclone, in one of two modes:

- **stream** (default): the drive appears as a folder (`~/GoogleDrive`, `~/OneDrive`). Files download when opened and stay cached.
- **mirror**: a full local copy that works offline, synced both ways every 5 minutes.

## Setup

For Google Drive, first create your own Google client ID, see [below](#own-google-client-id-do-this-for-google-drive). Then run:

```bash
curl -fsSL https://raw.githubusercontent.com/vofy/scripts/main/rclone-cloud-storage.sh | bash
```

The script asks for each setting; press Enter to accept the `[default]`. It shows a summary, asks you to confirm, then opens a browser to sign in. Rerun it any time to change settings. Run it once per service to use both.

Settings can also be passed as options (after `bash -s --` when piped):

| Option | Default |
|---|---|
| `--provider gdrive\|onedrive` | `gdrive` |
| `--mode stream\|mirror` | `stream` |
| `--path DIR` | `~/GoogleDrive` / `~/OneDrive` |
| `--remote-path PATH` (sync one folder only) | `/` (whole drive) |
| `--cache-size SIZE` (stream) | `20G` |
| `--interval TIME` (mirror) | `5min` |
| `--client-id ID --client-secret S` | required for Google Drive |
| `--token JSON` | for machines without a browser, see below |
| `--remote NAME` | provider name |
| `-y` | ask nothing, use the defaults |

### Own Google client ID (do this for Google Drive)

rclone's shared Google client ID is throttled and **is being retired in 2026**, after which drives that use it stop syncing. Create your own (free, about 5 minutes):

1. Go to <https://console.cloud.google.com/> and create a project.
2. Open **APIs & Services → Library → Google Drive API → Enable**.
3. Open **Google Auth Platform → Branding** (<https://console.cloud.google.com/auth/branding>). Choose audience **External**, then fill in:

   | Field | What to enter |
   |---|---|
   | App name | Anything, e.g. `rclone` |
   | User support email | Your email |
   | App logo | Leave empty |
   | Application home page | `https://github.com/vofy/scripts` |
   | Application privacy policy link | `https://github.com/vofy/scripts/blob/main/doc/rclone-cloud-storage.md` |
   | Application terms of service link | Leave empty |
   | Authorized domains | `github.com` |
   | Developer contact information | Your email |

   Google only checks the links when an app is submitted for verification, which an app used only by you never is.
4. Open **Audience** and add your Google account under **Test users**.
5. Open **Data access → Add or remove scopes**. Add `https://www.googleapis.com/auth/drive`.
6. Open **Clients → Create client** and choose type **Desktop app**. Copy the client ID and secret.
7. Open **Audience → Publish app** (to "In production"). While the app is in testing mode, sign-ins expire every 7 days.

When you sign in, Google shows an "unverified app" screen. Click **Advanced → Go to … (unsafe)**; it's your own app. The same client ID works on all your machines.

### Machines without a browser (servers, SSH)

On a computer with a browser and rclone, run `rclone authorize drive "CLIENT_ID" "CLIENT_SECRET"` (or `rclone authorize onedrive`). Pass the JSON it prints to the script:

```bash
./rclone-cloud-storage.sh --token '{"access_token":...}'
```

For stream mode, also keep your services running after logout: `sudo loginctl enable-linger $USER`.

## Uninstall

```bash
./rclone-cloud-storage.sh --provider gdrive --uninstall   # stop and remove the services (or onedrive)
rclone config delete gdrive                               # forget the account
rm -rf ~/.cache/rclone                                    # cache, logs and sync state (all services)
```

Then remove the app's access: [Google](https://myaccount.google.com/permissions), [Microsoft personal](https://account.live.com/consent/Manage), [Microsoft work/school](https://myapps.microsoft.com).

## Debug

The commands use `gdrive`; for OneDrive use `onedrive`.

```bash
# stream
systemctl --user status rclone-gdrive            # is it mounted?
systemctl --user restart rclone-gdrive           # remount
tail -f ~/.cache/rclone/gdrive-mount.log

# mirror
systemctl --user list-timers rclone-gdrive-bisync.timer   # next sync
systemctl --user start rclone-gdrive-bisync.service       # sync now
tail -f ~/.cache/rclone/gdrive-bisync.log

rclone about gdrive:                             # can rclone reach the drive?
```

| Problem | Fix |
|---|---|
| `invalid_grant`, `Invalid Credentials`, token expired | `rclone config reconnect gdrive:`, then restart the service. If it happens every 7 days, publish your Google app (step 7) |
| `rateLimitExceeded`, very slow Google Drive | You're on rclone's shared client ID. Rerun the script with your own |
| `Time may be set wrong`, sign-in errors | See **Clock** below |
| stream: `directory not empty` | The mount folder must be empty. Move its files out or use another `--path` |
| stream: `Transport endpoint is not connected` | `fusermount3 -uz ~/GoogleDrive; systemctl --user restart rclone-gdrive` |
| mirror: `must run --resync` | Rerun the script; its first sync does the resync (also needed after editing `~/.config/rclone/gdrive-bisync-filters.txt`) |
| mirror: `too many deletes` | Safety stop: over half the files would be deleted. If that's intended, run the `ExecStart` command from `systemctl --user cat rclone-gdrive-bisync.service` once with `--force` added |
| mirror: files named `*.conflict1` | The file changed on both sides. The newer copy keeps the name; check the other one and delete it |
| OneDrive work/school: Office files keep re-syncing | Add `--ignore-size --ignore-checksum` to `ExecStart` in `~/.config/systemd/user/rclone-onedrive-bisync.service`, then `systemctl --user daemon-reload` |

### Clock

Google and Microsoft reject sign-ins when the clock is wrong. In `timedatectl`, `System clock synchronized` should say `yes`. On a dual-boot machine with Windows, make both systems keep the hardware clock in UTC:

```bash
sudo timedatectl set-local-rtc 0
```

On Windows, in an admin terminal:

```
reg add "HKLM\System\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```
