#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# ============================================================
# Safe WordPress Core File Updater
#
# - No WP-CLI
# - No PHP execution
# - No database upgrade
# - Downloads and installs the latest official WordPress core
# - Preserves wp-content, wp-config.php, .htaccess, robots.txt
#   and custom files outside the official package root-file list
# - Changes ownership only on files/directories installed by this script
# - Never changes ownership of the WordPress root directory itself
#
# Usage:
#   bash wp-updater.sh /path/to/wordpress
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "[-] This script must be run as root." >&2
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: bash $0 /path/to/wordpress" >&2
    exit 1
fi

for cmd in tar find stat mktemp readlink sort grep sed date chmod chown mv rm mkdir; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[-] Required command not found: $cmd" >&2
        exit 1
    fi
done

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "[-] Either curl or wget is required." >&2
    exit 1
fi

WP_PATH="$(readlink -f -- "$1" 2>/dev/null || true)"

if [[ -z "$WP_PATH" || ! -d "$WP_PATH" ]]; then
    echo "[-] Invalid or missing directory: $1" >&2
    exit 1
fi

case "$WP_PATH" in
    /|/home|/var|/var/www|/usr|/opt|/root)
        echo "[-] Unsafe WordPress path: $WP_PATH" >&2
        exit 1
        ;;
esac

if [[ ! -f "$WP_PATH/wp-settings.php" ||
      ! -f "$WP_PATH/wp-includes/version.php" ||
      ! -d "$WP_PATH/wp-admin" ||
      ! -d "$WP_PATH/wp-includes" ||
      ! -d "$WP_PATH/wp-content" ]]; then
    echo "[-] The supplied path does not look like a WordPress root:" >&2
    echo "    $WP_PATH" >&2
    exit 1
fi

WP_CONFIG=""
if [[ -f "$WP_PATH/wp-config.php" ]]; then
    WP_CONFIG="$WP_PATH/wp-config.php"
elif [[ -f "$(dirname "$WP_PATH")/wp-config.php" ]]; then
    WP_CONFIG="$(dirname "$WP_PATH")/wp-config.php"
fi

# Use an existing site-owned item as the ownership source.
# The WordPress root directory itself is deliberately not used.
OWNER_SOURCE=""
for candidate in \
    "$WP_PATH/wp-settings.php" \
    "$WP_PATH/index.php" \
    "$WP_PATH/wp-content" \
    "$WP_CONFIG"
do
    if [[ -n "$candidate" && ( -e "$candidate" || -L "$candidate" ) ]]; then
        OWNER_SOURCE="$candidate"
        break
    fi
done

if [[ -z "$OWNER_SOURCE" ]]; then
    echo "[-] Could not determine a suitable ownership source." >&2
    exit 1
fi

OWNER_UID="$(stat -Lc '%u' "$OWNER_SOURCE")"
OWNER_GID="$(stat -Lc '%g' "$OWNER_SOURCE")"
OWNER_NAME="$(stat -Lc '%U:%G' "$OWNER_SOURCE")"

ROOT_UID_BEFORE="$(stat -Lc '%u' "$WP_PATH")"
ROOT_GID_BEFORE="$(stat -Lc '%g' "$WP_PATH")"
ROOT_OWNER_BEFORE="$(stat -Lc '%U:%G' "$WP_PATH")"

DOWNLOAD_URL="https://wordpress.org/latest.tar.gz"
MAINTENANCE_FILE="$WP_PATH/.maintenance"
LOCK_DIR="$WP_PATH/.wp-core-update.lock"

WORK_DIR=""
BACKUP_DIR=""
ROOT_LIST=""
MOVED_OLD_ROOT_LIST=""
INSTALLED_NEW_ROOT_LIST=""

MAINTENANCE_CREATED=0
UPDATE_STARTED=0
UPDATE_FINISHED=0
OLD_ADMIN_MOVED=0
OLD_INCLUDES_MOVED=0
NEW_ADMIN_INSTALLED=0
NEW_INCLUDES_INSTALLED=0

if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
    echo "[-] Another update may already be running." >&2
    echo "    Lock directory: $LOCK_DIR" >&2
    exit 1
fi
chmod 0700 "$LOCK_DIR"

rollback() {
    echo >&2
    echo "[!] Update failed. Restoring the previous WordPress core..." >&2

    if [[ -n "$INSTALLED_NEW_ROOT_LIST" && -f "$INSTALLED_NEW_ROOT_LIST" ]]; then
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            rm -rf -- "$WP_PATH/$file"
        done < "$INSTALLED_NEW_ROOT_LIST"
    fi

    if [[ $NEW_ADMIN_INSTALLED -eq 1 ]]; then
        rm -rf -- "$WP_PATH/wp-admin"
    fi

    if [[ $NEW_INCLUDES_INSTALLED -eq 1 ]]; then
        rm -rf -- "$WP_PATH/wp-includes"
    fi

    if [[ $OLD_ADMIN_MOVED -eq 1 && -d "$BACKUP_DIR/wp-admin" ]]; then
        rm -rf -- "$WP_PATH/wp-admin"
        mv -- "$BACKUP_DIR/wp-admin" "$WP_PATH/wp-admin"
    fi

    if [[ $OLD_INCLUDES_MOVED -eq 1 && -d "$BACKUP_DIR/wp-includes" ]]; then
        rm -rf -- "$WP_PATH/wp-includes"
        mv -- "$BACKUP_DIR/wp-includes" "$WP_PATH/wp-includes"
    fi

    if [[ -n "$MOVED_OLD_ROOT_LIST" && -f "$MOVED_OLD_ROOT_LIST" ]]; then
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            if [[ -e "$BACKUP_DIR/$file" || -L "$BACKUP_DIR/$file" ]]; then
                rm -rf -- "$WP_PATH/$file"
                mv -- "$BACKUP_DIR/$file" "$WP_PATH/$file"
            fi
        done < "$MOVED_OLD_ROOT_LIST"
    fi

    if [[ $MAINTENANCE_CREATED -eq 1 ]]; then
        rm -f -- "$MAINTENANCE_FILE"
        MAINTENANCE_CREATED=0
    fi

    echo "[+] Rollback completed." >&2
    echo "[!] Rollback files were kept at: $BACKUP_DIR" >&2
}

cleanup() {
    local exit_code=$?

    set +e
    trap - EXIT ERR INT TERM

    if [[ $exit_code -ne 0 && $UPDATE_STARTED -eq 1 && $UPDATE_FINISHED -eq 0 ]]; then
        rollback
    elif [[ $MAINTENANCE_CREATED -eq 1 ]]; then
        rm -f -- "$MAINTENANCE_FILE"
    fi

    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi

    if [[ $exit_code -eq 0 && -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        rm -rf -- "$BACKUP_DIR"
    elif [[ $UPDATE_STARTED -eq 0 && -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        rm -rf -- "$BACKUP_DIR"
    fi

    rm -rf -- "$LOCK_DIR"
    exit "$exit_code"
}

trap cleanup EXIT
trap 'echo "[-] Error on line $LINENO." >&2' ERR
trap 'exit 130' INT TERM

read_wp_version() {
    local root="$1"
    local version_file="$root/wp-includes/version.php"

    [[ -f "$version_file" ]] || return 1

    sed -n \
        "s/^[[:space:]]*\$wp_version[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
        "$version_file" | head -n1
}

download_file() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl \
            -fL \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 20 \
            --max-time 600 \
            -o "$output" \
            "$url"
    else
        wget \
            --timeout=20 \
            --tries=3 \
            -O "$output" \
            "$url"
    fi
}

OLD_VERSION="$(read_wp_version "$WP_PATH" || true)"

# Staging and rollback directories are created inside WP_PATH so all mv
# operations stay on the same filesystem. They are mode 700 and removed later.
WORK_DIR="$(mktemp -d "$WP_PATH/.wp-core-stage.XXXXXX")"
chmod 0700 "$WORK_DIR"

ARCHIVE="$WORK_DIR/latest.tar.gz"
ARCHIVE_LIST="$WORK_DIR/archive.list"
UNEXPECTED_LIST="$WORK_DIR/unexpected-archive-paths.list"
NEW_WP="$WORK_DIR/wordpress"

BACKUP_DIR="$WP_PATH/.wp-core-rollback.$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 0700 -- "$BACKUP_DIR"

ROOT_LIST="$BACKUP_DIR/.official-root-files.list"
MOVED_OLD_ROOT_LIST="$BACKUP_DIR/.moved-old-root-files.list"
INSTALLED_NEW_ROOT_LIST="$BACKUP_DIR/.installed-new-root-files.list"

: > "$MOVED_OLD_ROOT_LIST"
: > "$INSTALLED_NEW_ROOT_LIST"

echo "[+] WordPress path: $WP_PATH"
echo "[+] Owner source: $OWNER_SOURCE"
echo "[+] New core owner: $OWNER_NAME ($OWNER_UID:$OWNER_GID)"
echo "[+] Root directory owner will remain unchanged: $ROOT_OWNER_BEFORE"
echo "[+] Installed version: ${OLD_VERSION:-unknown}"

echo "[*] Downloading the latest WordPress package..."
download_file "$DOWNLOAD_URL" "$ARCHIVE"

if ! tar -tzf "$ARCHIVE" > "$ARCHIVE_LIST" 2>/dev/null; then
    echo "[-] Downloaded archive is not a valid tar.gz file." >&2
    exit 1
fi

if grep -E '(^/|(^|/)\.\.(/|$))' "$ARCHIVE_LIST" >/dev/null; then
    echo "[-] Unsafe path detected inside the downloaded archive." >&2
    exit 1
fi

grep -Ev '^wordpress(/|$)' "$ARCHIVE_LIST" > "$UNEXPECTED_LIST" || true
if [[ -s "$UNEXPECTED_LIST" ]]; then
    echo "[-] Unexpected top-level path detected inside the archive." >&2
    exit 1
fi

echo "[+] Archive verified."

tar -xzf "$ARCHIVE" -C "$WORK_DIR"

if [[ ! -d "$NEW_WP/wp-admin" ||
      ! -d "$NEW_WP/wp-includes" ||
      ! -d "$NEW_WP/wp-content" ||
      ! -f "$NEW_WP/wp-settings.php" ||
      ! -f "$NEW_WP/wp-includes/version.php" ||
      ! -f "$NEW_WP/xmlrpc.php" ]]; then
    echo "[-] Extracted WordPress package is incomplete." >&2
    exit 1
fi

if find "$NEW_WP" -type l -print -quit | grep -q .; then
    echo "[-] Unexpected symbolic link found in the WordPress package." >&2
    exit 1
fi

NEW_VERSION="$(read_wp_version "$NEW_WP" || true)"
if [[ -z "$NEW_VERSION" ]]; then
    echo "[-] Could not determine the downloaded WordPress version." >&2
    exit 1
fi

# Build the root-file list strictly from the extracted official package.
# Protected/custom items are not included and therefore are not moved,
# replaced, chmodded, or chowned.
find "$NEW_WP" \
    -mindepth 1 \
    -maxdepth 1 \
    -type f \
    -printf '%f\n' | \
    LC_ALL=C sort | \
    while IFS= read -r file; do
        case "$file" in
            wp-config.php|.htaccess|robots.txt)
                continue
                ;;
            *)
                printf '%s\n' "$file"
                ;;
        esac
    done > "$ROOT_LIST"

if [[ ! -s "$ROOT_LIST" ]]; then
    echo "[-] No official root core files were found in the package." >&2
    exit 1
fi

if ! grep -qx 'xmlrpc.php' "$ROOT_LIST"; then
    echo "[-] xmlrpc.php is missing from the official package list." >&2
    exit 1
fi

echo "[+] Downloaded version: $NEW_VERSION"
echo "[+] Official root core-file list loaded from the extracted package."
echo "[+] wp-content, wp-config.php, .htaccess, robots.txt and custom files will be preserved."
echo "[+] Package preparation completed before changing the live site."

if [[ -e "$MAINTENANCE_FILE" || -L "$MAINTENANCE_FILE" ]]; then
    echo "[-] An existing .maintenance file was found:" >&2
    echo "    $MAINTENANCE_FILE" >&2
    exit 1
fi

printf '<?php $upgrading = %s; ?>\n' "$(date +%s)" > "$MAINTENANCE_FILE"
chmod 0644 "$MAINTENANCE_FILE"
MAINTENANCE_CREATED=1
UPDATE_STARTED=1

echo "[+] Maintenance mode enabled."
echo "[*] Moving the existing core to the rollback area..."

mv -- "$WP_PATH/wp-admin" "$BACKUP_DIR/wp-admin"
OLD_ADMIN_MOVED=1

mv -- "$WP_PATH/wp-includes" "$BACKUP_DIR/wp-includes"
OLD_INCLUDES_MOVED=1

while IFS= read -r file; do
    [[ -n "$file" ]] || continue

    if [[ -e "$WP_PATH/$file" || -L "$WP_PATH/$file" ]]; then
        mv -- "$WP_PATH/$file" "$BACKUP_DIR/$file"
        printf '%s\n' "$file" >> "$MOVED_OLD_ROOT_LIST"
    fi
done < "$ROOT_LIST"

echo "[+] Old xmlrpc.php removed from the live path."
echo "[+] Previous core retained temporarily for rollback."
echo "[*] Installing the new WordPress core..."

mv -- "$NEW_WP/wp-admin" "$WP_PATH/wp-admin"
NEW_ADMIN_INSTALLED=1

mv -- "$NEW_WP/wp-includes" "$WP_PATH/wp-includes"
NEW_INCLUDES_INSTALLED=1

while IFS= read -r file; do
    [[ -n "$file" ]] || continue

    printf '%s\n' "$file" >> "$INSTALLED_NEW_ROOT_LIST"
    mv -- "$NEW_WP/$file" "$WP_PATH/$file"
done < "$ROOT_LIST"

# Permissions only for newly installed core directories and files.
find "$WP_PATH/wp-admin" "$WP_PATH/wp-includes" \
    -type d -exec chmod 0755 {} +

find "$WP_PATH/wp-admin" "$WP_PATH/wp-includes" \
    -type f -exec chmod 0644 {} +

while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    chmod 0644 -- "$WP_PATH/$file"
done < "$INSTALLED_NEW_ROOT_LIST"

# Ownership only for newly installed core directories and files.
# No chown is executed on WP_PATH, wp-content, wp-config.php, .htaccess,
# robots.txt, or custom files.
echo "[*] Correcting ownership only for newly installed core files..."

chown -hR "$OWNER_UID:$OWNER_GID" \
    "$WP_PATH/wp-admin" \
    "$WP_PATH/wp-includes"

while IFS= read -r file; do
    [[ -n "$file" ]] || continue

    if [[ -e "$WP_PATH/$file" || -L "$WP_PATH/$file" ]]; then
        chown -h "$OWNER_UID:$OWNER_GID" "$WP_PATH/$file"
    fi
done < "$INSTALLED_NEW_ROOT_LIST"

REQUIRED_CORE_FILES=(
    "$WP_PATH/wp-admin/index.php"
    "$WP_PATH/wp-includes/version.php"
    "$WP_PATH/wp-settings.php"
    "$WP_PATH/xmlrpc.php"
)

for required_file in "${REQUIRED_CORE_FILES[@]}"; do
    if [[ ! -f "$required_file" || ! -s "$required_file" ]]; then
        echo "[-] Verification failed for: $required_file" >&2
        exit 1
    fi
done

INSTALLED_VERSION="$(read_wp_version "$WP_PATH" || true)"
if [[ "$INSTALLED_VERSION" != "$NEW_VERSION" ]]; then
    echo "[-] Installed version verification failed." >&2
    echo "    Expected: $NEW_VERSION" >&2
    echo "    Found:    ${INSTALLED_VERSION:-unknown}" >&2
    exit 1
fi

ROOT_UID_AFTER="$(stat -Lc '%u' "$WP_PATH")"
ROOT_GID_AFTER="$(stat -Lc '%g' "$WP_PATH")"
ROOT_OWNER_AFTER="$(stat -Lc '%U:%G' "$WP_PATH")"

if [[ "$ROOT_UID_AFTER" != "$ROOT_UID_BEFORE" ||
      "$ROOT_GID_AFTER" != "$ROOT_GID_BEFORE" ]]; then
    echo "[-] WordPress root ownership changed unexpectedly." >&2
    echo "    Before: $ROOT_OWNER_BEFORE" >&2
    echo "    After:  $ROOT_OWNER_AFTER" >&2
    exit 1
fi

XMLRPC_OWNER="$(stat -Lc '%U:%G' "$WP_PATH/xmlrpc.php")"
XMLRPC_MODE="$(stat -Lc '%a' "$WP_PATH/xmlrpc.php")"

echo "[+] New core files verified."
echo "[+] Database was not changed."
echo "[+] WordPress root owner remained unchanged: $ROOT_OWNER_AFTER"
echo "[+] New xmlrpc.php is present."
echo "[+] xmlrpc.php owner: $XMLRPC_OWNER"
echo "[+] xmlrpc.php mode: $XMLRPC_MODE"

rm -f -- "$MAINTENANCE_FILE"
MAINTENANCE_CREATED=0
UPDATE_FINISHED=1

# Old core and staging data are deleted only after successful verification.
rm -rf -- "$BACKUP_DIR"
BACKUP_DIR=""

rm -rf -- "$WORK_DIR"
WORK_DIR=""

rm -rf -- "$LOCK_DIR"

echo
echo "[+] WordPress core update completed successfully."
echo "[+] Previous version: ${OLD_VERSION:-unknown}"
echo "[+] Current version:  $INSTALLED_VERSION"
echo "[+] Database:         unchanged"
echo "[+] wp-content:       preserved; owner unchanged"
echo "[+] wp-config.php:    preserved; owner unchanged"
echo "[+] .htaccess:        preserved; owner unchanged"
echo "[+] robots.txt:       preserved; owner unchanged"
echo "[+] Custom files:     preserved; owner unchanged"
echo "[+] xmlrpc.php:       replaced with the new official file"
echo "[+] New core owner:   $OWNER_NAME"
echo "[+] WordPress root owner remained unchanged."
