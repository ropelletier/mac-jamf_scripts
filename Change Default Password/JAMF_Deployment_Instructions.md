# JAMF Deployment Instructions
## Force Password Change for Default/Test Passwords

This solution deploys a single JAMF script that writes both the enforcement script and LaunchAgent directly to the Mac.

> **Note:** JAMF scripts run from a temporary directory and are deleted after execution — they do not get saved to a location on the Mac. To deploy a file to a persistent path, the script must write it there itself. That is exactly what the combined script below does.

---

## Step 1 — Create the Script in JAMF

1. Go to **Settings > Computer Management > Scripts > New**
2. Fill in:
   - **Display Name:** `Deploy - Check Default Password`
   - **Category:** (your choice, e.g. `Security`)
   - **Script tab:** paste the full combined script from Step 2 below
3. Click **Save**

> **Note:** JAMF Pro runs all policy scripts as root automatically — no "Run as" setting is needed.

> **Important:** Set `DEFAULT_PASSWORD` on line 4 of the script to your actual default/test password before saving.

---

## Step 2 — The Combined Deployment Script

Paste this into the Script tab. It writes both the enforcement script and the LaunchAgent to the Mac, then activates it immediately for any currently logged-in user.

```bash
#!/bin/bash
# Full deployment: writes the enforcement script and installs the LaunchAgent.
DEFAULT_PASSWORD="ChangeMe123"   # <-- SET THIS TO YOUR DEFAULT PASSWORD

SCRIPT_PATH="/usr/local/bin/check_default_password.sh"
PLIST_PATH="/Library/LaunchAgents/com.admin.checkdefaultpassword.plist"

# ── Write the enforcement script ──────────────────────────────────────────────
cat > "$SCRIPT_PATH" <<SCRIPT
#!/bin/bash
DEFAULT_PASSWORD="$DEFAULT_PASSWORD"

get_logged_in_user() { stat -f "%Su" /dev/console; }

show_dialog() {
    local message="\$1" button="\${2:-OK}"
    osascript -e "tell application \"System Events\" to activate" \
              -e "display dialog \"\$message\" buttons {\"\$button\"} default button \"\$button\" with title \"Password Change Required\" with icon caution" 2>/dev/null
}

prompt_hidden() {
    osascript <<EOF 2>/dev/null
tell application "System Events"
    activate
    set r to display dialog "\$1" with hidden answer default answer "" buttons {"Continue"} default button "Continue" with title "Password Change Required" with icon caution
    return text returned of r
end tell
EOF
}

CURRENT_USER=\$(get_logged_in_user)
[[ -z "\$CURRENT_USER" || "\$CURRENT_USER" == "root" ]] && exit 0
dscl . -authonly "\$CURRENT_USER" "\$DEFAULT_PASSWORD" &>/dev/null || exit 0

show_dialog "Your account is using a temporary default password.\n\nYou must set a new password before you can continue." "OK"

while true; do
    NEW_PASS=\$(prompt_hidden "Enter your NEW password:")
    [[ -z "\$NEW_PASS" ]] && { show_dialog "Password cannot be empty. Please try again." "OK"; continue; }
    [[ "\$NEW_PASS" == "\$DEFAULT_PASSWORD" ]] && { show_dialog "New password cannot match the temporary password." "OK"; continue; }
    CONFIRM_PASS=\$(prompt_hidden "Confirm your NEW password:")
    [[ "\$NEW_PASS" != "\$CONFIRM_PASS" ]] && { show_dialog "Passwords do not match. Please try again." "OK"; continue; }
    if dscl . -passwd "/Users/\$CURRENT_USER" "\$DEFAULT_PASSWORD" "\$NEW_PASS" &>/dev/null; then
        osascript -e "tell application \"System Events\" to activate" \
                  -e "display dialog \"Your password has been changed successfully.\" buttons {\"OK\"} default button \"OK\" with title \"Success\" with icon note" 2>/dev/null
        break
    else
        show_dialog "Failed to change password. Please try again." "OK"
    fi
done
exit 0
SCRIPT

chown root:wheel "$SCRIPT_PATH"
chmod 755 "$SCRIPT_PATH"

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

# ── Bootstrap the LaunchAgent for the current user ────────────────────────────
LOGGED_IN_USER=$(stat -f "%Su" /dev/console)
if [ -n "$LOGGED_IN_USER" ] && [ "$LOGGED_IN_USER" != "root" ]; then
    LOGGED_IN_UID=$(id -u "$LOGGED_IN_USER")
    launchctl bootstrap gui/"$LOGGED_IN_UID" "$PLIST_PATH" 2>/dev/null || true
fi

echo "Deployment complete."
exit 0
```

---

## Step 3 — Create a Policy

1. Go to **Computers > Policies > New**
2. **General tab:**
   - **Name:** `Deploy - Check Default Password`
   - **Trigger:** `Enrollment Complete` and/or `Recurring Check-in`
   - **Execution Frequency:** `Once per computer`
3. **Scripts tab:**
   - Click **Configure** and add `Deploy - Check Default Password`
   - **Priority:** `After`
4. **Scope tab:**
   - Target **All Managed Computers** or a specific group (e.g. `New Enrollments`)
5. Click **Save**

---

## Step 4 — Test

1. Enroll a test Mac
2. Log in with the default password
3. Confirm the password change dialog appears
4. Change the password and verify login works normally afterward
5. Log out and back in — confirm no dialog appears (password no longer matches the default)

---

## Removal

Run the following via a JAMF script or Remote Command to uninstall:

```bash
LOGGED_IN_UID=$(id -u "$(stat -f "%Su" /dev/console)")
launchctl bootout gui/"$LOGGED_IN_UID" /Library/LaunchAgents/com.admin.checkdefaultpassword.plist 2>/dev/null
rm -f /Library/LaunchAgents/com.admin.checkdefaultpassword.plist
rm -f /usr/local/bin/check_default_password.sh
```

---

## Files Reference

| File | Deployed Location on Mac | Purpose |
|------|--------------------------|---------|
| `check_default_password.sh` | `/usr/local/bin/check_default_password.sh` | Enforcement script (runs at login) |
| `com.admin.checkdefaultpassword.plist` | `/Library/LaunchAgents/com.admin.checkdefaultpassword.plist` | LaunchAgent login trigger |
