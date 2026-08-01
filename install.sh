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

VERSION="2.7"

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
    if [ -z "$DOMAIN" ]; then
        print_err "Domain cannot be empty."
        return
    fi

    read -p "Enter API Domain Name (e.g., api.example.com): " API_DOMAIN
    if [ -z "$API_DOMAIN" ]; then
        print_err "API Domain cannot be empty."
        return
    fi

    DOC_ROOT="/var/www/$DOMAIN"

    if [ -d "$DOC_ROOT" ]; then
        print_err "Directory $DOC_ROOT already exists."
        return
    fi

    print_msg "Cloning project from GitHub..."
    git clone https://github.com/PouryaDe/SmartIR.git $DOC_ROOT
    chown -R www-data:www-data $DOC_ROOT

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
    systemctl stop nginx
    certbot certonly --standalone --preferred-challenges http --agree-tos -d $DOMAIN --register-unsafely-without-email
    systemctl start nginx

    print_msg "Creating Nginx configuration..."
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    
    cat > $NGINX_CONF <<EOF
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
    
    location ~* ^/(functions\.php|Route\.php|subscription-link\.php|config\.php|cache|error\.log) {
        deny all;
    }
    
}
EOF

    ln -s $NGINX_CONF /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    print_msg "Testing Nginx configuration and reloading..."
    nginx -t && systemctl reload nginx

    print_msg "Site $DOMAIN added successfully! API Domain is set to $API_DOMAIN."
}

function list_sites() {
    print_msg "Currently enabled sites:"
    ls -1 /etc/nginx/sites-enabled/ | grep -v "default" || echo "No sites found."
}

function delete_site() {
    print_msg "Currently installed sites:"
    mapfile -t domains < <(ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "default")
    
    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No sites found."
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

    print_msg "Removing Nginx configuration..."
    rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    rm -f "/etc/nginx/sites-available/$DOMAIN"

    print_msg "Removing web directory..."
    rm -rf "/var/www/$DOMAIN"

    print_msg "Revoking SSL certificate..."
    certbot delete --cert-name "$DOMAIN" --non-interactive

    print_msg "Reloading Nginx..."
    systemctl reload nginx

    print_msg "Site $DOMAIN deleted successfully."
}

function update_site() {
    print_msg "Currently installed sites:"
    mapfile -t domains < <(ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "default")
    
    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No sites found."
        return
    fi

    echo "Select a Domain to update:"
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

    DOC_ROOT="/var/www/$DOMAIN"

    if [ ! -d "$DOC_ROOT" ]; then
        print_err "Directory $DOC_ROOT does not exist. Are you sure the site is installed?"
        return
    fi

    print_msg "Extracting current API Domain..."
    if [ -f "$DOC_ROOT/config.php" ]; then
        CURRENT_API=$(grep "define('API_DOMAIN'" "$DOC_ROOT/config.php" | awk -F"'" '{print $4}')
    else
        CURRENT_API=$(grep "define('API_DOMAIN'" "$DOC_ROOT/index.php" | awk -F"'" '{print $4}' 2>/dev/null)
    fi

    if [ -z "$CURRENT_API" ] || [ "$CURRENT_API" == "API_DOMAIN_PLACEHOLDER" ]; then
        read -p "Could not detect API Domain. Please enter API Domain Name manually: " CURRENT_API
    fi

    print_msg "Updating source code from GitHub..."
    cd /var/www || return
    rm -rf "$DOC_ROOT"
    git clone https://github.com/PouryaDe/SmartIR.git "$DOC_ROOT"
    chown -R www-data:www-data "$DOC_ROOT"

    print_msg "Restoring configuration..."
    CURRENT_PROXY=$(grep "define('PROXY_URL'" "$DOC_ROOT/config.php" 2>/dev/null | awk -F"'" '{print $4}')
    cat > "$DOC_ROOT/config.php" <<EOF
<?php
define('API_DOMAIN', '$CURRENT_API');
define('APP_DEBUG', false);
define('PROXY_URL', '${CURRENT_PROXY}');
EOF
    chown www-data:www-data "$DOC_ROOT/config.php"

    mkdir -p "$DOC_ROOT/cache"
    chown www-data:www-data "$DOC_ROOT/cache"

    print_msg "Clearing PHP OPcache..."
    systemctl reload php8.1-fpm

    print_msg "Site $DOMAIN updated successfully!"
}

function clear_cache() {
    print_info "Currently installed sites:"
    mapfile -t domains < <(ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "default")

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No sites found."
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

    CACHE_DIR="/var/www/$DOMAIN/cache"

    if [ ! -d "$CACHE_DIR" ]; then
        print_err "Cache directory not found: $CACHE_DIR"
        return
    fi

    FILE_COUNT=$(find "$CACHE_DIR" -name '*.json' | wc -l)

    if [ "$FILE_COUNT" -eq 0 ]; then
        print_info "Cache is already empty for $DOMAIN."
        return
    fi

    rm -f "$CACHE_DIR"/*.json
    print_msg "Cleared $FILE_COUNT cached file(s) for $DOMAIN."
}

function configure_proxy() {
    print_info "Currently installed sites:"
    mapfile -t domains < <(ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "default")

    if [ ${#domains[@]} -eq 0 ]; then
        print_err "No sites found."
        return
    fi

    echo ""
    echo -e "  ${CYAN}Select a domain to configure its proxy:${NC}"
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

    CONFIG_FILE="/var/www/$DOMAIN/config.php"

    if [ ! -f "$CONFIG_FILE" ]; then
        print_err "config.php not found for $DOMAIN."
        return
    fi

    CURRENT_PROXY=$(grep "define('PROXY_URL'" "$CONFIG_FILE" | awk -F"'" '{print $4}')
    if [ -n "$CURRENT_PROXY" ]; then
        print_info "Current proxy: $CURRENT_PROXY"
    else
        print_info "No proxy currently configured."
    fi

    echo ""
    echo -e "  ${DIM}Format: socks5://USERNAME:PASSWORD@PROXY_IP:PORT${NC}"
    echo -e "  ${DIM}Leave empty to remove proxy.${NC}"
    read -rp "  $(echo -e "${YELLOW}›${NC}") Enter proxy URL: " NEW_PROXY

    CURRENT_API=$(grep "define('API_DOMAIN'" "$CONFIG_FILE" | awk -F"'" '{print $4}')

    cat > "$CONFIG_FILE" <<EOF
<?php
define('API_DOMAIN', '$CURRENT_API');
define('APP_DEBUG', false);
define('PROXY_URL', '$NEW_PROXY');
EOF
    chown www-data:www-data "$CONFIG_FILE"

    if [ -z "$NEW_PROXY" ]; then
        print_msg "Proxy removed for $DOMAIN."
    else
        print_msg "Proxy configured for $DOMAIN: $NEW_PROXY"
    fi
}

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
    echo -e "  ${WHITE}3)${NC}  ${CYAN}List Sites${NC}"
    echo -e "  ${WHITE}4)${NC}  ${CYAN}Delete a Site${NC}"
    echo -e "  ${WHITE}5)${NC}  ${CYAN}Update Source Code${NC}"
    echo -e "  ${WHITE}6)${NC}  ${YELLOW}Clear Cache${NC}"
    echo -e "  ${WHITE}7)${NC}  ${YELLOW}Configure Proxy${NC}"
    echo -e "  ${WHITE}8)${NC}  ${RED}Exit${NC}"
    echo ""
    draw_line
    read -rp "  $(echo -e "${YELLOW}›${NC}") Select an option [1-8]: " OPTION
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
        8) echo -e "  ${DIM}Goodbye!${NC}\n"; exit 0 ;;
        *) print_err "Invalid option. Please try again." ;;
    esac

    echo ""
    read -rp "  $(echo -e "${DIM}Press Enter to continue...${NC}")"
done
