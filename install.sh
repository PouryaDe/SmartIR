#!/bin/bash

# UI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

VERSION="3.0"

function print_msg()  { echo -e "${GREEN}  ✔  $1${NC}"; }
function print_err()  { echo -e "${RED}  ✘  $1${NC}"; }
function print_info() { echo -e "${CYAN}  ➜  $1${NC}"; }

function draw_line() {
    echo -e "${DIM}──────────────────────────────────────────────${NC}"
}

function check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_err "Please run this script as root (use sudo)"
        exit 1
    fi
}

function validate_domain() {
    local d="$1"
    # Validate standard domain name or IPv4 address to prevent command injection and malformed configs
    if [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || [[ "$d" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

function validate_proxy() {
    local p="$1"
    if [ -z "$p" ]; then
        return 0
    fi
    # Validate proxy format (e.g. socks5://user:pass@ip:port or http://ip:port)
    if [[ "$p" =~ ^(socks5|socks5h|http|https)://([a-zA-Z0-9._~%-]+(:[a-zA-Z0-9._~%-]+)?@)?[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]; then
        return 0
    fi
    return 1
}

function install_prerequisites() {
    print_msg "Updating system packages..."
    apt update && apt upgrade -y

    print_msg "Installing essential packages (nginx, certbot, git)..."
    apt install -y software-properties-common certbot nginx git curl wget unzip

    print_msg "Adding PHP PPA and installing PHP 8.1..."
    add-apt-repository ppa:ondrej/php -y
    apt update
    apt install -y php8.1-fpm php8.1-cli php8.1-common php8.1-mbstring php8.1-xmlrpc \
                   php8.1-soap php8.1-gd php8.1-xml php8.1-intl php8.1-mysql \
                   php8.1-sqlite3 php8.1-ldap php8.1-zip php8.1-curl php8.1-opcache php8.1-readline

    systemctl enable php8.1-fpm --now

    print_msg "Ensuring IPv6 is enabled for optimal international connectivity..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    cat > /etc/sysctl.d/99-smartlink.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
    sysctl -p /etc/sysctl.d/99-smartlink.conf >/dev/null 2>&1
    print_msg "Optimizing Nginx and PHP-FPM settings based on server resources..."
    CPU_CORES=$(nproc)
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    
    MAX_CHILDREN=$(( (TOTAL_RAM - 256) / 20 ))
    if [ "$MAX_CHILDREN" -lt 10 ]; then MAX_CHILDREN=10; fi
    START_SERVERS=$(( MAX_CHILDREN / 4 ))
    if [ "$START_SERVERS" -lt 5 ]; then START_SERVERS=5; fi
    MIN_SPARE=$(( MAX_CHILDREN / 4 ))
    if [ "$MIN_SPARE" -lt 5 ]; then MIN_SPARE=5; fi
    MAX_SPARE=$(( MAX_CHILDREN / 2 ))
    if [ "$MAX_SPARE" -lt 10 ]; then MAX_SPARE=10; fi
    
    # Optimize Nginx
    sed -i "s/worker_processes.*/worker_processes auto;/" /etc/nginx/nginx.conf
    sed -i "s/worker_connections.*/worker_connections 4096;/" /etc/nginx/nginx.conf
    sed -i "s/# multi_accept on;/multi_accept on;/" /etc/nginx/nginx.conf

    FPM_CONF="/etc/php/8.1/fpm/pool.d/www.conf"
    if [ -f "$FPM_CONF" ]; then
        sed -i 's/pm = .*/pm = dynamic/' $FPM_CONF
        sed -i "s/pm.max_children = .*/pm.max_children = $MAX_CHILDREN/" $FPM_CONF
        sed -i "s/pm.start_servers = .*/pm.start_servers = $START_SERVERS/" $FPM_CONF
        sed -i "s/pm.min_spare_servers = .*/pm.min_spare_servers = $MIN_SPARE/" $FPM_CONF
        sed -i "s/pm.max_spare_servers = .*/pm.max_spare_servers = $MAX_SPARE/" $FPM_CONF
        systemctl reload php8.1-fpm
    fi
    systemctl reload nginx

    print_msg "Prerequisites installed successfully!"
}

function add_site() {
    read -p "Enter Domain Name (e.g., example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)
    if [ -z "$DOMAIN" ]; then
        print_err "Domain cannot be empty."
        return
    fi
    if ! validate_domain "$DOMAIN"; then
        print_err "Invalid domain format: $DOMAIN"
        return
    fi

    read -p "Enter API Domain Name (e.g., api.example.com): " API_DOMAIN
    API_DOMAIN=$(echo "$API_DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)
    if [ -z "$API_DOMAIN" ]; then
        print_err "API Domain cannot be empty."
        return
    fi
    if ! validate_domain "$API_DOMAIN"; then
        print_err "Invalid API domain format: $API_DOMAIN"
        return
    fi

    DOC_ROOT="/var/www/$DOMAIN"

    if [ -d "$DOC_ROOT" ]; then
        print_err "Directory $DOC_ROOT already exists."
        return
    fi

    print_msg "Downloading project from GitHub..."
    TMP_DIR=$(mktemp -d)
    if wget -q https://github.com/PouryaDe/SmartIR/archive/refs/heads/main.zip -O "$TMP_DIR/smartir.zip"; then
        unzip -q "$TMP_DIR/smartir.zip" -d "$TMP_DIR"
        mv "$TMP_DIR/SmartIR-main" "$DOC_ROOT"
        rm -rf "$TMP_DIR"
    else
        print_err "Failed to download project from GitHub."
        rm -rf "$TMP_DIR"
        return
    fi

    # Remove dev, test, and dependency files from public docroot
    rm -rf "$DOC_ROOT/tests" "$DOC_ROOT/phpunit.xml" "$DOC_ROOT/.phpunit.cache" \
           "$DOC_ROOT/.vscode" "$DOC_ROOT/.git" "$DOC_ROOT/.gitignore" \
           "$DOC_ROOT/composer.json" "$DOC_ROOT/composer.lock"

    chown -R www-data:www-data "$DOC_ROOT"

    print_msg "Configuring config.php for API Domain..."
    cat > "$DOC_ROOT/config.php" <<EOF
<?php
define('API_DOMAIN', '$API_DOMAIN');
define('APP_DEBUG', false);
define('PROXY_URL', '');
EOF
    chown www-data:www-data "$DOC_ROOT/config.php"

    print_msg "Creating cache directory..."
    mkdir -p "$DOC_ROOT/cache"
    chown www-data:www-data "$DOC_ROOT/cache"

    print_msg "Obtaining SSL Certificate for $DOMAIN..."
    systemctl stop nginx 2>/dev/null
    certbot certonly --standalone --preferred-challenges http --agree-tos -d "$DOMAIN" \
            --register-unsafely-without-email \
            --pre-hook "systemctl stop nginx" \
            --post-hook "systemctl start nginx"
    CERT_STATUS=$?
    systemctl start nginx 2>/dev/null

    if [ $CERT_STATUS -ne 0 ] || [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        print_err "Failed to obtain SSL certificate for $DOMAIN. Setup aborted."
        rm -rf "$DOC_ROOT"
        return
    fi

    print_msg "Creating Nginx configuration..."
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    access_log off;
    location / {
        rewrite ^ https://\$host\$request_uri? permanent;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;
    charset utf-8;
    
    root $DOC_ROOT;
    index index.php index.html index.htm index.nginx-debian.html;
    autoindex off;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location ~ \.php$ {
         include snippets/fastcgi-php.conf;
         fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
         fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
         include fastcgi_params;
    }

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt { log_not_found off; access_log off; allow all; }
    
    location ~* \.(css|gif|ico|jpeg|jpg|js|png)$ {
        expires max;
        log_not_found off;
    }
    
    location ~ /\. {
        deny all;
    }
    
    location ~* \.(sh|md)$ {
        deny all;
    }
    
    location ~* ^/(functions\.php|Route\.php|subscription-link\.php|config\.php|cache|error\.log|tests|composer\.(json|lock)|phpunit\.xml) {
        deny all;
    }
    
}
EOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    print_msg "Testing Nginx configuration and reloading..."
    if nginx -t; then
        systemctl reload nginx
        print_msg "Site $DOMAIN added successfully! API Domain is set to $API_DOMAIN."
    else
        print_err "Nginx configuration test failed. Reverting configuration..."
        rm -f "/etc/nginx/sites-enabled/$DOMAIN"
        rm -f "$NGINX_CONF"
        systemctl reload nginx
    fi
}

# ------------------------------------------------------------------------------
# SmartLink Helper Functions & Domain Discovery
# ------------------------------------------------------------------------------

# Resolves the document root path for a given domain.
# First checks standard /var/www/<domain>. If absent, parses Nginx vhost config.
# Arguments:
#   $1 - Domain name
# Outputs:
#   Path to document root directory
function get_doc_root() {
    local domain="$1"
    local base_www="${SMARTLINK_VAR_WWW:-/var/www}"
    local doc_root="$base_www/$domain"
    if [ -d "$doc_root" ]; then
        echo "$doc_root"
        return 0
    fi

    local base_nginx="${SMARTLINK_NGINX_CONF_DIR:-/etc/nginx/sites-enabled}"
    local nginx_conf="$base_nginx/$domain"
    [ -f "$nginx_conf" ] || nginx_conf="${SMARTLINK_NGINX_AVAIL_DIR:-/etc/nginx/sites-available}/$domain"
    if [ -f "$nginx_conf" ]; then
        local detected_root
        detected_root=$(grep -E '^\s*root\s+' "$nginx_conf" 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d ';')
        if [ -n "$detected_root" ] && [ -d "$detected_root" ]; then
            echo "$detected_root"
            return 0
        fi
    fi
    echo "$doc_root"
    return 1
}

# Verifies whether a given domain belongs to an IR SmartLink installation.
# Protects non-SmartLink vhosts (WordPress, panels, static sites) from being touched.
# Arguments:
#   $1 - Domain name
# Returns:
#   0 if domain is a valid SmartLink site, 1 otherwise.
function is_smartlink_site() {
    local domain="$1"
    [ -n "$domain" ] || return 1
    [ "$domain" == "default" ] && return 1

    # Disallow backup configs (.bak, .old, .disabled, etc.), swap files (.swp), or hidden files
    if [[ "$domain" =~ \.(bak|save|old|disabled|conf|orig|swp)$ ]] || [[ "$domain" =~ ^\. ]]; then
        return 1
    fi

    # Disallow malformed domain or IP names
    validate_domain "$domain" || return 1

    local doc_root
    doc_root=$(get_doc_root "$domain")

    [ -d "$doc_root" ] || return 1
    [ -f "$doc_root/index.php" ] || return 1

    # Must contain API_DOMAIN in config.php (current) or index.php (legacy)
    if [ -f "$doc_root/config.php" ] && grep -q "API_DOMAIN" "$doc_root/config.php" 2>/dev/null; then
        return 0
    elif grep -q "API_DOMAIN" "$doc_root/index.php" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Discovers and outputs all active IR SmartLink domains configured in Nginx.
# Filters out disabled sites, the default Nginx page, and non-SmartLink hosts.
# Outputs:
#   Newline-separated list of validated SmartLink domain names
function get_smartlink_domains() {
    local base_nginx="${SMARTLINK_NGINX_CONF_DIR:-/etc/nginx/sites-enabled}"
    local domains=()
    if [ -d "$base_nginx" ]; then
        for conf in "$base_nginx"/*; do
            [ -e "$conf" ] || continue
            local domain
            domain=$(basename "$conf")
            if is_smartlink_site "$domain"; then
                domains+=("$domain")
            fi
        done
    fi
    for d in "${domains[@]}"; do
        [ -n "$d" ] && echo "$d"
    done
}

# Extracts the current PROXY_URL configured for a site.
# Arguments:
#   $1 - Domain name
# Outputs:
#   Proxy URL string or empty if direct connection
function get_site_proxy() {
    local domain="$1"
    local doc_root
    doc_root=$(get_doc_root "$domain")
    local config_file="$doc_root/config.php"

    if [ -f "$config_file" ]; then
        local p
        p=$(grep "PROXY_URL" "$config_file" 2>/dev/null | sed -n "s/.*PROXY_URL['\"]\s*,\s*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n 1)
        if [ -z "$p" ]; then
            p=$(grep "define('PROXY_URL'" "$config_file" 2>/dev/null | awk -F"'" '{print $4}' | head -n 1)
        fi
        echo "$p"
    fi
}

# Extracts the current API_DOMAIN configured for a site.
# Arguments:
#   $1 - Domain name
# Outputs:
#   Upstream API domain string
function get_site_api() {
    local domain="$1"
    local doc_root
    doc_root=$(get_doc_root "$domain")
    local config_file="$doc_root/config.php"

    if [ -f "$config_file" ]; then
        local a
        a=$(grep "API_DOMAIN" "$config_file" 2>/dev/null | sed -n "s/.*API_DOMAIN['\"]\s*,\s*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n 1)
        if [ -z "$a" ]; then
            a=$(grep "define('API_DOMAIN'" "$config_file" 2>/dev/null | awk -F"'" '{print $4}' | head -n 1)
        fi
        echo "$a"
    elif [ -f "$doc_root/index.php" ]; then
        grep "define('API_DOMAIN'" "$doc_root/index.php" 2>/dev/null | awk -F"'" '{print $4}' | head -n 1
    fi
}

# Updates the proxy configuration for a specific SmartLink domain.
# Preserves existing API_DOMAIN and APP_DEBUG settings.
# Arguments:
#   $1 - Domain name
#   $2 - New proxy URL (empty string clears proxy)
# Returns:
#   0 on success, 1 on failure
function set_site_proxy() {
    local domain="$1"
    local new_proxy="$2"

    # Defense-in-depth validation to prevent code injection into config.php
    validate_domain "$domain" || return 1
    validate_proxy "$new_proxy" || return 1

    local doc_root
    doc_root=$(get_doc_root "$domain")
    local config_file="$doc_root/config.php"

    if [ ! -d "$doc_root" ]; then
        return 1
    fi

    local current_api
    current_api=$(get_site_api "$domain")
    if [ -z "$current_api" ] || [ "$current_api" == "API_DOMAIN_PLACEHOLDER" ] || ! validate_domain "$current_api"; then
        current_api="example.com"
    fi

    local current_debug="false"
    if [ -f "$config_file" ]; then
        if grep -iqE "define\(['\"]APP_DEBUG['\"],\s*true\)" "$config_file" 2>/dev/null; then
            current_debug="true"
        fi
    fi

    cat > "$config_file" <<EOF
<?php
define('API_DOMAIN', '$current_api');
define('APP_DEBUG', $current_debug);
define('PROXY_URL', '$new_proxy');
EOF
    chown www-data:www-data "$config_file" 2>/dev/null || true
    return 0
}

function list_sites() {
    print_info "Currently installed SmartLink sites:"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    draw_line
    for i in "${!domains[@]}"; do
        local d="${domains[$i]}"
        local p
        p=$(get_site_proxy "$d")
        local api
        api=$(get_site_api "$d")
        local num=$((i + 1))

        if [ -n "$p" ]; then
            echo -e "  ${WHITE}[$num]${NC} ${CYAN}$d${NC} ${DIM}➜${NC} Proxy: ${GREEN}$p${NC}"
        else
            echo -e "  ${WHITE}[$num]${NC} ${CYAN}$d${NC} ${DIM}➜${NC} Proxy: ${YELLOW}None (Direct)${NC}"
        fi
        if [ -n "$api" ]; then
            echo -e "      ${DIM}↳ API Domain: $api${NC}"
        fi
    done
    draw_line
}

function delete_site() {
    print_msg "Currently installed SmartLink sites:"
    mapfile -t domains < <(get_smartlink_domains)
    
    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo "Select a Domain to delete:"
    select DOMAIN in "${domains[@]}" "Cancel"; do
        if [ "$DOMAIN" == "Cancel" ]; then
            print_msg "Aborted."
            return
        elif [ -n "$DOMAIN" ]; then
            break
        else
            print_err "Invalid selection. Please try again."
        fi
    done

    read -p "Are you sure you want to completely delete $DOMAIN? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        print_msg "Aborted."
        return
    fi

    if [ -z "$DOMAIN" ] || [ "$DOMAIN" == "/" ]; then
        print_err "Invalid domain selection."
        return
    fi

    print_msg "Removing Nginx configuration..."
    rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    rm -f "/etc/nginx/sites-available/$DOMAIN"

    print_msg "Removing web directory..."
    local doc_root
    doc_root=$(get_doc_root "$DOMAIN")
    if [ -n "$doc_root" ] && [ "$doc_root" != "/" ] && [ "$doc_root" != "/var/www" ]; then
        rm -rf "$doc_root"
    fi

    print_msg "Revoking SSL certificate..."
    certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null

    print_msg "Reloading Nginx..."
    systemctl reload nginx

    print_msg "Site $DOMAIN deleted successfully."
}

# Downloads and extracts the latest SmartIR release from GitHub into a target directory.
# Arguments:
#   $1 - Target directory path
# Returns:
#   0 on success, 1 on failure
function download_smartlink_source() {
    local target_dir="$1"
    print_msg "Downloading latest release from GitHub..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if wget -q https://github.com/PouryaDe/SmartIR/archive/refs/heads/main.zip -O "$tmp_dir/smartir.zip"; then
        unzip -q "$tmp_dir/smartir.zip" -d "$tmp_dir"
        
        # Clean dev, test, and dependency files
        rm -rf "$tmp_dir/SmartIR-main/tests" \
               "$tmp_dir/SmartIR-main/phpunit.xml" \
               "$tmp_dir/SmartIR-main/.phpunit.cache" \
               "$tmp_dir/SmartIR-main/.vscode" \
               "$tmp_dir/SmartIR-main/.git" \
               "$tmp_dir/SmartIR-main/.gitignore" \
               "$tmp_dir/SmartIR-main/composer.json" \
               "$tmp_dir/SmartIR-main/composer.lock"

        mkdir -p "$target_dir"
        cp -r "$tmp_dir/SmartIR-main/." "$target_dir/"
        rm -rf "$tmp_dir"
        return 0
    else
        rm -rf "$tmp_dir"
        print_err "Failed to download update from GitHub."
        return 1
    fi
}

# Updates files for a single SmartLink domain from a prepared source directory.
# Preserves existing cache and config.php settings.
# Arguments:
#   $1 - Domain name
#   $2 - Source directory containing unpacked release
# Returns:
#   0 on success, 1 on failure
function perform_site_update() {
    local domain="$1"
    local source_dir="$2"

    validate_domain "$domain" || return 1
    local doc_root
    doc_root=$(get_doc_root "$domain")

    if [ -z "$doc_root" ] || [ ! -d "$doc_root" ] || [ ! -d "$source_dir" ]; then
        return 1
    fi

    local current_proxy
    current_proxy=$(get_site_proxy "$domain")
    local current_api
    current_api=$(get_site_api "$domain")

    if [ -z "$current_api" ] || [ "$current_api" == "API_DOMAIN_PLACEHOLDER" ]; then
        current_api="example.com"
    fi

    local current_debug="false"
    if [ -f "$doc_root/config.php" ]; then
        if grep -iqE "define\(['\"]APP_DEBUG['\"],\s*true\)" "$doc_root/config.php" 2>/dev/null; then
            current_debug="true"
        fi
    fi

    # Backup existing cache if present
    local tmp_cache
    tmp_cache=$(mktemp -d)
    if [ -d "$doc_root/cache" ]; then
        cp -r "$doc_root/cache/." "$tmp_cache/" 2>/dev/null || true
    fi

    # Replace site files with fresh source code safely
    find "$doc_root" -mindepth 1 -delete 2>/dev/null || rm -rf "${doc_root:?}"/*
    cp -r "$source_dir/." "$doc_root/"

    # Restore cache
    mkdir -p "$doc_root/cache"
    if [ "$(ls -A "$tmp_cache" 2>/dev/null)" ]; then
        cp -r "$tmp_cache/." "$doc_root/cache/" 2>/dev/null || true
    fi
    rm -rf "$tmp_cache"

    # Restore config.php
    cat > "$doc_root/config.php" <<EOF
<?php
define('API_DOMAIN', '$current_api');
define('APP_DEBUG', $current_debug);
define('PROXY_URL', '$current_proxy');
EOF

    chmod -R 755 "$doc_root" 2>/dev/null || true
    chmod -R 777 "$doc_root/cache" 2>/dev/null || true
    chown -R www-data:www-data "$doc_root" 2>/dev/null || true
    return 0
}

# Interactive menu to update a single SmartLink domain, or route to bulk update.
function update_site() {
    print_info "Update SmartLink Source Code"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}Select a domain to update:${NC}"
    for i in "${!domains[@]}"; do
        local d="${domains[$i]}"
        local api
        api=$(get_site_api "$d")
        echo -e "  ${WHITE}$((i+1)))${NC} $d ${DIM}(API: $api)${NC}"
    done
    local all_opt=$(( ${#domains[@]} + 1 ))
    local cancel_opt=$(( ${#domains[@]} + 2 ))
    echo -e "  ${WHITE}$all_opt)${NC} ${CYAN}[Update ALL sites]${NC}"
    echo -e "  ${WHITE}$cancel_opt)${NC} ${RED}Cancel${NC}"
    echo ""

    read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-$cancel_opt]: " CHOICE

    if [ "$CHOICE" == "$cancel_opt" ] || [ "$CHOICE" == "c" ] || [ "$CHOICE" == "C" ]; then
        print_msg "Aborted."
        return
    fi

    if [ "$CHOICE" == "$all_opt" ] || [ "$CHOICE" == "a" ] || [ "$CHOICE" == "A" ]; then
        update_all_sites
        return
    fi

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#domains[@]}" ]; then
        print_err "Invalid selection. Please try again."
        return
    fi

    local DOMAIN="${domains[$((CHOICE - 1))]}"
    local prep_dir
    prep_dir=$(mktemp -d)
    if ! download_smartlink_source "$prep_dir"; then
        rm -rf "$prep_dir"
        return 1
    fi

    print_info "Updating $DOMAIN..."
    if perform_site_update "$DOMAIN" "$prep_dir"; then
        print_msg "Clearing PHP OPcache..."
        systemctl reload php8.1-fpm 2>/dev/null || true
        print_msg "Site $DOMAIN updated successfully!"
    else
        print_err "Failed to update $DOMAIN."
    fi

    rm -rf "$prep_dir"
}

# Updates all configured SmartLink sites to the latest version in a single operation.
function update_all_sites() {
    print_info "Update Source Code for ALL SmartLink Sites"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}The following ${#domains[@]} SmartLink site(s) will be updated:${NC}"
    for i in "${!domains[@]}"; do
        local d="${domains[$i]}"
        local api
        api=$(get_site_api "$d")
        echo -e "  ${WHITE}[$((i+1))]${NC} $d ${DIM}(API: $api)${NC}"
    done

    echo ""
    read -rp "  $(echo -e "${YELLOW}›${NC}") Update all ${#domains[@]} site(s) to latest release? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        print_msg "Aborted."
        return
    fi

    local prep_dir
    prep_dir=$(mktemp -d)
    if ! download_smartlink_source "$prep_dir"; then
        rm -rf "$prep_dir"
        return 1
    fi

    local updated_count=0
    for d in "${domains[@]}"; do
        print_info "Updating $d..."
        if perform_site_update "$d" "$prep_dir"; then
            print_msg "$d updated successfully."
            updated_count=$((updated_count + 1))
        else
            print_err "Failed to update $d."
        fi
    done

    rm -rf "$prep_dir"

    print_msg "Clearing PHP OPcache..."
    systemctl reload php8.1-fpm 2>/dev/null || true

    echo ""
    print_msg "Update complete: $updated_count of ${#domains[@]} site(s) updated successfully!"
}

function clear_cache() {
    print_info "Currently installed SmartLink sites:"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}Select a domain to clear its cache:${NC}"
    select DOMAIN in "${domains[@]}" "Cancel"; do
        if [ "$DOMAIN" == "Cancel" ]; then
            print_msg "Aborted."
            return
        elif [ -n "$DOMAIN" ]; then
            break
        else
            print_err "Invalid selection. Please try again."
        fi
    done

    local doc_root
    doc_root=$(get_doc_root "$DOMAIN")
    local CACHE_DIR="$doc_root/cache"

    if [ ! -d "$CACHE_DIR" ]; then
        print_err "Cache directory not found: $CACHE_DIR"
        return
    fi

    FILE_COUNT=$(find "$CACHE_DIR" -name '*.json' 2>/dev/null | wc -l)

    if [ "$FILE_COUNT" -eq 0 ]; then
        print_info "Cache is already empty for $DOMAIN."
        return
    fi

    rm -f "$CACHE_DIR"/*.json
    print_msg "Cleared $FILE_COUNT cached file(s) for $DOMAIN."
}

# Configures proxy for a single selected SmartLink domain.
# Arguments:
#   $1 - Domain name
function configure_single_domain_proxy() {
    local DOMAIN="$1"
    local doc_root
    doc_root=$(get_doc_root "$DOMAIN")
    local CONFIG_FILE="$doc_root/config.php"

    if [ ! -f "$CONFIG_FILE" ]; then
        print_err "config.php not found for $DOMAIN."
        return
    fi

    local CURRENT_PROXY
    CURRENT_PROXY=$(get_site_proxy "$DOMAIN")
    if [ -n "$CURRENT_PROXY" ]; then
        print_info "Current proxy for $DOMAIN: $CURRENT_PROXY"
    else
        print_info "No proxy currently configured for $DOMAIN."
    fi

    echo ""
    echo -e "  ${DIM}Format: socks5://USERNAME:PASSWORD@PROXY_IP:PORT${NC}"
    echo -e "  ${DIM}Leave empty to remove proxy.${NC}"
    read -rp "  $(echo -e "${YELLOW}›${NC}") Enter proxy URL: " NEW_PROXY
    NEW_PROXY=$(echo "$NEW_PROXY" | xargs)

    if ! validate_proxy "$NEW_PROXY"; then
        print_err "Invalid proxy URL format. Example: socks5://user:pass@1.2.3.4:1080"
        return
    fi

    if set_site_proxy "$DOMAIN" "$NEW_PROXY"; then
        systemctl reload php8.1-fpm 2>/dev/null || true
        if [ -z "$NEW_PROXY" ]; then
            print_msg "Proxy removed for $DOMAIN."
        else
            print_msg "Proxy configured for $DOMAIN: $NEW_PROXY"
        fi
    else
        print_err "Failed to update configuration for $DOMAIN."
    fi
}

# Interactive menu to select a single SmartLink domain, or route to bulk operations.
function configure_proxy() {
    print_info "Currently installed SmartLink sites:"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}Select a domain to configure its proxy:${NC}"
    for i in "${!domains[@]}"; do
        local d="${domains[$i]}"
        local p
        p=$(get_site_proxy "$d")
        local num=$((i + 1))
        if [ -n "$p" ]; then
            echo -e "  ${WHITE}$num)${NC} $d ${DIM}➜${NC} Proxy: ${GREEN}$p${NC}"
        else
            echo -e "  ${WHITE}$num)${NC} $d ${DIM}➜${NC} Proxy: ${YELLOW}None (Direct)${NC}"
        fi
    done
    local all_opt=$(( ${#domains[@]} + 1 ))
    local rem_opt=$(( ${#domains[@]} + 2 ))
    local cancel_opt=$(( ${#domains[@]} + 3 ))
    echo -e "  ${WHITE}$all_opt)${NC} ${CYAN}[Apply proxy to ALL domains]${NC}"
    echo -e "  ${WHITE}$rem_opt)${NC} ${YELLOW}[Remove proxy from ALL domains]${NC}"
    echo -e "  ${WHITE}$cancel_opt)${NC} ${RED}Cancel${NC}"
    echo ""

    read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-$cancel_opt]: " CHOICE

    if [ "$CHOICE" == "$cancel_opt" ] || [ "$CHOICE" == "c" ] || [ "$CHOICE" == "C" ]; then
        print_msg "Aborted."
        return
    fi

    if [ "$CHOICE" == "$all_opt" ] || [ "$CHOICE" == "a" ] || [ "$CHOICE" == "A" ]; then
        configure_proxy_all
        return
    fi

    if [ "$CHOICE" == "$rem_opt" ] || [ "$CHOICE" == "r" ] || [ "$CHOICE" == "R" ]; then
        remove_proxy_all
        return
    fi

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#domains[@]}" ]; then
        print_err "Invalid selection. Please try again."
        return
    fi

    local SELECTED_DOMAIN="${domains[$((CHOICE - 1))]}"
    configure_single_domain_proxy "$SELECTED_DOMAIN"
}

# Configures the same proxy URL for all SmartLink sites at once.
function configure_proxy_all() {
    print_info "Configure Proxy for ALL SmartLink Sites"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}The following ${#domains[@]} SmartLink site(s) will be affected:${NC}"
    for i in "${!domains[@]}"; do
        local d="${domains[$i]}"
        local p
        p=$(get_site_proxy "$d")
        local num=$((i + 1))
        if [ -n "$p" ]; then
            echo -e "  ${WHITE}[$num]${NC} $d ${DIM}➜${NC} Proxy: ${GREEN}$p${NC}"
        else
            echo -e "  ${WHITE}[$num]${NC} $d ${DIM}➜${NC} Proxy: ${YELLOW}None (Direct)${NC}"
        fi
    done

    echo ""
    echo -e "  ${DIM}Format: socks5://USERNAME:PASSWORD@PROXY_IP:PORT${NC}"
    echo -e "  ${DIM}Leave empty to remove proxy from ALL domains.${NC}"
    read -rp "  $(echo -e "${YELLOW}›${NC}") Enter proxy URL for ALL domains: " NEW_PROXY
    NEW_PROXY=$(echo "$NEW_PROXY" | xargs)

    if ! validate_proxy "$NEW_PROXY"; then
        print_err "Invalid proxy URL format. Example: socks5://user:pass@1.2.3.4:1080"
        return
    fi

    echo ""
    if [ -z "$NEW_PROXY" ]; then
        read -rp "  $(echo -e "${YELLOW}›${NC}") Are you sure you want to REMOVE proxy from ALL ${#domains[@]} site(s)? [y/N]: " CONFIRM
    else
        read -rp "  $(echo -e "${YELLOW}›${NC}") Apply proxy to ALL ${#domains[@]} site(s)? [y/N]: " CONFIRM
    fi

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        print_msg "Aborted."
        return
    fi

    local updated_count=0
    for d in "${domains[@]}"; do
        if set_site_proxy "$d" "$NEW_PROXY"; then
            updated_count=$((updated_count + 1))
        else
            print_err "Failed to update proxy for $d"
        fi
    done

    if [ "$updated_count" -gt 0 ]; then
        systemctl reload php8.1-fpm 2>/dev/null || true
    fi

    echo ""
    if [ -z "$NEW_PROXY" ]; then
        print_msg "Proxy removed successfully from $updated_count site(s)."
    else
        print_msg "Proxy successfully applied to $updated_count site(s): $NEW_PROXY"
    fi
}

# Removes proxy configuration from all SmartLink sites, restoring direct routing.
function remove_proxy_all() {
    print_info "Remove Proxy from ALL SmartLink Sites"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}The following ${#domains[@]} SmartLink site(s) will have their proxy removed:${NC}"
    local active_proxies=0
    for i in "${!domains[@]}"; do
        local d="${domains[$i]}"
        local p
        p=$(get_site_proxy "$d")
        local num=$((i + 1))
        if [ -n "$p" ]; then
            echo -e "  ${WHITE}[$num]${NC} $d ${DIM}➜${NC} Proxy: ${GREEN}$p${NC}"
            active_proxies=$((active_proxies + 1))
        else
            echo -e "  ${WHITE}[$num]${NC} $d ${DIM}➜${NC} Proxy: ${YELLOW}None (Direct)${NC}"
        fi
    done

    if [ "$active_proxies" -eq 0 ]; then
        echo ""
        print_info "All sites are already using direct connections (no active proxies)."
        return
    fi

    echo ""
    read -rp "  $(echo -e "${YELLOW}›${NC}") Are you sure you want to REMOVE proxy from ALL ${#domains[@]} site(s)? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        print_msg "Aborted."
        return
    fi

    local removed_count=0
    for d in "${domains[@]}"; do
        if set_site_proxy "$d" ""; then
            removed_count=$((removed_count + 1))
        else
            print_err "Failed to remove proxy for $d"
        fi
    done

    if [ "$removed_count" -gt 0 ]; then
        systemctl reload php8.1-fpm 2>/dev/null || true
    fi

    echo ""
    print_msg "Proxy removed successfully from all $removed_count site(s). All sites now connect directly."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_root

    while true; do
        clear
        echo ""
        echo -e "  ${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "  ${BLUE}║${WHITE}      SmartLink Installer & Manager          ${BLUE}║${NC}"
        echo -e "  ${BLUE}║${DIM}                    v${VERSION}                        ${BLUE}║${NC}"
        echo -e "  ${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC}  ${CYAN}Install Prerequisites${NC}"
        echo -e "  ${WHITE}2)${NC}  ${CYAN}Add a New Site${NC}"
        echo -e "  ${WHITE}3)${NC}  ${CYAN}List Sites & Proxies${NC}"
        echo -e "  ${WHITE}4)${NC}  ${CYAN}Delete a Site${NC}"
        echo -e "  ${WHITE}5)${NC}  ${CYAN}Update Source Code (Single Site)${NC}"
        echo -e "  ${WHITE}6)${NC}  ${CYAN}Update Source Code (All Sites)${NC}"
        echo -e "  ${WHITE}7)${NC}  ${YELLOW}Clear Cache${NC}"
        echo -e "  ${WHITE}8)${NC}  ${YELLOW}Configure Proxy (Single Domain)${NC}"
        echo -e "  ${WHITE}9)${NC}  ${YELLOW}Configure Proxy (All Domains)${NC}"
        echo -e "  ${WHITE}10)${NC} ${YELLOW}Remove Proxy from ALL Domains${NC}"
        echo -e "  ${WHITE}11)${NC} ${RED}Exit${NC}"
        echo ""
        draw_line
        read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-11]: " OPTION
        draw_line
        echo ""

        case $OPTION in
            1) install_prerequisites ;;
            2) add_site ;;
            3) list_sites ;;
            4) delete_site ;;
            5) update_site ;;
            6) update_all_sites ;;
            7) clear_cache ;;
            8) configure_proxy ;;
            9) configure_proxy_all ;;
            10) remove_proxy_all ;;
            11) echo -e "  ${DIM}Goodbye!${NC}\n"; exit 0 ;;
            *) print_err "Invalid option. Please try again." ;;
        esac

        echo ""
        read -rp "  $(echo -e "${DIM}Press Enter to continue...${NC}")"
    done
fi
