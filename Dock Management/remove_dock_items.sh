#!/bin/bash
# remove_dock_items.sh
#
# Manages the Dock for the current user by adding and removing items.
# Configuration is loaded from a JSON file hosted on GitHub.
# Per-machine exceptions are supported by serial number.
# Uses dockutil — downloads and installs it automatically if not present.
#
# JAMF usage: deploy via Policy > Scripts, run as root at login or enrollment.

# ── Config ─────────────────────────────────────────────────────────────────────

# Raw GitHub URL to your dock_config.json file.
# Example: https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/Dock%20Management/dock_config.json
CONFIG_URL=""

DOCKUTIL="/usr/local/bin/dockutil"
DOCKUTIL_API="https://api.github.com/repos/kcrawford/dockutil/releases/latest"

# ── Fallback lists ─────────────────────────────────────────────────────────────
# Used only if CONFIG_URL is empty or the file cannot be fetched.

FALLBACK_ADD=(
    "/Applications/Google Chrome.app"
)

FALLBACK_REMOVE=(
    "Maps"
    "Messages"
    "Photos"
    "FaceTime"
    "Contacts"
    "Calendar"
    "Reminders"
    "Notes"
    "TV"
    "Music"
    "Podcasts"
    "News"
    "App Store"
    "Freeform"
)

# ── Functions ──────────────────────────────────────────────────────────────────

install_dockutil() {
    echo "dockutil not found. Attempting to download and install..."

    PKG_URL=$(python3 -c "
import urllib.request, json
with urllib.request.urlopen('$DOCKUTIL_API') as r:
    data = json.load(r)
    for a in data.get('assets', []):
        if a['name'].endswith('.pkg'):
            print(a['browser_download_url'])
            break
" 2>/dev/null)

    if [[ -z "$PKG_URL" ]]; then
        echo "ERROR: Could not retrieve dockutil download URL. Check network connectivity."
        exit 1
    fi

    TMP_PKG=$(mktemp /tmp/dockutil_XXXXXX.pkg)

    echo "Downloading dockutil from: $PKG_URL"
    if ! curl -fsSL "$PKG_URL" -o "$TMP_PKG"; then
        echo "ERROR: Failed to download dockutil."
        rm -f "$TMP_PKG"
        exit 1
    fi

    echo "Installing dockutil..."
    if ! installer -pkg "$TMP_PKG" -target /; then
        echo "ERROR: Failed to install dockutil."
        rm -f "$TMP_PKG"
        exit 1
    fi

    rm -f "$TMP_PKG"

    if [[ ! -x "$DOCKUTIL" ]]; then
        echo "ERROR: dockutil still not found after install."
        exit 1
    fi

    echo "dockutil installed successfully."
}

# Downloads dock_config.json from GitHub, applies serial number exceptions,
# and populates ITEMS_TO_ADD and ITEMS_TO_REMOVE.
# Returns 1 if config could not be loaded (caller falls back to hardcoded lists).
load_config() {
    local serial="$1"
    local tmp_config
    tmp_config=$(mktemp /tmp/dock_config_XXXXXX.json)

    if ! curl -fsSL "$CONFIG_URL" -o "$tmp_config" 2>/dev/null; then
        echo "Warning: Could not fetch config from GitHub. Using fallback lists."
        rm -f "$tmp_config"
        return 1
    fi

    local parsed
    parsed=$(python3 - "$tmp_config" "$serial" <<'PYEOF'
import json, sys

config_file = sys.argv[1]
serial      = sys.argv[2]

with open(config_file) as f:
    config = json.load(f)

add_list    = config.get("add", [])
remove_list = config.get("remove", [])
exceptions  = config.get("exceptions", {})

if serial in exceptions:
    exc = exceptions[serial]
    if exc.get("skip", False):
        print("SKIP")
        sys.exit(0)
    # Override lists only for the keys present in the exception block
    if "add"    in exc: add_list    = exc["add"]
    if "remove" in exc: remove_list = exc["remove"]

print("ADD:"    + "|".join(add_list))
print("REMOVE:" + "|".join(remove_list))
PYEOF
    )

    rm -f "$tmp_config"

    if [[ "$parsed" == "SKIP" ]]; then
        echo "Serial $serial is in the exceptions list with skip=true. No changes will be made."
        exit 0
    fi

    local add_line remove_line
    add_line=$(echo "$parsed"    | grep "^ADD:")
    remove_line=$(echo "$parsed" | grep "^REMOVE:")

    IFS='|' read -r -a ITEMS_TO_ADD    <<< "${add_line#ADD:}"
    IFS='|' read -r -a ITEMS_TO_REMOVE <<< "${remove_line#REMOVE:}"

    return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Ensure dockutil is available
if [[ ! -x "$DOCKUTIL" ]]; then
    install_dockutil
fi

# Get the currently logged-in user
CURRENT_USER=$(stat -f "%Su" /dev/console)

if [[ -z "$CURRENT_USER" || "$CURRENT_USER" == "root" ]]; then
    echo "ERROR: No user logged in or running as root user."
    exit 1
fi

USER_HOME="/Users/$CURRENT_USER"
DOCK_PLIST="$USER_HOME/Library/Preferences/com.apple.dock.plist"

if [[ ! -f "$DOCK_PLIST" ]]; then
    echo "ERROR: Dock plist not found for user $CURRENT_USER"
    exit 1
fi

# Load config from GitHub or fall back to hardcoded lists
SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $NF}')
echo "Machine serial: $SERIAL"

if [[ -n "$CONFIG_URL" ]] && load_config "$SERIAL"; then
    echo "Config loaded from GitHub."
else
    echo "Using fallback lists."
    ITEMS_TO_ADD=("${FALLBACK_ADD[@]}")
    ITEMS_TO_REMOVE=("${FALLBACK_REMOVE[@]}")
fi

echo "Updating Dock for user: $CURRENT_USER"

# Add items
for APP in "${ITEMS_TO_ADD[@]}"; do
    [[ -z "$APP" ]] && continue
    if [[ -d "$APP" ]]; then
        if "$DOCKUTIL" --find "$(basename "$APP" .app)" "$DOCK_PLIST" &>/dev/null; then
            echo "  Already in Dock (skipped): $(basename "$APP" .app)"
        else
            "$DOCKUTIL" --add "$APP" --no-restart "$DOCK_PLIST"
            echo "  Added: $(basename "$APP" .app)"
        fi
    else
        echo "  App not installed (skipped): $APP"
    fi
done

# Remove items
for ITEM in "${ITEMS_TO_REMOVE[@]}"; do
    [[ -z "$ITEM" ]] && continue
    if "$DOCKUTIL" --find "$ITEM" "$DOCK_PLIST" &>/dev/null; then
        "$DOCKUTIL" --remove "$ITEM" --no-restart "$DOCK_PLIST"
        echo "  Removed: $ITEM"
    else
        echo "  Not found (skipped): $ITEM"
    fi
done

# Restart the Dock to apply changes
CURRENT_UID=$(id -u "$CURRENT_USER")
launchctl asuser "$CURRENT_UID" killall Dock

echo "Done. Dock restarted for $CURRENT_USER."
exit 0
