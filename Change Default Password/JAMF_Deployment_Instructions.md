# JAMF Deployment Instructions
## Force Password Change for Default/Test Passwords

This solution uses two components:

1. **`check_default_password.sh`** — uploaded directly to JAMF Scripts and deployed to each Mac
2. **`install_launchagent.sh`** — a small install script that writes the LaunchAgent plist and activates it

Keeping them separate means `check_default_password.sh` is the single source of truth — no duplicate scripts to keep in sync.

> **Note:** JAMF scripts run as root automatically — no "Run as" setting is needed.

---

## Step 1 — Upload the Enforcement Script

1. Go to **Settings > Computer Management > Scripts > New**
2. Fill in:
   - **Display Name:** `Check Default Password`
   - **Category:** (e.g. `Security`)
   - **Script tab:** paste the full contents of `check_default_password.sh`
3. Click **Save**

> **Important:** Set `DEFAULT_PASSWORD` on line 13 of the script to your actual default/test password before saving.

---

## Step 2 — Upload the LaunchAgent Install Script

1. Go to **Settings > Computer Management > Scripts > New**
2. Fill in:
   - **Display Name:** `Install Default Password LaunchAgent`
   - **Category:** (e.g. `Security`)
   - **Script tab:** paste the script below
3. Click **Save**

```bash
#!/bin/bash
# Writes the LaunchAgent plist that triggers check_default_password.sh at every login.

PLIST_PATH="/Library/LaunchAgents/com.admin.checkdefaultpassword.plist"

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

# Bootstrap for the currently logged-in user if present
LOGGED_IN_USER=$(stat -f "%Su" /dev/console)
if [[ -n "$LOGGED_IN_USER" && "$LOGGED_IN_USER" != "root" ]]; then
    LOGGED_IN_UID=$(id -u "$LOGGED_IN_USER")
    launchctl bootstrap gui/"$LOGGED_IN_UID" "$PLIST_PATH" 2>/dev/null || true
fi

echo "LaunchAgent installed."
exit 0
```

---

## Step 3 — Create a Policy

1. Go to **Computers > Policies > New**
2. **General tab:**
   - **Name:** `Deploy - Check Default Password`
   - **Trigger:** `Enrollment Complete` and/or `Recurring Check-in`
   - **Execution Frequency:** `Once per computer`
3. **Scripts tab** — add both scripts in order:
   - `Check Default Password` — Priority: **Before**
   - `Install Default Password LaunchAgent` — Priority: **After**
4. **Scope tab:** target **All Managed Computers** or a group (e.g. `New Enrollments`)
5. Click **Save**

> The enforcement script runs **Before** so it lands at `/usr/local/bin/check_default_password.sh` before the LaunchAgent plist is written.

---

## Step 4 — Test

1. Enroll a test Mac
2. Log in with the default password — confirm the prompt appears with **"Remind Me Later"** and **"Change Password"**
3. Click **"Remind Me Later"** — confirm the dialog closes and you can use the Mac normally
4. Log out and back in — confirm the prompt reappears
5. Change the password — confirm the success dialog appears
6. Log out and back in — confirm no prompt appears

---

## Removal

Deploy `remove_default_password_check.sh` via a JAMF policy or run it directly:

```bash
/usr/local/bin/remove_default_password_check.sh
```

---

## Files Reference

| File | Deployed to Mac at | Purpose |
|------|--------------------|---------|
| `check_default_password.sh` | `/usr/local/bin/check_default_password.sh` | Enforcement script — runs at every login |
| `com.admin.checkdefaultpassword.plist` | `/Library/LaunchAgents/com.admin.checkdefaultpassword.plist` | LaunchAgent — triggers the script at login |
| `remove_default_password_check.sh` | `/usr/local/bin/remove_default_password_check.sh` | Removal script |
