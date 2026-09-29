# -------------------------------------------------------------------------- #
# OpenNebula Marketplace Driver - cozyportal (shared helpers)                #
# -------------------------------------------------------------------------- #

# Required environment (set via /etc/one/market/cozyportal/cozyportal.conf):
#   COZYPORTAL_API            e.g. https://kubernetes.default.svc
#   COZYPORTAL_TOKEN_FILE     path to a file holding the SA bearer token
#   COZYPORTAL_API_SUPERGROUP defaults to platform.aenix.io
#   COZYPORTAL_GROUP          defaults to files.$COZYPORTAL_API_SUPERGROUP
#   COZYPORTAL_VERSION        defaults to v1alpha1

: "${COZYPORTAL_API_SUPERGROUP:=platform.aenix.io}"
: "${COZYPORTAL_GROUP:=files.${COZYPORTAL_API_SUPERGROUP}}"
: "${COZYPORTAL_VERSION:=v1alpha1}"

cp_token() {
    if [ -z "${COZYPORTAL_TOKEN_FILE:-}" ]; then
        echo "COZYPORTAL_TOKEN_FILE is not set in cozyportal.conf" >&2
        return 1
    fi
    cat "$COZYPORTAL_TOKEN_FILE"
}

cp_files_api_url() {
    local ns=$1 file=$2

    if [ -z "${COZYPORTAL_API:-}" ]; then
        echo "COZYPORTAL_API is not set in cozyportal.conf" >&2
        return 1
    fi

    printf '%s/apis/%s/%s/namespaces/%s/files/%s' \
        "${COZYPORTAL_API%/}" \
        "$COZYPORTAL_GROUP" \
        "$COZYPORTAL_VERSION" \
        "$ns" \
        "$file"
}
