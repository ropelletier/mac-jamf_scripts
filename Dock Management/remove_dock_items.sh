#!/bin/bash
# remove_dock_items.sh
#
# Manages the Dock for the current user by adding and removing items.
# Configuration is loaded from a JSON file hosted on GitHub.
# Per-machine exceptions are supported by serial number.
# Uses dockutil — downloads and installs it automatically using native macOS
# tools (curl, Python 3, installer) if not already present.
#
# JAMF usage: deploy via Policy > Scripts, run as root at login or enrollment.

# ── Config ─────────────────────────────────────────────────────────────────────

# Raw GitHub URL to your dock_config.json file.
# Example: https://raw.githubusercontent.com/ropelletier/mac-jamf_scripts/main/Dock%20Management/dock_config.json
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

    # Fetch latest release .pkg URL using Python 3 (native on macOS)
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
# and populates ITEMS_TO_ADD and ITEMS_TO_REMOVE. Returns 1 on failure.
load_config() {
    local serial="$1"
    local tmp_json tmp_plist
    tmp_json=$(mktemp /tmp/dock_config_XXXXXX.json)
    tmp_plist=$(mktemp /tmp/dock_config_XXXXXX.plist)

    if ! curl -fsSL "$CONFIG_URL" -o "$tmp_json" 2>/dev/null; then
        echo "Warning: Could not fetch config from GitHub. Using fallback lists."
        rm -f "$tmp_json" "$tmp_plist"
        return 1
    fi

    # Convert JSON to XML plist so PlistBuddy can parse it
    if ! plutil -convert xml1 "$tmp_json" -o "$tmp_plist" 2>/dev/null; then
        echo "Warning: Config file is not valid JSON. Using fallback lists."
        rm -f "$tmp_json" "$tmp_plist"
        return 1
    fi
    rm -f "$tmp_json"

    # Check for skip exception
    local skip
    skip=$(/usr/libexec/PlistBuddy -c "Print :exceptions:$serial:skip" "$tmp_plist" 2>/dev/null)
    if [[ "$skip" == "true" ]]; then
        echo "Serial $serial is marked skip=true in config. No changes will be made."
        rm -f "$tmp_plist"
        exit 0
    fi

    # Determine which keys to read (exception override or global)
    local add_key="add" remove_key="remove"
    /usr/libexec/PlistBuddy -c "Print :exceptions:$serial:add:"    "$tmp_plist" &>/dev/null && add_key="exceptions:$serial:add"
    /usr/libexec/PlistBuddy -c "Print :exceptions:$serial:remove:" "$tmp_plist" &>/dev/null && remove_key="exceptions:$serial:remove"

    local count i item
    count=$(/usr/libexec/PlistBuddy -c "Print :$add_key:" "$tmp_plist" 2>/dev/null | grep -c "string")
    ITEMS_TO_ADD=()
    for ((i=0; i<count; i++)); do
        item=$(/usr/libexec/PlistBuddy -c "Print :$add_key:$i" "$tmp_plist" 2>/dev/null)
        [[ -n "$item" ]] && ITEMS_TO_ADD+=("$item")
    done

    count=$(/usr/libexec/PlistBuddy -c "Print :$remove_key:" "$tmp_plist" 2>/dev/null | grep -c "string")
    ITEMS_TO_REMOVE=()
    for ((i=0; i<count; i++)); do
        item=$(/usr/libexec/PlistBuddy -c "Print :$remove_key:$i" "$tmp_plist" 2>/dev/null)
        [[ -n "$item" ]] && ITEMS_TO_REMOVE+=("$item")
    done

    rm -f "$tmp_plist"
    return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Ensure dockutil is available, downloading and installing it if necessary
if [[ ! -x "$DOCKUTIL" ]]; then
    install_dockutil
fi

# Get the currently logged-in user
CURRENT_USER=$(stat -f "%Su" /dev/console)

if [[ -z "$CURRENT_USER" || "$CURRENT_USER" == "root" ]]; then
    echo "ERROR: No user logged in or running as root user."
    exit 1
fi

DOCK_PLIST="/Users/$CURRENT_USER/Library/Preferences/com.apple.dock.plist"

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
    if [[ ! -d "$APP" ]]; then
        echo "  App not installed (skipped): $APP"
    elif "$DOCKUTIL" --find "$(basename "$APP" .app)" "$DOCK_PLIST" &>/dev/null; then
        echo "  Already in Dock (skipped): $(basename "$APP" .app)"
    else
        "$DOCKUTIL" --add "$APP" --no-restart "$DOCK_PLIST"
        echo "  Added: $(basename "$APP" .app)"
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
launchctl asuser "$(id -u "$CURRENT_USER")" killall Dock

echo "Done. Dock restarted for $CURRENT_USER."
exit 0
