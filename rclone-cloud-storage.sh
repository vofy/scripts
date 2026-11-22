#!/usr/bin/env bash
# Set up Google Drive or OneDrive on Linux with rclone, mimicking the Windows clients.
#
#   stream  - the drive appears as a folder, files download on demand and are cached
#             (rclone mount + full VFS cache, systemd user service)
#   mirror  - full two-way local copy, works offline
#             (rclone bisync, systemd user timer)
#
# Asks for everything that isn't given as an option (-y takes the defaults instead).
#
# Works when piped:  curl -fsSL <url>/rclone-cloud-storage.sh | bash
# (prompts read from /dev/tty). Needs bash, not sh.
#
# Run ./rclone-cloud-storage.sh --help for options.
set -euo pipefail

PROVIDER=""
MODE=""
REMOTE=""
REMOTE_PATH=""
LOCAL_DIR=""
CACHE_SIZE=""
INTERVAL=""
CLIENT_ID=""
CLIENT_SECRET=""
TOKEN=""
UNINSTALL=0
ASSUME_YES=0

DEFAULT_CACHE_SIZE="20G"
DEFAULT_INTERVAL="5min"
MIN_RCLONE="1.66.0"   # bisync --resync-mode / --conflict-resolve need this
UNIT_DIR="$HOME/.config/systemd/user"
LOG_DIR="$HOME/.cache/rclone"
CLIENT_ID_DOC="https://github.com/vofy/scripts/blob/main/doc/rclone-cloud-storage.md#own-google-client-id-do-this-for-google-drive"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Anything not given is asked interactively.

  --provider gdrive|onedrive  Cloud service
  --mode stream|mirror   Sync mode
  --remote NAME          rclone remote name                 (default: the provider name)
  --remote-path PATH     Only this folder of the drive      (default: whole drive)
  --path DIR             Local folder                       (default: ~/GoogleDrive or ~/OneDrive)
  --cache-size SIZE      stream: max local cache size       (default: $DEFAULT_CACHE_SIZE)
  --interval TIME        mirror: time between syncs         (default: $DEFAULT_INTERVAL)
  --client-id ID         Your own OAuth client ID (required for Google Drive, see
                         $CLIENT_ID_DOC)
  --client-secret SECRET Its client secret
  --token JSON           OAuth token from 'rclone authorize drive|onedrive' (headless machines)
  --uninstall            Remove the systemd units for --remote (keeps files and config)
  -y, --yes              Don't ask anything, use the defaults
  -h, --help             Show this help
EOF
}

info() { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33mWarning:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31mError:\e[0m %s\n' "$*" >&2; exit 1; }

# Prompts read from /dev/tty so they work when the script is piped to bash.
interactive() { [[ $ASSUME_YES -eq 0 ]] && ( : </dev/tty ) 2>/dev/null; }

# confirm "Question" [Y|N]: the second argument is the answer for Enter and for -y.
confirm() {
    local def=${2:-N} ans=""
    [[ $ASSUME_YES -eq 1 ]] && return 0
    if interactive; then
        if [[ $def == Y ]]; then read -rp "$1 [Y/n] " ans </dev/tty; else read -rp "$1 [y/N] " ans </dev/tty; fi
    fi
    [[ ${ans:-$def} =~ ^[Yy] ]]
}

# ask VAR "Question" DEFAULT [LABEL]: sets VAR unless an option already did.
# LABEL is shown in place of an empty default.
ask() {
    local -n _var=$1
    [[ -n $_var ]] && return 0
    interactive && read -rp "$2 [${3:-${4:-none}}]: " _var </dev/tty
    _var=${_var:-$3}
}

# ask_secret VAR "Question": like ask, but hidden and without a default.
ask_secret() {
    local -n _secret=$1
    [[ -n $_secret ]] && return 0
    interactive && { read -rsp "$2: " _secret </dev/tty; echo; }
    return 0
}

# choose VAR "Question" value:Label ...: numbered menu, Enter picks the first one.
choose() {
    local -n _choice=$1
    local q=$2 c="" i=1 opt
    shift 2
    [[ -n $_choice ]] && return 0
    if interactive; then
        echo "$q"
        for opt in "$@"; do echo "  $i) ${opt#*:}"; i=$((i + 1)); done
        read -rp "Choice [1]: " c </dev/tty
    fi
    c=${c:-1}
    [[ $c =~ ^[0-9]+$ ]] && (( c >= 1 && c <= $# )) || die "Invalid choice: $c"
    opt=${!c}
    _choice=${opt%%:*}
}

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

remote_type() { command -v rclone >/dev/null && rclone listremotes --long 2>/dev/null | awk -v r="$1:" '$1==r{print $2}'; }

client_id_of() { command -v rclone >/dev/null && rclone config show "$1" 2>/dev/null | sed -n 's/^client_id = //p' || true; }

has_own_client_id() { [[ -n $(client_id_of "$1") ]]; }

install_pkgs() {
    if   command -v dnf     >/dev/null; then sudo dnf install -y "$@"
    elif command -v apt-get >/dev/null; then sudo apt-get update -qq && sudo apt-get install -y "$@"
    elif command -v pacman  >/dev/null; then sudo pacman -S --needed --noconfirm "$@"
    elif command -v zypper  >/dev/null; then sudo zypper install -y "$@"
    else return 1
    fi
}

rclone_version() { rclone version 2>/dev/null | awk 'NR==1{sub(/^v/,"",$2); sub(/-.*/,"",$2); print $2}'; }

# Wrapped in main() so a partially downloaded script (curl | bash) never runs.
main() {

while [[ $# -gt 0 ]]; do
    case $1 in
        --provider)      PROVIDER=$2; shift 2 ;;
        --mode)          MODE=$2; shift 2 ;;
        --remote)        REMOTE=$2; shift 2 ;;
        --remote-path)   REMOTE_PATH=$2; shift 2 ;;
        --path)          LOCAL_DIR=$2; shift 2 ;;
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
choose PROVIDER "Which cloud service?" "gdrive:Google Drive" "onedrive:OneDrive"

# Everything that differs between providers lives here.
case $PROVIDER in
    gdrive)
        NAME="Google Drive"
        TYPE=drive
        CREATE_ARGS=(scope=drive)
        # Google Docs become small .html links that open in the browser (like .gdoc files).
        MOUNT_ARGS=(--drive-export-formats link.html --drive-acknowledge-abuse --drive-chunk-size 64M)
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

# ---------------------------------------------------------------- questions
interactive && printf '\n==> %s setup (press Enter to accept the [default])\n\n' "$NAME"

choose MODE "How should $NAME be synced?" \
    "stream:stream - files download when opened, little disk space used (the Windows client's default)" \
    "mirror:mirror - full local copy, works offline, synced every ${INTERVAL:-$DEFAULT_INTERVAL}"
[[ $MODE == stream || $MODE == mirror ]] || die "--mode must be 'stream' or 'mirror'"

ask LOCAL_DIR "Local folder" "$HOME/${NAME// /}"
LOCAL_DIR=$(realpath -m "${LOCAL_DIR/#\~/$HOME}")

ask REMOTE_PATH "Only sync this folder of $NAME" "" "whole drive"
REMOTE_PATH=${REMOTE_PATH#/}

if [[ $MODE == stream ]]; then
    ask CACHE_SIZE "Maximum local cache size" "$DEFAULT_CACHE_SIZE"
else
    ask INTERVAL "Time between syncs" "$DEFAULT_INTERVAL"
fi
CACHE_SIZE=${CACHE_SIZE:-$DEFAULT_CACHE_SIZE}
INTERVAL=${INTERVAL:-$DEFAULT_INTERVAL}

# Google is retiring rclone's shared client ID (the drive then stops syncing), so Google Drive
# always needs your own. OneDrive works fine with rclone's built-in client.
client_label=""
if [[ $PROVIDER == gdrive && -z $CLIENT_ID ]]; then
    current_id=$(client_id_of "$REMOTE")
    if interactive; then
        cat <<EOF

    Google Drive needs your own Google client ID. rclone's shared one is throttled,
    and when Google retires it in 2026 the drive stops syncing.
    How to create one in Google Cloud (about 5 minutes):
    $CLIENT_ID_DOC

EOF
        while [[ -z $CLIENT_ID ]]; do
            ask CLIENT_ID "Client ID" "$current_id" "required"
            [[ -n $CLIENT_ID ]] || echo "A client ID is required. Create one using the link above."
        done
    else
        CLIENT_ID=$current_id
        [[ -n $CLIENT_ID ]] || die "Google Drive needs your own client ID: pass --client-id and --client-secret.
       How to create one: $CLIENT_ID_DOC"
    fi
    # Keeping the remote's current ID changes nothing, so no secret or new sign-in is needed.
    if [[ $CLIENT_ID == "$current_id" ]]; then
        CLIENT_ID=""
        client_label="your own (unchanged)"
    fi
fi
[[ -n $CLIENT_ID ]] && ask_secret CLIENT_SECRET "Client secret"
[[ -n $CLIENT_ID && -z $CLIENT_SECRET ]] && die "--client-id needs --client-secret"
[[ -n $CLIENT_ID ]] && client_label="your own (new, you'll sign in again)"

echo
info "Summary"
echo "    Service:       $NAME (rclone remote '$REMOTE')"
if [[ $MODE == stream ]]; then
    echo "    Mode:          stream, cache up to $CACHE_SIZE"
else
    echo "    Mode:          mirror, synced every $INTERVAL"
fi
echo "    Local folder:  $LOCAL_DIR"
echo "    Cloud folder:  ${REMOTE_PATH:-whole drive}"
[[ $PROVIDER == gdrive ]] && echo "    Client ID:     $client_label"
echo
confirm "Continue?" Y || die "Aborted."

# ---------------------------------------------------------------- install
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
    warn "Check 'timedatectl'. On dual-boot machines see doc/rclone-cloud-storage.md, section 'Clock'."
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
        # config_refresh_token=false: sign in once, in reconnect, not twice.
        rclone config update "$REMOTE" client_id="$CLIENT_ID" client_secret="$CLIENT_SECRET" config_refresh_token=false >/dev/null
        rclone config reconnect "$REMOTE:"
    fi
else
    info "Creating remote '$REMOTE'"
    # Without a desktop session there's no browser here: sign in on another machine instead.
    if [[ -z $TOKEN && -z ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
        auth_cmd="rclone authorize $TYPE${CLIENT_ID:+ \"$CLIENT_ID\" \"<client secret>\"}"
        interactive || die "No graphical session for the $NAME sign-in. On a machine with a browser run:
       $auth_cmd
and pass the printed JSON here with --token '<json>'."
        echo "There's no browser on this machine. On a computer with a browser and rclone, run:"
        echo "    $auth_cmd"
        echo "sign in, and paste the JSON it prints ({\"access_token\":...})."
        read -rp "Token: " TOKEN </dev/tty
        [[ -n $TOKEN ]] || die "A token is required."
    fi
    if [[ -n $TOKEN ]]; then
        rclone config create "$REMOTE" "$TYPE" "${auth_args[@]}" token="$TOKEN" config_refresh_token=false >/dev/null
    else
        echo "A browser window will open. Sign in and allow rclone access."
        echo "If it doesn't open, copy the http://127.0.0.1:53682/auth?... link printed below."
        rclone config create "$REMOTE" "$TYPE" "${auth_args[@]}" config_is_local=true >/dev/null
    fi
fi
chmod 600 "$(rclone config file | tail -1)"

# Own client ID has its own quota, so drop rclone's conservative 10 requests/s limit.
if [[ $PROVIDER == gdrive ]] && has_own_client_id "$REMOTE"; then
    MOUNT_ARGS+=(--drive-pacer-min-sleep 10ms --drive-pacer-burst 200)
    BISYNC_ARGS+=(--drive-pacer-min-sleep 10ms --drive-pacer-burst 200)
fi

rclone about "$REMOTE:" >/dev/null 2>&1 || die "Can't access '$REMOTE:'. Check 'rclone about $REMOTE:'."
SRC="$REMOTE:$REMOTE_PATH"
if [[ -n $REMOTE_PATH ]]; then
    rclone lsjson --stat "$SRC" >/dev/null 2>&1 || die "Folder '$REMOTE_PATH' not found on $NAME"
fi

mkdir -p "$UNIT_DIR" "$LOG_DIR" "$LOCAL_DIR"

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
}

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

    # Remote control socket in the user's private runtime dir (%t), used to pre-load the folder tree.
    # No auth needed: only this user can reach the socket.
    local sock="%t/rclone-$REMOTE.sock"

    info "Writing $UNIT_DIR/$STREAM_UNIT"
    cat > "$UNIT_DIR/$STREAM_UNIT" <<EOF
[Unit]
Description=$NAME stream mount ($SRC -> $LOCAL_DIR)
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStartPre=-$FUSERMOUNT -uz "$LOCAL_DIR"
ExecStartPre=-rm -f "$sock"
ExecStart=$RCLONE mount "$SRC" "$LOCAL_DIR" \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size $CACHE_SIZE \\
    --vfs-cache-max-age 720h \\
    --vfs-cache-min-free-space 10G \\
    --vfs-write-back 5s \\
    --vfs-read-ahead 128M \\
    --vfs-fast-fingerprint \\
    --dir-cache-time 1000h \\
    --poll-interval 15s \\
    --attr-timeout 10s \\
    --transfers 8 \\
    --rc --rc-addr "unix://$sock" --rc-no-auth \\
    --volname "$NAME" \\
    --umask 077 \\
    --log-level NOTICE \\
    --log-file "$LOG_DIR/$REMOTE-mount.log"$extra
# The folder list lives in memory, so without this every folder is slow the first time after boot.
ExecStartPost=$RCLONE rc --unix-socket "$sock" vfs/refresh recursive=true _async=true
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

main "$@"
