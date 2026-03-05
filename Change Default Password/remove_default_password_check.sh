#!/bin/bash
# remove_default_password_check.sh
#
# Removes the default password enforcement LaunchAgent and script.
# Kills any active password change dialog for the current user.
#
# JAMF usage: deploy via Policy > Scripts, run as root.

PLIST_LABEL="com.admin.checkdefaultpassword"
PLIST_PATH="/Library/LaunchAgents/$PLIST_LABEL.plist"
SCRIPT_PATH="/usr/local/bin/check_default_password.sh"

CURRENT_USER=$(stat -f "%Su" /dev/console)
CURRENT_UID=$(id -u "$CURRENT_USER" 2>/dev/null)

# Unload and remove the LaunchAgent
if [[ -f "$PLIST_PATH" ]]; then
    if [[ -n "$CURRENT_UID" && "$CURRENT_USER" != "root" ]]; then
        launchctl bootout gui/"$CURRENT_UID" "$PLIST_PATH" 2>/dev/null
        echo "LaunchAgent unloaded for $CURRENT_USER."
    fi
    rm -f "$PLIST_PATH"
    echo "Removed: $PLIST_PATH"
else
    echo "LaunchAgent plist not found (already removed)."
fi

# Remove the enforcement script
if [[ -f "$SCRIPT_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
    echo "Removed: $SCRIPT_PATH"
else
    echo "Enforcement script not found (already removed)."
fi

# Kill any running instance of the script and dismiss any open dialog
if [[ -n "$CURRENT_USER" && "$CURRENT_USER" != "root" ]]; then
    # Kill the script process
    pkill -u "$CURRENT_USER" -f "check_default_password.sh" 2>/dev/null
    # Dismiss any osascript dialog spawned by the script
    pkill -u "$CURRENT_USER" -f "Password Change Required" 2>/dev/null
    launchctl asuser "$CURRENT_UID" pkill -f "Password Change Required" 2>/dev/null
    echo "Killed any active password prompt for $CURRENT_USER."
fi

echo "Done."
exit 0
