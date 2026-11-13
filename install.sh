#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=".env"
DATA_DIR="data"
CONTAINER="ntfy"
YES=false; START=true; MODE=install; NEW_INSTALL=false

usage() {
    cat <<'EOF'
ntfy installer. Values come from the environment or .env, and are asked for when missing.

Usage: bash ./install.sh [--yes] [--no-start] | --update-env
  --yes, -y     never prompt; fail if a required value is missing
  --no-start    write the configuration but do not start ntfy
  --update-env  rebuild .env from .env.sample, keep your values, then exit
EOF
}

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

for arg in "$@"; do
    case "$arg" in
        --yes|-y)     YES=true ;;
        --no-start)   START=false ;;
        --update-env) MODE=update-env ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option: $arg (see --help)" ;;
    esac
done
[[ -t 0 ]] || YES=true

load_env() {
    local line key val
    [[ -f "$ENV_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        [[ "$val" =~ ^\'(.*)\'$ || "$val" =~ ^\"(.*)\"$ ]] && val="${BASH_REMATCH[1]}"
        [[ -n "${!key:-}" ]] || export "$key=$val"
    done < "$ENV_FILE"
}

quote() {
    if [[ "$1" =~ ^[A-Za-z0-9._:/@+,=-]+$ ]]; then printf '%s' "$1"
    else printf "'%s'" "${1//\'/\'\\\'\'}"; fi
}

write_env() {
    local tmp line key other; tmp="$(mktemp)"
    while IFS= read -r line; do
        if [[ "$line" =~ ^(#[[:space:]]*)?([A-Z][A-Z0-9_]*)= && -n "${!BASH_REMATCH[2]:-}" ]]; then
            key="${BASH_REMATCH[2]}"; line="$key=$(quote "${!key}")"
        fi
        echo "$line"
    done < .env.sample > "$tmp"
    other="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" 2>/dev/null | grep -v '^ADMIN_PASSWORD=' | while IFS= read -r line; do
        grep -qE "^#?[[:space:]]*${line%%=*}=" .env.sample || echo "$line"
    done || true)"
    [[ -z "$other" ]] || printf '\n# Other settings kept from the previous %s\n%s\n' "$ENV_FILE" "$other" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"; chmod 600 "$ENV_FILE"; rm -f "$tmp"
}

ask() {
    local var="$1" prompt="$2" default="${3:-}" reply
    [[ -n "${!var:-}" ]] && return 0
    if $YES; then
        [[ -n "$default" ]] || die "$var is not set (set it in the environment or $ENV_FILE)"
        printf -v "$var" '%s' "$default"; return 0
    fi
    read -r -p "$prompt${default:+ [$default]}: " reply
    reply="${reply:-$default}"
    [[ -n "$reply" ]] || die "$var is required"
    printf -v "$var" '%s' "$reply"
}

ask_secret() {
    local var="$1" p1 p2
    [[ -n "${!var:-}" ]] && return 0
    $YES && die "$var is not set (set it in the environment or $ENV_FILE)"
    while :; do
        read -r -s -p "$2: " p1; echo
        read -r -s -p "Repeat: " p2; echo
        [[ "$p1" == "$p2" && ${#p1} -ge 8 ]] && break
        echo "The values must match and have at least 8 characters."
    done
    printf -v "$var" '%s' "$p1"
}

compose() {
    if docker compose version >/dev/null 2>&1; then docker compose "$@"
    else docker-compose "$@"; fi
}

build_compose() {
    export COMPOSE_FILE="docker-compose.yaml"
    if [[ -f docker-compose.override.yaml ]]; then
        COMPOSE_FILE+=":docker-compose.override.yaml"
        info "Using docker-compose.override.yaml"
    fi
}

wait_ready() {
    local i
    info "Waiting for ntfy to start"
    for i in $(seq 1 30); do
        docker exec "$CONTAINER" wget -q -O /dev/null http://localhost:80/v1/health 2>/dev/null && return 0
        sleep 2
    done
    return 1
}

create_admin() {
    NTFY_PASSWORD="$1" docker exec -e NTFY_PASSWORD "$CONTAINER" ntfy user add --role=admin "$ADMIN_USER"
    info "Created admin user $ADMIN_USER"
}

start_ntfy() {
    local admin_pw="$1" answer=y
    $YES || read -r -p "Start ntfy now? [Y/n]: " answer
    [[ "${answer:-y}" =~ ^[Yy] ]] || return 0
    compose up -d
    if $NEW_INSTALL; then
        wait_ready && create_admin "$admin_pw" \
            || echo "ntfy is not ready yet. Create the admin later: docker exec -it $CONTAINER ntfy user add --role=admin $ADMIN_USER"
    fi
}

install() {
    ask NTFY_DOMAIN "ntfy domain (e.g. ntfy.example.com)"
    ask NTFY_VERSION "ntfy version" "v2.37.2"
    [[ "$NTFY_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "invalid NTFY_DOMAIN: $NTFY_DOMAIN"
    [[ -f "$DATA_DIR/user.db" ]] || NEW_INSTALL=true
    if $NEW_INSTALL; then
        ask ADMIN_USER "Admin username" "admin"
        [[ "$ADMIN_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "ADMIN_USER may only contain letters, digits, '.', '_' and '-'"
        ask_secret ADMIN_PASSWORD "Password for '$ADMIN_USER'"
    fi
    build_compose

    local admin_pw="${ADMIN_PASSWORD:-}"
    unset ADMIN_PASSWORD
    mkdir -p "$DATA_DIR"; chmod 700 "$DATA_DIR"
    write_env
    info "Saved settings to $ENV_FILE"
    ! $START || start_ntfy "$admin_pw"

    echo
    echo "ntfy: https://$NTFY_DOMAIN"
    echo "Point the DNS record for $NTFY_DOMAIN at this server for the certificate."
}

command -v docker >/dev/null 2>&1 || die "docker is not installed"
load_env
case "$MODE" in
    install)    install ;;
    update-env) unset ADMIN_PASSWORD
                build_compose
                write_env
                info "Updated $ENV_FILE from .env.sample" ;;
esac
