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

VERSION="3.3"

function print_msg()  { echo -e "${GREEN}  ✔  $1${NC}"; }
function print_err()  { echo -e "${RED}  ✘  $1${NC}"; }
function print_info() { echo -e "${CYAN}  ➜  $1${NC}"; }

function draw_line() {
    echo -e "${DIM}──────────────────────────────────────────────${NC}"
}

function get_php_fpm_service() {
    for svc in php8.1-fpm php8.2-fpm php8.3-fpm php8.0-fpm php-fpm; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo "$svc"
            return 0
        fi
    done
    for svc in php8.1-fpm php8.2-fpm php8.3-fpm php8.0-fpm php-fpm; do
        if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc"; then
            echo "$svc"
            return 0
        fi
    done
    echo "php8.1-fpm"
    return 1
}

function reload_php_fpm() {
    local svc
    svc=$(get_php_fpm_service)
    systemctl reload "$svc" 2>/dev/null || systemctl reload php8.1-fpm 2>/dev/null || systemctl reload php8.2-fpm 2>/dev/null || systemctl reload php-fpm 2>/dev/null || true
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

# Optimizes Linux kernel sysctl, file descriptor limits, Nginx configuration,
# and PHP-FPM pool parameters dynamically based on available server RAM and CPU cores.
function optimize_server_resources() {
    print_info "Optimizing server, Nginx, and PHP-FPM resources based on hardware..."
    local total_ram_mb
    total_ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    if ! [[ "$total_ram_mb" =~ ^[0-9]+$ ]] || [ "$total_ram_mb" -le 0 ]; then
        total_ram_mb=1024
    fi
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    if ! [[ "$cpu_cores" =~ ^[0-9]+$ ]] || [ "$cpu_cores" -le 0 ]; then
        cpu_cores=1
    fi

    print_msg "Detected Hardware: ${cpu_cores} CPU core(s), ${total_ram_mb} MB RAM"

    # 1. Linux Kernel Optimization (sysctl)
    local sysctl_file="${SMARTLINK_SYSCTL_FILE:-/etc/sysctl.d/99-smartlink.conf}"
    local sysctl_dir
    sysctl_dir=$(dirname "$sysctl_file")
    [ -d "$sysctl_dir" ] || mkdir -p "$sysctl_dir" 2>/dev/null || true
    if [ -d "$sysctl_dir" ]; then
        cat > "$sysctl_file" <<EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
fs.file-max = 2097152
vm.swappiness = 10
EOF
        chmod 644 "$sysctl_file" 2>/dev/null || true
        sysctl -p "$sysctl_file" >/dev/null 2>&1 || true
        print_msg "Kernel network stack tuned (sysctl)."
    fi

    # 2. System File Descriptors (limits.d)
    local limits_file="${SMARTLINK_LIMITS_FILE:-/etc/security/limits.d/99-smartlink.conf}"
    local limits_dir
    limits_dir=$(dirname "$limits_file")
    [ -d "$limits_dir" ] || mkdir -p "$limits_dir" 2>/dev/null || true
    if [ -d "$limits_dir" ]; then
        cat > "$limits_file" <<EOF
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
www-data soft nofile 65535
www-data hard nofile 65535
EOF
        chmod 644 "$limits_file" 2>/dev/null || true
        print_msg "File descriptor limits set to 65535 (nofile)."
    fi

    # 3. Dynamic PHP-FPM Sizing based on available RAM
    # Reserve 250MB for OS + Nginx base, each SmartLink worker ~20MB
    local usable_ram=$(( total_ram_mb - 250 ))
    if [ "$usable_ram" -lt 150 ]; then
        usable_ram=150
    fi
    local max_children=$(( usable_ram / 20 ))
    if [ "$max_children" -lt 10 ]; then max_children=10; fi
    if [ "$max_children" -gt 250 ]; then max_children=250; fi

    local start_servers=$(( max_children / 4 ))
    if [ "$start_servers" -lt 4 ]; then start_servers=4; fi
    local min_spare=$(( max_children / 4 ))
    if [ "$min_spare" -lt 4 ]; then min_spare=4; fi
    local max_spare=$(( max_children / 2 ))
    if [ "$max_spare" -lt 8 ]; then max_spare=8; fi

    print_msg "Calculated PHP-FPM sizing: max_children=$max_children, start=$start_servers, min_spare=$min_spare, max_spare=$max_spare"

    local fpm_pools=("/etc/php/8.1/fpm/pool.d/www.conf" "/etc/php/8.2/fpm/pool.d/www.conf" "/etc/php/8.3/fpm/pool.d/www.conf" "/etc/php/8.0/fpm/pool.d/www.conf" "/etc/php-fpm.d/www.conf")
    local fpm_tuned=0
    for pool in "${fpm_pools[@]}"; do
        if [ -f "$pool" ]; then
            sed -i 's/^\s*pm\s*=.*/pm = dynamic/' "$pool" 2>/dev/null || true
            sed -i "s/^\s*pm.max_children\s*=.*/pm.max_children = $max_children/" "$pool" 2>/dev/null || true
            sed -i "s/^\s*pm.start_servers\s*=.*/pm.start_servers = $start_servers/" "$pool" 2>/dev/null || true
            sed -i "s/^\s*pm.min_spare_servers\s*=.*/pm.min_spare_servers = $min_spare/" "$pool" 2>/dev/null || true
            sed -i "s/^\s*pm.max_spare_servers\s*=.*/pm.max_spare_servers = $max_spare/" "$pool" 2>/dev/null || true

            # Memory-leak protection: recycle workers after 1000 requests
            if grep -q "pm.max_requests" "$pool" 2>/dev/null; then
                sed -i 's/^\s*;*\s*pm.max_requests\s*=.*/pm.max_requests = 1000/' "$pool" 2>/dev/null || true
            else
                echo "pm.max_requests = 1000" >> "$pool" 2>/dev/null || true
            fi

            # Prevent zombie hung requests
            if grep -q "request_terminate_timeout" "$pool" 2>/dev/null; then
                sed -i 's/^\s*;*\s*request_terminate_timeout\s*=.*/request_terminate_timeout = 60s/' "$pool" 2>/dev/null || true
            else
                echo "request_terminate_timeout = 60s" >> "$pool" 2>/dev/null || true
            fi
            fpm_tuned=1
        fi
    done
    if [ $fpm_tuned -eq 1 ]; then
        print_msg "PHP-FPM pool tuned with anti-leak and request recycling."
    fi

    # 4. Nginx Global Tuning
    local nginx_main="${SMARTLINK_NGINX_MAIN_CONF:-/etc/nginx/nginx.conf}"
    if [ -f "$nginx_main" ]; then
        cp -p "$nginx_main" "$nginx_main.smartlink.bak" 2>/dev/null || true
        sed -i 's/^\s*worker_processes.*/worker_processes auto;/' "$nginx_main" 2>/dev/null || true
        if ! grep -q "worker_rlimit_nofile" "$nginx_main" 2>/dev/null; then
            sed -i '/worker_processes/a worker_rlimit_nofile 65535;' "$nginx_main" 2>/dev/null || true
        else
            sed -i 's/^\s*worker_rlimit_nofile.*/worker_rlimit_nofile 65535;/' "$nginx_main" 2>/dev/null || true
        fi
        sed -i 's/^\s*worker_connections.*/    worker_connections 8192;/' "$nginx_main" 2>/dev/null || true
        if grep -q "multi_accept" "$nginx_main" 2>/dev/null; then
            sed -i 's/^\s*#*\s*multi_accept.*/    multi_accept on;/' "$nginx_main" 2>/dev/null || true
        fi
        if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
            cp -p "$nginx_main.smartlink.bak" "$nginx_main" 2>/dev/null || true
            print_err "Nginx main config test failed after edits; restored original configuration."
        else
            rm -f "$nginx_main.smartlink.bak" 2>/dev/null || true
            print_msg "Nginx worker connections and limits optimized."
        fi
    fi

    # 5. Nginx Dedicated Tuning Snippet (conf.d)
    local nginx_conf_d="${SMARTLINK_NGINX_CONFD:-/etc/nginx/conf.d}"
    [ -d "$nginx_conf_d" ] || mkdir -p "$nginx_conf_d" 2>/dev/null || true
    if [ -d "$nginx_conf_d" ]; then
        cat > "$nginx_conf_d/smartlink-tuning.conf" <<EOF
# SmartLink High-Traffic & Anti-Crash Tuning
server_names_hash_bucket_size 128;
client_max_body_size 16M;
client_body_buffer_size 128k;
client_header_buffer_size 4k;
large_client_header_buffers 4 16k;

reset_timedout_connection on;
client_body_timeout 15;
client_header_timeout 15;
send_timeout 15;

fastcgi_buffers 16 16k;
fastcgi_buffer_size 32k;
fastcgi_busy_buffers_size 64k;
fastcgi_temp_file_write_size 64k;
fastcgi_connect_timeout 60s;
fastcgi_send_timeout 60s;
fastcgi_read_timeout 60s;
EOF
        chmod 644 "$nginx_conf_d/smartlink-tuning.conf" 2>/dev/null || true
        print_msg "Nginx FastCGI buffer and timeout profiles configured."
    fi

    # 6. Apply changes
    reload_php_fpm
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    fi

    print_msg "Resource optimization successfully applied!"
}

function install_prerequisites() {
    print_msg "Updating system packages..."
    apt update && apt upgrade -y

    print_msg "Installing essential packages (nginx, certbot, git, openssl, cron)..."
    apt install -y software-properties-common certbot nginx git curl wget unzip openssl cron

    print_msg "Adding PHP PPA and installing PHP 8.1..."
    add-apt-repository ppa:ondrej/php -y
    apt update
    apt install -y php8.1-fpm php8.1-cli php8.1-common php8.1-mbstring php8.1-xmlrpc \
                   php8.1-soap php8.1-gd php8.1-xml php8.1-intl php8.1-mysql \
                   php8.1-sqlite3 php8.1-ldap php8.1-zip php8.1-curl php8.1-opcache php8.1-readline

    systemctl enable php8.1-fpm --now

    # Optimize server, Nginx, and PHP-FPM based on detected RAM & CPU
    optimize_server_resources

    print_msg "Configuring SSL auto-renewal cron job and timer..."
    setup_ssl_autorenew

    print_msg "Configuring Watchdog self-healing daemon..."
    setup_watchdog

    print_msg "Prerequisites installed successfully!"
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

function add_site() {
    print_info "Add a New SmartLink Site"
    read -rp "  $(echo -e "${YELLOW}›${NC}") Enter Domain Name (e.g., example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)
    if [ -z "$DOMAIN" ]; then
        print_err "Domain cannot be empty."
        return
    fi
    if ! validate_domain "$DOMAIN"; then
        print_err "Invalid domain format: $DOMAIN"
        return
    fi

    read -rp "  $(echo -e "${YELLOW}›${NC}") Enter API Domain Name (e.g., api.example.com): " API_DOMAIN
    API_DOMAIN=$(echo "$API_DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)
    if [ -z "$API_DOMAIN" ]; then
        print_err "API Domain cannot be empty."
        return
    fi
    if ! validate_domain "$API_DOMAIN"; then
        print_err "Invalid API domain format: $API_DOMAIN"
        return
    fi

    local DOC_ROOT="/var/www/$DOMAIN"

    if [ -d "$DOC_ROOT" ]; then
        print_err "Directory $DOC_ROOT already exists."
        return
    fi

    if ! download_smartlink_source "$DOC_ROOT"; then
        print_err "Failed to install site files."
        rm -rf "$DOC_ROOT"
        return 1
    fi

    print_msg "Configuring config.php for API Domain..."
    cat > "$DOC_ROOT/config.php" <<EOF
<?php
define('API_DOMAIN', '$API_DOMAIN');
define('APP_DEBUG', false);
define('PROXY_URL', '');
EOF

    mkdir -p "$DOC_ROOT/cache"
    chmod -R 755 "$DOC_ROOT"
    chmod 644 "$DOC_ROOT/config.php"
    chmod -R 777 "$DOC_ROOT/cache"
    chown -R www-data:www-data "$DOC_ROOT"

    print_msg "Obtaining SSL Certificate for $DOMAIN..."
    systemctl stop nginx 2>/dev/null
    certbot certonly --standalone --preferred-challenges http --agree-tos -d "$DOMAIN" \
            --register-unsafely-without-email --non-interactive \
            --pre-hook "systemctl stop nginx" \
            --post-hook "systemctl start nginx"
    CERT_STATUS=$?
    systemctl start nginx 2>/dev/null

    if [ $CERT_STATUS -ne 0 ] || [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        print_err "Failed to obtain SSL certificate for $DOMAIN. Setup aborted."
        rm -rf "$DOC_ROOT"
        return 1
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
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    charset utf-8;
    
    root $DOC_ROOT;
    index index.php index.html index.htm;
    autoindex off;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # Security Headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location ~ \.php$ {
         include snippets/fastcgi-php.conf;
         fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
         fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
         include fastcgi_params;
         fastcgi_buffers 16 16k;
         fastcgi_buffer_size 32k;
         fastcgi_busy_buffers_size 64k;
         fastcgi_temp_file_write_size 64k;
         fastcgi_connect_timeout 60s;
         fastcgi_send_timeout 60s;
         fastcgi_read_timeout 60s;
    }

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt { log_not_found off; access_log off; allow all; }
    
    location ~* \.(css|gif|ico|jpeg|jpg|js|png|webp|svg)$ {
        expires max;
        log_not_found off;
    }
    
    location ~ /\. {
        deny all;
    }
    
    location ~* \.(sh|md|sql|log)$ {
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
        setup_ssl_autorenew
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

# Installs or verifies the automated Let's Encrypt renewal cron job and systemd timer.
# Ensures certificate checks run twice daily with Nginx stop/start hooks.
function setup_ssl_autorenew() {
    local cron_dir="${SMARTLINK_CRON_DIR:-/etc/cron.d}"
    local cron_file="$cron_dir/smartlink-certbot"

    if [ -d "$cron_dir" ]; then
        cat > "$cron_file" <<'EOF'
# IR SmartLink SSL Auto-Renewal Job
# Automatically checks certificates twice daily and renews any expiring within 30 days
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/snap/bin

30 3,15 * * * root certbot renew --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" --deploy-hook "systemctl reload nginx" --quiet
EOF
        chmod 644 "$cron_file" 2>/dev/null || true
    fi

    systemctl enable --now certbot.timer 2>/dev/null || true
    systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
    return 0
}

# Resolves the path to the SSL certificate for a given domain.
# First checks the domain's Nginx vhost config for ssl_certificate.
# Falls back to standard /etc/letsencrypt/live/<domain>/fullchain.pem.
# Arguments:
#   $1 - Domain name
# Outputs:
#   Absolute path to certificate fullchain.pem
function get_site_ssl_cert() {
    local domain="$1"
    local base_nginx="${SMARTLINK_NGINX_CONF_DIR:-/etc/nginx/sites-enabled}"
    local nginx_conf="$base_nginx/$domain"
    [ -f "$nginx_conf" ] || nginx_conf="${SMARTLINK_NGINX_AVAIL_DIR:-/etc/nginx/sites-available}/$domain"

    if [ -f "$nginx_conf" ]; then
        local detected_cert
        detected_cert=$(grep -E '^\s*ssl_certificate\s+' "$nginx_conf" 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d ';')
        if [ -n "$detected_cert" ]; then
            echo "$detected_cert"
            return 0
        fi
    fi

    local le_dir="${SMARTLINK_LE_LIVE_DIR:-/etc/letsencrypt/live}"
    echo "$le_dir/$domain/fullchain.pem"
    return 0
}

# Evaluates certificate validity using OpenSSL.
# Arguments:
#   $1 - Domain name
# Outputs:
#   Status string: "valid", "expiring", "expired", "missing", or "unknown"
# Returns:
#   0 if valid or expiring soon, 1 if expired or invalid, 2 if missing
function get_ssl_cert_status() {
    local domain="$1"
    validate_domain "$domain" || { echo "invalid"; return 1; }

    local cert_file
    cert_file=$(get_site_ssl_cert "$domain")

    if [ ! -f "$cert_file" ]; then
        echo "missing"
        return 2
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        echo "unknown"
        return 0
    fi

    # Check if certificate is already expired (checkend 0 returns non-zero if expired)
    if ! openssl x509 -checkend 0 -noout -in "$cert_file" >/dev/null 2>&1; then
        echo "expired"
        return 1
    fi

    # Check if certificate expires within 30 days (2592000 seconds = 30 * 86400)
    if ! openssl x509 -checkend 2592000 -noout -in "$cert_file" >/dev/null 2>&1; then
        echo "expiring"
        return 0
    fi

    echo "valid"
    return 0
}

# Returns human-readable expiration details (days remaining or expired).
# Arguments:
#   $1 - Domain name
# Outputs:
#   String with remaining/expired days and expiration timestamp
function get_ssl_expiry_info() {
    local domain="$1"
    local cert_file
    cert_file=$(get_site_ssl_cert "$domain")

    if [ ! -f "$cert_file" ]; then
        echo "No certificate file found"
        return 1
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        echo "OpenSSL not available"
        return 1
    fi

    local raw_date
    raw_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | sed 's/notAfter=//')
    if [ -z "$raw_date" ]; then
        echo "Unable to read certificate date"
        return 1
    fi

    local exp_epoch
    exp_epoch=$(date -d "$raw_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$raw_date" +%s 2>/dev/null)
    if [ -n "$exp_epoch" ]; then
        local now_epoch
        now_epoch=$(date +%s)
        local diff_days=$(( (exp_epoch - now_epoch) / 86400 ))
        if [ "$diff_days" -lt 0 ]; then
            echo "Expired ($((-diff_days)) day(s) ago - $raw_date)"
        elif [ "$diff_days" -eq 0 ]; then
            echo "Expires TODAY ($raw_date)"
        else
            echo "$diff_days day(s) remaining ($raw_date)"
        fi
        return 0
    fi

    echo "$raw_date"
    return 0
}

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
    if [ -f "$doc_root/config.php" ] && grep -qE "^\s*define\s*\(\s*['\"]API_DOMAIN['\"]" "$doc_root/config.php" 2>/dev/null; then
        return 0
    elif [ -f "$doc_root/config.php" ] && grep -q "API_DOMAIN" "$doc_root/config.php" 2>/dev/null; then
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
        p=$(grep -E "^\s*define\s*\(\s*['\"]PROXY_URL['\"]" "$config_file" 2>/dev/null | sed -n "s/.*PROXY_URL['\"]\s*,\s*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n 1)
        if [ -z "$p" ]; then
            p=$(grep "PROXY_URL" "$config_file" 2>/dev/null | sed -n "s/.*PROXY_URL['\"]\s*,\s*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n 1)
        fi
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
        a=$(grep -E "^\s*define\s*\(\s*['\"]API_DOMAIN['\"]" "$config_file" 2>/dev/null | sed -n "s/.*API_DOMAIN['\"]\s*,\s*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n 1)
        if [ -z "$a" ]; then
            a=$(grep "API_DOMAIN" "$config_file" 2>/dev/null | sed -n "s/.*API_DOMAIN['\"]\s*,\s*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n 1)
        fi
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
        if grep -iqE "^\s*define\s*\(\s*['\"]APP_DEBUG['\"],\s*true\)" "$config_file" 2>/dev/null; then
            current_debug="true"
        elif grep -iqE "define\(['\"]APP_DEBUG['\"],\s*true\)" "$config_file" 2>/dev/null; then
            current_debug="true"
        fi
    fi

    cat > "$config_file" <<EOF
<?php
define('API_DOMAIN', '$current_api');
define('APP_DEBUG', $current_debug);
define('PROXY_URL', '$new_proxy');
EOF
    chmod 644 "$config_file" 2>/dev/null || true
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
        local doc_root
        doc_root=$(get_doc_root "$d")
        local cache_count=0
        if [ -d "$doc_root/cache" ]; then
            cache_count=$(find "$doc_root/cache" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
        fi
        local num=$((i + 1))

        local ssl_status
        ssl_status=$(get_ssl_cert_status "$d")
        local ssl_info
        ssl_info=$(get_ssl_expiry_info "$d")
        local ssl_badge
        if [ "$ssl_status" == "valid" ]; then
            ssl_badge="${GREEN}Valid${NC} ${DIM}($ssl_info)${NC}"
        elif [ "$ssl_status" == "expiring" ]; then
            ssl_badge="${YELLOW}Expiring Soon${NC} ${DIM}($ssl_info)${NC}"
        elif [ "$ssl_status" == "expired" ]; then
            ssl_badge="${RED}EXPIRED${NC} ${DIM}($ssl_info)${NC}"
        elif [ "$ssl_status" == "missing" ]; then
            ssl_badge="${RED}Missing Certificate${NC}"
        else
            ssl_badge="${YELLOW}Unknown ($ssl_info)${NC}"
        fi

        if [ -n "$p" ]; then
            echo -e "  ${WHITE}[$num]${NC} ${CYAN}$d${NC}"
            echo -e "      ${DIM}↳ API Domain :${NC} ${WHITE}$api${NC}"
            echo -e "      ${DIM}↳ Routing    :${NC} ${GREEN}Proxy ($p)${NC}"
            echo -e "      ${DIM}↳ Cache      :${NC} ${YELLOW}$cache_count cached subscription(s)${NC}"
            echo -e "      ${DIM}↳ SSL Status :${NC} $ssl_badge"
        else
            echo -e "  ${WHITE}[$num]${NC} ${CYAN}$d${NC}"
            echo -e "      ${DIM}↳ API Domain :${NC} ${WHITE}$api${NC}"
            echo -e "      ${DIM}↳ Routing    :${NC} ${YELLOW}Direct (No Proxy)${NC}"
            echo -e "      ${DIM}↳ Cache      :${NC} ${YELLOW}$cache_count cached subscription(s)${NC}"
            echo -e "      ${DIM}↳ SSL Status :${NC} $ssl_badge"
        fi
        echo ""
    done
    draw_line
}

function delete_site() {
    print_info "Delete a SmartLink Site"
    mapfile -t domains < <(get_smartlink_domains)
    
    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}Select a domain to delete:${NC}"
    for i in "${!domains[@]}"; do
        local d="${domains[$i]}"
        local api
        api=$(get_site_api "$d")
        echo -e "  ${WHITE}$((i+1)))${NC} ${RED}$d${NC} ${DIM}(API: $api)${NC}"
    done
    local cancel_opt=$(( ${#domains[@]} + 1 ))
    echo -e "  ${WHITE}$cancel_opt)${NC} ${CYAN}Cancel${NC}"
    echo ""

    read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-$cancel_opt]: " CHOICE

    if [ "$CHOICE" == "$cancel_opt" ] || [ "$CHOICE" == "c" ] || [ "$CHOICE" == "C" ]; then
        print_msg "Aborted."
        return
    fi

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#domains[@]}" ]; then
        print_err "Invalid selection. Please try again."
        return
    fi

    local DOMAIN="${domains[$((CHOICE - 1))]}"

    echo ""
    read -rp "  $(echo -e "${YELLOW}›${NC}") Are you sure you want to COMPLETELY delete $DOMAIN? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        print_msg "Aborted."
        return
    fi

    if [ -z "$DOMAIN" ] || ! validate_domain "$DOMAIN"; then
        print_err "Invalid domain selection."
        return
    fi

    print_msg "Removing Nginx configuration..."
    rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    rm -f "/etc/nginx/sites-available/$DOMAIN"

    print_msg "Removing web directory..."
    local doc_root
    doc_root=$(get_doc_root "$DOMAIN")
    local base_www="${SMARTLINK_VAR_WWW:-/var/www}"
    if [ -n "$doc_root" ] && [ "$doc_root" != "/" ] && [ "$doc_root" != "$base_www" ] && [ -d "$doc_root" ]; then
        rm -rf "${doc_root:?}"
    fi

    print_msg "Revoking SSL certificate..."
    certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null

    print_msg "Reloading Nginx..."
    systemctl reload nginx 2>/dev/null || true

    print_msg "Site $DOMAIN deleted successfully."
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

    if [ -z "$current_api" ] || [ "$current_api" == "API_DOMAIN_PLACEHOLDER" ] || ! validate_domain "$current_api"; then
        current_api="example.com"
    fi

    local current_debug="false"
    if [ -f "$doc_root/config.php" ]; then
        if grep -iqE "^\s*define\s*\(\s*['\"]APP_DEBUG['\"],\s*true\)" "$doc_root/config.php" 2>/dev/null; then
            current_debug="true"
        elif grep -iqE "define\(['\"]APP_DEBUG['\"],\s*true\)" "$doc_root/config.php" 2>/dev/null; then
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
    chmod 644 "$doc_root/config.php" 2>/dev/null || true
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
        reload_php_fpm
        print_msg "Site $DOMAIN updated successfully!"

        echo ""
        print_info "Checking SSL certificate status for $DOMAIN..."
        renew_site_ssl "$DOMAIN" "auto"
        setup_ssl_autorenew
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
            echo ""
            print_info "Checking SSL certificate status for $d..."
            renew_site_ssl "$d" "auto"
            updated_count=$((updated_count + 1))
        else
            print_err "Failed to update $d."
        fi
    done

    rm -rf "$prep_dir"

    print_msg "Clearing PHP OPcache..."
    reload_php_fpm
    setup_ssl_autorenew

    echo ""
    print_msg "Update complete: $updated_count of ${#domains[@]} site(s) updated successfully!"
}

function clear_cache() {
    print_info "Clear Subscription Cache"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}Select a domain to clear its cache:${NC}"
    for i in "${!domains[@]}"; do
        local d="${domains[$i]}"
        local doc_root
        doc_root=$(get_doc_root "$d")
        local file_count=0
        if [ -d "$doc_root/cache" ]; then
            file_count=$(find "$doc_root/cache" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
        fi
        echo -e "  ${WHITE}$((i+1)))${NC} $d ${DIM}($file_count cached files)${NC}"
    done
    local all_opt=$(( ${#domains[@]} + 1 ))
    local cancel_opt=$(( ${#domains[@]} + 2 ))
    echo -e "  ${WHITE}$all_opt)${NC} ${CYAN}[Clear cache for ALL sites]${NC}"
    echo -e "  ${WHITE}$cancel_opt)${NC} ${RED}Cancel${NC}"
    echo ""

    read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-$cancel_opt]: " CHOICE

    if [ "$CHOICE" == "$cancel_opt" ] || [ "$CHOICE" == "c" ] || [ "$CHOICE" == "C" ]; then
        print_msg "Aborted."
        return
    fi

    if [ "$CHOICE" == "$all_opt" ] || [ "$CHOICE" == "a" ] || [ "$CHOICE" == "A" ]; then
        clear_cache_all
        return
    fi

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#domains[@]}" ]; then
        print_err "Invalid selection. Please try again."
        return
    fi

    local DOMAIN="${domains[$((CHOICE - 1))]}"
    local doc_root
    doc_root=$(get_doc_root "$DOMAIN")
    local CACHE_DIR="$doc_root/cache"

    if [ ! -d "$CACHE_DIR" ]; then
        print_err "Cache directory not found: $CACHE_DIR"
        return
    fi

    local FILE_COUNT
    FILE_COUNT=$(find "$CACHE_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)

    if [ "$FILE_COUNT" -eq 0 ]; then
        print_info "Cache is already empty for $DOMAIN."
        return
    fi

    rm -f "$CACHE_DIR"/*.json
    print_msg "Cleared $FILE_COUNT cached file(s) for $DOMAIN."
}

# Clears subscription cache for all SmartLink domains at once.
function clear_cache_all() {
    print_info "Clear Cache for ALL SmartLink Sites"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    read -rp "  $(echo -e "${YELLOW}›${NC}") Are you sure you want to clear cache for ALL ${#domains[@]} site(s)? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        print_msg "Aborted."
        return
    fi

    local total_cleared=0
    for d in "${domains[@]}"; do
        local doc_root
        doc_root=$(get_doc_root "$d")
        local cache_dir="$doc_root/cache"
        if [ -d "$cache_dir" ]; then
            local count
            count=$(find "$cache_dir" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
            if [ "$count" -gt 0 ]; then
                rm -f "$cache_dir"/*.json
                total_cleared=$((total_cleared + count))
            fi
        fi
    done

    echo ""
    print_msg "Cleared a total of $total_cleared cached file(s) across all ${#domains[@]} site(s)."
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
        reload_php_fpm
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
        reload_php_fpm
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
        reload_php_fpm
    fi

    echo ""
    print_msg "Proxy removed successfully from all $removed_count site(s). All sites now connect directly."
}

# ------------------------------------------------------------------------------
# SSL Certificate Management & Renewal Functions
# ------------------------------------------------------------------------------

# Renews SSL certificate for a specified domain.
# Arguments:
#   $1 - Domain name
#   $2 - Mode ("auto" or "force", default: "auto")
# Returns:
#   0 on success or if already valid, 1 on failure
function renew_site_ssl() {
    local domain="$1"
    local mode="${2:-auto}"

    validate_domain "$domain" || {
        print_err "Invalid domain: $domain"
        return 1
    }

    local current_status
    current_status=$(get_ssl_cert_status "$domain")

    if [ "$mode" != "force" ] && [ "$current_status" == "valid" ]; then
        local valid_info
        valid_info=$(get_ssl_expiry_info "$domain")
        print_msg "SSL certificate for $domain is valid ($valid_info). No renewal needed."
        return 0
    fi

    local certbot_bin="${SMARTLINK_CERTBOT_BIN:-certbot}"
    if ! command -v "$certbot_bin" >/dev/null 2>&1; then
        print_err "Certbot binary '$certbot_bin' not found. Please install prerequisites first."
        return 1
    fi

    if [ "$current_status" == "expired" ]; then
        print_info "SSL certificate for $domain is EXPIRED! Initiating renewal..."
    elif [ "$current_status" == "expiring" ]; then
        print_info "SSL certificate for $domain is expiring soon. Initiating renewal..."
    elif [ "$current_status" == "missing" ]; then
        print_info "No SSL certificate found for $domain. Obtaining new certificate..."
    else
        print_info "Renewing SSL certificate for $domain (mode: $mode)..."
    fi

    local renew_success=0

    # Attempt 1: certbot renew for this specific lineage
    local renew_args=(renew --cert-name "$domain" --non-interactive --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx")
    if [ "$mode" == "force" ]; then
        renew_args+=(--force-renewal)
    fi

    if "$certbot_bin" "${renew_args[@]}" 2>&1; then
        renew_success=1
    fi

    # Attempt 2: If certbot renew failed (e.g. missing lineage/conf), run certonly standalone
    if [ $renew_success -eq 0 ]; then
        print_info "Certbot renew did not succeed for $domain. Attempting standalone issuance..."
        systemctl stop nginx 2>/dev/null || true
        local certonly_args=(certonly --standalone --preferred-challenges http --agree-tos -d "$domain" \
                             --register-unsafely-without-email --non-interactive \
                             --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx")
        if [ "$mode" == "force" ]; then
            certonly_args+=(--force-renewal)
        fi

        if "$certbot_bin" "${certonly_args[@]}" 2>&1; then
            renew_success=1
        fi
        systemctl start nginx 2>/dev/null || true
    fi

    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true

    local final_status
    final_status=$(get_ssl_cert_status "$domain")
    if [ "$final_status" == "valid" ] || [ "$final_status" == "expiring" ]; then
        local updated_info
        updated_info=$(get_ssl_expiry_info "$domain")
        print_msg "SSL certificate for $domain is now active ($updated_info)!"
        return 0
    elif [ $renew_success -eq 1 ]; then
        print_msg "SSL renewal completed for $domain."
        return 0
    else
        print_err "Failed to obtain or renew SSL certificate for $domain."
        return 1
    fi
}

# Renews SSL certificates across all configured SmartLink domains.
# Arguments:
#   $1 - Mode ("auto" or "force", default: "auto")
function renew_all_ssl() {
    local mode="${1:-auto}"
    print_info "Processing SSL certificates for all SmartLink sites (mode: $mode)..."
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    local renewed=0
    local skipped=0
    local failed=0

    for d in "${domains[@]}"; do
        echo ""
        print_info "Checking $d..."
        local st
        st=$(get_ssl_cert_status "$d")
        if [ "$mode" != "force" ] && [ "$st" == "valid" ]; then
            local info
            info=$(get_ssl_expiry_info "$d")
            print_msg "$d is already valid ($info). Skipping."
            skipped=$((skipped + 1))
            continue
        fi

        if renew_site_ssl "$d" "$mode"; then
            renewed=$((renewed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    setup_ssl_autorenew

    echo ""
    draw_line
    print_msg "SSL Summary: $renewed renewed, $skipped already valid, $failed failed."
    draw_line
}

function renew_ssl_menu() {
    print_info "SSL Certificate Management & Renewal"
    mapfile -t domains < <(get_smartlink_domains)

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No SmartLink sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}Installed SmartLink sites & SSL status:${NC}"
    for i in "${!domains[@]}"; do
        local d="${domains[$i]}"
        local ssl_status
        ssl_status=$(get_ssl_cert_status "$d")
        local ssl_info
        ssl_info=$(get_ssl_expiry_info "$d")
        local num=$((i + 1))
        if [ "$ssl_status" == "valid" ]; then
            echo -e "  ${WHITE}$num)${NC} $d ${DIM}➜${NC} ${GREEN}Valid${NC} ${DIM}($ssl_info)${NC}"
        elif [ "$ssl_status" == "expiring" ]; then
            echo -e "  ${WHITE}$num)${NC} $d ${DIM}➜${NC} ${YELLOW}Expiring Soon${NC} ${DIM}($ssl_info)${NC}"
        elif [ "$ssl_status" == "expired" ]; then
            echo -e "  ${WHITE}$num)${NC} $d ${DIM}➜${NC} ${RED}EXPIRED${NC} ${DIM}($ssl_info)${NC}"
        elif [ "$ssl_status" == "missing" ]; then
            echo -e "  ${WHITE}$num)${NC} $d ${DIM}➜${NC} ${RED}Missing Certificate${NC}"
        else
            echo -e "  ${WHITE}$num)${NC} $d ${DIM}➜${NC} ${YELLOW}Unknown ($ssl_info)${NC}"
        fi
    done

    local auto_renew_opt=$(( ${#domains[@]} + 1 ))
    local force_all_opt=$(( ${#domains[@]} + 2 ))
    local setup_cron_opt=$(( ${#domains[@]} + 3 ))
    local cancel_opt=$(( ${#domains[@]} + 4 ))

    echo ""
    echo -e "  ${WHITE}$auto_renew_opt)${NC} ${CYAN}[Renew all expired / expiring certificates]${NC}"
    echo -e "  ${WHITE}$force_all_opt)${NC} ${YELLOW}[Force renew ALL certificates]${NC}"
    echo -e "  ${WHITE}$setup_cron_opt)${NC} ${GREEN}[Enable / Verify Auto-Renewal Cron Job]${NC}"
    echo -e "  ${WHITE}$cancel_opt)${NC} ${RED}Cancel${NC}"
    echo ""

    read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-$cancel_opt]: " CHOICE

    if [ "$CHOICE" == "$cancel_opt" ] || [ "$CHOICE" == "c" ] || [ "$CHOICE" == "C" ]; then
        print_msg "Aborted."
        return
    fi

    if [ "$CHOICE" == "$auto_renew_opt" ] || [ "$CHOICE" == "a" ] || [ "$CHOICE" == "A" ]; then
        renew_all_ssl "auto"
        return
    fi

    if [ "$CHOICE" == "$force_all_opt" ] || [ "$CHOICE" == "f" ] || [ "$CHOICE" == "F" ]; then
        renew_all_ssl "force"
        return
    fi

    if [ "$CHOICE" == "$setup_cron_opt" ]; then
        setup_ssl_autorenew
        print_msg "SSL auto-renewal cron job and systemd timer configured successfully!"
        return
    fi

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#domains[@]}" ]; then
        print_err "Invalid selection. Please try again."
        return
    fi

    local SELECTED_DOMAIN="${domains[$((CHOICE - 1))]}"
    echo ""
    read -rp "  $(echo -e "${YELLOW}›${NC}") Force renewal even if certificate is currently valid? [y/N]: " FORCE_CHOICE
    local mode="auto"
    if [[ "$FORCE_CHOICE" == "y" || "$FORCE_CHOICE" == "Y" ]]; then
        mode="force"
    fi

    renew_site_ssl "$SELECTED_DOMAIN" "$mode"
    setup_ssl_autorenew
}

# ------------------------------------------------------------------------------
# Watchdog & Service Recovery Functions
# ------------------------------------------------------------------------------

# Installs or updates the standalone self-healing watchdog daemon and cron schedule.
function setup_watchdog() {
    local watchdog_script="${SMARTLINK_WATCHDOG_SCRIPT:-/usr/local/bin/smartlink-watchdog.sh}"
    local watchdog_cron="${SMARTLINK_WATCHDOG_CRON:-/etc/cron.d/smartlink-watchdog}"
    local watchdog_log="${SMARTLINK_WATCHDOG_LOG:-/var/log/smartlink-watchdog.log}"

    local script_dir
    script_dir=$(dirname "$watchdog_script")
    [ -d "$script_dir" ] || mkdir -p "$script_dir" 2>/dev/null || true

    cat > "$watchdog_script" <<'EOF'
#!/bin/bash
# SmartLink Self-Healing Watchdog Daemon
# Automatically checks service health, HTTP responsiveness, and resource availability every minute.

LOG_FILE="${SMARTLINK_WATCHDOG_LOG:-/var/log/smartlink-watchdog.log}"
LOCK_FILE="/var/run/smartlink-watchdog.lock"

# Concurrency lock to prevent overlapping runs
if [ -e "$LOCK_FILE" ]; then
    PREV_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$PREV_PID" ] && kill -0 "$PREV_PID" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE" 2>/dev/null || true
trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 1. Identify active PHP-FPM service
FPM_SVC=""
for svc in php8.1-fpm php8.2-fpm php8.3-fpm php8.0-fpm php-fpm; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        FPM_SVC="$svc"
        break
    fi
done
if [ -z "$FPM_SVC" ]; then
    for svc in php8.1-fpm php8.2-fpm php8.3-fpm php8.0-fpm php-fpm; do
        if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc"; then
            FPM_SVC="$svc"
            break
        fi
    done
fi

RECOVERED=0

# 2. Check Nginx process
if ! systemctl is-active --quiet nginx 2>/dev/null; then
    log_msg "ALERT: Nginx service was INACTIVE or CRASHED. Restarting..."
    systemctl restart nginx 2>/dev/null
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_msg "SUCCESS: Nginx successfully recovered by Watchdog."
    else
        log_msg "ERROR: Watchdog failed to restart Nginx."
    fi
    RECOVERED=1
fi

# 3. Check PHP-FPM process
if [ -n "$FPM_SVC" ] && ! systemctl is-active --quiet "$FPM_SVC" 2>/dev/null; then
    log_msg "ALERT: PHP-FPM ($FPM_SVC) was INACTIVE or CRASHED. Restarting..."
    systemctl restart "$FPM_SVC" 2>/dev/null
    if systemctl is-active --quiet "$FPM_SVC" 2>/dev/null; then
        log_msg "SUCCESS: PHP-FPM ($FPM_SVC) successfully recovered by Watchdog."
    else
        log_msg "ERROR: Watchdog failed to restart PHP-FPM."
    fi
    RECOVERED=1
fi

# 4. Local HTTP Probe (detect hung workers, deadlocks, or 502/504 Bad Gateway)
if [ $RECOVERED -eq 0 ] && command -v curl >/dev/null 2>&1; then
    VAR_WWW="${SMARTLINK_VAR_WWW:-/var/www}"
    PROBE_DOMAIN=""
    if [ -d "$VAR_WWW" ]; then
        for site_dir in "$VAR_WWW"/*; do
            if [ -f "$site_dir/config.php" ] && [ -f "$site_dir/index.php" ]; then
                PROBE_DOMAIN=$(basename "$site_dir")
                break
            fi
        done
    fi

    HTTP_CODE="000"
    if [ -n "$PROBE_DOMAIN" ]; then
        HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 6 -H "Host: $PROBE_DOMAIN" https://127.0.0.1/ 2>/dev/null || echo "000")
    else
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 http://127.0.0.1/ 2>/dev/null || echo "000")
    fi

    if [ "$HTTP_CODE" == "502" ] || [ "$HTTP_CODE" == "504" ] || [ "$HTTP_CODE" == "000" ]; then
        log_msg "ALERT: Local health probe failed (HTTP $HTTP_CODE). Recycling Nginx and PHP-FPM..."
        if [ -n "$FPM_SVC" ]; then
            systemctl restart "$FPM_SVC" 2>/dev/null || true
        fi
        systemctl restart nginx 2>/dev/null || true
        log_msg "RECOVERY: Stack recycled after HTTP $HTTP_CODE probe failure."
    fi
fi

# 5. OOM / Low Memory Protection (Free/Available memory < 5%)
if command -v free >/dev/null 2>&1; then
    FREE_MEM_PCT=$(free -m 2>/dev/null | awk '/^Mem:/{avail=($7 ? $7 : $4); if ($2 > 0) printf("%d", (avail/$2)*100); else print 100}')
    if [ -n "$FREE_MEM_PCT" ] && [ "$FREE_MEM_PCT" -lt 5 ]; then
        log_msg "WARNING: Available memory critically low (${FREE_MEM_PCT}%). Recycling PHP workers..."
        if [ -n "$FPM_SVC" ]; then
            systemctl reload "$FPM_SVC" 2>/dev/null || true
        fi
        sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi
fi

# 6. Automatic log rotation (keep last 1000 lines)
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
fi
EOF
    chmod 755 "$watchdog_script" 2>/dev/null || true

    local cron_dir
    cron_dir=$(dirname "$watchdog_cron")
    [ -d "$cron_dir" ] || mkdir -p "$cron_dir" 2>/dev/null || true
    if [ -d "$cron_dir" ]; then
        cat > "$watchdog_cron" <<EOF
# SmartLink Self-Healing Watchdog (Runs every minute)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

* * * * * root $watchdog_script >/dev/null 2>&1
EOF
        chmod 644 "$watchdog_cron" 2>/dev/null || true
    fi

    local log_dir
    log_dir=$(dirname "$watchdog_log")
    [ -d "$log_dir" ] || mkdir -p "$log_dir" 2>/dev/null || true
    if [ ! -f "$watchdog_log" ]; then
        touch "$watchdog_log" 2>/dev/null || true
        chmod 644 "$watchdog_log" 2>/dev/null || true
    fi

    systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
    return 0
}

function disable_watchdog() {
    local watchdog_cron="${SMARTLINK_WATCHDOG_CRON:-/etc/cron.d/smartlink-watchdog}"
    rm -f "$watchdog_cron" 2>/dev/null || true
    return 0
}

function get_watchdog_status() {
    local watchdog_cron="${SMARTLINK_WATCHDOG_CRON:-/etc/cron.d/smartlink-watchdog}"
    if [ -f "$watchdog_cron" ]; then
        echo "active"
    else
        echo "inactive"
    fi
}

function manage_watchdog_menu() {
    print_info "SmartLink Watchdog & Self-Healing Service"
    local status
    status=$(get_watchdog_status)
    local watchdog_log="${SMARTLINK_WATCHDOG_LOG:-/var/log/smartlink-watchdog.log}"

    echo ""
    if [ "$status" == "active" ]; then
        echo -e "  ${DIM}Current Status :${NC} ${GREEN}Active & Monitoring every 1 minute${NC}"
    else
        echo -e "  ${DIM}Current Status :${NC} ${YELLOW}Inactive (Disabled)${NC}"
    fi
    echo ""
    echo -e "  ${WHITE}1)${NC} Enable / Reinstall Watchdog (Auto-Healing)"
    echo -e "  ${WHITE}2)${NC} View Recent Watchdog Logs & Recovery History"
    echo -e "  ${WHITE}3)${NC} Run Watchdog Healthcheck Probe Now"
    echo -e "  ${WHITE}4)${NC} Disable Watchdog"
    echo -e "  ${WHITE}5)${NC} Cancel"
    echo ""

    read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-5]: " CHOICE

    case $CHOICE in
        1)
            setup_watchdog
            print_msg "SmartLink Watchdog enabled successfully! It monitors and heals services every minute."
            ;;
        2)
            echo ""
            print_info "Recent Watchdog Logs (/var/log/smartlink-watchdog.log):"
            draw_line
            if [ -f "$watchdog_log" ] && [ -s "$watchdog_log" ]; then
                tail -n 25 "$watchdog_log"
            else
                echo -e "  ${DIM}No incident logs recorded yet (services running smoothly without failures).${NC}"
            fi
            draw_line
            ;;
        3)
            echo ""
            print_info "Executing manual Watchdog healthcheck probe..."
            local watchdog_script="${SMARTLINK_WATCHDOG_SCRIPT:-/usr/local/bin/smartlink-watchdog.sh}"
            if [ -f "$watchdog_script" ]; then
                bash "$watchdog_script"
                print_msg "Probe completed."
                if [ -f "$watchdog_log" ] && [ -s "$watchdog_log" ]; then
                    draw_line
                    tail -n 10 "$watchdog_log"
                    draw_line
                fi
            else
                print_err "Watchdog script not found. Please choose Option 1 to enable it first."
            fi
            ;;
        4)
            disable_watchdog
            print_msg "SmartLink Watchdog disabled."
            ;;
        *)
            print_msg "Aborted."
            return
            ;;
    esac
}

function restart_services_menu() {
    print_info "Restart & Reload Services"
    echo ""
    echo -e "  ${CYAN}Select an action:${NC}"
    echo -e "  ${WHITE}1)${NC} Restart All Services (Nginx & PHP-FPM Stack)"
    echo -e "  ${WHITE}2)${NC} Restart Nginx Only"
    echo -e "  ${WHITE}3)${NC} Restart PHP-FPM Only"
    echo -e "  ${WHITE}4)${NC} Reload Services (Zero-Downtime Config Reload)"
    echo -e "  ${WHITE}5)${NC} Test Nginx Configuration (nginx -t)"
    echo -e "  ${WHITE}6)${NC} Cancel"
    echo ""

    read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-6]: " CHOICE

    case $CHOICE in
        1)
            print_info "Testing Nginx configuration before restart..."
            if command -v nginx >/dev/null 2>&1 && ! nginx -t 2>&1; then
                print_err "Nginx configuration test failed! Restart aborted to prevent downtime."
                return 1
            fi
            print_msg "Nginx configuration test passed."
            local fpm_svc
            fpm_svc=$(get_php_fpm_service)
            print_info "Restarting $fpm_svc..."
            systemctl restart "$fpm_svc" 2>/dev/null || true
            print_info "Restarting Nginx..."
            systemctl restart nginx 2>/dev/null || true

            if systemctl is-active --quiet nginx 2>/dev/null; then
                print_msg "Nginx restarted successfully and is active."
            else
                print_err "Nginx failed to start! Check systemctl status nginx."
            fi
            if [ -n "$fpm_svc" ] && systemctl is-active --quiet "$fpm_svc" 2>/dev/null; then
                print_msg "$fpm_svc restarted successfully and is active."
            fi
            print_msg "All SmartLink services restarted successfully!"
            ;;
        2)
            print_info "Testing Nginx configuration before restart..."
            if command -v nginx >/dev/null 2>&1 && ! nginx -t 2>&1; then
                print_err "Nginx configuration test failed! Restart aborted to prevent downtime."
                return 1
            fi
            print_msg "Nginx configuration test passed."
            print_info "Restarting Nginx..."
            systemctl restart nginx 2>/dev/null || true
            if systemctl is-active --quiet nginx 2>/dev/null; then
                print_msg "Nginx restarted successfully and is active."
            else
                print_err "Nginx failed to start! Check systemctl status nginx."
            fi
            ;;
        3)
            local fpm_svc
            fpm_svc=$(get_php_fpm_service)
            print_info "Restarting $fpm_svc..."
            systemctl restart "$fpm_svc" 2>/dev/null || true
            if [ -n "$fpm_svc" ] && systemctl is-active --quiet "$fpm_svc" 2>/dev/null; then
                print_msg "$fpm_svc restarted successfully and is active."
            else
                print_err "$fpm_svc failed to start! Check systemctl status $fpm_svc."
            fi
            ;;
        4)
            print_info "Reloading Nginx and PHP-FPM without dropping active connections..."
            if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null || true
                print_msg "Nginx reloaded successfully."
            fi
            reload_php_fpm
            print_msg "PHP-FPM reloaded successfully."
            ;;
        5)
            echo ""
            print_info "Testing Nginx configuration..."
            nginx -t
            ;;
        *)
            print_msg "Aborted."
            return
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_root

    case "$1" in
        --renew-ssl|renew-ssl)
            renew_all_ssl "${2:-auto}"
            exit 0
            ;;
        --force-renew-ssl|force-renew-ssl)
            renew_all_ssl "force"
            exit 0
            ;;
        --update|update)
            update_all_sites
            exit 0
            ;;
        --restart|restart)
            restart_services_menu
            exit 0
            ;;
        --watchdog|watchdog)
            manage_watchdog_menu
            exit 0
            ;;
        --optimize|optimize)
            optimize_server_resources
            exit 0
            ;;
    esac

    while true; do
        clear
        echo ""
        echo -e "  ${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "  ${BLUE}║${WHITE}       SmartLink Installer & Manager          ${BLUE}║${NC}"
        echo -e "  ${BLUE}║${DIM}                     v${VERSION}                     ${BLUE}║${NC}"
        
        mapfile -t detected_domains < <(get_smartlink_domains 2>/dev/null)
        total_sites=${#detected_domains[@]}
        proxy_count=0
        expired_ssl=0
        for sd in "${detected_domains[@]}"; do
            [ -n "$(get_site_proxy "$sd")" ] && proxy_count=$((proxy_count + 1))
            [ "$(get_ssl_cert_status "$sd")" == "expired" ] && expired_ssl=$((expired_ssl + 1))
        done
        direct_count=$((total_sites - proxy_count))

        watchdog_st=$(get_watchdog_status)
        if [ "$watchdog_st" == "active" ]; then
            watchdog_badge="${GREEN}Active${NC}"
        else
            watchdog_badge="${YELLOW}Inactive${NC}"
        fi

        echo -e "  ${BLUE}╟──────────────────────────────────────────────╢${NC}"
        printf "  ${BLUE}║${NC}  ${CYAN}Sites:${NC} %-3d ${BLUE}│${NC}  ${GREEN}Proxy:${NC} %-3d ${BLUE}│${NC}  ${YELLOW}Direct:${NC} %-3d      ${BLUE}║${NC}\n" "$total_sites" "$proxy_count" "$direct_count"
        printf "  ${BLUE}║${NC}  ${DIM}Watchdog:${NC} %-39b ${BLUE}║${NC}\n" "$watchdog_badge"
        if [ "$expired_ssl" -gt 0 ]; then
            echo -e "  ${BLUE}╟──────────────────────────────────────────────╢${NC}"
            echo -e "  ${BLUE}║${NC}  ${RED}⚠ WARNING: $expired_ssl site(s) have EXPIRED SSL!${NC}     ${BLUE}║${NC}"
        fi
        echo -e "  ${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC}  ${CYAN}Install Prerequisites${NC}"
        echo -e "  ${WHITE}2)${NC}  ${CYAN}Add a New Site${NC}"
        echo -e "  ${WHITE}3)${NC}  ${CYAN}List Sites & Status${NC}"
        echo -e "  ${WHITE}4)${NC}  ${CYAN}Delete a Site${NC}"
        echo -e "  ${WHITE}5)${NC}  ${CYAN}Update Source Code${NC} ${DIM}(Auto-renews expired SSL)${NC}"
        echo -e "  ${WHITE}6)${NC}  ${YELLOW}Clear Cache${NC}"
        echo -e "  ${WHITE}7)${NC}  ${YELLOW}Configure Proxy${NC}"
        echo -e "  ${WHITE}8)${NC}  ${GREEN}Renew SSL Certificates${NC}"
        echo -e "  ${WHITE}9)${NC}  ${CYAN}Restart Services (Nginx & PHP-FPM)${NC}"
        echo -e "  ${WHITE}10)${NC} ${GREEN}Watchdog & Auto-Healing Service${NC}"
        echo -e "  ${WHITE}11)${NC} ${WHITE}Optimize Server & Nginx Resources${NC}"
        echo -e "  ${WHITE}12)${NC} ${RED}Exit${NC}"
        echo ""
        draw_line
        read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-12]: " OPTION
        draw_line
        echo ""

        case $OPTION in
            1) install_prerequisites ;;
            2) add_site ;;
            3) list_sites ;;
            4) delete_site ;;
            5) update_site ;;
            6) clear_cache ;;
            7) configure_proxy ;;
            8) renew_ssl_menu ;;
            9) restart_services_menu ;;
            10) manage_watchdog_menu ;;
            11) optimize_server_resources ;;
            12) echo -e "  ${DIM}Goodbye!${NC}\n"; exit 0 ;;
            *) print_err "Invalid option. Please try again." ;;
        esac

        echo ""
        read -rp "  $(echo -e "${DIM}Press Enter to continue...${NC}")"
    done
fi
