#!/usr/bin/env bash

# Top level errexit is intentionally disabled: every installation step runs
# through run_step(), which enables errexit inside a subshell so that a single
# failing step no longer aborts the whole installer.
set -uo pipefail

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
DB_ROOT_PASSWORD=""
INSTALL_PATH=""
SERVER_NAME=""

# Environment survey results.
PHP_PRESENT="n"
PHP_CLI_VERSION=""
PHP_CLI_FULL_VERSION=""
PHP_CONFIGURED_VERSIONS=""
PHP_APACHE_SAPI="n"
PHP_MISSING_PACKAGES=()
PHP_MISSING_OPTIONAL_PACKAGES=()

APACHE_PRESENT="n"
APACHE_VERSION=""
APACHE_ACTIVE="n"

DB_PRESENT="n"
DB_ENGINE=""
DB_SERVER_VERSION=""
DB_SERVICE=""
DB_ACTIVE="n"
DB_ROOT_ACCESS="n"

GLPI_DIR_PRESENT="n"
GLPI_DIR_VERSION=""
GLPI_DB_CONFIGURED="n"
GLPI_DB_EXISTS="unknown"
GLPI_DB_USER_EXISTS="unknown"

# Step selection flags.
DO_SYSTEM_UPDATE="y"
DO_SYSTEM_UPGRADE="y"
DO_BASE_PACKAGES="y"
DO_PHP_REPO="y"
DO_PHP="y"
DO_APACHE="y"
DO_MARIADB="y"
DO_SERVICES="y"
DO_DB_HARDENING="y"
DO_DB_SETUP="y"
DO_GLPI_DOWNLOAD="y"
DO_APACHE_VHOST="y"
DO_PHP_TUNING="y"
DO_PERMISSIONS="y"

# Reasons shown in the plan for steps that are disabled by default.
SKIP_REASON_PHP=""
SKIP_REASON_APACHE=""
SKIP_REASON_MARIADB=""
SKIP_REASON_GLPI=""
SKIP_REASON_DB_SETUP=""
SKIP_REASON_DB_HARDENING=""

STEP_KEYS=()
declare -A STEP_LABELS=()
declare -A STEP_STATUS=()
declare -A STEP_DETAIL=()
FAILED_STEPS=0

# Extensions GLPI cannot run without.
PHP_REQUIRED_SUFFIXES=(
    ""
    "cli"
    "common"
    "curl"
    "gd"
    "mbstring"
    "mysql"
    "xml"
    "intl"
    "zip"
    "bcmath"
)

# Extensions GLPI only needs for optional features. Some distributions no
# longer package all of them (php-imap is the usual case), so a failure here
# is reported as a warning instead of failing the whole PHP step.
PHP_OPTIONAL_SUFFIXES=(
    "imap"
    "ldap"
    "soap"
    "snmp"
    "apcu"
    "bz2"
)

OPTIONAL_FAILURES_FILE="/tmp/glpi-install-optional-php.txt"

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

package_installed() {
    local package="$1"

    dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
        | grep -q "install ok installed"
}

service_unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

detect_php() {
    PHP_PRESENT="n"
    PHP_CLI_VERSION=""
    PHP_CLI_FULL_VERSION=""
    PHP_CONFIGURED_VERSIONS=""
    PHP_APACHE_SAPI="n"

    if command -v php >/dev/null 2>&1; then
        PHP_PRESENT="y"
        PHP_CLI_VERSION="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
        PHP_CLI_FULL_VERSION="$(php -v 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -d /etc/php ]]; then
        local version=""
        local versions=()

        while IFS= read -r version; do
            versions+=("$(basename "$version")")
        done < <(find /etc/php -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

        if [[ "${#versions[@]}" -gt 0 ]]; then
            PHP_CONFIGURED_VERSIONS="${versions[*]}"
        fi
    fi
}

php_required_packages() {
    local version="$1"
    local suffix=""

    for suffix in "${PHP_REQUIRED_SUFFIXES[@]}"; do
        if [[ -z "$suffix" ]]; then
            echo "php${version}"
        else
            echo "php${version}-${suffix}"
        fi
    done

    echo "libapache2-mod-php${version}"
}

php_optional_packages() {
    local version="$1"
    local suffix=""

    for suffix in "${PHP_OPTIONAL_SUFFIXES[@]}"; do
        echo "php${version}-${suffix}"
    done
}

detect_php_missing_packages() {
    local version="$1"
    local package=""

    PHP_MISSING_PACKAGES=()
    PHP_MISSING_OPTIONAL_PACKAGES=()

    while IFS= read -r package; do
        if ! package_installed "$package"; then
            PHP_MISSING_PACKAGES+=("$package")
        fi
    done < <(php_required_packages "$version")

    while IFS= read -r package; do
        if ! package_installed "$package"; then
            PHP_MISSING_OPTIONAL_PACKAGES+=("$package")
        fi
    done < <(php_optional_packages "$version")

    if [[ -f "/etc/php/${version}/apache2/php.ini" ]]; then
        PHP_APACHE_SAPI="y"
    else
        PHP_APACHE_SAPI="n"
    fi
}

detect_apache() {
    APACHE_PRESENT="n"
    APACHE_VERSION=""
    APACHE_ACTIVE="n"

    if package_installed apache2 || command -v apache2ctl >/dev/null 2>&1; then
        APACHE_PRESENT="y"
        APACHE_VERSION="$(apache2 -v 2>/dev/null | sed -n 's/^Server version: *//p' | head -n 1 || true)"

        if [[ -z "$APACHE_VERSION" ]]; then
            APACHE_VERSION="version unknown"
        fi

        if service_is_active apache2; then
            APACHE_ACTIVE="y"
        fi
    fi
}

detect_database() {
    DB_PRESENT="n"
    DB_ENGINE=""
    DB_SERVER_VERSION=""
    DB_SERVICE=""
    DB_ACTIVE="n"
    DB_ROOT_ACCESS="n"

    if package_installed mariadb-server; then
        DB_PRESENT="y"
        DB_ENGINE="MariaDB"
    elif package_installed mysql-server; then
        DB_PRESENT="y"
        DB_ENGINE="MySQL"
    elif command -v mariadbd >/dev/null 2>&1 || command -v mysqld >/dev/null 2>&1; then
        DB_PRESENT="y"
        DB_ENGINE="MariaDB/MySQL"
    fi

    if [[ "$DB_PRESENT" != "y" ]]; then
        return
    fi

    local binary=""
    for binary in mariadbd mysqld; do
        if command -v "$binary" >/dev/null 2>&1; then
            DB_SERVER_VERSION="$("$binary" --version 2>/dev/null | head -n 1 || true)"
            break
        fi
    done

    if [[ -z "$DB_SERVER_VERSION" ]]; then
        DB_SERVER_VERSION="version unknown"
    fi

    local unit=""
    for unit in mariadb mysql mysqld; do
        if service_unit_exists "$unit"; then
            DB_SERVICE="$unit"
            break
        fi
    done

    if [[ -n "$DB_SERVICE" ]] && service_is_active "$DB_SERVICE"; then
        DB_ACTIVE="y"
    fi

    if db_root_can_connect; then
        DB_ROOT_ACCESS="y"
    fi
}

get_db_client() {
    if command -v mariadb >/dev/null 2>&1; then
        echo "mariadb"
    elif command -v mysql >/dev/null 2>&1; then
        echo "mysql"
    else
        return 1
    fi
}

db_root_exec() {
    local db_client=""
    db_client="$(get_db_client)" || fail "Neither mariadb nor mysql client was found."

    if [[ -n "$DB_ROOT_PASSWORD" ]]; then
        MYSQL_PWD="$DB_ROOT_PASSWORD" "$db_client" -u root "$@"
    else
        "$db_client" "$@"
    fi
}

db_root_can_connect() {
    local db_client=""
    db_client="$(get_db_client)" || return 1

    if [[ -n "$DB_ROOT_PASSWORD" ]]; then
        MYSQL_PWD="$DB_ROOT_PASSWORD" "$db_client" -u root -e "SELECT 1;" >/dev/null 2>&1
    else
        "$db_client" -e "SELECT 1;" >/dev/null 2>&1
    fi
}

detect_glpi_installation() {
    GLPI_DIR_PRESENT="n"
    GLPI_DIR_VERSION=""
    GLPI_DB_CONFIGURED="n"

    if [[ ! -d "$INSTALL_PATH" ]]; then
        return
    fi

    GLPI_DIR_PRESENT="y"

    local define_file="${INSTALL_PATH}/inc/define.php"

    if [[ -f "$define_file" ]]; then
        GLPI_DIR_VERSION="$(sed -n "s/.*define(['\"]GLPI_VERSION['\"][^'\"]*['\"]\\([^'\"]*\\)['\"].*/\\1/p" \
            "$define_file" 2>/dev/null | head -n 1)"
    fi

    if [[ -z "$GLPI_DIR_VERSION" ]]; then
        GLPI_DIR_VERSION="version unknown"
    fi

    if [[ -f "${INSTALL_PATH}/config/config_db.php" ]]; then
        GLPI_DB_CONFIGURED="y"
    fi
}

detect_glpi_db_objects() {
    GLPI_DB_EXISTS="unknown"
    GLPI_DB_USER_EXISTS="unknown"

    if [[ "$DB_ROOT_ACCESS" != "y" ]]; then
        return
    fi

    if db_root_exec -N -B -e "SHOW DATABASES LIKE '${DB_NAME}';" 2>/dev/null | grep -q .; then
        GLPI_DB_EXISTS="y"
    else
        GLPI_DB_EXISTS="n"
    fi

    if db_root_exec -N -B -e \
        "SELECT 1 FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost';" 2>/dev/null | grep -q .; then
        GLPI_DB_USER_EXISTS="y"
    else
        GLPI_DB_USER_EXISTS="n"
    fi
}

survey_environment() {
    detect_php
    detect_apache
    detect_database
}

print_environment_report() {
    section "Environment check"

    log "Operating system: ${OS_NAME}"

    if [[ "$PHP_PRESENT" == "y" ]]; then
        log "PHP: installed (${PHP_CLI_FULL_VERSION:-unknown})"
    else
        log "PHP: not installed"
    fi

    if [[ -n "$PHP_CONFIGURED_VERSIONS" ]]; then
        log "PHP versions configured under /etc/php: ${PHP_CONFIGURED_VERSIONS}"
    else
        log "PHP versions configured under /etc/php: none"
    fi

    if [[ "$APACHE_PRESENT" == "y" ]]; then
        log "Apache: installed (${APACHE_VERSION}) - service active: ${APACHE_ACTIVE}"
    else
        log "Apache: not installed"
    fi

    if [[ "$DB_PRESENT" == "y" ]]; then
        log "Database: ${DB_ENGINE} installed (${DB_SERVER_VERSION})"
        log "Database service: ${DB_SERVICE:-not found} - active: ${DB_ACTIVE}"
        log "Database root access without password: ${DB_ROOT_ACCESS}"
    else
        log "Database: no MariaDB or MySQL server installed"
    fi

    if [[ "$PHP_REPO" == "none" ]]; then
        log "PHP repository: no third-party repository is known for this system"
    else
        log "PHP repository (${PHP_REPO_LABEL}) already configured: ${PHP_REPO_PRESENT}"
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

prompt_secret() {
    local prompt="$1"
    local value=""

    read -r -s -p "$prompt: " value
    echo >&2
    printf '%s' "$value"
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
    section "Installation parameters"

    log "Default GLPI version: ${DEFAULT_GLPI_VERSION}"
    log "Default database: MariaDB"

    local php_default="$DEFAULT_PHP_VERSION"

    if [[ "$PHP_PRESENT" == "y" && -n "$PHP_CLI_VERSION" ]]; then
        php_default="$PHP_CLI_VERSION"
        log "PHP ${PHP_CLI_VERSION} is already installed and will be offered as the default."
    fi

    echo

    GLPI_VERSION="$(prompt_default "Enter GLPI version" "$DEFAULT_GLPI_VERSION")"
    PHP_VERSION="$(prompt_default "Enter PHP version" "$php_default")"
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
}

request_db_root_password() {
    if [[ "$DB_PRESENT" != "y" || "$DB_ROOT_ACCESS" == "y" ]]; then
        return
    fi

    if [[ "$DB_ACTIVE" != "y" ]]; then
        log "The database server is installed but not running, so its credentials cannot be tested yet."
        return
    fi

    echo
    log "The database server is running but root cannot connect through the local socket."

    local answer
    answer="$(prompt_yes_no "Provide the MariaDB/MySQL root password now?" "y")"

    if [[ "$answer" != "y" ]]; then
        return
    fi

    local attempt
    for attempt in 1 2 3; do
        DB_ROOT_PASSWORD="$(prompt_secret "MariaDB/MySQL root password")"

        if db_root_can_connect; then
            DB_ROOT_ACCESS="y"
            log "Database root credentials accepted."
            return
        fi

        DB_ROOT_PASSWORD=""
        log "Could not authenticate with the provided password (attempt ${attempt}/3)."
    done

    log "Continuing without database root access. Database steps will be reported as failed if they cannot run."
}

build_plan() {
    detect_php_missing_packages "$PHP_VERSION"
    detect_glpi_installation
    request_db_root_password
    detect_glpi_db_objects

    # PHP.
    if [[ "${#PHP_MISSING_PACKAGES[@]}" -eq 0 && "${#PHP_MISSING_OPTIONAL_PACKAGES[@]}" -eq 0 ]]; then
        DO_PHP="n"
        SKIP_REASON_PHP="PHP ${PHP_VERSION} and all its packages are already installed"
    else
        DO_PHP="y"
        SKIP_REASON_PHP=""
    fi

    # PHP repository.
    if [[ "$DO_PHP" != "y" || "$PHP_REPO" == "none" ]]; then
        DO_PHP_REPO="n"
    else
        DO_PHP_REPO="y"
    fi

    # Apache.
    if [[ "$APACHE_PRESENT" == "y" ]]; then
        DO_APACHE="n"
        SKIP_REASON_APACHE="Apache is already installed (${APACHE_VERSION})"
    else
        DO_APACHE="y"
        SKIP_REASON_APACHE=""
    fi

    # Database server.
    if [[ "$DB_PRESENT" == "y" ]]; then
        DO_MARIADB="n"
        SKIP_REASON_MARIADB="${DB_ENGINE} is already installed (${DB_SERVER_VERSION})"
    else
        DO_MARIADB="y"
        SKIP_REASON_MARIADB=""
    fi

    # Database hardening: only meaningful on a fresh database server.
    if [[ "$DB_PRESENT" == "y" ]]; then
        DO_DB_HARDENING="n"
        SKIP_REASON_DB_HARDENING="the database server was already installed before this run"
    else
        DO_DB_HARDENING="y"
        SKIP_REASON_DB_HARDENING=""
    fi

    # GLPI database and user.
    if [[ "$GLPI_DB_CONFIGURED" == "y" ]]; then
        DO_DB_SETUP="n"
        SKIP_REASON_DB_SETUP="${INSTALL_PATH}/config/config_db.php already exists, so the current credentials are in use"
    else
        DO_DB_SETUP="y"
        SKIP_REASON_DB_SETUP=""
    fi

    # GLPI files.
    if [[ "$GLPI_DIR_PRESENT" == "y" && "$GLPI_DIR_VERSION" == "$GLPI_VERSION" ]]; then
        DO_GLPI_DOWNLOAD="n"
        SKIP_REASON_GLPI="GLPI ${GLPI_VERSION} is already present at ${INSTALL_PATH}"
    else
        DO_GLPI_DOWNLOAD="y"
        SKIP_REASON_GLPI=""
    fi

    DO_SYSTEM_UPDATE="y"
    DO_SYSTEM_UPGRADE="y"
    DO_BASE_PACKAGES="y"
    DO_SERVICES="y"
    DO_APACHE_VHOST="y"
    DO_PHP_TUNING="y"
    DO_PERMISSIONS="y"
}

print_plan() {
    section "Installation plan"

    log "$(printf '%-3s %-46s %s' "" "Step" "Action")"
    log "$(printf '%-3s %-46s %s' "1" "Update APT package lists" "$(plan_action "$DO_SYSTEM_UPDATE")")"
    log "$(printf '%-3s %-46s %s' "2" "Upgrade installed system packages" "$(plan_action "$DO_SYSTEM_UPGRADE")")"
    log "$(printf '%-3s %-46s %s' "3" "Install base utility packages" "$(plan_action "$DO_BASE_PACKAGES")")"
    log "$(printf '%-3s %-46s %s' "4" "Configure ${PHP_REPO_LABEL}" "$(plan_action "$DO_PHP_REPO")")"
    log "$(printf '%-3s %-46s %s' "5" "Install PHP ${PHP_VERSION} and extensions" "$(plan_action "$DO_PHP")")"
    log "$(printf '%-3s %-46s %s' "6" "Install Apache" "$(plan_action "$DO_APACHE")")"
    log "$(printf '%-3s %-46s %s' "7" "Install MariaDB server" "$(plan_action "$DO_MARIADB")")"
    log "$(printf '%-3s %-46s %s' "8" "Enable and start Apache and database" "$(plan_action "$DO_SERVICES")")"
    log "$(printf '%-3s %-46s %s' "9" "Apply basic database hardening" "$(plan_action "$DO_DB_HARDENING")")"
    log "$(printf '%-3s %-46s %s' "10" "Create GLPI database and user" "$(plan_action "$DO_DB_SETUP")")"
    log "$(printf '%-3s %-46s %s' "11" "Download and extract GLPI ${GLPI_VERSION}" "$(plan_action "$DO_GLPI_DOWNLOAD")")"
    log "$(printf '%-3s %-46s %s' "12" "Configure Apache virtual host" "$(plan_action "$DO_APACHE_VHOST")")"
    log "$(printf '%-3s %-46s %s' "13" "Tune PHP settings for GLPI" "$(plan_action "$DO_PHP_TUNING")")"
    log "$(printf '%-3s %-46s %s' "14" "Apply GLPI file permissions" "$(plan_action "$DO_PERMISSIONS")")"

    echo

    if [[ -n "$SKIP_REASON_PHP" ]]; then
        log "PHP: ${SKIP_REASON_PHP}."
    else
        if [[ "${#PHP_MISSING_PACKAGES[@]}" -gt 0 ]]; then
            log "Required PHP packages to install: ${PHP_MISSING_PACKAGES[*]}"
        else
            log "Required PHP packages: already installed"
        fi

        if [[ "${#PHP_MISSING_OPTIONAL_PACKAGES[@]}" -gt 0 ]]; then
            log "Optional PHP packages to install: ${PHP_MISSING_OPTIONAL_PACKAGES[*]}"
            log "An optional package that the distribution does not provide is reported as a"
            log "warning and does not fail the PHP step."
        fi
    fi

    if [[ -n "$SKIP_REASON_APACHE" ]]; then
        log "Apache: ${SKIP_REASON_APACHE}."
    fi

    if [[ -n "$SKIP_REASON_MARIADB" ]]; then
        log "Database server: ${SKIP_REASON_MARIADB}."
    fi

    if [[ -n "$SKIP_REASON_DB_HARDENING" ]]; then
        log "Database hardening: ${SKIP_REASON_DB_HARDENING}."
    fi

    if [[ -n "$SKIP_REASON_DB_SETUP" ]]; then
        log "GLPI database: ${SKIP_REASON_DB_SETUP}."
    fi

    if [[ "$GLPI_DB_EXISTS" == "y" ]]; then
        log "Database '${DB_NAME}' already exists and will be reused, never dropped."
    fi

    if [[ "$GLPI_DB_USER_EXISTS" == "y" ]]; then
        log "WARNING: user '${DB_USER}'@'localhost' already exists. If the GLPI database step runs,"
        log "its password will be reset to the value chosen in this run, and any application"
        log "already using the old password must be updated."
    fi

    if [[ -n "$SKIP_REASON_GLPI" ]]; then
        log "GLPI files: ${SKIP_REASON_GLPI}."
    elif [[ "$GLPI_DIR_PRESENT" == "y" ]]; then
        log "WARNING: ${INSTALL_PATH} already contains GLPI ${GLPI_DIR_VERSION}. If the download step runs,"
        log "the current directory is moved to a timestamped backup, not deleted."
    fi

    if [[ "$DB_PRESENT" == "y" && "$DB_ROOT_ACCESS" != "y" ]]; then
        log "WARNING: no database root access is available, so database steps are likely to fail."
    fi
}

plan_action() {
    if [[ "$1" == "y" ]]; then
        echo "install"
    else
        echo "skip"
    fi
}

customize_plan() {
    echo
    log "Answer y to run the step or n to skip it."
    echo

    DO_SYSTEM_UPDATE="$(prompt_yes_no "Update APT package lists?" "$DO_SYSTEM_UPDATE")"
    DO_SYSTEM_UPGRADE="$(prompt_yes_no "Upgrade installed system packages?" "$DO_SYSTEM_UPGRADE")"
    DO_BASE_PACKAGES="$(prompt_yes_no "Install base utility packages?" "$DO_BASE_PACKAGES")"

    if [[ "$PHP_REPO" != "none" ]]; then
        DO_PHP_REPO="$(prompt_yes_no "Configure the ${PHP_REPO_LABEL} repository?" "$DO_PHP_REPO")"
    fi

    DO_PHP="$(prompt_yes_no "Install PHP ${PHP_VERSION} and its extensions?" "$DO_PHP")"
    DO_APACHE="$(prompt_yes_no "Install Apache?" "$DO_APACHE")"
    DO_MARIADB="$(prompt_yes_no "Install MariaDB server?" "$DO_MARIADB")"
    DO_SERVICES="$(prompt_yes_no "Enable and start Apache and the database service?" "$DO_SERVICES")"
    DO_DB_HARDENING="$(prompt_yes_no "Apply basic database hardening (mysql_secure_installation equivalent)?" "$DO_DB_HARDENING")"
    DO_DB_SETUP="$(prompt_yes_no "Create the GLPI database and user?" "$DO_DB_SETUP")"
    DO_GLPI_DOWNLOAD="$(prompt_yes_no "Download and extract GLPI ${GLPI_VERSION}?" "$DO_GLPI_DOWNLOAD")"
    DO_APACHE_VHOST="$(prompt_yes_no "Configure the Apache virtual host?" "$DO_APACHE_VHOST")"
    DO_PHP_TUNING="$(prompt_yes_no "Tune PHP settings for GLPI?" "$DO_PHP_TUNING")"
    DO_PERMISSIONS="$(prompt_yes_no "Apply GLPI file permissions?" "$DO_PERMISSIONS")"
}

confirm_plan() {
    while true; do
        print_plan

        echo
        local accept
        accept="$(prompt_yes_no "Run the plan above?" "y")"

        if [[ "$accept" == "y" ]]; then
            break
        fi

        local customize
        customize="$(prompt_yes_no "Choose each step manually?" "y")"

        if [[ "$customize" != "y" ]]; then
            fail "Installation cancelled by user."
        fi

        customize_plan
    done

    if [[ "$DO_PHP" == "y" && "$PHP_REPO" != "none" && "$DO_PHP_REPO" == "y" ]]; then
        USE_PHP_REPO="y"
    else
        USE_PHP_REPO="n"
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

    if [[ "$PHP_REPO" == "none" ]]; then
        log "PHP repository: distribution repositories only"
    elif [[ "$PHP_REPO_PRESENT" == "y" ]]; then
        log "PHP repository: ${PHP_REPO_LABEL} (already configured)"
    elif [[ "$USE_PHP_REPO" == "y" ]]; then
        log "PHP repository: ${PHP_REPO_LABEL} (will be added)"
    else
        log "PHP repository: ${PHP_REPO_LABEL} (not used, distribution packages will be used)"
    fi
}

record_step() {
    local key="$1"
    local label="$2"
    local status="$3"
    local detail="${4:-}"

    if [[ -z "${STEP_LABELS[$key]:-}" ]]; then
        STEP_KEYS+=("$key")
    fi

    STEP_LABELS["$key"]="$label"
    STEP_STATUS["$key"]="$status"
    STEP_DETAIL["$key"]="$detail"
}

skip_step() {
    local key="$1"
    local label="$2"
    local reason="${3:-not selected}"

    record_step "$key" "$label" "SKIPPED" "$reason"

    section "$label"
    log "Skipped: ${reason}."
}

run_step() {
    local key="$1"
    local label="$2"
    local fn="$3"
    shift 3

    local dep=""
    for dep in "$@"; do
        if [[ "${STEP_STATUS[$dep]:-}" == "FAILED" ]]; then
            record_step "$key" "$label" "SKIPPED" "dependency failed: ${STEP_LABELS[$dep]}"
            section "$label"
            log "Skipped because a required step failed: ${STEP_LABELS[$dep]}."
            return 0
        fi
    done

    section "$label"

    # errexit inside the subshell is only honoured when the subshell is not
    # part of a && or || list, so the exit code is read from $? afterwards.
    local rc=0
    ( set -e; "$fn" )
    rc=$?

    if [[ "$rc" -eq 0 ]]; then
        record_step "$key" "$label" "OK" ""
    else
        record_step "$key" "$label" "FAILED" "exit code ${rc}"
        FAILED_STEPS=$((FAILED_STEPS + 1))
        log "Step failed: ${label} (exit code ${rc}). Continuing with the remaining steps."
    fi

    return 0
}

update_package_lists() {
    apt-get update
}

upgrade_system_packages() {
    apt-get upgrade -y
}

install_base_packages() {
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
    if [[ "$PHP_REPO_PRESENT" == "y" ]]; then
        log "The ${PHP_REPO_LABEL} repository is already configured; only refreshing the package lists."
        apt-get update
        return
    fi

    case "$PHP_REPO" in
        ondrej)
            add-apt-repository -y ppa:ondrej/php
            ;;
        sury)
            configure_sury_repository
            ;;
        *)
            log "No third-party PHP repository is available for this system."
            return
            ;;
    esac

    apt-get update
}

install_php_packages() {
    detect_php_missing_packages "$PHP_VERSION"

    rm -f "$OPTIONAL_FAILURES_FILE"

    if [[ "${#PHP_MISSING_PACKAGES[@]}" -eq 0 && "${#PHP_MISSING_OPTIONAL_PACKAGES[@]}" -eq 0 ]]; then
        log "PHP ${PHP_VERSION} and all its packages are already installed."
        return
    fi

    if ! apt-cache show "php${PHP_VERSION}" >/dev/null 2>&1; then
        log "PHP ${PHP_VERSION} was not found in the configured repositories."

        if [[ "$PHP_REPO" != "none" && "$USE_PHP_REPO" != "y" ]]; then
            log "Re-run the installer and accept the ${PHP_REPO_LABEL} repository, or pick a PHP version packaged by ${OS_NAME}."
        else
            log "Pick a PHP version available in the configured repositories."
        fi

        fail "PHP ${PHP_VERSION} package is not available for installation."
    fi

    if [[ "${#PHP_MISSING_PACKAGES[@]}" -gt 0 ]]; then
        log "Installing required packages: ${PHP_MISSING_PACKAGES[*]}"
        apt-get install -y "${PHP_MISSING_PACKAGES[@]}"
    fi

    # Optional extensions are installed one by one so a package the
    # distribution does not ship cannot abort the whole PHP installation.
    local package=""
    local optional_failures=()

    for package in ${PHP_MISSING_OPTIONAL_PACKAGES[@]+"${PHP_MISSING_OPTIONAL_PACKAGES[@]}"}; do
        log "Installing optional package: ${package}"

        if ! apt-get install -y "$package"; then
            log "WARNING: optional package ${package} could not be installed and was skipped."
            optional_failures+=("$package")
        fi
    done

    if [[ "${#optional_failures[@]}" -gt 0 ]]; then
        printf '%s\n' "${optional_failures[*]}" > "$OPTIONAL_FAILURES_FILE"
    fi

    detect_php
    detect_php_missing_packages "$PHP_VERSION"

    if [[ "${#PHP_MISSING_PACKAGES[@]}" -gt 0 ]]; then
        fail "These required PHP packages are still missing after installation: ${PHP_MISSING_PACKAGES[*]}"
    fi

    log "PHP ${PHP_VERSION} installed with all required extensions."
}

install_apache() {
    apt-get install -y apache2
    detect_apache
    log "Apache installed: ${APACHE_VERSION}"
}

install_mariadb() {
    apt-get install -y mariadb-server mariadb-client
    detect_database
    log "Database server installed: ${DB_SERVER_VERSION}"
}

ensure_services() {
    if service_unit_exists apache2; then
        systemctl enable apache2
        systemctl start apache2
        log "Apache service enabled and started."
    else
        log "Apache service unit not found; nothing to start."
    fi

    detect_database

    if [[ -n "$DB_SERVICE" ]]; then
        systemctl enable "$DB_SERVICE"
        systemctl start "$DB_SERVICE"
        log "Database service ${DB_SERVICE} enabled and started."
    else
        log "Database service unit not found; nothing to start."
    fi

    detect_apache
    detect_database
}

harden_mariadb() {
    if ! db_root_can_connect; then
        fail "Cannot connect to the database as root, so hardening was not applied."
    fi

    db_root_exec <<SQL
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

    log "Basic database hardening applied."
}

configure_database() {
    if ! db_root_can_connect; then
        fail "Cannot connect to the database as root, so the GLPI database was not created."
    fi

    db_root_exec <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

    log "Database and user are in place."

    local db_client=""
    db_client="$(get_db_client)" || fail "Neither mariadb nor mysql client was found."

    MYSQL_PWD="${DB_PASSWORD}" "$db_client" -u "${DB_USER}" -e "SHOW DATABASES;" >/dev/null

    log "Database authentication test succeeded."
}

download_glpi() {
    local tmp_dir
    local archive_name
    local download_url

    tmp_dir="/tmp/glpi-install"
    archive_name="glpi-${GLPI_VERSION}.tgz"
    download_url="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/${archive_name}"

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    wget -O "${tmp_dir}/${archive_name}" "$download_url"

    log "Extracting GLPI."

    tar -xzf "${tmp_dir}/${archive_name}" -C "$tmp_dir"

    if [[ ! -d "${tmp_dir}/glpi" ]]; then
        fail "Extracted GLPI directory was not found."
    fi

    if [[ -d "$INSTALL_PATH" ]]; then
        local backup_path
        backup_path="${INSTALL_PATH}.backup.$(date +%Y%m%d%H%M%S)"

        log "Existing directory found. Moving ${INSTALL_PATH} to ${backup_path}"

        mv "$INSTALL_PATH" "$backup_path"
    fi

    mkdir -p "$(dirname "$INSTALL_PATH")"
    mv "${tmp_dir}/glpi" "$INSTALL_PATH"

    log "GLPI installed at ${INSTALL_PATH}"
}

configure_apache() {
    local apache_conf="/etc/apache2/sites-available/glpi.conf"

    if [[ ! -d /etc/apache2/sites-available ]]; then
        fail "Apache configuration directory not found. Install Apache before configuring the virtual host."
    fi

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
    if [[ ! -d "$INSTALL_PATH" ]]; then
        fail "Installation path not found: ${INSTALL_PATH}"
    fi

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

    local db_setup_status="${STEP_STATUS[db_setup]:-SKIPPED}"

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
Database step result: ${db_setup_status}

Log file: ${LOG_FILE}
EOF

    chmod 600 "$CREDENTIALS_FILE"

    log "Credentials saved at: ${CREDENTIALS_FILE}"

    if [[ "$db_setup_status" != "OK" ]]; then
        log "NOTE: the GLPI database step did not run successfully, so the password above may not be active."
    fi
}

print_final_environment() {
    section "Final environment"

    survey_environment
    detect_php_missing_packages "$PHP_VERSION"
    detect_glpi_installation

    if [[ "$PHP_PRESENT" == "y" ]]; then
        log "PHP: ${PHP_CLI_FULL_VERSION:-installed}"
    else
        log "PHP: not installed"
    fi

    if [[ "${#PHP_MISSING_PACKAGES[@]}" -gt 0 ]]; then
        log "Required PHP packages still missing: ${PHP_MISSING_PACKAGES[*]}"
    else
        log "Required PHP packages for version ${PHP_VERSION}: complete"
    fi

    if [[ "${#PHP_MISSING_OPTIONAL_PACKAGES[@]}" -gt 0 ]]; then
        log "Optional PHP packages not installed: ${PHP_MISSING_OPTIONAL_PACKAGES[*]}"
    fi

    if [[ "$APACHE_PRESENT" == "y" ]]; then
        log "Apache: ${APACHE_VERSION} - active: ${APACHE_ACTIVE}"
    else
        log "Apache: not installed"
    fi

    if [[ "$DB_PRESENT" == "y" ]]; then
        log "Database: ${DB_SERVER_VERSION} - service ${DB_SERVICE:-unknown} active: ${DB_ACTIVE}"
    else
        log "Database: not installed"
    fi

    if [[ "$GLPI_DIR_PRESENT" == "y" ]]; then
        log "GLPI files: ${GLPI_DIR_VERSION} at ${INSTALL_PATH}"
    else
        log "GLPI files: not present at ${INSTALL_PATH}"
    fi
}

print_report() {
    section "Installation report"

    local key=""
    local status=""
    local label=""
    local detail=""
    local tag=""
    local ok=0
    local failed=0
    local skipped=0

    if [[ "${#STEP_KEYS[@]}" -eq 0 ]]; then
        log "No step was executed."
        return
    fi

    for key in "${STEP_KEYS[@]}"; do
        status="${STEP_STATUS[$key]}"
        label="${STEP_LABELS[$key]}"
        detail="${STEP_DETAIL[$key]}"

        case "$status" in
            OK)
                tag="[  OK  ]"
                ok=$((ok + 1))
                ;;
            FAILED)
                tag="[ FAIL ]"
                failed=$((failed + 1))
                ;;
            *)
                tag="[ SKIP ]"
                skipped=$((skipped + 1))
                ;;
        esac

        if [[ -n "$detail" ]]; then
            log "$(printf '%s %-46s %s' "$tag" "$label" "$detail")"
        else
            log "$(printf '%s %s' "$tag" "$label")"
        fi
    done

    echo

    if [[ -s "$OPTIONAL_FAILURES_FILE" ]]; then
        log "Optional PHP packages that could not be installed: $(cat "$OPTIONAL_FAILURES_FILE")"
        log "GLPI works without them; the related features (IMAP mail collector, LDAP, SNMP)"
        log "stay unavailable until the packages exist for this distribution."
        echo
    fi

    log "Succeeded: ${ok}  Failed: ${failed}  Skipped: ${skipped}"
    log "Full log: ${LOG_FILE}"

    if [[ "$failed" -gt 0 ]]; then
        echo
        log "Some steps failed. Fix the reported problems and run ${SCRIPT_NAME} again:"
        log "the installer detects what is already in place and offers to skip it."
    fi
}

step_ok_or_skipped() {
    local status="${STEP_STATUS[$1]:-SKIPPED}"

    [[ "$status" == "OK" || "$status" == "SKIPPED" ]]
}

print_final_information() {
    local key=""
    local blocking=()

    for key in php apache mariadb services db_setup glpi_download apache_vhost php_tuning permissions; do
        if ! step_ok_or_skipped "$key"; then
            blocking+=("${STEP_LABELS[$key]}")
        fi
    done

    if [[ "${#blocking[@]}" -gt 0 ]]; then
        section "Next steps"
        log "GLPI cannot be opened in a browser yet because these steps failed:"

        for key in "${blocking[@]}"; do
            log "- ${key}"
        done

        echo
        log "Fix the problems above and run ${SCRIPT_NAME} again. Everything that already"
        log "succeeded is detected on the next run and offered as a step to skip."
        return
    fi

    section "How to finish the installation"

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

run_selected_steps() {
    if [[ "$DO_SYSTEM_UPDATE" == "y" ]]; then
        run_step system_update "Update APT package lists" update_package_lists
    else
        skip_step system_update "Update APT package lists" "not selected"
    fi

    if [[ "$DO_SYSTEM_UPGRADE" == "y" ]]; then
        run_step system_upgrade "Upgrade installed system packages" upgrade_system_packages system_update
    else
        skip_step system_upgrade "Upgrade installed system packages" "not selected"
    fi

    if [[ "$DO_BASE_PACKAGES" == "y" ]]; then
        run_step base_packages "Install base utility packages" install_base_packages
    else
        skip_step base_packages "Install base utility packages" "not selected"
    fi

    if [[ "$DO_PHP_REPO" == "y" ]]; then
        run_step php_repo "Configure ${PHP_REPO_LABEL}" configure_php_repository
    else
        skip_step php_repo "Configure ${PHP_REPO_LABEL}" \
            "distribution repositories will be used"
    fi

    if [[ "$DO_PHP" == "y" ]]; then
        run_step php "Install PHP ${PHP_VERSION} and extensions" install_php_packages php_repo
    else
        skip_step php "Install PHP ${PHP_VERSION} and extensions" \
            "${SKIP_REASON_PHP:-not selected}"
    fi

    if [[ "$DO_APACHE" == "y" ]]; then
        run_step apache "Install Apache" install_apache
    else
        skip_step apache "Install Apache" "${SKIP_REASON_APACHE:-not selected}"
    fi

    if [[ "$DO_MARIADB" == "y" ]]; then
        run_step mariadb "Install MariaDB server" install_mariadb
    else
        skip_step mariadb "Install MariaDB server" "${SKIP_REASON_MARIADB:-not selected}"
    fi

    if [[ "$DO_SERVICES" == "y" ]]; then
        run_step services "Enable and start Apache and database" ensure_services
    else
        skip_step services "Enable and start Apache and database" "not selected"
    fi

    if [[ "$DO_DB_HARDENING" == "y" ]]; then
        run_step db_hardening "Apply basic database hardening" harden_mariadb mariadb
    else
        skip_step db_hardening "Apply basic database hardening" \
            "${SKIP_REASON_DB_HARDENING:-not selected}"
    fi

    if [[ "$DO_DB_SETUP" == "y" ]]; then
        run_step db_setup "Create GLPI database and user" configure_database mariadb
    else
        skip_step db_setup "Create GLPI database and user" \
            "${SKIP_REASON_DB_SETUP:-not selected}"
    fi

    if [[ "$DO_GLPI_DOWNLOAD" == "y" ]]; then
        run_step glpi_download "Download and extract GLPI ${GLPI_VERSION}" download_glpi
    else
        skip_step glpi_download "Download and extract GLPI ${GLPI_VERSION}" \
            "${SKIP_REASON_GLPI:-not selected}"
    fi

    if [[ "$DO_APACHE_VHOST" == "y" ]]; then
        run_step apache_vhost "Configure Apache virtual host" configure_apache apache glpi_download
    else
        skip_step apache_vhost "Configure Apache virtual host" "not selected"
    fi

    if [[ "$DO_PHP_TUNING" == "y" ]]; then
        run_step php_tuning "Tune PHP settings for GLPI" configure_php php
    else
        skip_step php_tuning "Tune PHP settings for GLPI" "not selected"
    fi

    if [[ "$DO_PERMISSIONS" == "y" ]]; then
        run_step permissions "Apply GLPI file permissions" set_permissions glpi_download
    else
        skip_step permissions "Apply GLPI file permissions" "not selected"
    fi
}

main() {
    require_root
    detect_os
    detect_php_repository
    survey_environment
    print_environment_report
    collect_inputs
    build_plan
    confirm_plan
    rm -f "$OPTIONAL_FAILURES_FILE"
    run_selected_steps
    save_credentials
    print_final_environment
    print_report
    print_final_information

    if [[ "$FAILED_STEPS" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
