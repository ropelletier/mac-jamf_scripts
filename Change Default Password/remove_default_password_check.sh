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
LOCAL_COPY="/usr/local/bin/remove_default_password_check.sh"

CURRENT_USER=$(stat -f "%Su" /dev/console)
CURRENT_UID=$(id -u "$CURRENT_USER" 2>/dev/null)

# Save a local copy of this script so it can be run manually later
if [[ "$0" != "$LOCAL_COPY" ]]; then
    cp "$0" "$LOCAL_COPY"
    chmod 755 "$LOCAL_COPY"
    echo "Removal script saved to $LOCAL_COPY"
fi

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
    # Step 1: Kill the bash script first so it cannot spawn new dialogs
    pkill -KILL -u "$CURRENT_USER" -f "check_default_password" 2>/dev/null
    sleep 1

    # Step 2: Kill all osascript processes for the user
    pkill -KILL -u "$CURRENT_USER" osascript 2>/dev/null

    # Step 3: Kill System Events for the user — it renders the dialog windows
    launchctl asuser "$CURRENT_UID" pkill -KILL -f "System Events" 2>/dev/null
    pkill -KILL -u "$CURRENT_USER" -f "System Events" 2>/dev/null

    # Step 4: Final sweep in case any osascript survived
    sleep 1
    pkill -KILL -u "$CURRENT_USER" osascript 2>/dev/null

    echo "Killed all active password prompts for $CURRENT_USER."
fi

echo "Done."
exit 0
