#!/bin/bash

# ============================================================================
# DEBIAN 13 SERVER SETUP SCRIPT
# Interactive menu-driven setup for new server configuration
# Must be run as root
# ============================================================================

set -e

# ---------- Colors & Logging ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "\n${BLUE}==> $1${NC}"; }
log_success(){ echo -e "${GREEN}[OK]${NC} $1"; }
log_banner(){
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════╗"
    printf "║%*s║\n" "$((51))" ""
    printf "║ %-${50}s ║\n" "$1"
    printf "║ %-${50}s ║\n" "$2"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ---------- Show banner at startup ----------
log_banner "DEBIAN 13 SERVER SETUP" "Customized interactive configuration"

# ---------- Root check ----------
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root."
    exit 1
fi

# ---------- Ensure sudo is installed ----------
ensure_sudo() {
    if ! command -v sudo &>/dev/null; then
        log_warn "sudo not found — installing…"
        apt install -y sudo
    fi
}

# ---------- Globals set by interactive sections ----------
ACTION_CREATE_USER=false
ACTION_CONFIGURE_SSH=false
ACTION_SETUP_UFW=false
ACTION_INSTALL_FAIL2BAN=false
ACTION_INSTALL_DOCKER=false
USERNAME=""
PASSWORD=""
USER_IS_SUDO=false

# ---------- Helper: prompt username ----------
prompt_username() {
    while true; do
        read -rp "Enter username : " USERNAME
        if [[ -z "$USERNAME" ]]; then
            log_error "Username cannot be empty."
            continue
        fi
        if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_error "Only letters, numbers, underscores and hyphens are allowed."
            continue
        fi
        if id "$USERNAME" &>/dev/null; then
            log_warn "User '$USERNAME' already exists."
            read -rp "Continue anyway? (y/n) : " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && return 0 || USERNAME=""
        else
            return 0
        fi
    done
}

# ---------- Helper: prompt password ----------
prompt_password() {
    local msg="${1:-Enter password : }"
    while true; do
        read -sp "$msg" PASSWORD
        echo ""
        read -sp "Confirm password : " PCONFIRM
        echo ""
        if [[ "$PASSWORD" == "$PCONFIRM" ]]; then
            if [[ -z "$PASSWORD" ]]; then
                log_warn "Password must not be empty."
                continue
            fi
            return 0
        fi
        log_error "Passwords do not match. Try again."
    done
}

# ---------- Helper: import SSH keys from root ----------
import_ssh_keys() {
    local target_user="$1"
    read -rp "Import SSH keys from root? (y/n) : " imp
    if [[ "$imp" =~ ^[Yy]$ ]]; then
        if [[ -d "/root/.ssh" ]]; then
            mkdir -p "/home/${target_user}/.ssh"
            cp -a /root/.ssh/* "/home/${target_user}/.ssh/" 2>/dev/null || true
            chmod 700 "/home/${target_user}/.ssh"
            find "/home/${target_user}/.ssh" -type f -exec chmod 600 {} \;
            find "/home/${target_user}/.ssh" -type d -exec chmod 700 {} \;
            chown -R "${target_user}:${target_user}" "/home/${target_user}/.ssh"
            log_success "SSH keys copied for $target_user."
        else
            log_warn "No /root/.ssh directory found — nothing to copy."
        fi
    fi
}

# ========================================================================
# Create user (optionally with sudo privileges)
# ========================================================================
do_create_user() {
    ensure_sudo
    local fresh=true
    if [[ -n "$USERNAME" ]] && id "$USERNAME" &>/dev/null; then
        log_warn "User '$USERNAME' already exists, will skip creation."
        fresh=false
    fi
    if [[ "$fresh" == true ]]; then
        prompt_username
        prompt_password "Password for '$USERNAME': "
        useradd -m -s /bin/bash "$USERNAME"
        echo "$USERNAME:$PASSWORD" | chpasswd
        log_success "User '$USERNAME' created."
    else
        log_warn "User '$USERNAME' already exists — skipping creation."
    fi

    if $USER_IS_SUDO; then
        # Add to sudo group
        usermod -aG sudo "$USERNAME" 2>/dev/null || true
        log_success "'$USERNAME' added to sudo group."

        # Passwordless sudo via /etc/sudoers.d
        local sfile="/etc/sudoers.d/$USERNAME"
        rm -f "$sfile"
        echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > "$sfile"
        chmod 0440 "$sfile"

        if visudo -c &>/dev/null; then
            log_success "Sudoers syntax validated OK."
        else
            log_error "visudo -c reported errors — please check $sfile manually!"
        fi

        # Import SSH keys only for sudo users
        import_ssh_keys "$USERNAME"
    else
        log_info "No sudo privileges assigned (as requested)."
    fi
}
# ========================================================================
# SECTION 3 – Configure SSH security (interactive)
# ========================================================================
do_configure_ssh() {
    local conf_dir="/etc/ssh/sshd_config.d"
    local conf_file="$conf_dir/90-custom.conf"

    if [[ ! -d "$conf_dir" ]]; then
        mkdir -p "$conf_dir"
        log_info "Created $conf_dir."
    fi

    # Always force PubkeyAuthentication yes
    echo "# === Managed by server-setup.sh — do NOT edit manually ===" > "$conf_file"
    echo "" >> "$conf_file"
    echo "# Mandatory: Public key authentication" >> "$conf_file"
    echo "PubkeyAuthentication yes" >> "$conf_file"

    # --- PermitRootLogin ---
    read -rp "Disallow root login via SSH? (y/n, default y): " opt
    opt=${opt:-y}
    if [[ "$opt" =~ ^[Yy]$ ]]; then
        echo "" >> "$conf_file"
        echo "# Disallow root login" >> "$conf_file"
        echo "PermitRootLogin no" >> "$conf_file"
        log_success "Root login disabled." 
    else
        log_info "Root login will remain unchanged." 
    fi

    # --- PasswordAuthentication ---
    read -rp "Disable password authentication (SSH keys only)? (y/n, default y): " opt
    opt=${opt:-y}
    if [[ "$opt" =~ ^[Yy]$ ]]; then
        echo "" >> "$conf_file"
        echo "# Require SSH-key authentication only" >> "$conf_file"
        echo "PasswordAuthentication no" >> "$conf_file"
        log_success "Password authentication disabled." 
    else
        log_info "Password authentication will remain enabled." 
    fi



    # --- Hardening options ---
    read -rp "Apply hardening: MaxAuthTries 5 / MaxSessions 5? (y/n, default y): " opt
    opt=${opt:-y}
    if [[ "$opt" =~ ^[Yy]$ ]]; then
        echo "" >> "$conf_file"
        echo "# Security hardening" >> "$conf_file"
        echo "MaxAuthTries 5" >> "$conf_file"
        echo "MaxSessions 5" >> "$conf_file"
        log_success "Hardening applied." 
    else
        log_info "Hardening skipped." 
    fi

    echo "UsePAM yes" >> "$conf_file"

    chmod 0644 "$conf_file"
    log_success "Wrote $conf_file"

    if sshd -t 2>&1; then
        log_success "sshd config syntax OK — restarting SSH."
        systemctl restart ssh
    else
        log_warn "sshd -t failed — review $conf_file manually:"
        sshd -t 2>&1 || true
    fi
}

# ========================================================================
# Install Docker Engine on Debian
# ========================================================================
do_install_docker() {
    ensure_sudo
    ### See [documentation](https://docs.docker.com/engine/install/debian/)
    # 1. Remove conflicting packages
    log_info "Removing any conflicting Docker packages…"
    sudo apt remove -y docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc 2>/dev/null || true

    # 2. Install prerequisites
    log_info "Installing prerequisites (ca-certificates, curl)…"
    sudo apt install -y ca-certificates curl

    # 3. Set up the Docker GPG key
    log_info "Adding Docker's official GPG key…"
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # 4. Add the Docker repository to Apt sources
    log_info "Configuring Docker APT repository…"
    sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # 5. Update and install Docker
    log_info "Updating package list and installing Docker Engine…"
    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log_success "Docker Engine installed successfully."

    # 6. Ask which user(s) to add to the docker group
    read -rp "Add a user to the 'docker' group? (y/n, default n): " docker_group
    if [[ "$docker_group" =~ ^[Yy]$ ]]; then
        while true; do
            read -rp "Enter username to add (or 'done' to finish): " target_user
            if [[ "$target_user" =~ ^[Dd]one$ ]]; then
                break
            elif [[ -z "$target_user" ]]; then
                log_error "Username cannot be empty."
                continue
            fi
            
            if id "$target_user" &>/dev/null; then
                sudo usermod -aG docker "$target_user"
                log_success "'$target_user' added to docker group."
                
                # Try to make the change effective in the current session if possible
                if [[ "$target_user" == "$(logname 2>/dev/null)" ]]; then
                    newgrp docker || true
                    log_info "Attempted to apply group change via newgrp for your current session."
                    log_warn "If it didn't take effect, log out and log back in again."
                fi
            else
                log_warn "User '$target_user' does not exist — skipped."
            fi
        done
    else
        log_info "No users added to docker group. Use 'sudo usermod -aG docker <username>' manually if needed."
    fi
}

# ========================================================================
# SECTION 4 – Setup UFW firewall
# ========================================================================
do_setup_ufw() {
    ensure_sudo

    if ! command -v ufw &>/dev/null; then
        log_info "Installing ufw …"
        LC_ALL=C.UTF-8 LANG=C.UTF-8 apt install -y ufw 2>/dev/null || apt install -y ufw
    fi

    # Disable IPv6
    log_info "Disabling IPv6 in UFW …"
    if grep -q '^IPV6=' /etc/default/ufw; then
        sed 's/^IPV6=.*/IPV6=no/' /etc/default/ufw > /tmp/ufw_tmp.conf
        mv /tmp/ufw_tmp.conf /etc/default/ufw
    else
        echo 'IPV6=no' >> /etc/default/ufw
    fi

    # Start clean — use yes to auto-confirm the reset prompt
    yes | ufw reset 2>/dev/null || true

    # Default policies
    # ufw default drop incoming
    # ufw default allow outgoing

    # Allow SSH
    ufw allow 22/tcp comment 'allow SSH from anywhere'
    log_success "SSH port 22/tcp allowed."

    # Extra ports
    while true; do
        read -rp "Allow any additional port(s)? (y/n) : " more
        if [[ "$more" =~ ^[Nn]$ ]]; then
            break
        elif [[ ! "$more" =~ ^[Yy]$ ]]; then
            log_error "Please answer y or n."
            continue
        fi

        while true; do
            log_warn "If you install docker, be sure to open the ports for your containers"
            read -rp "Port number (or 'done' to finish) : " pnum
            if [[ "$pnum" =~ ^[0-9]+$ ]]; then
                read -rp "Protocol (tcp/udp/both, default tcp) : " proto
                proto=${proto:-tcp}
                case "$proto" in
                    tcp)   ufw allow "$pnum/tcp" comment "custom rule" ;;
                    udp)   ufw allow "$pnum/udp" comment "custom rule" ;;
                    both|"")
                        ufw allow "$pnum/tcp" comment "custom rule"
                        ufw allow "$pnum/udp" comment "custom rule"
                        ;;
                esac
                log_success "Port $pnum ($proto) allowed."
            elif [[ "$pnum" =~ ^[Dd]one$ ]]; then
                break
            else
                log_error "'$pnum' is not a valid port number."
            fi
        done
    done

    # Enable
    echo "y" | ufw enable
    ufw status verbose
}

# ========================================================================
# Install fail2ban for SSH protection
# ========================================================================
do_install_fail2ban() {
    ensure_sudo
    log_info "Installing fail2ban for SSH protection…"
    sudo apt install -y fail2ban
    
    # Configure fail2ban for SSH by creating a custom config
    local jail_conf="/etc/fail2ban/jail.d/90-custom.conf"
    cat > "$jail_conf" << 'EOF'
[fail2ban]
# Settings are applied globally to all jails
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port   = ssh
filter = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 86400
findtime = 600
EOF
    chmod 0644 "$jail_conf"
    log_success "Fail2ban installed with SSH protection configured."
    
    # Restart fail2ban to apply configuration
    systemctl restart fail2ban 2>/dev/null || service fail2ban restart 2>/dev/null || true
    log_success "Fail2ban restarted successfully."
}

# ========================================================================
# MAIN
# ========================================================================
main() {
    ensure_sudo

    banner="DEBIAN 13 SERVER SETUP"
    tagline="Customized interactive configuration"

    # ── Option A ────────────────────────────────
    read -rp "[$(tput bold)A$(tput sgr0)] Create a user            ? (y/n): " opt
    if [[ "$opt" =~ ^[Yy]$ ]]; then
        ACTION_CREATE_USER=true
        read -rp "Should this user have sudo privileges? (y/n, default n): " sudo_opt
        sudo_opt=${sudo_opt:-n}
        if [[ "$sudo_opt" =~ ^[Yy]$ ]]; then
            USER_IS_SUDO=true
            log_success "User will have sudo privileges." 
        else
            log_info "User will NOT have sudo privileges." 
        fi
    fi

    # ── Option C ────────────────────────────────
    read -rp "[$(tput bold)C$(tput sgr0)] Configure SSH security     ? (y/n): " opt
    if [[ "$opt" =~ ^[Yy]$ ]]; then
        ACTION_CONFIGURE_SSH=true
    fi

    # ── Option D ────────────────────────────────
    read -rp "[$(tput bold)D$(tput sgr0)] Set up UFW firewall        ? (y/n): " opt
    if [[ "$opt" =~ ^[Yy]$ ]]; then
        ACTION_SETUP_UFW=true
    fi

    # ── Option E ────────────────────────────────
    read -rp "[$(tput bold)E$(tput sgr0)] Install fail2ban for SSH ? (y/n): " opt
    if [[ "$opt" =~ ^[Yy]$ ]]; then
        ACTION_INSTALL_FAIL2BAN=true
    fi

    # ── Option F ────────────────────────────────
    read -rp "[$(tput bold)F$(tput sgr0)] Install Docker Engine    ? (y/n): " opt
    if [[ "$opt" =~ ^[Yy]$ ]]; then
        ACTION_INSTALL_DOCKER=true
    fi

    # ── Nothing selected ────────────────────────
    if ! $ACTION_CREATE_USER && ! $ACTION_CONFIGURE_SSH && ! $ACTION_SETUP_UFW && ! $ACTION_INSTALL_FAIL2BAN && ! $ACTION_INSTALL_DOCKER; then
        log_warn "No actions selected — exiting."
        exit 0
    fi

    # ── Package updates & upgrade ───────────────
    echo ""
    echo ""
    log_banner "SYSTEM UPDATE" "apt update + upgrade"

    log_step "Running apt update…"
    sudo apt update -y

    log_step "Running apt upgrade -y …"
    sudo apt upgrade -y

    # ── Run chosen actions ──────────────────────
    echo ""
    echo ""
    log_banner "RUNNING CHOSEN ACTIONS" "Tell what do you want"
    
    $ACTION_CREATE_USER      && do_create_user
    $ACTION_CONFIGURE_SSH    && do_configure_ssh
    $ACTION_SETUP_UFW        && do_setup_ufw
    $ACTION_INSTALL_FAIL2BAN && do_install_fail2ban
    $ACTION_INSTALL_DOCKER   && do_install_docker

    # ── Sistem cleanup ───────────────────────────
    echo ""
    log_banner "SYSTEM CLEANUP" "apt autopurge + autoclean"

    log_step "Running apt autopurge & autoclean"
    sudo apt autopurge -y; sudo apt autoclean -y
    
    # ── Final message ───────────────────────────
    echo ""
    log_banner "SETUP COMPLETE" "All requested tasks finished."
    echo ""
    log_success "Everything done successfully."
    echo ""
        
    # ── Summary of what was configured ──────────
    echo ""
    log_banner "$banner" "$tagline"
    echo ""
    echo -e "${CYAN}Configuration Summary:${NC}"
    echo "─────────────────────────"

    $ACTION_CREATE_USER      && { [[ -n "$USERNAME" ]] && echo "  ✓ User          '$USERNAME' processed"; }
    $ACTION_CONFIGURE_SSH    && echo "  ✓ SSH security  hardened"
    $ACTION_SETUP_UFW        && echo "  ✓ Firewall      enabled"
    $ACTION_INSTALL_FAIL2BAN && echo "  ✓ Fail2ban      installed for SSH"
    $ACTION_INSTALL_DOCKER   && echo "  ✓ Docker Engine installed"

    log_warn "Be sure to back up your SSH keys elsewhere before losing root access!"
    echo ""
}

main "$@"
