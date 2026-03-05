#!/bin/bash
# JAMF_dock_deploy.sh
#
# Single-file JAMF deployment script for Dock management.
# Paste the entire contents of this file into JAMF Pro > Scripts > Script tab.
#
# CONFIGURE the sections marked with <-- before uploading to JAMF.
# No external dependencies — uses only tools built into macOS.

# ── Config ─────────────────────────────────────────────────────────────────────

# Optional: Raw GitHub URL to a dock_config.json for centralized config.
# Leave empty to use only the lists defined below.
# Example: https://raw.githubusercontent.com/ropelletier/mac-jamf_scripts/main/Dock%20Management/dock_config.json
CONFIG_URL=""   # <-- SET THIS or leave empty

PLISTBUDDY="/usr/libexec/PlistBuddy"

# ── Items to add  <-- EDIT THIS LIST ──────────────────────────────────────────
# Full /Applications path to each app. Added in order listed.
FALLBACK_ADD=(
    "/Applications/Google Chrome.app"
)

# ── Items to remove  <-- EDIT THIS LIST ───────────────────────────────────────
# App name exactly as shown in the Dock (case-sensitive).
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

# ── Dock helper functions ───────────────────────────────────────────────────────

dock_has_item() {
    local label="$1" count i item_label
    count=$("$PLISTBUDDY" -c "Print :persistent-apps:" "$DOCK_PLIST" 2>/dev/null | grep -c "Dict")
    for ((i=0; i<count; i++)); do
        item_label=$("$PLISTBUDDY" -c "Print :persistent-apps:$i:tile-data:file-label" "$DOCK_PLIST" 2>/dev/null)
        [[ "$item_label" == "$label" ]] && return 0
    done
    return 1
}

dock_remove_item() {
    local label="$1" count i item_label
    count=$("$PLISTBUDDY" -c "Print :persistent-apps:" "$DOCK_PLIST" 2>/dev/null | grep -c "Dict")
    for ((i=count-1; i>=0; i--)); do
        item_label=$("$PLISTBUDDY" -c "Print :persistent-apps:$i:tile-data:file-label" "$DOCK_PLIST" 2>/dev/null)
        if [[ "$item_label" == "$label" ]]; then
            "$PLISTBUDDY" -c "Delete :persistent-apps:$i" "$DOCK_PLIST"
            return 0
        fi
    done
    return 1
}

dock_add_item() {
    local app_path="$1" app_name idx
    app_name=$(basename "$app_path" .app)
    idx=$("$PLISTBUDDY" -c "Print :persistent-apps:" "$DOCK_PLIST" 2>/dev/null | grep -c "Dict")
    "$PLISTBUDDY" \
        -c "Add :persistent-apps: dict" \
        -c "Add :persistent-apps:$idx:tile-type string application-tile" \
        -c "Add :persistent-apps:$idx:tile-data dict" \
        -c "Add :persistent-apps:$idx:tile-data:file-label string $app_name" \
        -c "Add :persistent-apps:$idx:tile-data:file-data dict" \
        -c "Add :persistent-apps:$idx:tile-data:file-data:_CFURLString string file://$app_path/" \
        -c "Add :persistent-apps:$idx:tile-data:file-data:_CFURLStringType integer 15" \
        "$DOCK_PLIST" 2>/dev/null
}

# ── Config loader ───────────────────────────────────────────────────────────────

load_config() {
    local serial="$1" tmp_json tmp_plist
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

    # Check for skip exception in config file
    local skip
    skip=$("$PLISTBUDDY" -c "Print :exceptions:$serial:skip" "$tmp_plist" 2>/dev/null)
    if [[ "$skip" == "true" ]]; then
        echo "Serial $serial is marked skip=true in config. No changes will be made."
        rm -f "$tmp_plist"
        exit 0
    fi

    local add_key="add" remove_key="remove"
    "$PLISTBUDDY" -c "Print :exceptions:$serial:add:"    "$tmp_plist" &>/dev/null && add_key="exceptions:$serial:add"
    "$PLISTBUDDY" -c "Print :exceptions:$serial:remove:" "$tmp_plist" &>/dev/null && remove_key="exceptions:$serial:remove"

    local count i item
    count=$("$PLISTBUDDY" -c "Print :$add_key:" "$tmp_plist" 2>/dev/null | grep -c "string")
    ITEMS_TO_ADD=()
    for ((i=0; i<count; i++)); do
        item=$("$PLISTBUDDY" -c "Print :$add_key:$i" "$tmp_plist" 2>/dev/null)
        [[ -n "$item" ]] && ITEMS_TO_ADD+=("$item")
    done

    count=$("$PLISTBUDDY" -c "Print :$remove_key:" "$tmp_plist" 2>/dev/null | grep -c "string")
    ITEMS_TO_REMOVE=()
    for ((i=0; i<count; i++)); do
        item=$("$PLISTBUDDY" -c "Print :$remove_key:$i" "$tmp_plist" 2>/dev/null)
        [[ -n "$item" ]] && ITEMS_TO_REMOVE+=("$item")
    done

    rm -f "$tmp_plist"
    return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────

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
    elif dock_has_item "$(basename "$APP" .app)"; then
        echo "  Already in Dock (skipped): $(basename "$APP" .app)"
    else
        dock_add_item "$APP" && echo "  Added: $(basename "$APP" .app)"
    fi
done

for ITEM in "${ITEMS_TO_REMOVE[@]}"; do
    [[ -z "$ITEM" ]] && continue
    if dock_has_item "$ITEM"; then
        dock_remove_item "$ITEM" && echo "  Removed: $ITEM"
    else
        echo "  Not found (skipped): $ITEM"
    fi
done

launchctl asuser "$(id -u "$CURRENT_USER")" killall Dock
echo "Done. Dock restarted for $CURRENT_USER."
exit 0
