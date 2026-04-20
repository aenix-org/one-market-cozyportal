#!/bin/bash

# -------------------------------------------------------------------------- #
# OpenNebula Marketplace Driver - cozyportal                                 #
#                                                                            #
# Copyright 2026, Aenix (aenix.io).                                          #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
# -------------------------------------------------------------------------- #

###############################################################################
# Download an image from the Cozyportal Files API.
#
# Prints a shell-quoted command on stdout that, when eval'd by downloader.sh,
# streams the file's content on stdout. This mirrors the restic/rsync/netapp
# extension points used by upstream OpenNebula.
#
# Called from datastore/downloader.sh when a source URL of the form
#   cozyportal://<namespace>/<file-uuid>
# is encountered.
###############################################################################

set -euo pipefail

SOURCE_URL=${1:-}

if [ -z "$SOURCE_URL" ]; then
    echo "usage: $0 cozyportal://<namespace>/<file-uuid>" >&2
    exit 1
fi

if [[ "$SOURCE_URL" != cozyportal://* ]]; then
    echo "unsupported URL scheme for cozyportal downloader: $SOURCE_URL" >&2
    exit 1
fi

# -------- Load shared config/helpers --------------------------------------

# shellcheck source=/dev/null
source /var/lib/one/remotes/etc/market/cozyportal/cozyportal.conf
# shellcheck source=/dev/null
source /var/lib/one/remotes/market/cozyportal/cozyportal.lib.sh

# -------- Parse cozyportal://<namespace>/<file-uuid> ----------------------

rest="${SOURCE_URL#cozyportal://}"
NAMESPACE="${rest%%/*}"
FILE_ID="${rest#*/}"

if [ -z "$NAMESPACE" ] || [ -z "$FILE_ID" ] || [ "$NAMESPACE" = "$FILE_ID" ]; then
    echo "malformed cozyportal URL: $SOURCE_URL" >&2
    exit 1
fi

CONTENT_URL="$(cp_files_api_url "$NAMESPACE" "$FILE_ID")/content"

TOKEN_FILE="${COZYPORTAL_TOKEN_FILE:?COZYPORTAL_TOKEN_FILE is not set}"

# -------- Emit the command downloader.sh will exec ------------------------
# Single-quoted with safe escapes so downloader.sh can eval it verbatim.

esc() { printf '%s' "$1" | sed -e "s/'/'\\\\''/g"; }

AUTH_HEADER="Authorization: Bearer \$(cat '$(esc "$TOKEN_FILE")')"

CURL_OPTS="--fail --silent --show-error --location"
CURL_OPTS+=" --connect-timeout ${COZYPORTAL_CONNECT_TIMEOUT:-30}"
CURL_OPTS+=" --max-time ${COZYPORTAL_DOWNLOAD_TIMEOUT:-7200}"

if [ "${COZYPORTAL_INSECURE:-no}" = "yes" ]; then
    CURL_OPTS+=" --insecure"
fi

if [ -n "${COZYPORTAL_CACERT:-}" ]; then
    CURL_OPTS+=" --cacert '$(esc "$COZYPORTAL_CACERT")'"
fi

printf "command='curl %s -H \"%s\" %s'\n" \
    "$CURL_OPTS" \
    "$AUTH_HEADER" \
    "'$(esc "$CONTENT_URL")'"
