#!/bin/bash
# JAMF_dock_deploy.sh
#
# Single-file JAMF deployment script for Dock management.
# Paste the entire contents of this file into JAMF Pro > Scripts > Script tab.
#
# Uses dockutil for dock management. If dockutil is not installed, it is
# downloaded and installed automatically using only native macOS tools
# (Python 3, curl, installer) — no manual pre-deployment required.
#
# CONFIGURE the sections marked with <-- before uploading to JAMF.

# ── Config ─────────────────────────────────────────────────────────────────────

# Optional: Raw GitHub URL to a dock_config.json for centralized config.
# Leave empty to use only the lists defined below.
# Example: https://raw.githubusercontent.com/ropelletier/mac-jamf_scripts/main/Dock%20Management/dock_config.json
CONFIG_URL=""   # <-- SET THIS or leave empty

DOCKUTIL="/usr/local/bin/dockutil"
DOCKUTIL_API="https://api.github.com/repos/kcrawford/dockutil/releases/latest"

# ── Items to add  <-- EDIT THIS LIST ──────────────────────────────────────────
FALLBACK_ADD=(
    "/Applications/Google Chrome.app"
)

# ── Items to remove  <-- EDIT THIS LIST ───────────────────────────────────────
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

# ── Serial number exceptions  <-- EDIT THIS LIST ──────────────────────────────
# Machines listed here will be skipped entirely. Add one serial per line.
SKIP_SERIALS=(
    "SERIALNUMBER1"
    "SERIALNUMBER2"
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

    if ! plutil -convert xml1 "$tmp_json" -o "$tmp_plist" 2>/dev/null; then
        echo "Warning: Config file is not valid JSON. Using fallback lists."
        rm -f "$tmp_json" "$tmp_plist"
        return 1
    fi
    rm -f "$tmp_json"

    local skip
    skip=$(/usr/libexec/PlistBuddy -c "Print :exceptions:$serial:skip" "$tmp_plist" 2>/dev/null)
    if [[ "$skip" == "true" ]]; then
        echo "Serial $serial is marked skip=true in config. No changes will be made."
        rm -f "$tmp_plist"
        exit 0
    fi

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

# Ensure dockutil is available
if [[ ! -x "$DOCKUTIL" ]]; then
    install_dockutil
fi

CURRENT_USER=$(stat -f "%Su" /dev/console)
if [[ -z "$CURRENT_USER" || "$CURRENT_USER" == "root" ]]; then
    echo "ERROR: No user logged in or running as root."
    exit 1
fi

DOCK_PLIST="/Users/$CURRENT_USER/Library/Preferences/com.apple.dock.plist"
if [[ ! -f "$DOCK_PLIST" ]]; then
    echo "ERROR: Dock plist not found for $CURRENT_USER"
    exit 1
fi

SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $NF}')
echo "Machine serial: $SERIAL"

# Check SKIP_SERIALS list
for SKIP in "${SKIP_SERIALS[@]}"; do
    if [[ "$SERIAL" == "$SKIP" ]]; then
        echo "Serial $SERIAL is in the skip list. No changes will be made."
        exit 0
    fi
done

# Load config from GitHub or fall back to hardcoded lists
if [[ -n "$CONFIG_URL" ]] && load_config "$SERIAL"; then
    echo "Config loaded from GitHub."
else
    echo "Using fallback lists."
    ITEMS_TO_ADD=("${FALLBACK_ADD[@]}")
    ITEMS_TO_REMOVE=("${FALLBACK_REMOVE[@]}")
fi

echo "Updating Dock for: $CURRENT_USER"

for APP in "${ITEMS_TO_ADD[@]}"; do
    [[ -z "$APP" ]] && continue
    if [[ ! -d "$APP" ]]; then
        echo "  Not installed (skipped): $APP"
    elif "$DOCKUTIL" --find "$(basename "$APP" .app)" "$DOCK_PLIST" &>/dev/null; then
        echo "  Already in Dock (skipped): $(basename "$APP" .app)"
    else
        "$DOCKUTIL" --add "$APP" --no-restart "$DOCK_PLIST"
        echo "  Added: $(basename "$APP" .app)"
    fi
done

for ITEM in "${ITEMS_TO_REMOVE[@]}"; do
    [[ -z "$ITEM" ]] && continue
    if "$DOCKUTIL" --find "$ITEM" "$DOCK_PLIST" &>/dev/null; then
        "$DOCKUTIL" --remove "$ITEM" --no-restart "$DOCK_PLIST"
        echo "  Removed: $ITEM"
    else
        echo "  Not found (skipped): $ITEM"
    fi
done

launchctl asuser "$(id -u "$CURRENT_USER")" killall Dock
echo "Done. Dock restarted for $CURRENT_USER."
exit 0
