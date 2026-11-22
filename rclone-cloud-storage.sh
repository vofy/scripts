#!/usr/bin/env bash
# Set up Google Drive or OneDrive on Linux with rclone, mimicking the Windows clients.
#
#   stream  - the drive appears as a folder, files download on demand and are cached
#             (rclone mount + full VFS cache, systemd user service)
#   mirror  - full two-way local copy, works offline
#             (rclone bisync, systemd user timer)
#
# Works when piped:  curl -fsSL <url>/setup.sh | bash -s -- --provider onedrive --mode stream
# (prompts read from /dev/tty). Needs bash, not sh.
#
# Run ./setup.sh --help for options.
set -euo pipefail

PROVIDER=""
MODE=""
REMOTE=""
REMOTE_PATH=""
LOCAL_DIR=""
CACHE_SIZE="20G"
INTERVAL="5min"
CLIENT_ID=""
CLIENT_SECRET=""
TOKEN=""
UNINSTALL=0
ASSUME_YES=0

MIN_RCLONE="1.66.0"   # bisync --resync-mode / --conflict-resolve need this
UNIT_DIR="$HOME/.config/systemd/user"
LOG_DIR="$HOME/.cache/rclone"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --provider gdrive|onedrive  Cloud service (asked interactively if omitted)
  --mode stream|mirror   Sync mode (asked interactively if omitted)
  --remote NAME          rclone remote name                 (default: the provider name)
  --remote-path PATH     Only this folder of the drive      (default: whole drive)
  --path DIR             Local folder                       (default: ~/GoogleDrive or ~/OneDrive)
  --cache-size SIZE      stream: max local cache size       (default: $CACHE_SIZE)
  --interval TIME        mirror: time between syncs         (default: $INTERVAL)
  --client-id ID         Your own OAuth client ID (recommended for Google Drive)
  --client-secret SECRET Its client secret
  --token JSON           OAuth token from 'rclone authorize drive|onedrive' (headless machines)
  --uninstall            Remove the systemd units for --remote (keeps files and config)
  -y, --yes              Don't ask for confirmation
  -h, --help             Show this help
EOF
}

info() { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33mWarning:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31mError:\e[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    read -rp "$1 [y/N] " ans </dev/tty
    [[ $ans =~ ^[Yy] ]]
}

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

remote_type() { command -v rclone >/dev/null && rclone listremotes --long 2>/dev/null | awk -v r="$1:" '$1==r{print $2}'; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --provider)      PROVIDER=$2; shift 2 ;;
        --mode)          MODE=$2; shift 2 ;;
        --remote)        REMOTE=$2; shift 2 ;;
        --remote-path)   REMOTE_PATH=${2#/}; shift 2 ;;
        --path)          LOCAL_DIR=$(realpath -m "$2"); shift 2 ;;
        --cache-size)    CACHE_SIZE=$2; shift 2 ;;
        --interval)      INTERVAL=$2; shift 2 ;;
        --client-id)     CLIENT_ID=$2; shift 2 ;;
        --client-secret) CLIENT_SECRET=$2; shift 2 ;;
        --token)         TOKEN=$2; shift 2 ;;
        --uninstall)     UNINSTALL=1; shift ;;
        -y|--yes)        ASSUME_YES=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; die "Unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] && die "Run this as your normal user, not root (it uses sudo when needed)."

# ---------------------------------------------------------------- choose provider
# An existing --remote already tells us the provider.
if [[ -z $PROVIDER && -n $REMOTE ]]; then
    case $(remote_type "$REMOTE" || true) in
        drive)    PROVIDER=gdrive ;;
        onedrive) PROVIDER=onedrive ;;
    esac
fi
if [[ -z $PROVIDER ]]; then
    echo "Which cloud service?"
    echo "  1) Google Drive"
    echo "  2) OneDrive"
    read -rp "Choice [1]: " c </dev/tty
    case ${c:-1} in 1|gdrive) PROVIDER=gdrive ;; 2|onedrive) PROVIDER=onedrive ;; *) die "Invalid choice" ;; esac
fi

# Everything that differs between providers lives here.
case $PROVIDER in
    gdrive)
        NAME="Google Drive"
        TYPE=drive
        CREATE_ARGS=(scope=drive)
        # Google Docs become small .html links that open in the browser (like .gdoc files).
        MOUNT_ARGS=(--drive-export-formats link.html --drive-acknowledge-abuse)
        # Google Docs have no size or hash, so they can't be synced both ways.
        BISYNC_ARGS=(--drive-skip-gdocs --drive-acknowledge-abuse)
        ;;
    onedrive)
        NAME="OneDrive"
        TYPE=onedrive
        CREATE_ARGS=()
        MOUNT_ARGS=()
        BISYNC_ARGS=()
        ;;
    *) die "--provider must be 'gdrive' or 'onedrive'" ;;
esac
REMOTE=${REMOTE:-$PROVIDER}
LOCAL_DIR=${LOCAL_DIR:-$HOME/${NAME// /}}

STREAM_UNIT="rclone-$REMOTE.service"
MIRROR_UNIT="rclone-$REMOTE-bisync"

# ---------------------------------------------------------------- uninstall
if [[ $UNINSTALL -eq 1 ]]; then
    info "Removing systemd units for remote '$REMOTE'"
    systemctl --user disable --now "$STREAM_UNIT" "$MIRROR_UNIT.timer" 2>/dev/null || true
    systemctl --user stop "$MIRROR_UNIT.service" 2>/dev/null || true
    rm -f "$UNIT_DIR/$STREAM_UNIT" "$UNIT_DIR/$MIRROR_UNIT.service" "$UNIT_DIR/$MIRROR_UNIT.timer"
    systemctl --user daemon-reload
    echo "Done. Local files, the rclone remote and its cache were left in place."
    echo "To remove those too:  rclone config delete $REMOTE; rm -rf ~/.cache/rclone"
    exit 0
fi

# ---------------------------------------------------------------- choose mode
if [[ -z $MODE ]]; then
    echo "How should $NAME be synced?"
    echo "  1) stream - files download when opened, little disk space used (the Windows client's default)"
    echo "  2) mirror - full local copy, works offline, synced every $INTERVAL"
    read -rp "Choice [1]: " c </dev/tty
    case ${c:-1} in 1|stream) MODE=stream ;; 2|mirror) MODE=mirror ;; *) die "Invalid choice" ;; esac
fi
[[ $MODE == stream || $MODE == mirror ]] || die "--mode must be 'stream' or 'mirror'"
[[ -n $CLIENT_ID && -z $CLIENT_SECRET ]] && die "--client-id needs --client-secret"

# ---------------------------------------------------------------- install
install_pkgs() {
    if   command -v dnf     >/dev/null; then sudo dnf install -y "$@"
    elif command -v apt-get >/dev/null; then sudo apt-get update -qq && sudo apt-get install -y "$@"
    elif command -v pacman  >/dev/null; then sudo pacman -S --needed --noconfirm "$@"
    elif command -v zypper  >/dev/null; then sudo zypper install -y "$@"
    else return 1
    fi
}

rclone_version() { rclone version 2>/dev/null | awk 'NR==1{sub(/^v/,"",$2); sub(/-.*/,"",$2); print $2}'; }

if ! command -v rclone >/dev/null; then
    info "Installing rclone"
    install_pkgs rclone || true
fi
if ! command -v rclone >/dev/null || ! version_ge "$(rclone_version)" "$MIN_RCLONE"; then
    info "Distro rclone missing or older than $MIN_RCLONE, installing the official build"
    command -v curl >/dev/null || install_pkgs curl
    command -v unzip >/dev/null || install_pkgs unzip
    curl -fsSL https://rclone.org/install.sh | sudo bash
    hash -r
fi
info "Using rclone $(rclone_version)"

if [[ $MODE == stream ]] && ! command -v fusermount3 >/dev/null && ! command -v fusermount >/dev/null; then
    info "Installing FUSE"
    install_pkgs fuse3 || install_pkgs fuse || die "Install FUSE (fuse3) manually"
fi
FUSERMOUNT=$(command -v fusermount3 || command -v fusermount || true)
RCLONE=$(command -v rclone)

# ---------------------------------------------------------------- clock check
if command -v timedatectl >/dev/null && [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) != yes ]]; then
    warn "System clock is not NTP-synchronized. A wrong clock breaks sign-in and sync timestamps."
    warn "Check 'timedatectl'. On dual-boot machines see the README section 'Clock'."
fi

# ---------------------------------------------------------------- remote
auth_args=("${CREATE_ARGS[@]}")
[[ -n $CLIENT_ID ]] && auth_args+=(client_id="$CLIENT_ID" client_secret="$CLIENT_SECRET")

existing=$(remote_type "$REMOTE" || true)
if [[ -n $existing ]]; then
    [[ $existing == "$TYPE" ]] || die "Remote '$REMOTE' is of type '$existing', not '$TYPE'. Pick another --remote."
    info "Remote '$REMOTE' already exists, reusing it"
    if [[ -n $CLIENT_ID ]]; then
        info "Switching '$REMOTE' to your own client ID (sign in again in the browser)"
        rclone config update "$REMOTE" client_id="$CLIENT_ID" client_secret="$CLIENT_SECRET"
        rclone config reconnect "$REMOTE:"
    fi
else
    info "Creating remote '$REMOTE'"
    if [[ -n $TOKEN ]]; then
        rclone config create "$REMOTE" "$TYPE" "${auth_args[@]}" token="$TOKEN" config_refresh_token=false >/dev/null
    elif [[ -z ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
        die "No graphical session for the $NAME sign-in. On a machine with a browser run:
       rclone authorize $TYPE${CLIENT_ID:+ \"$CLIENT_ID\" \"$CLIENT_SECRET\"}
and pass the printed JSON here with --token '<json>'."
    else
        echo "A browser window will open. Sign in and allow rclone access."
        echo "If it doesn't open, copy the http://127.0.0.1:53682/auth?... link printed below."
        rclone config create "$REMOTE" "$TYPE" "${auth_args[@]}" config_is_local=true >/dev/null
    fi
fi
chmod 600 "$(rclone config file | tail -1)"

if [[ $PROVIDER == gdrive ]] && ! rclone config show "$REMOTE" | grep -qE '^client_id = .+'; then
    warn "'$REMOTE' uses rclone's shared Google client ID, which Google is retiring in 2026."
    warn "Create your own (README: 'Own Google client ID') and rerun with --client-id/--client-secret."
fi

rclone about "$REMOTE:" >/dev/null 2>&1 || die "Can't access '$REMOTE:'. Check 'rclone about $REMOTE:'."
SRC="$REMOTE:$REMOTE_PATH"
if [[ -n $REMOTE_PATH ]]; then
    rclone lsjson --stat "$SRC" >/dev/null 2>&1 || die "Folder '$REMOTE_PATH' not found on $NAME"
fi

mkdir -p "$UNIT_DIR" "$LOG_DIR" "$LOCAL_DIR"

# ---------------------------------------------------------------- stream
setup_stream() {
    systemctl --user disable --now "$MIRROR_UNIT.timer" 2>/dev/null || true
    rm -f "$UNIT_DIR/$MIRROR_UNIT.service" "$UNIT_DIR/$MIRROR_UNIT.timer"

    if ! mountpoint -q "$LOCAL_DIR" && [[ -n $(ls -A "$LOCAL_DIR") ]]; then
        die "$LOCAL_DIR is not empty. Stream mode mounts over it; pick an empty --path."
    fi

    # Provider flags go on one extra continuation line, or nowhere when there are none.
    local extra=""
    [[ ${#MOUNT_ARGS[@]} -gt 0 ]] && extra=" \\"$'\n'"    ${MOUNT_ARGS[*]}"

    info "Writing $UNIT_DIR/$STREAM_UNIT"
    cat > "$UNIT_DIR/$STREAM_UNIT" <<EOF
[Unit]
Description=$NAME stream mount ($SRC -> $LOCAL_DIR)
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStartPre=-$FUSERMOUNT -uz "$LOCAL_DIR"
ExecStart=$RCLONE mount "$SRC" "$LOCAL_DIR" \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size $CACHE_SIZE \\
    --vfs-cache-max-age 720h \\
    --vfs-cache-min-free-space 10G \\
    --vfs-write-back 5s \\
    --vfs-read-ahead 128M \\
    --dir-cache-time 1000h \\
    --poll-interval 15s \\
    --volname "$NAME" \\
    --umask 077 \\
    --log-level NOTICE \\
    --log-file "$LOG_DIR/$REMOTE-mount.log"$extra
ExecStop=$FUSERMOUNT -uz "$LOCAL_DIR"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable "$STREAM_UNIT"
    systemctl --user restart "$STREAM_UNIT"
    sleep 2
    systemctl --user is-active --quiet "$STREAM_UNIT" || die "Mount failed: journalctl --user -u $STREAM_UNIT"
}

# ---------------------------------------------------------------- mirror
setup_mirror() {
    systemctl --user disable --now "$STREAM_UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$STREAM_UNIT"
    mountpoint -q "$LOCAL_DIR" && { [[ -n $FUSERMOUNT ]] && "$FUSERMOUNT" -uz "$LOCAL_DIR"; }

    local filters="$HOME/.config/rclone/$REMOTE-bisync-filters.txt"
    info "Writing $filters"
    cat > "$filters" <<'EOF'
# Temporary and system files that should never be synced.
# After editing this file run the bisync once with --resync.
- .~lock.*#
- ~$*
- *.tmp
- *.part
- .Trash-*/**
- .directory
- .DS_Store
- desktop.ini
- Thumbs.db
EOF

    local need used free
    used=$(rclone size "$SRC" --json 2>/dev/null | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
    free=$(df -B1 --output=avail "$LOCAL_DIR" | tail -1)
    need=${used:-0}
    info "$NAME data to download: $(numfmt --to=iec "$need"), free locally: $(numfmt --to=iec "$free")"
    (( need > free )) && die "Not enough disk space for a full mirror. Use stream mode or --remote-path."

    local args=(
        "$SRC" "$LOCAL_DIR"
        --create-empty-src-dirs
        --resilient --recover --max-lock 2m
        --conflict-resolve newer --conflict-loser num
        --filters-file "$filters"
        "${BISYNC_ARGS[@]}"
        --log-level NOTICE --log-file "$LOG_DIR/$REMOTE-bisync.log"
    )

    info "Writing $UNIT_DIR/$MIRROR_UNIT.{service,timer}"
    cat > "$UNIT_DIR/$MIRROR_UNIT.service" <<EOF
[Unit]
Description=$NAME two-way sync ($SRC <-> $LOCAL_DIR)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$RCLONE bisync $(printf '"%s" ' "${args[@]}")
Nice=10
IOSchedulingClass=idle
EOF
    cat > "$UNIT_DIR/$MIRROR_UNIT.timer" <<EOF
[Unit]
Description=Run $NAME two-way sync every $INTERVAL

[Timer]
OnBootSec=2min
OnUnitInactiveSec=$INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload

    if [[ -n $(ls -A "$LOCAL_DIR") ]]; then
        warn "$LOCAL_DIR already has files. The first sync merges both sides (newer copy wins)."
    fi
    confirm "Run the first full sync now? It can take a long time on a big drive." \
        || die "Aborted. Nothing was synced; rerun the script when ready."
    info "First sync (--resync), progress below"
    rclone bisync "${args[@]}" --resync --resync-mode newer --progress --log-file "" \
        || die "Initial sync failed. Fix the error above and rerun the script."

    systemctl --user enable --now "$MIRROR_UNIT.timer"
}

if [[ $MODE == stream ]]; then setup_stream; else setup_mirror; fi

# ---------------------------------------------------------------- file manager bookmark
bm="$HOME/.config/gtk-3.0/bookmarks"
mkdir -p "$(dirname "$bm")"
uri="file://$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$LOCAL_DIR" 2>/dev/null || echo "$LOCAL_DIR")"
grep -q "^$uri " "$bm" 2>/dev/null || echo "$uri $NAME" >> "$bm"

echo
info "Done: $NAME ($MODE) at $LOCAL_DIR"
if [[ $MODE == stream ]]; then
    echo "  Status:  systemctl --user status $STREAM_UNIT"
    echo "  Log:     $LOG_DIR/$REMOTE-mount.log"
else
    echo "  Status:  systemctl --user list-timers $MIRROR_UNIT.timer"
    echo "  Sync now: systemctl --user start $MIRROR_UNIT.service"
    echo "  Log:     $LOG_DIR/$REMOTE-bisync.log"
fi
