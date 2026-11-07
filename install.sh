#!/usr/bin/env bash
# One-command installer and updater of the panel:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | sudo bash
#
# Without a terminal, set these environment variables instead of answering the questions:
#   PANEL_DOMAIN, ROOT_USER_EMAIL, ROOT_USER_PASSWORD

set -euo pipefail

# Set PANEL_REPO to your GitHub repository, for example my-user/my-panel.
PANEL_NAME="${PANEL_NAME:-Panel}"
PANEL_REPO="${PANEL_REPO:-LUMINAOFFICIAL1/opanel-test}"
PANEL_BRANCH="${PANEL_BRANCH:-main}"
ENV_FILE="/data/coolify/source/.env"
CREDENTIALS_FILE="/root/.panel-credentials"
WINGS_CONFIG_FILE="${WINGS_CONFIG_FILE:-/etc/pterodactyl/config.yml}"
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
MIN_MEMORY_MB=2000

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi

say() { printf '%s\n' "$*"; }
warn() { printf '%s! %s%s\n' "$YELLOW" "$*" "$RESET"; }
die() {
    printf '%sError: %s%s\n' "$RED" "$*" "$RESET" >&2
    exit 1
}

has_terminal() {
    (exec </dev/tty) 2>/dev/null
}

# The script itself arrives on stdin through "curl | bash", so answers come from the terminal.
ask() {
    local question="$1" default="${2:-}" answer=""
    if ! has_terminal; then
        printf '%s' "$default"
        return
    fi
    printf '%s%s%s%s: ' "$BOLD" "$question" "$RESET" "${default:+ ${DIM}[$default]${RESET}}" >/dev/tty
    IFS= read -r answer </dev/tty || true
    printf '%s' "${answer:-$default}"
}

ask_secret() {
    local answer=""
    has_terminal || return 0
    printf '%s%s%s: ' "$BOLD" "$1" "$RESET" >/dev/tty
    IFS= read -rs answer </dev/tty || true
    printf '\n' >/dev/tty
    printf '%s' "$answer"
}

confirm() {
    local answer
    answer=$(ask "$1 (y/N)" "n")
    case "$answer" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
    esac
}

is_valid_repo() {
    [[ $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

is_valid_domain() {
    [ "${#1}" -le 253 ] && [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

is_valid_email() {
    [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

# The rules of RootUserSeeder, except the check against leaked passwords, which needs the network.
is_strong_password() {
    [ "${#1}" -ge 8 ] && [[ $1 =~ [a-z] ]] && [[ $1 =~ [A-Z] ]] && [[ $1 =~ [0-9] ]] && [[ $1 =~ [^A-Za-z0-9] ]]
}

generate_password() {
    local random
    random=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)
    printf 'Aa1-%s' "$random"
}

check_requirements() {
    [ "$(id -u)" -eq 0 ] || die "Run this installer as root, or with sudo."
    command -v curl >/dev/null 2>&1 || die "curl is missing. Install it first, for example: apt-get install -y curl"

    # Game servers already use part of the memory on a Wings node, so only the free memory counts there.
    local memory_mb memory_key=MemTotal
    if is_wings_host; then
        memory_key=MemAvailable
    fi
    memory_mb=$(awk -v key="$memory_key:" '$1 == key {print int($2 / 1024)}' /proc/meminfo)
    if [ "$memory_mb" -lt "$MIN_MEMORY_MB" ]; then
        warn "This server has ${memory_mb} MB of memory for the panel. The panel needs at least 2 GB."
        confirm "Continue anyway?" || exit 1
    fi
}

is_wings_host() {
    [ -f "$WINGS_CONFIG_FILE" ]
}

is_installed() {
    docker inspect coolify >/dev/null 2>&1
}

# Prints the ports that the panel needs and another program already listens on.
busy_ports() {
    ss -ltnH 2>/dev/null | awk '{count = split($4, part, ":"); print part[count]}' | grep -xE '80|443|6001|6002|8000' | sort -un | tr '\n' ' ' || true
}

check_ports() {
    local busy
    command -v ss >/dev/null 2>&1 || return 0
    busy=$(busy_ports)
    [ -n "$busy" ] || return 0

    warn "These ports are already in use: ${busy}(run 'ss -ltnp' to see which program uses them)."
    case " $busy " in
    *" 8000 "* | *" 6001 "* | *" 6002 "*)
        die "The panel cannot start while ports 8000, 6001, and 6002 are in use. Move any game server off these ports, then run the installer again."
        ;;
    esac
    warn "Ports 80 and 443 are needed for SSL. If nginx or Apache uses them, for example for the Pterodactyl Panel, use another VPS or stop that program."
    confirm "Continue without working SSL?" || exit 1
}

# Wings certificates that renew with certbot standalone need port 80, which the proxy now uses.
# Certbot runs these hooks only when it renews, so the proxy stops for a few seconds at most every 60 days.
uses_certbot_standalone() {
    grep -qsE '^authenticator *= *standalone' "$LETSENCRYPT_DIR"/renewal/*.conf
}

install_certbot_hooks() {
    mkdir -p "$LETSENCRYPT_DIR/renewal-hooks/pre" "$LETSENCRYPT_DIR/renewal-hooks/post"
    printf '#!/bin/sh\ndocker stop coolify-proxy >/dev/null 2>&1 || true\n' >"$LETSENCRYPT_DIR/renewal-hooks/pre/panel-proxy.sh"
    printf '#!/bin/sh\ndocker start coolify-proxy >/dev/null 2>&1 || true\n' >"$LETSENCRYPT_DIR/renewal-hooks/post/panel-proxy.sh"
    chmod 755 "$LETSENCRYPT_DIR/renewal-hooks/pre/panel-proxy.sh" "$LETSENCRYPT_DIR/renewal-hooks/post/panel-proxy.sh"
}

show_wings_notice() {
    say "${BOLD}Pterodactyl Wings found on this server.${RESET} Your game servers keep running during the install."
    say "${DIM}Take a VPS snapshot or back up /var/lib/pterodactyl before you continue.${RESET}"
    ask "Press Enter to continue, or Ctrl+C to stop" >/dev/null
    say ""
}

show_wings_reminders() {
    say ""
    say "${BOLD}Wings node:${RESET}"
    say "  - In Pterodactyl, lower the Memory of this node by 2-3 GB for the panel."
    say "  - Do not give game servers ports 80, 443, 6001, 6002, or 8000."
    say "  - Do not run this installer with DOCKER_POOL_FORCE_OVERRIDE=true: it restarts Docker and all game servers."
    if uses_certbot_standalone; then
        say "  - Added certbot hooks, so the Wings certificate can still renew on port 80."
    fi
}

read_version() {
    curl -fsSL "$PANEL_SOURCE_URL/versions.json" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -n 1
}

# Stops early with a clear message, instead of a failed pull after Docker is installed.
check_image_exists() {
    local version="$1" repository token
    case "$COOLIFY_IMAGE" in
    ghcr.io/*) repository="${COOLIFY_IMAGE#ghcr.io/}" ;;
    *) return 0 ;;
    esac
    token=$(curl -fsSL "https://ghcr.io/token?scope=repository:${repository}:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || token=""
    if ! curl -fsSL -o /dev/null -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
        "https://ghcr.io/v2/${repository}/manifests/${version}"; then
        die "Cannot read the image ${COOLIFY_IMAGE}:${version}. Check that the 'Build panel image' GitHub Action finished, and that the package is public."
    fi
}

# Prints nothing when the domain does not resolve.
domain_ip() {
    getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 {print $1}'
}

public_ip() {
    curl -4fsS --max-time 5 https://ifconfig.io 2>/dev/null || true
}

ask_domain() {
    local domain resolved ip
    domain="${PANEL_DOMAIN:-}"
    ip=$(public_ip)
    while true; do
        if [ -z "$domain" ]; then
            domain=$(ask "Domain for the panel, press Enter to use http://${ip:-server-ip}:8000 without SSL")
        fi
        if [ -z "$domain" ]; then
            return 0
        fi
        if ! is_valid_domain "$domain"; then
            warn "'$domain' is not a valid domain. Example: panel.example.com"
            has_terminal || exit 1
            domain=""
            continue
        fi
        resolved=$(domain_ip "$domain")
        if [ -n "$ip" ] && [ "$resolved" != "$ip" ]; then
            warn "$domain points to '${resolved:-nothing}', not to this server ($ip). Add a DNS A record, or SSL will fail."
            if has_terminal && ! confirm "Use this domain anyway?"; then
                domain=""
                continue
            fi
        fi
        PANEL_DOMAIN="$domain"
        return 0
    done
}

ask_account() {
    local default_email=""
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        default_email="admin@${PANEL_DOMAIN}"
    fi
    while ! is_valid_email "${ROOT_USER_EMAIL:-}"; do
        ROOT_USER_EMAIL=$(ask "Admin email" "$default_email")
        if ! is_valid_email "$ROOT_USER_EMAIL"; then
            warn "Enter an email address on a domain that exists."
            has_terminal || exit 1
        fi
    done
    while [ -z "${ROOT_USER_PASSWORD:-}" ]; do
        ROOT_USER_PASSWORD=$(ask_secret "Admin password, press Enter to generate a strong one")
        if [ -z "$ROOT_USER_PASSWORD" ]; then
            ROOT_USER_PASSWORD=$(generate_password)
            PASSWORD_WAS_GENERATED=true
        elif ! is_strong_password "$ROOT_USER_PASSWORD"; then
            warn "Use at least 8 characters with a lowercase letter, an uppercase letter, a number, and a symbol."
            ROOT_USER_PASSWORD=""
        fi
    done
    if ! is_strong_password "$ROOT_USER_PASSWORD"; then
        die "ROOT_USER_PASSWORD needs at least 8 characters with a lowercase letter, an uppercase letter, a number, and a symbol."
    fi
}

run_base_installer() {
    local script
    script=$(mktemp)
    curl -fsSL "$PANEL_SOURCE_URL/scripts/install.sh" -o "$script"
    # Auto-update stays off: a new version reaches a server only when you publish it.
    PANEL_SOURCE_URL="$PANEL_SOURCE_URL" COOLIFY_IMAGE="$COOLIFY_IMAGE" AUTOUPDATE=false bash "$script" </dev/null
    rm -f "$script"
}

# RootUserSeeder only prints an error for an invalid email or a leaked password.
# Registration then stays open, so anyone who opens the panel first becomes its admin.
root_user_exists() {
    local db_user
    db_user=$(grep -m1 '^DB_USERNAME=' "$ENV_FILE" | cut -d '=' -f2-)
    [ "$(docker exec coolify-db psql -U "${db_user:-coolify}" -d coolify -tAc 'select count(*) from users where id = 0' 2>/dev/null | tr -d '[:space:]')" = "1" ]
}

configure_domain() {
    local attempt
    say "Setting up https://$PANEL_DOMAIN ..."
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if docker exec coolify php artisan panel:set-domain "https://$PANEL_DOMAIN" >/dev/null 2>&1; then
            break
        fi
        if [ "$attempt" = 10 ]; then
            return 1
        fi
        sleep 6
    done
    # curl verifies the certificate, so this succeeds only with a real certificate.
    for attempt in $(seq 1 30); do
        if curl -fsS -o /dev/null --max-time 5 "https://$PANEL_DOMAIN/api/health" 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    return 1
}

save_credentials() {
    (
        umask 077
        printf 'Email: %s\nPassword: %s\n' "$ROOT_USER_EMAIL" "$ROOT_USER_PASSWORD" >"$CREDENTIALS_FILE"
    )
}

install_panel() {
    local version="$1" url ip ssl_ready=false
    PASSWORD_WAS_GENERATED=false
    if is_wings_host; then
        show_wings_notice
    fi
    check_ports
    ask_domain
    ask_account
    export ROOT_USER_EMAIL ROOT_USER_PASSWORD
    export ROOT_USERNAME="${ROOT_USERNAME:-Admin}"

    run_base_installer

    if uses_certbot_standalone; then
        install_certbot_hooks
    fi

    ip=$(public_ip)
    url="http://${ip:-server-ip}:8000"
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        if configure_domain; then
            url="https://$PANEL_DOMAIN"
            ssl_ready=true
        else
            warn "The SSL certificate is not ready. Check the DNS record and ports 80 and 443, then run:"
            say "  docker exec coolify php artisan panel:set-domain https://$PANEL_DOMAIN"
        fi
    fi

    say ""
    say "${GREEN}${BOLD}${PANEL_NAME} ${version} is installed.${RESET}"
    say "  URL:      ${BOLD}${url}${RESET}"
    say "  Email:    ${ROOT_USER_EMAIL}"
    if [ "$PASSWORD_WAS_GENERATED" = true ]; then
        save_credentials
        say "  Password: ${BOLD}${ROOT_USER_PASSWORD}${RESET}"
        say "  ${DIM}Also saved in ${CREDENTIALS_FILE}. Store it in a password manager, then delete that file.${RESET}"
    fi
    say ""
    if ! root_user_exists; then
        warn "The admin account was not created: the email domain has no DNS record, or the password is on a list of leaked passwords."
        warn "Open ${url} NOW and register. The first person who registers becomes the admin."
    fi
    if [ "$ssl_ready" = false ]; then
        warn "The panel uses plain HTTP. Add a domain to protect your login."
    fi
    say "Open these ports in the firewall of your VPS provider: 22, 80, 443, 8000, 6001, 6002."
    say "Back up ${ENV_FILE} outside this server."
    if is_wings_host; then
        show_wings_reminders
    fi
}

update_panel() {
    local version="$1"
    say "An installation exists on this server. It will be updated to ${BOLD}${version}${RESET}. Your data stays."
    confirm "Continue?" || exit 0
    run_base_installer
    say "${GREEN}${BOLD}${PANEL_NAME} is updated to ${version}.${RESET}"
}

main() {
    is_valid_repo "$PANEL_REPO" || die "PANEL_REPO is not set. Set it in install.sh to your GitHub repository, for example my-user/my-panel."
    PANEL_SOURCE_URL="https://raw.githubusercontent.com/${PANEL_REPO}/${PANEL_BRANCH}"
    COOLIFY_IMAGE="${COOLIFY_IMAGE:-ghcr.io/$(printf '%s' "$PANEL_REPO" | tr '[:upper:]' '[:lower:]')}"

    say ""
    say "${BOLD}${PANEL_NAME} installer${RESET}"
    say "${DIM}Press Enter to accept the value in brackets.${RESET}"
    say ""

    check_requirements

    local version
    version=$(read_version)
    [ -n "$version" ] || die "Cannot read $PANEL_SOURCE_URL/versions.json. The repository must be public."
    check_image_exists "$version"

    # A failed first install leaves .env behind, so only a running panel counts as installed.
    if is_installed; then
        update_panel "$version"
    else
        install_panel "$version"
    fi
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
