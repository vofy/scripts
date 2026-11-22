# Drive clipboard

Scan on your phone, press Ctrl+V on your computer. A phone scanner app that saves to Google Drive (e.g. [FairScan](https://github.com/pynicolas/FairScan)) puts each scan in a Drive folder for this computer. This script copies every new scan from there to the clipboard, and deletes scans older than 24 hours.

PNG and JPEG scans are copied as they are; a PDF is copied as an image of its first page.

## Setup

Needs Google Drive set up with [rclone-cloud-storage.sh](rclone-cloud-storage.md) (an rclone remote named `gdrive`), a Wayland desktop and `wl-clipboard`.

```bash
curl -fsSLO https://raw.githubusercontent.com/vofy/scripts/main/drive-clipboard.sh
chmod +x drive-clipboard.sh
./drive-clipboard.sh --install
```

It creates the Drive folder `10_Clipboard/<hostname>` and a systemd user service that checks it every 10 seconds while you're logged in. In the phone app, choose that folder as the Google Drive destination.

| Option | Default |
|---|---|
| `--remote NAME` | `gdrive` |
| `--folder PATH` | `10_Clipboard/<hostname>` |
| `--max-age AGE` | `24h` |

Deleted scans go to Drive's trash, where they stay for 30 days.

## Uninstall

```bash
./drive-clipboard.sh --uninstall
```

The Drive folder and its scans are kept.

## Debug

```bash
systemctl --user status drive-clipboard         # is it running?
journalctl --user -u drive-clipboard -f         # copied scans and errors
rclone lsf gdrive:10_Clipboard/$(hostname -s)   # what's in the folder
```

| Problem | Fix |
|---|---|
| Nothing is copied | Check that the phone saves to `10_Clipboard/<hostname>` of the same Google account. Scans already there when the service starts aren't copied, only new ones |
| `wl-copy is missing` | Install `wl-clipboard` |
| Errors about the remote or `invalid_grant` | See Debug in [rclone-cloud-storage](rclone-cloud-storage.md#debug) |
