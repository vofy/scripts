#!/usr/bin/env bash
# Copy each new scan from a Google Drive folder to this computer's clipboard, then keep it
# in an archive subfolder for a day. For phone scanner apps that save to Drive (e.g. FairScan):
# scan on the phone, press Ctrl+V on the computer.
#
#   ./drive-clipboard.sh --install     keep it running in the background (systemd user service)
#   ./drive-clipboard.sh --uninstall   remove the service (the Drive folder is kept)
#   ./drive-clipboard.sh               run in the foreground (what the service runs)
#
# Needs an rclone Drive remote (see rclone-cloud-storage.sh), wl-copy and, for PDFs, pdftoppm.
# Docs: https://github.com/vofy/scripts/blob/main/doc/drive-clipboard.md
set -euo pipefail

# ---------------------------------------------------------------- defaults
REMOTE=gdrive                        # rclone remote
FOLDER=10_Clipboard/$(hostname -s)   # Drive folder the phone app saves into, one per computer
ARCHIVE=Archive                      # copied scans move to this subfolder...
MAX_AGE=24h                          # ...and are deleted from it (to Drive's trash) at this age
POLL=10                              # seconds between checks for a new scan
CLEANUP_EVERY=3600                   # seconds between deletions of old scans

UNIT=drive-clipboard.service
UNIT_DIR=$HOME/.config/systemd/user
STATE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/drive-clipboard
ACTION=run

usage() {
    cat <<EOF
Usage: $(basename "$0") [--install | --uninstall] [options]

  --remote NAME     rclone remote                 (default: $REMOTE)
  --folder PATH     Drive folder to watch         (default: $FOLDER)
  --max-age AGE     how long copied scans stay in $ARCHIVE (default: $MAX_AGE)
  --install         run in the background from now on
  --uninstall       remove the background service
  -h, --help        show this help
EOF
}

info() { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33mWarning:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31mError:\e[0m %s\n' "$*" >&2; exit 1; }

# Scans not copied yet as sorted "modtime;name" lines, or nothing (also when Drive can't be reached).
scans() {
    rclone lsf "$REMOTE:$FOLDER" --files-only --format tp --separator ';' 2>/dev/null | sort || true
}

clipboard() {
    local name=$1 file=$STATE_DIR/scan.${1##*.} type
    rclone copyto "$REMOTE:$FOLDER/$name" "$file" || return 1
    case ${name,,} in
        *.png)        type=image/png ;;
        *.jpg|*.jpeg) type=image/jpeg ;;
        *.pdf)        # The clipboard holds images, so a PDF becomes an image of its first page.
                      pdftoppm -png -r 150 -f 1 -l 1 -singlefile "$file" "$STATE_DIR/page" \
                          || { warn "Can't read $name, skipped"; return 0; }
                      file=$STATE_DIR/page.png type=image/png ;;
        *)            warn "$name isn't an image or PDF, skipped"; return 0 ;;
    esac
    wl-copy --type "$type" < "$file"
    info "Copied $name to the clipboard"
    notify-send -a "Drive clipboard" -i image-x-generic "Scan copied to the clipboard" "$name" 2>/dev/null || true
}

run() {
    command -v wl-copy >/dev/null || die "wl-copy is missing (package wl-clipboard)."
    mkdir -p "$STATE_DIR"
    local now name started=0 next_cleanup=0
    rclone mkdir "$REMOTE:$FOLDER/$ARCHIVE" 2>/dev/null || true
    info "Watching $REMOTE:$FOLDER"
    while :; do
        if (( SECONDS >= next_cleanup )); then
            rclone delete "$REMOTE:$FOLDER/$ARCHIVE" --min-age "$MAX_AGE" || warn "Deleting old scans failed"
            next_cleanup=$((SECONDS + CLEANUP_EVERY))
        fi
        now=$(scans)
        if [[ -n $now ]]; then
            # Several scans can arrive between two checks: copy the newest, archive them all.
            # Scans waiting when the service starts are only archived, so logging in doesn't
            # replace the clipboard. A failed download is tried again at the next check.
            if (( started )) && ! clipboard "$(tail -1 <<<"$now" | cut -d';' -f2-)"; then
                sleep "$POLL"
                continue
            fi
            while IFS=';' read -r _ name; do
                rclone moveto "$REMOTE:$FOLDER/$name" "$REMOTE:$FOLDER/$ARCHIVE/$name" || warn "Archiving $name failed"
            done <<<"$now"
        fi
        started=1
        sleep "$POLL"
    done
}

install() {
    local self
    self=$(realpath "$0")
    [[ -f $self ]] || die "Download the script first; --install needs a copy it can run from."
    rclone mkdir "$REMOTE:$FOLDER/$ARCHIVE" || die "Can't reach '$REMOTE:'. Is the rclone remote set up?"

    mkdir -p "$UNIT_DIR"
    info "Writing $UNIT_DIR/$UNIT"
    cat > "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=Copy new scans from $REMOTE:$FOLDER to the clipboard
# The clipboard belongs to the desktop session.
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart="$self" --remote "$REMOTE" --folder "$FOLDER" --max-age $MAX_AGE
Restart=on-failure
RestartSec=30

[Install]
WantedBy=graphical-session.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable "$UNIT"
    systemctl --user restart "$UNIT"
    echo
    info "Done. In the phone app, save scans to the Google Drive folder: $FOLDER"
    echo "  Status:  systemctl --user status $UNIT"
    echo "  Log:     journalctl --user -u $UNIT -f"
}

uninstall() {
    systemctl --user disable --now "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$UNIT"
    systemctl --user daemon-reload
    info "Removed. The Drive folder $REMOTE:$FOLDER and its scans were kept."
}

# Wrapped in main() so a partially downloaded script never runs.
main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --remote)    REMOTE=$2; shift 2 ;;
            --folder)    FOLDER=${2#/}; shift 2 ;;
            --max-age)   MAX_AGE=$2; shift 2 ;;
            --install)   ACTION=install; shift ;;
            --uninstall) ACTION=uninstall; shift ;;
            -h|--help)   usage; exit 0 ;;
            *)           usage >&2; die "Unknown option: $1" ;;
        esac
    done
    "$ACTION"
}

main "$@"
