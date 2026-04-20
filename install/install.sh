#!/bin/bash

# -------------------------------------------------------------------------- #
# Installer for the cozyportal OpenNebula marketplace driver.                #
#                                                                            #
# Run as root on the OpenNebula frontend. Idempotent: safe to re-run after   #
# updating the repository.                                                   #
# -------------------------------------------------------------------------- #

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

ONE_REMOTES=${ONE_REMOTES:-/var/lib/one/remotes}
ONE_ETC=${ONE_ETC:-/etc/one}
ONE_CONF=${ONE_CONF:-$ONE_ETC/oned.conf}
ONEADMIN=${ONEADMIN:-oneadmin}

if [ "$(id -u)" -ne 0 ]; then
    echo "must be run as root" >&2
    exit 1
fi

have_sudo_u() { command -v sudo >/dev/null 2>&1; }

as_oneadmin() {
    if have_sudo_u; then
        sudo -u "$ONEADMIN" "$@"
    else
        su -s /bin/bash - "$ONEADMIN" -c "$(printf '%q ' "$@")"
    fi
}

log() { printf '[cozyportal-install] %s\n' "$*"; }

# ---------- 1. Drop the driver scripts under /var/lib/one/remotes ----------

MARKET_DIR="$ONE_REMOTES/market/cozyportal"
DS_DIR="$ONE_REMOTES/datastore"

log "installing market driver to $MARKET_DIR"
install -d -o "$ONEADMIN" -g "$ONEADMIN" -m 0755 "$MARKET_DIR"

for f in import delete monitor cozyportal.lib.sh; do
    install -o "$ONEADMIN" -g "$ONEADMIN" -m 0755 \
        "$REPO_ROOT/market/cozyportal/$f" "$MARKET_DIR/$f"
done

log "installing datastore helper to $DS_DIR"
install -o "$ONEADMIN" -g "$ONEADMIN" -m 0755 \
    "$REPO_ROOT/datastore/cozyportal_downloader.sh" \
    "$DS_DIR/cozyportal_downloader.sh"

# ---------- 2. Configuration file ------------------------------------------
# OpenNebula looks for per-market driver configs under
# /var/lib/one/remotes/etc/market/<driver>/<driver>.conf (next to the
# driver scripts) — not under /etc/one. Our driver follows that layout.

CONF_DIR="$ONE_REMOTES/etc/market/cozyportal"
CONF_FILE="$CONF_DIR/cozyportal.conf"

log "installing config directory $CONF_DIR"
install -d -o "$ONEADMIN" -g "$ONEADMIN" -m 0750 "$CONF_DIR"

if [ ! -e "$CONF_FILE" ]; then
    log "writing default config to $CONF_FILE (review it before use)"
    install -o "$ONEADMIN" -g "$ONEADMIN" -m 0640 \
        "$REPO_ROOT/etc/market/cozyportal/cozyportal.conf" "$CONF_FILE"
else
    log "config already present at $CONF_FILE — leaving untouched"
fi

# Secure location for the ServiceAccount token. The operator deploys the
# actual token here out-of-band; this script just ensures the directory.
TOKEN_DIR=/var/lib/one/.cozyportal
install -d -o "$ONEADMIN" -g "$ONEADMIN" -m 0700 "$TOKEN_DIR"

# ---------- 3. Register the driver in oned.conf ----------------------------

if ! grep -qE '^\s*MARKET_MAD\s*=' "$ONE_CONF"; then
    log "MARKET_MAD block not found in $ONE_CONF — skipping autoconfig"
else
    # Append cozyportal to the -m argument if it's not there already.
    if grep -E '^\s*ARGUMENTS\b' "$ONE_CONF" | grep -q 'cozyportal'; then
        log "cozyportal is already listed in MARKET_MAD ARGUMENTS"
    else
        log "patching MARKET_MAD ARGUMENTS to include cozyportal"
        cp -a "$ONE_CONF" "$ONE_CONF.cozyportal.bak.$(date +%s)"

        # Match the first ARGUMENTS line that belongs to MARKET_MAD (between
        # MARKET_MAD = [ ... ] block). We use a tiny awk state machine to be
        # precise.
        awk '
            BEGIN { in_block = 0; patched = 0 }
            /^\s*MARKET_MAD\s*=\s*\[/  { in_block = 1 }
            in_block && !patched && /-m[ \t]+[^\"]*\"?/ {
                # already-patched check
                if (match($0, /-m[ \t]+[a-zA-Z0-9_,\+\-]+/)) {
                    current = substr($0, RSTART, RLENGTH)
                    sub(/^-m[ \t]+/, "", current)
                    if (index(current, "cozyportal") == 0) {
                        new = current ",cozyportal"
                        sub(current, new)
                        patched = 1
                    } else {
                        patched = 1
                    }
                }
            }
            in_block && /\]/ { in_block = 0 }
            { print }
        ' "$ONE_CONF" > "$ONE_CONF.new"
        mv "$ONE_CONF.new" "$ONE_CONF"
        chown root:"$ONEADMIN" "$ONE_CONF"
        chmod 0640 "$ONE_CONF"
    fi
fi

# Append MARKET_MAD_CONF if missing.
if ! grep -qE 'NAME\s*=\s*"cozyportal"' "$ONE_CONF"; then
    log "appending MARKET_MAD_CONF for cozyportal to $ONE_CONF"
    cat >> "$ONE_CONF" <<'EOF'

MARKET_MAD_CONF = [
    NAME           = "cozyportal",
    SUNSTONE_NAME  = "Cozyportal",
    REQUIRED_ATTRS = "",
    APP_ACTIONS    = "create, delete, monitor",
    PUBLIC         = "no"
]
EOF
else
    log "MARKET_MAD_CONF for cozyportal already present"
fi

# ---------- 4. Patch downloader.sh to handle cozyportal:// URLs ------------

DOWNLOADER="$DS_DIR/downloader.sh"
MARKER='# cozyportal-downloader-scheme'

if grep -q "$MARKER" "$DOWNLOADER"; then
    log "downloader.sh already patched for cozyportal://"
else
    log "patching $DOWNLOADER to handle cozyportal:// URLs"
    cp -a "$DOWNLOADER" "$DOWNLOADER.cozyportal.bak.$(date +%s)"

    # Insert a new case branch right before the existing http://*|https://* one.
    python3 - "$DOWNLOADER" "$MARKER" <<'PY'
import re, sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path).read()
needle = 'http://*|https://*)'
block = (
    f'cozyportal://*) {marker}\n'
    '    defs=`$VAR_LOCATION/remotes/datastore/cozyportal_downloader.sh "$FROM"`\n'
    '    ret=$?\n'
    '    [ $ret -ne 0 ] && exit $ret\n'
    '    eval "$defs"\n'
    '    ;;\n'
)
if needle not in src:
    sys.stderr.write("could not locate http case in downloader.sh\n")
    sys.exit(1)
src = src.replace(needle, block + needle, 1)
open(path, 'w').write(src)
PY

    chown "$ONEADMIN":"$ONEADMIN" "$DOWNLOADER"
    chmod 0755 "$DOWNLOADER"
fi

# ---------- 5. Patch libfs.sh::fs_size to accept cozyportal:// URLs --------
# When an Image is created with PATH=cozyportal://..., fs_mad/stat calls
# fs_size to probe the remote image header. Upstream fs_size only routes
# through downloader.sh for local files or http(s) URLs — so we extend the
# scheme whitelist to recognise cozyportal:// too.

LIBFS="$DS_DIR/libfs.sh"
LIBFS_MARKER='# cozyportal-fs-size-scheme'

if grep -q "$LIBFS_MARKER" "$LIBFS"; then
    log "libfs.sh already patched for cozyportal://"
else
    log "patching $LIBFS::fs_size to recognise cozyportal:// URLs"
    cp -a "$LIBFS" "$LIBFS.cozyportal.bak.$(date +%s)"

    python3 - "$LIBFS" "$LIBFS_MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path).read()
# NOTE: we keep the marker inside a /* */-style bash comment so it does not
# separate the conditional from the trailing `; then`.
old = "(echo \"${SRC}\" | grep -qe '^https\\?://')"
new = "(echo \"${SRC}\" | grep -qe '^\\(https\\?\\|cozyportal\\)://')"
if src.count(old) != 1:
    sys.stderr.write(f"could not uniquely locate fs_size http check; occurrences={src.count(old)}\n")
    sys.exit(1)
src = src.replace(old, new, 1)
# Leave a trail so we can detect the patch next time.
src = src.replace(
    "function fs_size {",
    f"function fs_size {{ {marker}",
    1,
)
open(path, 'w').write(src)
PY

    chown "$ONEADMIN":"$ONEADMIN" "$LIBFS"
    chmod 0644 "$LIBFS"
fi

log "driver installed. Restart opennebula to pick up oned.conf changes:"
log "  systemctl restart opennebula opennebula-scheduler"
log ""
log "After restart, register the marketplace with:"
log "  onemarket create /usr/share/one/etc/cozyportal.market"
log "  (or see install/cozyportal.market in this repo)"
