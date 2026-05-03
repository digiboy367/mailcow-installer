#!/bin/bash
# =============================================================================
#  Mailcow Setup & Manager
#  https://github.com/digiboy367/mailcow-installer
#
#  curl -fsSL https://raw.githubusercontent.com/digiboy367/mailcow-installer/refs/heads/main/mailcow-setup.sh | bash
# =============================================================================

set -euo pipefail

# ── constants ─────────────────────────────────────────────────────────────────
MARKER_FILE="/etc/mailcow-installed"
INSTALL_DIR="/opt/mailcow-dockerized"
LOG_FILE="/var/log/mailcow-setup.log"
MANAGER_BIN="/usr/local/bin/mailcow"
MOTD_FILE="/etc/update-motd.d/99-mailcow"
BASHRC_MARKER="# mailcow-auto-install-hook"

# ── colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
B='\033[0;34m'  C='\033[0;36m'  M='\033[0;35m'  N='\033[0m'

# ── helpers ───────────────────────────────────────────────────────────────────
log()   { echo -e "${G}[$(date '+%H:%M:%S')]${N} $*" | tee -a "$LOG_FILE"; }
info()  { echo -e "${B}[INFO]${N} $*"  | tee -a "$LOG_FILE"; }
warn()  { echo -e "${Y}[WARN]${N} $*"  | tee -a "$LOG_FILE"; }
error() { echo -e "${R}[ERROR]${N} $*" | tee -a "$LOG_FILE"; }
die()   { error "$*"; exit 1; }

hr()    { echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }

# ── detect compose command ────────────────────────────────────────────────────
detect_compose() {
    if docker compose version &>/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# ── read marker ───────────────────────────────────────────────────────────────
load_marker() {
    [ -f "$MARKER_FILE" ] && source "$MARKER_FILE" || true
}

# ── generate random password ──────────────────────────────────────────────────
gen_pass() { tr -dc 'A-Za-z0-9!#%&*+=' </dev/urandom | head -c "${1:-24}"; }

# =============================================================================
#  MANAGER SCRIPT  (written to /usr/local/bin/mailcow)
# =============================================================================
install_manager() {
    log "Installing manager script at $MANAGER_BIN …"
    cat > "$MANAGER_BIN" <<'MANAGER'
#!/bin/bash
# Mailcow Manager
# Usage: mailcow [command]

MARKER_FILE="/etc/mailcow-installed"
INSTALL_DIR="/opt/mailcow-dockerized"
LOG_FILE="/var/log/mailcow-setup.log"

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' M='\033[0;35m' N='\033[0m'

log()   { echo -e "${G}[$(date '+%H:%M:%S')]${N} $*" | tee -a "$LOG_FILE"; }
info()  { echo -e "${B}[INFO]${N} $*"; }
warn()  { echo -e "${Y}[WARN]${N} $*"; }
error() { echo -e "${R}[ERROR]${N} $*"; }
die()   { error "$*"; exit 1; }
hr()    { echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }

load_marker() { [ -f "$MARKER_FILE" ] && source "$MARKER_FILE" || true; }
detect_compose() {
    if docker compose version &>/dev/null 2>&1; then echo "docker compose"
    elif command -v docker-compose &>/dev/null; then echo "docker-compose"
    else echo ""; fi
}

# ── require installed ─────────────────────────────────────────────────────────
require_installed() {
    [ -f "$MARKER_FILE" ] || die "Mailcow is not installed. Run: mailcow install"
    [ -d "$INSTALL_DIR" ] || die "Install directory $INSTALL_DIR missing."
}

# ── api helper  (uses mailcow API with admin key stored in marker) ────────────
mc_api() {
    local method="$1" path="$2" data="${3:-}"
    load_marker
    local url="https://localhost${path}"
    if [ -n "$data" ]; then
        curl -sk -X "$method" "$url" \
            -H "Content-Type: application/json" \
            -H "X-API-Key: ${MC_API_KEY:-}" \
            -d "$data"
    else
        curl -sk -X "$method" "$url" \
            -H "Content-Type: application/json" \
            -H "X-API-Key: ${MC_API_KEY:-}"
    fi
}

# ── set admin password via helper script ──────────────────────────────────────
set_admin_credentials() {
    local new_user="$1" new_pass="$2"
    load_marker
    local COMPOSE
    COMPOSE=$(detect_compose)
    [ -z "$COMPOSE" ] && die "Docker Compose not found."
    cd "$INSTALL_DIR"

    log "Setting admin credentials in database …"
    # Use mailcow's reset helper which handles BLF-CRYPT hashing
    $COMPOSE exec -T mysql-mailcow mysql \
        -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" \
        -e "UPDATE admin SET username='${new_user}', password='{BLF-CRYPT}$(python3 -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(12)).decode())" "${new_pass}" 2>/dev/null || echo "HASH_FAILED")' WHERE username='${MC_ADMIN_USER:-admin}';" 2>>"$LOG_FILE" || {
            # fallback: use the built-in helper script
            warn "Direct SQL failed, trying mailcow-reset-admin.sh …"
            if [ -f "$INSTALL_DIR/helper-scripts/mailcow-reset-admin.sh" ]; then
                # The helper resets to random; we then set our own via SQL
                echo -e "n\n" | bash "$INSTALL_DIR/helper-scripts/mailcow-reset-admin.sh" >> "$LOG_FILE" 2>&1 || true
            fi
        }

    # Update marker
    sed -i "s|^MC_ADMIN_USER=.*|MC_ADMIN_USER=${new_user}|" "$MARKER_FILE"
    sed -i "s|^MC_ADMIN_PASS=.*|MC_ADMIN_PASS=${new_pass}|" "$MARKER_FILE"
    log "Admin credentials updated."
}

# ── add domain via API ────────────────────────────────────────────────────────
api_add_domain() {
    local domain="$1"
    load_marker
    [ -z "${MC_API_KEY:-}" ] && { warn "API key not set yet; skipping domain add via API."; return 0; }

    local resp
    resp=$(mc_api POST /api/v1/add/domain \
        "{\"domain\":\"${domain}\",\"description\":\"Added by mailcow manager\",\"aliases\":400,\"mailboxes\":10,\"defquota\":3072,\"maxquota\":10240,\"quota\":10240,\"active\":\"1\",\"rl_value\":10,\"rl_frame\":\"s\",\"backupmx\":\"0\",\"relay_all_recipients\":\"0\"}")
    echo "$resp" | grep -qi '"type":"success"' && log "Domain ${domain} added." \
        || warn "Domain add response: $resp"
}

# ── generate API key via SQL ──────────────────────────────────────────────────
generate_api_key() {
    load_marker
    local COMPOSE key
    COMPOSE=$(detect_compose)
    cd "$INSTALL_DIR"
    key=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    $COMPOSE exec -T mysql-mailcow mysql \
        -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" \
        -e "DELETE FROM api WHERE username='${MC_ADMIN_USER:-admin}'; \
            INSERT INTO api (username,api_key,active,allow_from) \
            VALUES('${MC_ADMIN_USER:-admin}','${key}','1','127.0.0.1/32,::1/128');" \
        >>"$LOG_FILE" 2>&1 || { warn "Could not set API key via SQL."; return 1; }
    sed -i "s|^MC_API_KEY=.*|MC_API_KEY=${key}|" "$MARKER_FILE"
    export MC_API_KEY="$key"
    log "API key generated."
}

# ─────────────────────────────────────────────────────────────────────────────
#  COMMANDS
# ─────────────────────────────────────────────────────────────────────────────

cmd_status() {
    require_installed
    load_marker
    local COMPOSE
    COMPOSE=$(detect_compose)
    cd "$INSTALL_DIR"
    echo ""
    echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${G}║${N}              ${Y}Mailcow Status${N}                        ${G}║${N}"
    echo -e "${G}╠══════════════════════════════════════════════════════╣${N}"
    echo -e "${G}║${N}  Hostname   : ${C}${MAILCOW_HOSTNAME:-n/a}${N}"
    echo -e "${G}║${N}  Domain     : ${C}${MAIL_DOMAIN:-n/a}${N}"
    echo -e "${G}║${N}  Admin      : ${C}${MC_ADMIN_USER:-admin}${N}"
    echo -e "${G}║${N}  Server IP  : ${C}${SERVER_IP:-n/a}${N}"
    echo -e "${G}║${N}  Branch     : ${C}${MAILCOW_BRANCH:-master}${N}"
    echo -e "${G}║${N}  Web UI     : ${C}https://${MAILCOW_HOSTNAME:-localhost}${N}"
    echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
    echo ""
    echo -e "${Y}Container status:${N}"
    $COMPOSE ps
    echo ""
}

cmd_install() {
    # Delegate to the main setup script
    bash /usr/local/bin/mailcow-setup-run install
}

cmd_uninstall() {
    require_installed
    load_marker
    local COMPOSE
    COMPOSE=$(detect_compose)

    echo ""
    warn "This will STOP all containers and DELETE all Mailcow data including emails!"
    echo -e "${R}Type 'yes I am sure' to confirm:${N} "
    read -r confirm
    [ "$confirm" = "yes I am sure" ] || { info "Aborted."; exit 0; }

    log "Stopping containers …"
    cd "$INSTALL_DIR" && $COMPOSE down --volumes --remove-orphans || true
    log "Removing $INSTALL_DIR …"
    rm -rf "$INSTALL_DIR"
    log "Removing marker file …"
    rm -f "$MARKER_FILE"
    # Remove MOTD
    rm -f /etc/update-motd.d/99-mailcow
    log "Mailcow uninstalled."
    echo -e "${G}Done. All data removed.${N}"
}

cmd_reinstall() {
    cmd_uninstall
    sleep 2
    cmd_install
}

cmd_change_hostname() {
    require_installed
    load_marker
    echo ""
    echo -e "${C}Current mail hostname: ${Y}${MAILCOW_HOSTNAME:-n/a}${N}"
    echo -e "Enter new mail hostname (FQDN): "
    read -r new_hostname
    new_hostname="${new_hostname// /}"
    [[ "$new_hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]] \
        || die "Invalid FQDN: $new_hostname"

    local COMPOSE
    COMPOSE=$(detect_compose)
    cd "$INSTALL_DIR"

    log "Updating MAILCOW_HOSTNAME in mailcow.conf …"
    sed -i "s|^MAILCOW_HOSTNAME=.*|MAILCOW_HOSTNAME=${new_hostname}|" "$INSTALL_DIR/mailcow.conf"

    # Also update system hostname
    echo ""
    read -rp "Also update OS hostname to ${new_hostname}? [y/N]: " upd_os
    if [[ "$upd_os" =~ ^[Yy]$ ]]; then
        hostnamectl set-hostname "$new_hostname"
        log "OS hostname set to $new_hostname"
    fi

    sed -i "s|^MAILCOW_HOSTNAME=.*|MAILCOW_HOSTNAME=${new_hostname}|" "$MARKER_FILE"
    MAIL_DOMAIN_NEW=$(echo "$new_hostname" | awk -F. 'NF>=2{print $(NF-1)"."$NF}')
    sed -i "s|^MAIL_DOMAIN=.*|MAIL_DOMAIN=${MAIL_DOMAIN_NEW}|" "$MARKER_FILE"

    log "Restarting Mailcow …"
    $COMPOSE pull
    $COMPOSE up -d
    log "Hostname changed to $new_hostname"
}

cmd_change_domain() {
    require_installed
    load_marker
    echo ""
    echo -e "${C}Current mail domain: ${Y}${MAIL_DOMAIN:-n/a}${N}"
    echo -e "Enter new mail domain (e.g. example.com): "
    read -r new_domain
    new_domain="${new_domain// /}"
    [[ "$new_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]] \
        || die "Invalid domain: $new_domain"

    api_add_domain "$new_domain"
    sed -i "s|^MAIL_DOMAIN=.*|MAIL_DOMAIN=${new_domain}|" "$MARKER_FILE"
    log "Domain $new_domain added to Mailcow."
}

cmd_change_admin() {
    require_installed
    load_marker
    echo ""
    echo -e "${C}Current admin user: ${Y}${MC_ADMIN_USER:-admin}${N}"
    echo ""
    read -rp "New admin username [${MC_ADMIN_USER:-admin}]: " new_user
    new_user="${new_user:-${MC_ADMIN_USER:-admin}}"

    local p1 p2
    while true; do
        read -rsp "New admin password: " p1; echo
        read -rsp "Confirm password:   " p2; echo
        [ "$p1" = "$p2" ] && break
        echo -e "${R}Passwords do not match. Try again.${N}"
    done
    [ ${#p1} -ge 8 ] || die "Password must be at least 8 characters."

    set_admin_credentials "$new_user" "$p1"
    log "Admin credentials updated to user: $new_user"
}

cmd_update() {
    require_installed
    load_marker
    local COMPOSE
    COMPOSE=$(detect_compose)
    cd "$INSTALL_DIR"
    log "Fetching latest Mailcow …"
    git fetch --all --tags
    git checkout "${MAILCOW_BRANCH:-master}"
    git pull origin "${MAILCOW_BRANCH:-master}"
    log "Pulling new images …"
    $COMPOSE pull
    log "Restarting stack …"
    $COMPOSE up -d
    log "Update complete."
}

cmd_logs() {
    require_installed
    local COMPOSE
    COMPOSE=$(detect_compose)
    cd "$INSTALL_DIR"
    $COMPOSE logs -f --tail=100 "$@"
}

cmd_help() {
    echo ""
    echo -e "${C}╔═══════════════════════════════════════════════╗${N}"
    echo -e "${C}║          Mailcow Manager          ║${N}"
    echo -e "${C}╚═══════════════════════════════════════════════╝${N}"
    echo ""
    echo -e "  ${Y}mailcow${N} ${G}<command>${N}"
    echo ""
    echo -e "  ${G}install${N}           Run the installation wizard"
    echo -e "  ${G}uninstall${N}         Stop & remove all Mailcow data"
    echo -e "  ${G}reinstall${N}         Uninstall then re-install"
    echo -e "  ${G}status${N}            Show status and container info"
    echo -e "  ${G}update${N}            Pull latest images & restart"
    echo -e "  ${G}change-hostname${N}   Change mail server hostname"
    echo -e "  ${G}change-domain${N}     Add / change primary mail domain"
    echo -e "  ${G}change-admin${N}      Change admin username or password"
    echo -e "  ${G}logs [svc]${N}        Follow container logs"
    echo ""
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-help}" in
    install)         cmd_install ;;
    uninstall)       cmd_uninstall ;;
    reinstall)       cmd_reinstall ;;
    status)          cmd_status ;;
    update)          cmd_update ;;
    change-hostname) cmd_change_hostname ;;
    change-domain)   cmd_change_domain ;;
    change-admin)    cmd_change_admin ;;
    logs)            shift; cmd_logs "$@" ;;
    *)               cmd_help ;;
esac
MANAGER
    chmod +x "$MANAGER_BIN"
    log "Manager installed: mailcow <command>"
}

# =============================================================================
#  MOTD
# =============================================================================
install_motd() {
    cat > "$MOTD_FILE" <<'MOTD'
#!/bin/bash
MARKER_FILE="/etc/mailcow-installed"
if [ -f "$MARKER_FILE" ]; then
    source "$MARKER_FILE"
    echo ""
    echo -e "\033[0;36m╔══════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[0;36m║\033[0m  \033[1;33m✉  Mailcow Mail Server\033[0m             \033[0;36m║\033[0m"
    echo -e "\033[0;36m╠══════════════════════════════════════════════════════╣\033[0m"
    printf "\033[0;36m║\033[0m  %-14s \033[0;33m%s\033[0m\n" "Hostname:"   "${MAILCOW_HOSTNAME:-n/a}"
    printf "\033[0;36m║\033[0m  %-14s \033[0;33m%s\033[0m\n" "Domain:"     "${MAIL_DOMAIN:-n/a}"
    printf "\033[0;36m║\033[0m  %-14s \033[0;33m%s\033[0m\n" "Admin user:" "${MC_ADMIN_USER:-admin}"
    printf "\033[0;36m║\033[0m  %-14s \033[0;36m%s\033[0m\n" "Web UI:"     "https://${MAILCOW_HOSTNAME:-localhost}"
    echo -e "\033[0;36m╠══════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[0;36m║\033[0m  Manage: \033[0;32mmailcow <install|status|update|logs …>\033[0m  \033[0;36m║\033[0m"
    echo -e "\033[0;36m╚══════════════════════════════════════════════════════╝\033[0m"
    echo ""
else
    echo ""
    echo -e "\033[1;33m╔══════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;33m║   Mailcow not installed yet.  Run: mailcow install  ║\033[0m"
    echo -e "\033[1;33m╚══════════════════════════════════════════════════════╝\033[0m"
    echo ""
fi
MOTD
    chmod +x "$MOTD_FILE"
    log "MOTD installed."
}

# =============================================================================
#  .BASHRC HOOK  (auto-wizard until installed)
# =============================================================================
install_bashrc_hook() {
    local BASHRC="/root/.bashrc"
    # Remove old hook if present
    if grep -q "$BASHRC_MARKER" "$BASHRC" 2>/dev/null; then
        sed -i "/${BASHRC_MARKER}/,/^# end-mailcow-hook$/d" "$BASHRC"
    fi
    cat >> "$BASHRC" <<HOOK

${BASHRC_MARKER}
if [ -t 1 ] && [ "\${TERM:-}" != "dumb" ] && [ ! -f "$MARKER_FILE" ]; then
    echo ""
    echo -e "\033[1;33m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;33m║   Mailcow is not installed yet.                 ║\033[0m"
    echo -e "\033[1;33m║   Starting setup wizard …                       ║\033[0m"
    echo -e "\033[1;33m╚══════════════════════════════════════════════════╝\033[0m"
    sleep 1
    bash /usr/local/bin/mailcow-setup-run install
fi
# end-mailcow-hook
HOOK
    log ".bashrc hook installed."
}

remove_bashrc_hook() {
    local BASHRC="/root/.bashrc"
    if grep -q "$BASHRC_MARKER" "$BASHRC" 2>/dev/null; then
        sed -i "/${BASHRC_MARKER}/,/^# end-mailcow-hook$/d" "$BASHRC"
        log ".bashrc hook removed."
    fi
}

# =============================================================================
#  INSTALL DEPENDENCIES
# =============================================================================
install_deps() {
    log "Installing system dependencies …"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y git openssl curl gawk coreutils grep jq python3 python3-bcrypt \
            dnsutils 2>>"$LOG_FILE" || \
        apt-get install -y git openssl curl gawk coreutils grep jq python3 \
            dnsutils 2>>"$LOG_FILE" || true
    elif command -v dnf &>/dev/null; then
        dnf install -y git openssl curl gawk coreutils grep jq python3 python3-bcrypt \
            bind-utils 2>>"$LOG_FILE" || true
    fi

    # Docker
    if ! command -v docker &>/dev/null; then
        log "Installing Docker …"
        curl -fsSL https://get.docker.com | CHANNEL=stable sh >>"$LOG_FILE" 2>&1
        systemctl enable --now docker >>"$LOG_FILE" 2>&1
    fi

    # Docker Compose plugin
    local COMPOSE
    COMPOSE=$(detect_compose)
    if [ -z "$COMPOSE" ]; then
        log "Installing Docker Compose plugin …"
        if command -v apt-get &>/dev/null; then
            apt-get install -y docker-compose-plugin >>"$LOG_FILE" 2>&1 || true
        fi
        COMPOSE=$(detect_compose)
        [ -z "$COMPOSE" ] && die "Docker Compose could not be installed. Install it manually."
    fi
    log "Using: $COMPOSE"
}

# =============================================================================
#  MAIN INSTALL WIZARD
# =============================================================================
run_install() {

    # ── root check ──────────────────────────────────────────────────────────
    [ "$EUID" -eq 0 ] || die "Must run as root."

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    # ── banner ───────────────────────────────────────────────────────────────
    clear
    echo ""
    echo -e "${C}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${C}║${N}   ${M}✉  Mailcow Dockerized Setup Wizard${N}               ${C}║${N}"
    echo -e "${C}║${N}     ${B}github.com/digiboy367/mailcow-installer${N}     ${C}║${N}"
    echo -e "${C}╚══════════════════════════════════════════════════════╝${N}"
    echo ""

    # ── already installed? ───────────────────────────────────────────────────
    if [ -f "$MARKER_FILE" ]; then
        source "$MARKER_FILE"
        echo -e "${G}Mailcow is already installed.${N}"
        echo ""
        echo -e "  Hostname : ${Y}${MAILCOW_HOSTNAME}${N}"
        echo -e "  Domain   : ${Y}${MAIL_DOMAIN}${N}"
        echo -e "  Admin    : ${Y}${MC_ADMIN_USER}${N}"
        echo -e "  Web UI   : ${C}https://${MAILCOW_HOSTNAME}${N}"
        echo ""
        echo -e "Use ${G}mailcow${N} to manage your installation."
        remove_bashrc_hook
        exit 0
    fi

    # ── get server IP ────────────────────────────────────────────────────────
    info "Detecting server IP …"
    SERVER_IP=""
    for ip_url in \
        "https://api4.my-ip.io/ip" \
        "https://ipv4.icanhazip.com" \
        "https://checkip.amazonaws.com" \
        "https://4.ident.me"; do
        SERVER_IP=$(curl -s --max-time 6 "$ip_url" 2>/dev/null | tr -d '[:space:]')
        [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        SERVER_IP=""
    done
    [ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')

    # ─────────────────────────────────────────────────────────────────────────
    #  STEP 1 – HOSTNAME
    # ─────────────────────────────────────────────────────────────────────────
    hr
    echo -e "${Y}  Step 1/6 – Mail Server Hostname (FQDN)${N}"
    hr
    CURRENT_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    echo ""
    echo -e "  Current OS hostname: ${C}${CURRENT_HOSTNAME}${N}"
    echo -e "  Server IP:           ${C}${SERVER_IP}${N}"
    echo ""
    echo -e "  The FQDN must have an A record → ${C}${SERVER_IP}${N}"
    echo -e "  Example: ${C}mail.example.com${N}"
    echo ""

    while true; do
        read -rp "  Mail hostname [${CURRENT_HOSTNAME}]: " MAILCOW_HOSTNAME
        MAILCOW_HOSTNAME="${MAILCOW_HOSTNAME:-$CURRENT_HOSTNAME}"
        MAILCOW_HOSTNAME="${MAILCOW_HOSTNAME// /}"
        [[ "$MAILCOW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]] \
            && break
        error "  Not a valid FQDN. Must contain at least one dot."
    done

    # Update OS hostname if changed
    if [ "$MAILCOW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
        echo ""
        read -rp "  Update OS hostname to ${MAILCOW_HOSTNAME}? [Y/n]: " upd_hn
        upd_hn="${upd_hn:-Y}"
        if [[ "$upd_hn" =~ ^[Yy]$ ]]; then
            hostnamectl set-hostname "$MAILCOW_HOSTNAME"
            # Also update /etc/hosts if needed
            if ! grep -q "$MAILCOW_HOSTNAME" /etc/hosts; then
                echo "127.0.1.1  $MAILCOW_HOSTNAME" >> /etc/hosts
            fi
            log "OS hostname updated to $MAILCOW_HOSTNAME"
        fi
    fi

    MAIL_DOMAIN=$(echo "$MAILCOW_HOSTNAME" | awk -F. 'NF>=2{print $(NF-1)"."$NF}')
    log "Mail hostname: $MAILCOW_HOSTNAME"

    # ─────────────────────────────────────────────────────────────────────────
    #  STEP 2 – ADMIN CREDENTIALS
    # ─────────────────────────────────────────────────────────────────────────
    hr
    echo -e "${Y}  Step 2/6 – Admin Credentials${N}"
    hr
    echo ""

    read -rp "  Admin username [admin]: " MC_ADMIN_USER
    MC_ADMIN_USER="${MC_ADMIN_USER:-admin}"

    while true; do
        local DEFAULT_PASS
        DEFAULT_PASS=$(gen_pass 16)
        echo ""
        echo -e "  Leave blank to use a generated password: ${C}${DEFAULT_PASS}${N}"
        read -rsp "  Admin password [generated]: " MC_ADMIN_PASS; echo
        if [ -z "$MC_ADMIN_PASS" ]; then
            MC_ADMIN_PASS="$DEFAULT_PASS"
            echo -e "  Using generated password: ${Y}${MC_ADMIN_PASS}${N}"
            break
        fi
        if [ ${#MC_ADMIN_PASS} -lt 8 ]; then
            error "  Password must be at least 8 characters."; continue
        fi
        local p2
        read -rsp "  Confirm password: " p2; echo
        [ "$MC_ADMIN_PASS" = "$p2" ] && break
        error "  Passwords do not match."
    done
    log "Admin user: $MC_ADMIN_USER"

    # ─────────────────────────────────────────────────────────────────────────
    #  STEP 3 – MAIL DOMAIN
    # ─────────────────────────────────────────────────────────────────────────
    hr
    echo -e "${Y}  Step 3/6 – Primary Mail Domain${N}"
    hr
    echo ""
    echo -e "  This is the domain for mailboxes, e.g. ${C}user@example.com${N}"
    echo -e "  Default (derived from hostname): ${C}${MAIL_DOMAIN}${N}"
    echo ""

    while true; do
        read -rp "  Mail domain [${MAIL_DOMAIN}]: " input_domain
        input_domain="${input_domain:-$MAIL_DOMAIN}"
        input_domain="${input_domain// /}"
        [[ "$input_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]] \
            && { MAIL_DOMAIN="$input_domain"; break; }
        error "  Invalid domain."
    done
    log "Mail domain: $MAIL_DOMAIN"

    # ─────────────────────────────────────────────────────────────────────────
    #  STEP 4 – TIMEZONE
    # ─────────────────────────────────────────────────────────────────────────
    hr
    echo -e "${Y}  Step 4/6 – Timezone${N}"
    hr
    DETECTED_TZ=$(timedatectl show -p Timezone --value 2>/dev/null \
        || cat /etc/timezone 2>/dev/null || echo "UTC")
    echo ""
    echo -e "  Detected: ${C}${DETECTED_TZ}${N}"
    read -rp "  Timezone [${DETECTED_TZ}]: " MAILCOW_TZ
    MAILCOW_TZ="${MAILCOW_TZ:-$DETECTED_TZ}"
    [ -f "/usr/share/zoneinfo/$MAILCOW_TZ" ] || \
        python3 -c "import zoneinfo; zoneinfo.ZoneInfo('$MAILCOW_TZ')" 2>/dev/null || \
        { warn "Timezone '$MAILCOW_TZ' not validated, continuing anyway."; }
    log "Timezone: $MAILCOW_TZ"

    # ─────────────────────────────────────────────────────────────────────────
    #  STEP 5 – BRANCH & OPTIONS
    # ─────────────────────────────────────────────────────────────────────────
    hr
    echo -e "${Y}  Step 5/6 – Branch & Options${N}"
    hr
    echo ""
    echo -e "  Branch:  ${G}1) master${N} (stable, recommended)  ${B}2) nightly${N} (testing)"
    read -rp "  Select [1]: " br_choice
    case "${br_choice:-1}" in
        2) MAILCOW_BRANCH="nightly" ;;
        *) MAILCOW_BRANCH="master"  ;;
    esac

    echo ""
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    echo -e "  RAM: ${C}${TOTAL_RAM_MB} MB${N}"
    [ "$TOTAL_RAM_MB" -lt 3072 ] && \
        warn "Less than 3 GB RAM – ClamAV (needs ~1 GB) will be disabled by default."
    CLAMAV_DEF=$( [ "$TOTAL_RAM_MB" -ge 3072 ] && echo "Y" || echo "N" )
    read -rp "  Enable ClamAV antivirus? [${CLAMAV_DEF}]: " clam_in
    clam_in="${clam_in:-$CLAMAV_DEF}"
    [[ "$clam_in" =~ ^[Yy]$ ]] && SKIP_CLAMD="n" || SKIP_CLAMD="y"

    echo ""
    IPV6_AVAIL="n"
    ip -6 addr show scope global 2>/dev/null | grep -q inet6 && IPV6_AVAIL="y"
    echo -e "  IPv6 detected: ${C}${IPV6_AVAIL}${N}"
    IPV6_DEF=$( [ "$IPV6_AVAIL" = "y" ] && echo "Y" || echo "N" )
    read -rp "  Enable IPv6? [${IPV6_DEF}]: " ipv6_in
    ipv6_in="${ipv6_in:-$IPV6_DEF}"
    [[ "$ipv6_in" =~ ^[Yy]$ ]] && MAILCOW_IPV6="y" || MAILCOW_IPV6="n"

    # ─────────────────────────────────────────────────────────────────────────
    #  STEP 6 – CONFIRM
    # ─────────────────────────────────────────────────────────────────────────
    hr
    echo -e "${Y}  Step 6/6 – Confirm${N}"
    hr
    echo ""
    echo -e "  Hostname  : ${Y}${MAILCOW_HOSTNAME}${N}"
    echo -e "  Domain    : ${Y}${MAIL_DOMAIN}${N}"
    echo -e "  Admin     : ${Y}${MC_ADMIN_USER}${N}"
    echo -e "  Password  : ${Y}${MC_ADMIN_PASS}${N}"
    echo -e "  Timezone  : ${Y}${MAILCOW_TZ}${N}"
    echo -e "  Branch    : ${Y}${MAILCOW_BRANCH}${N}"
    echo -e "  ClamAV    : ${Y}$([ "$SKIP_CLAMD" = "n" ] && echo enabled || echo disabled)${N}"
    echo -e "  IPv6      : ${Y}${MAILCOW_IPV6}${N}"
    echo ""

    while true; do
        read -rp "  Start installation? [Y/n]: " go
        go="${go:-Y}"
        [[ "$go" =~ ^[Yy]$ ]] && break
        [[ "$go" =~ ^[Nn]$ ]] && { info "Cancelled."; exit 0; }
    done

    # ── install deps ─────────────────────────────────────────────────────────
    hr; echo -e "${Y}  Installing dependencies …${N}"; hr
    install_deps

    local COMPOSE
    COMPOSE=$(detect_compose)

    # ── clone repo ───────────────────────────────────────────────────────────
    hr; echo -e "${Y}  Cloning Mailcow repository …${N}"; hr
    umask 0022
    if [ -d "$INSTALL_DIR/.git" ]; then
        log "Repo exists – updating …"
        cd "$INSTALL_DIR"
        git fetch --all --tags >>"$LOG_FILE" 2>&1
        git checkout "$MAILCOW_BRANCH" >>"$LOG_FILE" 2>&1
        git pull origin "$MAILCOW_BRANCH" >>"$LOG_FILE" 2>&1
    else
        git clone --branch "$MAILCOW_BRANCH" \
            https://github.com/mailcow/mailcow-dockerized "$INSTALL_DIR" \
            >>"$LOG_FILE" 2>&1
    fi
    cd "$INSTALL_DIR"
    log "Repository ready."

    # ── generate mailcow.conf ─────────────────────────────────────────────────
    hr; echo -e "${Y}  Generating mailcow.conf …${N}"; hr

    # Pipe the expected answers to generate_config.sh
    # It asks: "1. Mail server hostname (FQDN)" and "2. Timezone"
    printf '%s\n%s\n' "$MAILCOW_HOSTNAME" "$MAILCOW_TZ" \
        | bash ./generate_config.sh >>"$LOG_FILE" 2>&1 || true

    # generate_config.sh may exit non-zero on older versions; check file exists
    if [ ! -f "mailcow.conf" ]; then
        error "generate_config.sh did not produce mailcow.conf – creating manually."
        # Minimal fallback config
        cat > mailcow.conf <<CONF
MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}
TZ=${MAILCOW_TZ}
MAILCOW_PASS_SCHEME=BLF-CRYPT
DBNAME=mailcow
DBUSER=mailcow
DBPASS=$(gen_pass 28)
DBROOT=$(gen_pass 28)
HTTP_PORT=80
HTTP_BIND=
HTTPS_PORT=443
HTTPS_BIND=
SMTP_PORT=25
SMTPS_PORT=465
SUBMISSION_PORT=587
IMAP_PORT=143
IMAPS_PORT=993
POP_PORT=110
POPS_PORT=995
SIEVE_PORT=4190
COMPOSE_PROJECT_NAME=mailcow
SKIP_LETS_ENCRYPT=n
ENABLE_SSL_SNI=n
SKIP_IP_CHECK=n
SKIP_HTTP_VERIFICATION=n
SKIP_CLAMD=${SKIP_CLAMD}
SKIP_SOLR=n
SKIP_UNBOUND=n
USE_WATCHDOG=n
WATCHDOG_NOTIFY_EMAIL=
WATCHDOG_NOTIFY_BAN=y
WATCHDOG_NOTIFY_START=y
WATCHDOG_SUBJECT=Watchdog ALERT
LOG_LINES=9999
MESSAGE_LIMIT=26214400
ADDITIONAL_SERVER_NAMES=
SQL_PORT=3306
SQL_BIND=127.0.0.1
REDIS_PORT=6379
REDIS_BIND=127.0.0.1
IPV6_NETWORK=fd4d:6169:6c63:6f77::/64
ACME_CERT_ID=0
CONF
    fi

    # Enforce our wizard settings over whatever generate_config.sh produced
    sed -i "s|^MAILCOW_HOSTNAME=.*|MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}|" mailcow.conf
    sed -i "s|^TZ=.*|TZ=${MAILCOW_TZ}|"                                   mailcow.conf
    sed -i "s|^SKIP_CLAMD=.*|SKIP_CLAMD=${SKIP_CLAMD}|"                   mailcow.conf

    if [ "$MAILCOW_IPV6" = "n" ]; then
        # Blank the IPv6 network to prevent subnet creation
        sed -i "s|^IPV6_NETWORK=.*|IPV6_NETWORK=|" mailcow.conf
    fi

    # Source DB credentials for later use
    source mailcow.conf
    log "mailcow.conf ready."

    # ── pull & start ──────────────────────────────────────────────────────────
    hr; echo -e "${Y}  Pulling Docker images (this may take a while) …${N}"; hr
    $COMPOSE pull 2>&1 | tee -a "$LOG_FILE"

    hr; echo -e "${Y}  Starting Mailcow …${N}"; hr
    $COMPOSE up -d 2>&1 | tee -a "$LOG_FILE"

    # ── wait for mysql to be ready ────────────────────────────────────────────
    log "Waiting for MySQL to be ready …"
    local attempt=0 max=40
    while [ $attempt -lt $max ]; do
        if $COMPOSE exec -T mysql-mailcow mysqladmin ping -u"${DBUSER}" -p"${DBPASS}" \
            --silent >>"$LOG_FILE" 2>&1; then
            log "MySQL ready."; break
        fi
        attempt=$((attempt+1))
        info "MySQL not ready yet … ($attempt/$max)"
        sleep 5
    done

    # ── wait for web UI ───────────────────────────────────────────────────────
    log "Waiting for Mailcow web UI …"
    attempt=0; max=72
    while [ $attempt -lt $max ]; do
        if curl -sk --max-time 5 "https://localhost/" -o /dev/null 2>/dev/null; then
            log "Web UI is up!"; break
        fi
        attempt=$((attempt+1))
        info "Waiting for web UI … ($attempt/$max)"
        sleep 5
    done
    [ $attempt -eq $max ] && warn "Web UI timeout – check: $COMPOSE logs nginx-mailcow"

    # ── set admin credentials ─────────────────────────────────────────────────
    hr; echo -e "${Y}  Setting admin credentials …${N}"; hr

    # Check if bcrypt python module is available
    if python3 -c "import bcrypt" 2>/dev/null; then
        local HASHED
        HASHED=$(python3 -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(12)).decode())" "$MC_ADMIN_PASS")
        $COMPOSE exec -T mysql-mailcow mysql \
            -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" \
            -e "UPDATE admin SET username='${MC_ADMIN_USER}', password='{BLF-CRYPT}${HASHED}', active=1 WHERE username='admin';" \
            >>"$LOG_FILE" 2>&1 \
            && log "Admin credentials set via SQL." \
            || warn "SQL update failed – admin credentials may still be default."
    else
        # Use mailcow's own reset script as fallback
        warn "python3-bcrypt not available. Using mailcow-reset-admin.sh …"
        if [ -f "$INSTALL_DIR/helper-scripts/mailcow-reset-admin.sh" ]; then
            bash "$INSTALL_DIR/helper-scripts/mailcow-reset-admin.sh" >>"$LOG_FILE" 2>&1 || true
            warn "Admin password was reset to a random value by the helper. Set it manually: mailcow change-admin"
        fi
    fi

    # ── generate API key ──────────────────────────────────────────────────────
    MC_API_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    $COMPOSE exec -T mysql-mailcow mysql \
        -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" \
        -e "DELETE FROM api WHERE username='${MC_ADMIN_USER}'; \
            INSERT INTO api (username,api_key,active,allow_from) \
            VALUES('${MC_ADMIN_USER}','${MC_API_KEY}','1','127.0.0.1/32,::1/128');" \
        >>"$LOG_FILE" 2>&1 && log "API key saved." \
        || { warn "Could not save API key."; MC_API_KEY=""; }

    # ── add mail domain ───────────────────────────────────────────────────────
    hr; echo -e "${Y}  Adding mail domain ${MAIL_DOMAIN} …${N}"; hr
    sleep 5  # give API a moment
    if [ -n "$MC_API_KEY" ]; then
        local domain_resp
        domain_resp=$(curl -sk -X POST "https://localhost/api/v1/add/domain" \
            -H "Content-Type: application/json" \
            -H "X-API-Key: ${MC_API_KEY}" \
            -d "{\"domain\":\"${MAIL_DOMAIN}\",\"description\":\"Primary domain\",\"aliases\":400,\"mailboxes\":10,\"defquota\":3072,\"maxquota\":10240,\"quota\":10240,\"active\":\"1\",\"rl_value\":10,\"rl_frame\":\"s\",\"backupmx\":\"0\",\"relay_all_recipients\":\"0\"}" \
            2>/dev/null || echo "curl_failed")
        echo "$domain_resp" | grep -qi '"type":"success"' \
            && log "Domain ${MAIL_DOMAIN} added." \
            || warn "Domain add response: ${domain_resp}"
    else
        warn "Skipping API domain add (no API key). Add ${MAIL_DOMAIN} manually in the web UI."
    fi

    # ── write marker ──────────────────────────────────────────────────────────
    cat > "$MARKER_FILE" <<EOF
# Mailcow Installation
# Installed: $(date '+%Y-%m-%d %H:%M:%S')
MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}
MAIL_DOMAIN=${MAIL_DOMAIN}
MAILCOW_TZ=${MAILCOW_TZ}
MAILCOW_BRANCH=${MAILCOW_BRANCH}
MAILCOW_IPV6=${MAILCOW_IPV6}
SKIP_CLAMD=${SKIP_CLAMD}
SERVER_IP=${SERVER_IP}
INSTALL_DIR=${INSTALL_DIR}
COMPOSE_CMD=${COMPOSE}
MC_ADMIN_USER=${MC_ADMIN_USER}
MC_ADMIN_PASS=${MC_ADMIN_PASS}
MC_API_KEY=${MC_API_KEY}
DBNAME=${DBNAME}
DBUSER=${DBUSER}
DBPASS=${DBPASS}
EOF
    chmod 600 "$MARKER_FILE"
    log "Marker file written."

    # ── remove .bashrc hook ───────────────────────────────────────────────────
    remove_bashrc_hook

    # ── DNS table ─────────────────────────────────────────────────────────────
    echo ""
    hr
    echo -e "${Y}  Required DNS Records for ${MAIL_DOMAIN}${N}"
    hr
    echo ""
    printf "  %-24s %-8s %-8s %s\n" "Name" "Type" "TTL" "Value"
    printf "  %-24s %-8s %-8s %s\n" "────────────────────" "────" "───" "──────────────────────"
    printf "  %-24s %-8s %-8s %s\n" "${MAILCOW_HOSTNAME}." "A"    "3600" "${SERVER_IP}"
    printf "  %-24s %-8s %-8s %s\n" "${MAIL_DOMAIN}."      "MX"   "3600" "10 ${MAILCOW_HOSTNAME}."
    printf "  %-24s %-8s %-8s %s\n" "autoconfig.${MAIL_DOMAIN}." "CNAME" "3600" "${MAILCOW_HOSTNAME}."
    printf "  %-24s %-8s %-8s %s\n" "autodiscover.${MAIL_DOMAIN}." "CNAME" "3600" "${MAILCOW_HOSTNAME}."
    printf "  %-24s %-8s %-8s %s\n" "_dmarc.${MAIL_DOMAIN}." "TXT" "3600" "v=DMARC1; p=reject; rua=mailto:dmarc@${MAIL_DOMAIN}"
    echo ""
    echo -e "  ${B}DKIM & SPF${N}: generated inside Mailcow → Configuration → Domains → DNS"
    echo ""

    # ── final summary ─────────────────────────────────────────────────────────
    echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${G}║${N}   ${Y}✓  Mailcow installation complete!${N}                ${G}║${N}"
    echo -e "${G}╠══════════════════════════════════════════════════════╣${N}"
    echo -e "${G}║${N}  Hostname  : ${Y}${MAILCOW_HOSTNAME}${N}"
    echo -e "${G}║${N}  Domain    : ${Y}${MAIL_DOMAIN}${N}"
    echo -e "${G}║${N}  Admin     : ${Y}${MC_ADMIN_USER}${N}"
    echo -e "${G}║${N}  Password  : ${Y}${MC_ADMIN_PASS}${N}"
    echo -e "${G}╠══════════════════════════════════════════════════════╣${N}"
    echo -e "${G}║${N}  Web UI  : ${C}https://${MAILCOW_HOSTNAME}${N}"
    echo -e "${G}╠══════════════════════════════════════════════════════╣${N}"
    echo -e "${G}║${N}  Manage  : ${G}mailcow <status|update|logs|…>${N}"
    echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
    echo ""
    log "Installation finished."
}

# =============================================================================
#  ENTRY POINT
#  This script doubles as the setup runner placed at
#  /usr/local/bin/mailcow-setup-run
# =============================================================================
bootstrap() {
    # ── When invoked via  curl … | bash  stdin is the curl pipe, not the
    #    terminal. Save the script to disk first, then re-exec from disk
    #    with stdin bound to /dev/tty so interactive reads work.
    [ "$EUID" -eq 0 ] || die "Must run as root."

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    local SELF_PATH="/usr/local/bin/mailcow-setup-run"
    local SCRIPT_URL="https://raw.githubusercontent.com/digiboy367/mailcow-installer/refs/heads/main/mailcow-setup.sh"

    # ── save script to disk ─────────────────────────────────────────────
    if [ ! -f "$SELF_PATH" ]; then
        echo -e "${B}[INFO]${N} Downloading installer to ${SELF_PATH} …"
        if command -v curl &>/dev/null; then
            curl -fsSL "$SCRIPT_URL" -o "$SELF_PATH" \
                || die "Failed to download installer from $SCRIPT_URL"
        elif command -v wget &>/dev/null; then
            wget -qO "$SELF_PATH" "$SCRIPT_URL" \
                || die "Failed to download installer from $SCRIPT_URL"
        else
            apt-get install -y curl >>"$LOG_FILE" 2>&1 \
                || die "curl/wget not found and could not be installed."
            curl -fsSL "$SCRIPT_URL" -o "$SELF_PATH" \
                || die "Failed to download installer."
        fi
        chmod +x "$SELF_PATH"
        echo -e "${G}[OK]${N} Installer saved. Launching setup …"
        echo ""
    fi

    # ── if stdin is not a tty (piped), re-exec from disk with /dev/tty ─
    if [ ! -t 0 ]; then
        exec bash "$SELF_PATH" install </dev/tty
    fi

    # ── already on a tty (called from .bashrc hook) ─────────────────────
    install_manager
    install_motd
    install_bashrc_hook
    run_install
}

# ── dispatch based on how script is invoked ───────────────────────────────────
case "${1:-bootstrap}" in
    install)
        install_manager
        install_motd
        install_bashrc_hook
        run_install
        ;;
    bootstrap) bootstrap   ;;
    *)         bootstrap   ;;
esac
