#!/usr/bin/env bash

set -euo pipefail

DEFAULT_GLPI_VERSION="11.0.8"
DEFAULT_PHP_VERSION="8.2"
DEFAULT_DB_NAME="glpi"
DEFAULT_DB_USER="glpi"
DEFAULT_INSTALL_PATH="/var/www/glpi"
DEFAULT_SERVER_NAME=""

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/glpi-install.log"
CREDENTIALS_FILE="/root/glpi-install-credentials.txt"

OS_NAME=""
OS_VERSION=""
OS_ID=""
OS_ID_LIKE=""
OS_FAMILY="unknown"
OS_CODENAME=""

PHP_REPO="none"
PHP_REPO_LABEL="distribution repositories only"
PHP_REPO_PRESENT="n"
USE_PHP_REPO="n"

GLPI_VERSION=""
PHP_VERSION=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
INSTALL_PATH=""
SERVER_NAME=""
RUN_SECURE_DB_HARDENING="y"

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

section() {
    echo
    log "============================================================"
    log "-- $1 --"
    log "============================================================"
}

fail() {
    log "ERROR: $1"
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "This script must be executed as root."
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        fail "Cannot detect operating system. /etc/os-release was not found."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_NAME="${PRETTY_NAME:-Unknown Linux}"
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"

    if ! command -v apt-get >/dev/null 2>&1; then
        fail "This installer currently supports only APT-based systems."
    fi

    # Ubuntu must be tested first because Ubuntu itself reports ID_LIKE=debian.
    if [[ "$OS_ID" == "ubuntu" || " ${OS_ID_LIKE} " == *" ubuntu "* ]]; then
        OS_FAMILY="ubuntu"
        OS_CODENAME="${UBUNTU_CODENAME:-$OS_CODENAME}"
    elif [[ "$OS_ID" == "debian" || " ${OS_ID_LIKE} " == *" debian "* ]]; then
        OS_FAMILY="debian"
    else
        OS_FAMILY="unknown"
    fi

    if [[ -z "$OS_CODENAME" ]] && command -v lsb_release >/dev/null 2>&1; then
        OS_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
    fi
}

php_repository_configured() {
    local pattern=""

    case "$PHP_REPO" in
        ondrej)
            pattern="ondrej"
            ;;
        sury)
            pattern="packages.sury.org"
            ;;
        *)
            return 1
            ;;
    esac

    # Only inspect the files APT actually reads, so a disabled or backed up
    # repository file is not mistaken for a configured repository.
    local files=()
    local file=""

    if [[ -f /etc/apt/sources.list ]]; then
        files+=(/etc/apt/sources.list)
    fi

    if [[ -d /etc/apt/sources.list.d ]]; then
        while IFS= read -r file; do
            files+=("$file")
        done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \
            \( -name '*.list' -o -name '*.sources' \) 2>/dev/null)
    fi

    if [[ "${#files[@]}" -eq 0 ]]; then
        return 1
    fi

    grep -IqsE "^[^#]*${pattern}" "${files[@]}"
}

detect_php_repository() {
    case "$OS_FAMILY" in
        ubuntu)
            PHP_REPO="ondrej"
            PHP_REPO_LABEL="ondrej/php PPA"
            ;;
        debian)
            PHP_REPO="sury"
            PHP_REPO_LABEL="Sury (packages.sury.org/php)"
            ;;
        *)
            PHP_REPO="none"
            PHP_REPO_LABEL="distribution repositories only"
            ;;
    esac

    if php_repository_configured; then
        PHP_REPO_PRESENT="y"
    else
        PHP_REPO_PRESENT="n"
    fi
}

generate_password() {
    openssl rand -hex 18
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value=""

    read -r -p "$prompt [$default]: " value
    echo "${value:-$default}"
}

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local value=""

    while true; do
        read -r -p "$prompt [$default]: " value
        value="${value:-$default}"

        case "$value" in
            y|Y|yes|YES|Yes)
                echo "y"
                return
                ;;
            n|N|no|NO|No)
                echo "n"
                return
                ;;
            *)
                echo "Please answer y or n."
                ;;
        esac
    done
}

collect_inputs() {
    section "Detected operating system"
    log "Detected installation target: ${OS_NAME}"

    echo
    log "Default GLPI version: ${DEFAULT_GLPI_VERSION}"
    log "Default PHP version: ${DEFAULT_PHP_VERSION}"
    log "Default database: MariaDB"
    echo

    GLPI_VERSION="$(prompt_default "Enter GLPI version" "$DEFAULT_GLPI_VERSION")"
    PHP_VERSION="$(prompt_default "Enter PHP version" "$DEFAULT_PHP_VERSION")"
    DB_NAME="$(prompt_default "Enter GLPI database name" "$DEFAULT_DB_NAME")"
    DB_USER="$(prompt_default "Enter GLPI database user" "$DEFAULT_DB_USER")"

    local generated_password
    generated_password="$(generate_password)"

    echo
    log "A random database password was generated."
    DB_PASSWORD="$(prompt_default "Enter GLPI database password or press Enter to use the generated one" "$generated_password")"

    INSTALL_PATH="$(prompt_default "Enter GLPI installation path" "$DEFAULT_INSTALL_PATH")"

    echo
    SERVER_NAME="$(prompt_default "Enter Apache ServerName or press Enter to leave it empty" "$DEFAULT_SERVER_NAME")"

    echo
    RUN_SECURE_DB_HARDENING="$(prompt_yes_no "Apply basic MariaDB hardening equivalent to mysql_secure_installation?" "y")"

    echo
    if [[ "$PHP_REPO" == "none" ]]; then
        log "No third-party PHP repository is known for ${OS_NAME}."
        log "Only the PHP versions packaged by the distribution will be available."
        USE_PHP_REPO="n"
    elif [[ "$PHP_REPO_PRESENT" == "y" ]]; then
        log "The ${PHP_REPO_LABEL} repository is already configured on this system and will be reused."
        USE_PHP_REPO="y"
    else
        log "Detected PHP repository for this system: ${PHP_REPO_LABEL}"
        USE_PHP_REPO="$(prompt_yes_no "Add the ${PHP_REPO_LABEL} repository to install the selected PHP version?" "y")"
    fi

    section "Installation summary"
    log "Operating system: ${OS_NAME}"
    log "GLPI version: ${GLPI_VERSION}"
    log "PHP version: ${PHP_VERSION}"
    log "Database engine: MariaDB"
    log "Database name: ${DB_NAME}"
    log "Database user: ${DB_USER}"
    log "Installation path: ${INSTALL_PATH}"

    if [[ -n "$SERVER_NAME" ]]; then
        log "Apache ServerName: ${SERVER_NAME}"
    else
        log "Apache ServerName: not configured"
    fi

    log "Apply database hardening: ${RUN_SECURE_DB_HARDENING}"

    if [[ "$PHP_REPO" == "none" ]]; then
        log "PHP repository: distribution repositories only"
    elif [[ "$PHP_REPO_PRESENT" == "y" ]]; then
        log "PHP repository: ${PHP_REPO_LABEL} (already configured)"
    elif [[ "$USE_PHP_REPO" == "y" ]]; then
        log "PHP repository: ${PHP_REPO_LABEL} (will be added)"
    else
        log "PHP repository: ${PHP_REPO_LABEL} (declined, distribution packages will be used)"
    fi

    echo
    local confirm
    confirm="$(prompt_yes_no "Continue with installation?" "y")"

    if [[ "$confirm" != "y" ]]; then
        fail "Installation cancelled by user."
    fi
}

install_base_packages() {
    section "Updating operating system packages"

    apt-get update
    apt-get upgrade -y

    section "Installing base packages"

    apt-get install -y \
        ca-certificates \
        curl \
        wget \
        vim \
        unzip \
        tar \
        lsb-release \
        gnupg \
        openssl \
        software-properties-common \
        apt-transport-https
}

configure_sury_repository() {
    if [[ -z "$OS_CODENAME" ]]; then
        fail "Could not detect the distribution codename, which is required to configure the Sury repository."
    fi

    local keyring="/usr/share/keyrings/sury-php.gpg"
    local tmp_key="/tmp/sury-php-apt.key"

    install -d -m 0755 /usr/share/keyrings

    if ! curl -fsSL https://packages.sury.org/php/apt.gpg -o "$tmp_key"; then
        fail "Could not download the Sury repository signing key."
    fi

    if head -c 64 "$tmp_key" | grep -q "BEGIN PGP PUBLIC KEY BLOCK"; then
        gpg --batch --yes --dearmor --output "$keyring" "$tmp_key"
        chmod 0644 "$keyring"
    else
        install -m 0644 "$tmp_key" "$keyring"
    fi

    rm -f "$tmp_key"

    echo "deb [signed-by=${keyring}] https://packages.sury.org/php/ ${OS_CODENAME} main" \
        > /etc/apt/sources.list.d/sury-php.list

    log "Sury repository configured for ${OS_CODENAME}."
}

configure_php_repository() {
    if [[ "$PHP_REPO" == "none" || "$USE_PHP_REPO" != "y" ]]; then
        section "Skipping external PHP repository"
        log "The script will use PHP packages available from the current APT repositories."
        return
    fi

    if [[ "$PHP_REPO_PRESENT" == "y" ]]; then
        section "Reusing the ${PHP_REPO_LABEL} repository"
        log "The repository is already configured; only refreshing the package lists."
        apt-get update
        return
    fi

    section "Configuring the ${PHP_REPO_LABEL} repository"

    case "$PHP_REPO" in
        ondrej)
            add-apt-repository -y ppa:ondrej/php
            ;;
        sury)
            configure_sury_repository
            ;;
    esac

    apt-get update
}

verify_php_available() {
    section "Checking PHP ${PHP_VERSION} availability"

    if apt-cache show "php${PHP_VERSION}" >/dev/null 2>&1; then
        log "PHP ${PHP_VERSION} is available in the configured repositories."
        return
    fi

    log "PHP ${PHP_VERSION} was not found in the configured repositories."

    if [[ "$PHP_REPO" != "none" && "$USE_PHP_REPO" != "y" ]]; then
        log "Re-run the installer and accept the ${PHP_REPO_LABEL} repository, or pick a PHP version packaged by ${OS_NAME}."
    else
        log "Pick a PHP version available in the configured repositories."
    fi

    fail "PHP ${PHP_VERSION} package is not available for installation."
}

install_web_stack() {
    section "Installing Apache and MariaDB"

    apt-get install -y apache2 mariadb-server mariadb-client

    section "Installing PHP ${PHP_VERSION} and required extensions"

    local php_packages=(
        "php${PHP_VERSION}"
        "php${PHP_VERSION}-cli"
        "php${PHP_VERSION}-common"
        "php${PHP_VERSION}-curl"
        "php${PHP_VERSION}-gd"
        "php${PHP_VERSION}-mbstring"
        "php${PHP_VERSION}-mysql"
        "php${PHP_VERSION}-xml"
        "php${PHP_VERSION}-imap"
        "php${PHP_VERSION}-ldap"
        "php${PHP_VERSION}-soap"
        "php${PHP_VERSION}-snmp"
        "php${PHP_VERSION}-apcu"
        "php${PHP_VERSION}-intl"
        "php${PHP_VERSION}-bz2"
        "php${PHP_VERSION}-zip"
        "php${PHP_VERSION}-bcmath"
        "libapache2-mod-php${PHP_VERSION}"
    )

    apt-get install -y "${php_packages[@]}"

    systemctl enable apache2
    systemctl enable mariadb
    systemctl start apache2
    systemctl start mariadb
}

get_db_client() {
    if command -v mariadb >/dev/null 2>&1; then
        echo "mariadb"
    elif command -v mysql >/dev/null 2>&1; then
        echo "mysql"
    else
        fail "Neither mariadb nor mysql client was found."
    fi
}

harden_mariadb() {
    if [[ "$RUN_SECURE_DB_HARDENING" != "y" ]]; then
        section "Skipping MariaDB hardening"
        return
    fi

    section "Applying basic MariaDB hardening"

    local db_client
    db_client="$(get_db_client)"

    "$db_client" <<SQL
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

    log "Basic MariaDB hardening applied."
}

configure_database() {
    section "Creating GLPI database and user"

    local db_client
    db_client="$(get_db_client)"

    "$db_client" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

    log "Database and user created successfully."

    section "Testing GLPI database credentials"

    MYSQL_PWD="${DB_PASSWORD}" "$db_client" -u "${DB_USER}" -e "SHOW DATABASES;" >/dev/null

    log "Database authentication test succeeded."
}

download_glpi() {
    section "Downloading GLPI ${GLPI_VERSION}"

    local tmp_dir
    local archive_name
    local download_url

    tmp_dir="/tmp/glpi-install"
    archive_name="glpi-${GLPI_VERSION}.tgz"
    download_url="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/${archive_name}"

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    wget -O "${tmp_dir}/${archive_name}" "$download_url"

    section "Extracting GLPI"

    tar -xzf "${tmp_dir}/${archive_name}" -C "$tmp_dir"

    if [[ ! -d "${tmp_dir}/glpi" ]]; then
        fail "Extracted GLPI directory was not found."
    fi

    if [[ -d "$INSTALL_PATH" ]]; then
        local backup_path
        backup_path="${INSTALL_PATH}.backup.$(date +%Y%m%d%H%M%S)"

        section "Existing GLPI directory found"
        log "Moving existing directory to ${backup_path}"

        mv "$INSTALL_PATH" "$backup_path"
    fi

    mkdir -p "$(dirname "$INSTALL_PATH")"
    mv "${tmp_dir}/glpi" "$INSTALL_PATH"

    log "GLPI installed at ${INSTALL_PATH}"
}

configure_apache() {
    section "Configuring Apache virtual host"

    local apache_conf="/etc/apache2/sites-available/glpi.conf"

    if [[ -n "$SERVER_NAME" ]]; then
        cat > "$apache_conf" <<EOF
<VirtualHost *:80>
    ServerName ${SERVER_NAME}
    DocumentRoot ${INSTALL_PATH}/public

    <Directory ${INSTALL_PATH}/public>
        Require all granted

        RewriteEngine On
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]

        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF
    else
        cat > "$apache_conf" <<EOF
<VirtualHost *:80>
    DocumentRoot ${INSTALL_PATH}/public

    <Directory ${INSTALL_PATH}/public>
        Require all granted

        RewriteEngine On
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]

        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF
    fi

    a2enmod rewrite
    a2dissite 000-default.conf >/dev/null 2>&1 || true
    a2ensite glpi.conf

    apache2ctl configtest

    systemctl restart apache2

    log "Apache virtual host configured successfully."
}

configure_php() {
    section "Configuring PHP ${PHP_VERSION}"

    local php_ini="/etc/php/${PHP_VERSION}/apache2/php.ini"

    if [[ ! -f "$php_ini" ]]; then
        fail "PHP ini file was not found: ${php_ini}"
    fi

    sed -i 's/^;*session.cookie_httponly.*/session.cookie_httponly = On/' "$php_ini"
    sed -i 's/^;*expose_php.*/expose_php = Off/' "$php_ini"
    sed -i 's/^;*memory_limit.*/memory_limit = 256M/' "$php_ini"
    sed -i 's/^;*upload_max_filesize.*/upload_max_filesize = 64M/' "$php_ini"
    sed -i 's/^;*post_max_size.*/post_max_size = 64M/' "$php_ini"
    sed -i 's/^;*max_execution_time.*/max_execution_time = 120/' "$php_ini"

    systemctl restart apache2

    log "PHP configuration adjusted successfully."
}

set_permissions() {
    section "Setting GLPI permissions"

    chown -R www-data:www-data "$INSTALL_PATH"

    find "$INSTALL_PATH" -type d -exec chmod 755 {} \;
    find "$INSTALL_PATH" -type f -exec chmod 644 {} \;

    chmod -R 775 "${INSTALL_PATH}/files" || true
    chmod -R 775 "${INSTALL_PATH}/config" || true
    chmod -R 775 "${INSTALL_PATH}/plugins" || true
    chmod -R 775 "${INSTALL_PATH}/marketplace" || true

    log "Permissions applied successfully."
}

save_credentials() {
    section "Saving installation credentials"

    cat > "$CREDENTIALS_FILE" <<EOF
GLPI installation information
Generated at: $(date)

Operating system: ${OS_NAME}
GLPI version: ${GLPI_VERSION}
PHP version: ${PHP_VERSION}
Database engine: MariaDB

Installation path: ${INSTALL_PATH}
Apache configuration: /etc/apache2/sites-available/glpi.conf

Database host: localhost
Database name: ${DB_NAME}
Database user: ${DB_USER}
Database password: ${DB_PASSWORD}

Log file: ${LOG_FILE}
EOF

    chmod 600 "$CREDENTIALS_FILE"

    log "Credentials saved at: ${CREDENTIALS_FILE}"
}

print_final_information() {
    section "Installation completed"

    local access_url="http://SERVER_IP_OR_HOSTNAME"

    if [[ -n "$SERVER_NAME" ]]; then
        access_url="http://${SERVER_NAME}"
    fi

    log "The web server and database are ready, but GLPI itself is NOT installed yet."
    log "Finish the setup by completing the GLPI web installer. Follow these steps:"
    echo
    log "Step 1 - Open the web installer:"
    log "${access_url}"
    echo
    log "Step 2 - Walk through the wizard using this database information"
    log "(also saved in ${CREDENTIALS_FILE}):"
    log "Database host: localhost"
    log "Database name: ${DB_NAME}"
    log "Database user: ${DB_USER}"
    log "Database password: stored in ${CREDENTIALS_FILE}"
    echo
    log "Step 3 - When the wizard finishes, it creates default accounts (glpi/glpi,"
    log "tech/tech, normal/normal, post-only/postonly). Log in and change or disable"
    log "the ones you will not use."
    echo
    log "Step 4 - Only after the wizard completes, remove the install directory"
    log "(GLPI refuses to run normally while it still exists):"
    log "rm -rf ${INSTALL_PATH}/install"
    echo
    log "Step 5 - Set a strong MariaDB root password, if not already done:"
    log "sudo mariadb"
    log "ALTER USER 'root'@'localhost' IDENTIFIED BY 'STRONG_ROOT_PASSWORD';"
    log "FLUSH PRIVILEGES;"
}

main() {
    require_root
    detect_os
    detect_php_repository
    collect_inputs
    install_base_packages
    configure_php_repository
    verify_php_available
    install_web_stack
    harden_mariadb
    configure_database
    download_glpi
    configure_apache
    configure_php
    set_permissions
    save_credentials
    print_final_information
}

main "$@"