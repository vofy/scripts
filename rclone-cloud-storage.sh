#!/usr/bin/env bash
# Set up Google Drive or OneDrive on Linux with rclone, like the Windows clients:
#   stream - the drive appears as a folder, files download when opened (rclone mount, systemd service)
#   mirror - full two-way local copy that works offline (rclone bisync, systemd timer)
#
# Asks for every setting not given as an option; -y takes the defaults.
# Works when piped (prompts read /dev/tty):  curl -fsSL <url>/rclone-cloud-storage.sh | bash
set -euo pipefail

# ---------------------------------------------------------------- defaults
CACHE_SIZE_DEFAULT=20G   # stream: max local cache
INTERVAL_DEFAULT=5min    # mirror: time between syncs
MIN_RCLONE=1.66.0        # bisync --resync-mode / --conflict-resolve need this

# stream: opened files stay cached for 30 days, changes upload after 5 s, and the folder
# list is kept in memory and refreshed by polling every 15 s.
MOUNT_FLAGS=(
    --vfs-cache-mode full --vfs-cache-max-age 720h --vfs-cache-min-free-space 10G
    --vfs-write-back 5s --vfs-read-ahead 128M --vfs-fast-fingerprint
    --dir-cache-time 1000h --poll-interval 15s --attr-timeout 10s
    --transfers 8 --umask 077 --log-level NOTICE
)
# mirror: on a conflict the newer copy wins and the other is kept with a number suffix.
BISYNC_FLAGS=(
    --create-empty-src-dirs --resilient --recover --max-lock 2m
    --conflict-resolve newer --conflict-loser num --log-level NOTICE
)
# Google Drive: bigger upload chunks and, since the script requires your own client ID, a
# higher request rate. Google Docs become .html links in stream mode (like .gdoc files) and
# are skipped in mirror mode, because they have no size or hash.
GDRIVE_FLAGS=(--drive-acknowledge-abuse --drive-chunk-size 64M --drive-pacer-min-sleep 10ms --drive-pacer-burst 200)
GDRIVE_MOUNT_FLAGS=(--drive-export-formats link.html)
GDRIVE_BISYNC_FLAGS=(--drive-skip-gdocs)

# mirror: temporary and system files that are never synced.
BISYNC_FILTERS='- .~lock.*#
- ~$*
- *.tmp
- *.part
- .Trash-*/**
- .directory
- .DS_Store
- desktop.ini
- Thumbs.db'

UNIT_DIR=$HOME/.config/systemd/user
LOG_DIR=$HOME/.cache/rclone
CLIENT_ID_DOC=https://github.com/vofy/scripts/blob/main/doc/rclone-cloud-storage.md#own-google-client-id-do-this-for-google-drive

# ---------------------------------------------------------------- options
PROVIDER="" MODE="" REMOTE="" REMOTE_PATH="" LOCAL_DIR="" CACHE_SIZE="" INTERVAL=""
CLIENT_ID="" CLIENT_SECRET="" TOKEN="" UNINSTALL=0 ASSUME_YES=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Anything not given is asked for.

  --provider gdrive|onedrive  Cloud service                 (default: gdrive)
  --mode stream|mirror        Sync mode                     (default: stream)
  --path DIR                  Local folder                  (default: ~/GoogleDrive or ~/OneDrive)
  --remote-path PATH          Only this folder of the drive (default: whole drive)
  --cache-size SIZE           stream: max local cache       (default: $CACHE_SIZE_DEFAULT)
  --interval TIME             mirror: time between syncs    (default: $INTERVAL_DEFAULT)
  --client-id ID              Your own OAuth client ID, required for Google Drive:
  --client-secret SECRET        $CLIENT_ID_DOC
  --token JSON                Token from 'rclone authorize' (machines without a browser)
  --name NAME                 Name of this setup (its rclone remote), to set up the
                              same service more than once   (default: gdrive or onedrive)
  --uninstall [NAME]          Remove the setup NAME (asks which if not given)
  -y, --yes                   Don't ask, use the defaults
  -h, --help                  Show this help
EOF
}

# ---------------------------------------------------------------- helpers
info() { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33mWarning:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31mError:\e[0m %s\n' "$*" >&2; exit 1; }

# Prompts read /dev/tty so they work when the script is piped to bash.
can_ask() { [[ $ASSUME_YES -eq 0 ]] && ( : </dev/tty ) 2>/dev/null; }

# ask VAR "Question" DEFAULT: sets VAR unless an option already did.
ask() {
    local -n _v=$1
    [[ -n $_v ]] && return 0
    can_ask && read -rp "$2${3:+ [$3]}: " _v </dev/tty
    _v=${_v:-$3}
}

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }
rclone_version() { rclone version 2>/dev/null | awk 'NR==1{sub(/^v/,"",$2); sub(/-.*/,"",$2); print $2}'; }
folder_uri() { echo "file://$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1" 2>/dev/null || echo "$1")"; }
client_id_of() { command -v rclone >/dev/null && rclone config show "$1" 2>/dev/null | sed -n 's/^client_id = //p' || true; }

install_pkgs() {
    if   command -v dnf     >/dev/null; then sudo dnf install -y "$@"
    elif command -v apt-get >/dev/null; then sudo apt-get update -qq && sudo apt-get install -y "$@"
    elif command -v pacman  >/dev/null; then sudo pacman -S --needed --noconfirm "$@"
    elif command -v zypper  >/dev/null; then sudo zypper install -y "$@"
    else return 1
    fi
}

# Flags for a systemd ExecStart line: one flag (with its value) per continuation line,
# values with spaces quoted.
unit_args() {
    local a
    for a; do
        [[ $a == *' '* ]] && a="\"$a\""
        if [[ $a == -* ]]; then printf ' \\\n    %s' "$a"; else printf ' %s' "$a"; fi
    done
}

# ---------------------------------------------------------------- steps
# Google is retiring rclone's shared client ID (the drive then stops syncing), so Google Drive
# always needs your own. Keeping the remote's current one needs no new sign-in.
ask_client_id() {
    local current
    current=$(client_id_of "$REMOTE")
    if [[ -z $CLIENT_ID ]] && can_ask; then
        echo
        echo "Google Drive needs your own Google client ID; rclone's shared one stops working in 2026."
        echo "How to create one (about 5 minutes): $CLIENT_ID_DOC"
        while [[ -z $CLIENT_ID ]]; do
            read -rp "Client ID [${current:-required}]: " CLIENT_ID </dev/tty
            CLIENT_ID=${CLIENT_ID:-$current}
        done
    fi
    CLIENT_ID=${CLIENT_ID:-$current}
    [[ -n $CLIENT_ID ]] || die "Google Drive needs your own client ID (--client-id, --client-secret): $CLIENT_ID_DOC"
    if [[ $CLIENT_ID == "$current" ]]; then
        CLIENT_ID=""
    elif [[ -z $CLIENT_SECRET ]] && can_ask; then
        read -rsp "Client secret: " CLIENT_SECRET </dev/tty
        echo
    fi
}

install_rclone() {
    command -v rclone >/dev/null || { info "Installing rclone"; install_pkgs rclone || true; }
    if ! command -v rclone >/dev/null || ! version_ge "$(rclone_version)" "$MIN_RCLONE"; then
        info "Installing the official rclone build ($MIN_RCLONE or newer is needed)"
        command -v curl >/dev/null || install_pkgs curl
        command -v unzip >/dev/null || install_pkgs unzip
        curl -fsSL https://rclone.org/install.sh | sudo bash
        hash -r
    fi
    if [[ $MODE == stream ]] && ! command -v fusermount3 >/dev/null && ! command -v fusermount >/dev/null; then
        info "Installing FUSE"
        install_pkgs fuse3 || install_pkgs fuse || die "Install FUSE (fuse3) manually"
    fi
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo yes) != yes ]]; then
        warn "The system clock isn't NTP-synchronized; a wrong clock breaks sign-in and sync. See 'Clock' in the doc."
    fi
}

setup_remote() {
    local existing auth=("${CREATE_ARGS[@]}")
    [[ -n $CLIENT_ID ]] && auth+=(client_id="$CLIENT_ID" client_secret="$CLIENT_SECRET")
    existing=$(rclone listremotes --long | awk -v r="$REMOTE:" '$1==r{print $2}')

    if [[ -n $existing ]]; then
        [[ $existing == "$TYPE" ]] || die "Remote '$REMOTE' is a $existing remote, not $TYPE. Pick another --remote."
        if [[ -n $CLIENT_ID ]]; then
            info "Switching '$REMOTE' to your client ID, sign in again in the browser"
            # config_refresh_token=false: sign in once, in reconnect, not twice.
            rclone config update "$REMOTE" "${auth[@]}" config_refresh_token=false >/dev/null
            rclone config reconnect "$REMOTE:"
        fi
    elif [[ -n $TOKEN ]]; then
        rclone config create "$REMOTE" "$TYPE" "${auth[@]}" token="$TOKEN" config_refresh_token=false >/dev/null
    elif [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
        info "Sign in to $NAME in the browser (if it doesn't open, use the link below)"
        rclone config create "$REMOTE" "$TYPE" "${auth[@]}" config_is_local=true >/dev/null
    else
        die "There's no browser here for the $NAME sign-in. On a computer with one, run
       rclone authorize $TYPE${CLIENT_ID:+ \"$CLIENT_ID\" \"<client secret>\"}
and rerun this script with --token '<the JSON it prints>'."
    fi
    chmod 600 "$(rclone config file | tail -1)"
    rclone lsf --max-depth 1 "$SRC" >/dev/null 2>&1 || die "Can't open '$SRC'. Check 'rclone lsf $SRC'."
}

setup_stream() {
    systemctl --user disable --now "$MIRROR_UNIT.timer" 2>/dev/null || true
    systemctl --user stop "$MIRROR_UNIT.service" 2>/dev/null || true
    rm -f "$UNIT_DIR/$MIRROR_UNIT".{service,timer}
    mountpoint -q "$LOCAL_DIR" || [[ -z $(ls -A "$LOCAL_DIR") ]] \
        || die "$LOCAL_DIR isn't empty. Stream mode mounts over it, so pick an empty --path."

    # ExecStartPost pre-loads the folder tree through a socket in the private runtime dir (%t),
    # so folders don't each take a second or two to open the first time after boot.
    local sock=%t/rclone-$REMOTE.sock fusermount
    fusermount=$(command -v fusermount3 || command -v fusermount)
    info "Writing $UNIT_DIR/$STREAM_UNIT"
    cat > "$UNIT_DIR/$STREAM_UNIT" <<EOF
[Unit]
Description=$NAME stream mount ($SRC -> $LOCAL_DIR)
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStartPre=-$fusermount -uz "$LOCAL_DIR"
ExecStartPre=-rm -f "$sock"
ExecStart=$(command -v rclone) mount "$SRC" "$LOCAL_DIR"$(unit_args "${MOUNT_FLAGS[@]}" \
    --vfs-cache-max-size "$CACHE_SIZE" --volname "$NAME" --log-file "$LOG_DIR/$REMOTE-mount.log" \
    --rc --rc-addr "unix://$sock" --rc-no-auth)
ExecStartPost=$(command -v rclone) rc --unix-socket "$sock" vfs/refresh recursive=true _async=true
ExecStop=$fusermount -uz "$LOCAL_DIR"
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

setup_mirror() {
    systemctl --user disable --now "$STREAM_UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$STREAM_UNIT"

    local filters=$HOME/.config/rclone/$REMOTE-bisync-filters.txt used free
    printf '# After editing this file, run the bisync once with --resync.\n%s\n' "$BISYNC_FILTERS" > "$filters"
    local args=("${BISYNC_FLAGS[@]}" --filters-file "$filters" --log-file "$LOG_DIR/$REMOTE-bisync.log")

    used=$(rclone size "$SRC" --json | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
    used=${used:-0}
    free=$(df -B1 --output=avail "$LOCAL_DIR" | tail -1)
    (( used < free )) || die "$NAME holds $(numfmt --to=iec "$used") but only $(numfmt --to=iec "$free") is free here. Use stream mode or --remote-path."

    info "Writing $UNIT_DIR/$MIRROR_UNIT.{service,timer}"
    cat > "$UNIT_DIR/$MIRROR_UNIT.service" <<EOF
[Unit]
Description=$NAME two-way sync ($SRC <-> $LOCAL_DIR)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$(command -v rclone) bisync "$SRC" "$LOCAL_DIR"$(unit_args "${args[@]}")
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

    [[ -z $(ls -A "$LOCAL_DIR") ]] || warn "$LOCAL_DIR already has files. The first sync merges both sides (the newer copy wins)."
    info "First full sync, $(numfmt --to=iec "$used") to download"
    rclone bisync "$SRC" "$LOCAL_DIR" "${args[@]}" --resync --resync-mode newer --progress --log-file "" \
        || die "The first sync failed. Fix the error above and rerun the script."
    systemctl --user enable --now "$MIRROR_UNIT.timer"
}

# Names of the setups that have systemd units (rclone-NAME.service, rclone-NAME-bisync.*).
installed_names() {
    local f n
    for f in "$UNIT_DIR"/rclone-*.service "$UNIT_DIR"/rclone-*-bisync.timer; do
        [[ -e $f ]] || continue
        n=${f##*/rclone-}; n=${n%.service}; n=${n%.timer}
        echo "${n%-bisync}"
    done | sort -u
}

# stream: changes upload in the background and wait in the cache until then, so the cache
# may only be deleted once the mount has nothing left to upload. Starting the mount (a no-op
# when it runs) also uploads what a stopped mount left in the cache.
wait_for_uploads() {
    local sock=${XDG_RUNTIME_DIR:-/run/user/$UID}/rclone-$REMOTE.sock n last=""
    systemctl --user start "rclone-$REMOTE.service" \
        || die "Can't start '$REMOTE' to upload pending changes, so nothing was removed."
    while :; do
        n=$(rclone rc --unix-socket "$sock" vfs/stats 2>/dev/null \
            | awk -F'[:,]' '/"uploads(InProgress|Queued)"/ {n += $2; ok = 1} END {print ok ? n : "?"}' || true)
        [[ $n == 0 ]] && return 0
        [[ $n == "?" ]] && die "Can't check '$REMOTE' for pending uploads, so nothing was removed.
       Rerun the setup to update its service, or keep the local data."
        [[ $n != "$last" ]] && info "Waiting for $n upload(s) to finish (Ctrl+C cancels, nothing has been removed yet)"
        last=$n
        sleep 2
    done
}

uninstall() {
    local names default=""
    names=$(installed_names)
    [[ -n $names ]] || die "No cloud storage is set up."
    if [[ -z $REMOTE ]]; then
        can_ask && echo "Set up: $(echo $names)"
        [[ $names == *$'\n'* ]] || default=$names
        ask REMOTE "Name to remove" "$default"
    fi
    [[ -n $REMOTE ]] || die "Say which one to remove: --uninstall NAME. Set up: $(echo $names)"
    grep -qxF -- "$REMOTE" <<<"$names" || die "'$REMOTE' isn't set up. Set up: $(echo $names)"

    # The local folder is the second quoted argument of ExecStart: rclone mount|bisync "SRC" "DIR".
    local unit=$UNIT_DIR/rclone-$REMOTE.service mirror=0 dir delete=""
    [[ -e $UNIT_DIR/rclone-$REMOTE-bisync.service ]] && { unit=$UNIT_DIR/rclone-$REMOTE-bisync.service; mirror=1; }
    dir=$(sed -n 's/^ExecStart=[^"]*"[^"]*" "\([^"]*\)".*/\1/p' "$unit" 2>/dev/null)

    if can_ask; then
        [[ $mirror -eq 1 ]] && echo "${dir:-The local folder} holds a full copy of the files; they stay in the cloud."
        read -rp "Delete the local data of '$REMOTE' (${dir:+$dir, }cache and logs)? [y/N] " delete </dev/tty
    fi
    [[ $delete =~ ^[Yy] ]] && delete=1 || delete=0
    if [[ $delete -eq 1 && $mirror -eq 1 ]]; then
        info "Syncing once more so no local changes are lost"
        systemctl --user start "rclone-$REMOTE-bisync.service" \
            || die "The last sync failed, so nothing was removed. See: journalctl --user -u rclone-$REMOTE-bisync"
    elif [[ $delete -eq 1 ]]; then
        wait_for_uploads
    fi

    info "Removing '$REMOTE'"
    # One unit per call: systemctl gives up on all of them when one doesn't exist.
    local u
    for u in "rclone-$REMOTE.service" "rclone-$REMOTE-bisync.timer" "rclone-$REMOTE-bisync.service"; do
        systemctl --user disable --now "$u" 2>/dev/null || systemctl --user stop "$u" 2>/dev/null || true
    done
    rm -f "$UNIT_DIR/rclone-$REMOTE.service" "$UNIT_DIR/rclone-$REMOTE-bisync".{service,timer}
    systemctl --user daemon-reload

    local bm=$HOME/.config/gtk-3.0/bookmarks uri
    if [[ -n $dir && -f $bm ]]; then
        uri="$(folder_uri "$dir") "
        awk -v u="$uri" 'index($0, u) != 1' "$bm" > "$bm.tmp" && mv "$bm.tmp" "$bm"
    fi

    if [[ $delete -eq 1 ]]; then
        info "Deleting the local data"
        local p
        for p in "$LOG_DIR"/vfs*/"$REMOTE{"* "$LOG_DIR/bisync/${REMOTE}_"* "$LOG_DIR/$REMOTE"-*.log \
                 "$HOME/.config/rclone/$REMOTE-bisync-filters.txt"; do
            if [[ -d $p ]]; then rclone purge "$p"; elif [[ -e $p ]]; then rclone deletefile "$p"; fi
        done
        if [[ -n $dir && -d $dir ]]; then
            # A folder that is still mounted shows the cloud files: deleting it would delete those.
            mountpoint -q "$dir" && die "$dir is still mounted, so it was kept. Unmount it with: fusermount3 -uz '$dir'"
            if [[ $mirror -eq 1 ]]; then
                [[ $dir != "$HOME" && $dir != / ]] && rclone purge "$dir"
            else
                # rmdir only removes an empty folder.
                rclone rmdir "$dir" 2>/dev/null || warn "$dir isn't empty, so it was kept."
            fi
        fi
        echo "Done. The account was kept; to remove it: rclone config delete $REMOTE"
    else
        echo "Done. ${dir:+$dir, }the cache and the account were kept."
    fi
}

# ---------------------------------------------------------------- main
# Wrapped in main() so a partially downloaded script (curl | bash) never runs.
main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --provider)      PROVIDER=$2; shift 2 ;;
            --mode)          MODE=$2; shift 2 ;;
            --path)          LOCAL_DIR=$2; shift 2 ;;
            --remote-path)   REMOTE_PATH=$2; shift 2 ;;
            --cache-size)    CACHE_SIZE=$2; shift 2 ;;
            --interval)      INTERVAL=$2; shift 2 ;;
            --client-id)     CLIENT_ID=$2; shift 2 ;;
            --client-secret) CLIENT_SECRET=$2; shift 2 ;;
            --token)         TOKEN=$2; shift 2 ;;
            --name|--remote) REMOTE=$2; shift 2 ;;
            --uninstall)     UNINSTALL=1
                             [[ -n ${2:-} && $2 != -* ]] && { REMOTE=$2; shift; }
                             shift ;;
            -y|--yes)        ASSUME_YES=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            *)               usage >&2; die "Unknown option: $1" ;;
        esac
    done
    [[ $EUID -eq 0 ]] && die "Run this as your normal user, not root (it uses sudo when needed)."
    if [[ $UNINSTALL -eq 1 ]]; then uninstall; exit 0; fi

    can_ask && echo "Press Enter to accept the [default]."
    ask PROVIDER "Cloud service, gdrive or onedrive" gdrive
    case $PROVIDER in
        gdrive)
            NAME="Google Drive" TYPE=drive CREATE_ARGS=(scope=drive)
            MOUNT_FLAGS+=("${GDRIVE_FLAGS[@]}" "${GDRIVE_MOUNT_FLAGS[@]}")
            BISYNC_FLAGS+=("${GDRIVE_FLAGS[@]}" "${GDRIVE_BISYNC_FLAGS[@]}") ;;
        onedrive)
            NAME=OneDrive TYPE=onedrive CREATE_ARGS=() ;;
        *)  die "--provider must be gdrive or onedrive" ;;
    esac
    REMOTE=${REMOTE:-$PROVIDER}
    STREAM_UNIT=rclone-$REMOTE.service
    MIRROR_UNIT=rclone-$REMOTE-bisync

    ask MODE "Mode, stream (files download when opened) or mirror (full offline copy)" stream
    [[ $MODE == stream || $MODE == mirror ]] || die "--mode must be stream or mirror"
    ask LOCAL_DIR "Local folder" "$HOME/${NAME// /}"
    LOCAL_DIR=$(realpath -m "${LOCAL_DIR/#\~/$HOME}")
    ask REMOTE_PATH "Folder of $NAME to sync, / for all of it" /
    REMOTE_PATH=${REMOTE_PATH#/}
    SRC=$REMOTE:$REMOTE_PATH
    if [[ $MODE == stream ]]; then
        ask CACHE_SIZE "Maximum cache size" "$CACHE_SIZE_DEFAULT"
    else
        ask INTERVAL "Time between syncs" "$INTERVAL_DEFAULT"
    fi
    [[ $PROVIDER == gdrive ]] && ask_client_id
    [[ -n $CLIENT_ID && -z $CLIENT_SECRET ]] && die "--client-id needs --client-secret"

    echo
    info "'$REMOTE' ($NAME): ${REMOTE_PATH:-whole drive} -> $LOCAL_DIR"
    if [[ $MODE == stream ]]; then
        echo "    stream mode, cache up to $CACHE_SIZE"
    else
        echo "    mirror mode: downloads everything now, then syncs every $INTERVAL"
    fi
    [[ $PROVIDER == gdrive ]] && echo "    client ID: ${CLIENT_ID:-unchanged}"
    if can_ask; then
        local ans
        read -rp "Continue? [Y/n] " ans </dev/tty
        [[ ! $ans =~ ^[Nn] ]] || die "Aborted."
    fi

    install_rclone
    setup_remote
    mkdir -p "$UNIT_DIR" "$LOG_DIR" "$LOCAL_DIR"
    "setup_$MODE"

    # Sidebar shortcut in GNOME Files and other GTK file managers.
    local bm=$HOME/.config/gtk-3.0/bookmarks uri
    uri=$(folder_uri "$LOCAL_DIR")
    mkdir -p "${bm%/*}"
    grep -q "^$uri " "$bm" 2>/dev/null || echo "$uri $NAME" >> "$bm"

    echo
    info "Done: '$REMOTE' ($NAME, $MODE) at $LOCAL_DIR"
    if [[ $MODE == stream ]]; then
        echo "  Status:   systemctl --user status $STREAM_UNIT"
        echo "  Log:      $LOG_DIR/$REMOTE-mount.log"
    else
        echo "  Status:   systemctl --user list-timers $MIRROR_UNIT.timer"
        echo "  Sync now: systemctl --user start $MIRROR_UNIT.service"
        echo "  Log:      $LOG_DIR/$REMOTE-bisync.log"
    fi
    echo "  Remove:   rclone-cloud-storage.sh --uninstall $REMOTE"
}

main "$@"
