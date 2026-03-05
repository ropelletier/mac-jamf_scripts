# JAMF Deployment Instructions
## Force Password Change for Default/Test Passwords

A single script (`JAMF_deploy_check_password.sh`) handles everything — paste it into JAMF and it writes both the enforcement script and LaunchAgent to each Mac.

> **Note:** JAMF scripts run as root automatically.

---

## Step 1 — Upload the Script to JAMF

1. Go to **Settings > Computer Management > Scripts > New**
2. Fill in:
   - **Display Name:** `Deploy - Check Default Password`
   - **Category:** (e.g. `Security`)
   - **Script tab:** paste the full contents of `JAMF_deploy_check_password.sh`
3. Set `DEFAULT_PASSWORD` on line 7 to your actual default/test password
4. Click **Save**

---

## Step 2 — Create a Policy

1. Go to **Computers > Policies > New**
2. **General tab:**
   - **Name:** `Deploy - Check Default Password`
   - **Trigger:** `Enrollment Complete` and/or `Recurring Check-in`
   - **Execution Frequency:** `Once per computer`
3. **Scripts tab:** add `Deploy - Check Default Password`, Priority: **After**
4. **Scope tab:** target **All Managed Computers** or a group (e.g. `New Enrollments`)
5. Click **Save**

---

## Step 3 — Test

1. Enroll a test Mac
2. Log in with the default password — confirm the prompt appears with **"Remind Me Later"** and **"Change Password"**
3. Click **"Remind Me Later"** — confirm the dialog closes and the Mac is usable
4. Log out and back in — confirm the prompt reappears
5. Change the password — confirm the success dialog appears
6. Log out and back in — confirm no prompt appears

---

## Removal

Deploy `remove_default_password_check.sh` via a JAMF policy, or run it directly on the Mac:

```bash
/usr/local/bin/remove_default_password_check.sh
```

---

## Files Reference

| Repo File | Deployed to Mac at | Purpose |
|-----------|--------------------|---------|
| `JAMF_deploy_check_password.sh` | — | Paste into JAMF Scripts; writes the two files below |
| *(written by deploy script)* | `/usr/local/bin/check_default_password.sh` | Enforcement script — runs at every login |
| *(written by deploy script)* | `/Library/LaunchAgents/com.admin.checkdefaultpassword.plist` | LaunchAgent — triggers the script at login |
| `remove_default_password_check.sh` | `/usr/local/bin/remove_default_password_check.sh` | Removal script |
