#!/bin/bash
# JAMF_deploy_check_password.sh
#
# Single JAMF deployment script — paste into JAMF Pro > Scripts > Script tab.
# Writes check_default_password.sh and the LaunchAgent to each Mac,
# then activates the LaunchAgent for the currently logged-in user.
#
# CONFIGURE: Set DEFAULT_PASSWORD below before uploading to JAMF.

DEFAULT_PASSWORD="ChangeMe123"   # <-- SET THIS

SCRIPT_PATH="/usr/local/bin/check_default_password.sh"
PLIST_PATH="/Library/LaunchAgents/com.admin.checkdefaultpassword.plist"

# ── Write check_default_password.sh ───────────────────────────────────────────

cat > "$SCRIPT_PATH" <<SCRIPT
#!/bin/bash
# check_default_password.sh — managed by JAMF, do not edit manually.

DEFAULT_PASSWORD="${DEFAULT_PASSWORD}"

get_logged_in_user() { stat -f "%Su" /dev/console; }

# Displays a dialog. \$1=message \$2=primary button \$3=cancel button label (omit to hide cancel).
# Returns 0 if primary clicked, 1 if cancelled.
show_dialog() {
    local message="\$1" ok_button="\${2:-OK}" cancel_label="\$3"
    local buttons cancel_clause
    if [[ -n "\$cancel_label" ]]; then
        buttons="{\"\$cancel_label\", \"\$ok_button\"}"
        cancel_clause="cancel button \"\$cancel_label\""
    else
        buttons="{\"\$ok_button\"}"
        cancel_clause=""
    fi
    osascript \\
        -e "tell application \"System Events\" to activate" \\
        -e "display dialog \"\$message\" buttons \$buttons default button \"\$ok_button\" \$cancel_clause with title \"Password Change Required\" with icon caution" \\
        &>/dev/null
    return \$?
}

# Prompts for a hidden password input with Cancel and Continue buttons.
# Prints the entered text on success. Returns 1 if the user cancels.
prompt_hidden() {
    local result exit_code
    result=\$(osascript <<EOF 2>/dev/null
tell application "System Events"
    activate
    set r to display dialog "\$1" with hidden answer default answer "" ¬
        buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" ¬
        with title "Password Change Required" with icon caution
    return text returned of r
end tell
EOF
    )
    exit_code=\$?
    [[ \$exit_code -ne 0 ]] && return 1
    echo "\$result"
    return 0
}

CURRENT_USER=\$(get_logged_in_user)
[[ -z "\$CURRENT_USER" || "\$CURRENT_USER" == "root" ]] && exit 0
dscl . -authonly "\$CURRENT_USER" "\$DEFAULT_PASSWORD" &>/dev/null || exit 0

show_dialog "Your account is using a temporary default password.\\n\\nYou will be reminded at every login until your password is changed." "Change Password" "Remind Me Later" || exit 0

while true; do
    NEW_PASS=\$(prompt_hidden "Enter your NEW password:")
    [[ \$? -ne 0 ]] && exit 0

    if [[ -z "\$NEW_PASS" ]]; then
        show_dialog "Password cannot be empty. Please try again." "Try Again" "Cancel" || exit 0
        continue
    fi
    if [[ "\$NEW_PASS" == "\$DEFAULT_PASSWORD" ]]; then
        show_dialog "Your new password cannot match the temporary password.\\nPlease choose a different one." "Try Again" "Cancel" || exit 0
        continue
    fi

    CONFIRM_PASS=\$(prompt_hidden "Confirm your NEW password:")
    [[ \$? -ne 0 ]] && exit 0

    if [[ "\$NEW_PASS" != "\$CONFIRM_PASS" ]]; then
        show_dialog "Passwords do not match. Please try again." "Try Again" "Cancel" || exit 0
        continue
    fi

    if dscl . -passwd "/Users/\$CURRENT_USER" "\$DEFAULT_PASSWORD" "\$NEW_PASS" &>/dev/null; then
        osascript \\
            -e "tell application \"System Events\" to activate" \\
            -e "display dialog \"Your password has been changed successfully.\" buttons {\"OK\"} default button \"OK\" with title \"Success\" with icon note" \\
            2>/dev/null
        break
    else
        show_dialog "Failed to change password. Please try again." "Try Again" "Cancel" || exit 0
    fi
done
exit 0
SCRIPT

chown root:wheel "$SCRIPT_PATH"
chmod 755 "$SCRIPT_PATH"
echo "Wrote: $SCRIPT_PATH"

# ── Write the LaunchAgent plist ───────────────────────────────────────────────

cat > "$PLIST_PATH" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.admin.checkdefaultpassword</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/usr/local/bin/check_default_password.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LaunchOnlyOnce</key>
    <false/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
</dict>
</plist>
PLIST

chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"
echo "Wrote: $PLIST_PATH"

# ── Bootstrap the LaunchAgent for the currently logged-in user ────────────────

LOGGED_IN_USER=$(stat -f "%Su" /dev/console)
if [[ -n "$LOGGED_IN_USER" && "$LOGGED_IN_USER" != "root" ]]; then
    LOGGED_IN_UID=$(id -u "$LOGGED_IN_USER")
    launchctl bootstrap gui/"$LOGGED_IN_UID" "$PLIST_PATH" 2>/dev/null || true
    echo "LaunchAgent bootstrapped for $LOGGED_IN_USER."
fi

echo "Deployment complete."
exit 0
