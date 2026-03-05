#!/bin/bash
# check_default_password.sh
#
# Checks if the current user's password matches a known default/test password.
# If it does, prompts the user to change it. The user may dismiss the prompt
# and will be reminded again at every login until the password is changed.
#
# DEPLOY via JAMF: see JAMF_Deployment_Instructions.md
#
# CONFIGURE: Change DEFAULT_PASSWORD below to the test/default password to detect.

DEFAULT_PASSWORD="ChangeMe123"

# ── Helpers ────────────────────────────────────────────────────────────────────

get_logged_in_user() {
    stat -f "%Su" /dev/console
}

show_dialog() {
    local message="$1"
    local button="${2:-OK}"
    osascript \
        -e "tell application \"System Events\" to activate" \
        -e "display dialog \"$message\" buttons {\"$button\"} default button \"$button\" with title \"Password Change Required\" with icon caution" \
        2>/dev/null
}

# Shows the initial warning with "Change Password" and "Remind Me Later" buttons.
# Returns 0 if the user chooses to change, 1 if they dismiss.
prompt_initial() {
    local result
    result=$(osascript \
        -e "tell application \"System Events\" to activate" \
        -e "display dialog \"Your account is using a temporary default password.\n\nYou will be reminded at every login until your password is changed.\" buttons {\"Remind Me Later\", \"Change Password\"} default button \"Change Password\" with title \"Password Change Required\" with icon caution" \
        2>/dev/null)
    [[ "$result" == *"Change Password"* ]] && return 0 || return 1
}

# Prompts for a hidden password input with a Cancel option.
# Prints the entered text and returns 0, or returns 1 if the user cancels.
prompt_hidden() {
    local prompt="$1"
    local result
    result=$(osascript <<EOF 2>/dev/null
tell application "System Events"
    activate
    set r to display dialog "$prompt" with hidden answer default answer "" ¬
        buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" ¬
        with title "Password Change Required" with icon caution
    return text returned of r
end tell
EOF
    )
    local exit_code=$?
    [[ $exit_code -ne 0 ]] && return 1
    echo "$result"
    return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────

CURRENT_USER=$(get_logged_in_user)

# Skip root and empty user
if [[ -z "$CURRENT_USER" || "$CURRENT_USER" == "root" ]]; then
    exit 0
fi

# Check if the current user's password matches the default password
if ! dscl . -authonly "$CURRENT_USER" "$DEFAULT_PASSWORD" &>/dev/null; then
    # Password does NOT match the default — nothing to do
    exit 0
fi

# Show initial warning — exit if user chooses "Remind Me Later"
prompt_initial || exit 0

while true; do
    NEW_PASS=$(prompt_hidden "Enter your NEW password:")
    [[ $? -ne 0 ]] && exit 0  # User cancelled

    if [[ -z "$NEW_PASS" ]]; then
        show_dialog "Password cannot be empty. Please try again." "OK"
        continue
    fi

    if [[ "$NEW_PASS" == "$DEFAULT_PASSWORD" ]]; then
        show_dialog "Your new password cannot match the temporary password.\nPlease choose a different one." "OK"
        continue
    fi

    CONFIRM_PASS=$(prompt_hidden "Confirm your NEW password:")
    [[ $? -ne 0 ]] && exit 0  # User cancelled

    if [[ "$NEW_PASS" != "$CONFIRM_PASS" ]]; then
        show_dialog "Passwords do not match. Please try again." "OK"
        continue
    fi

    # Attempt to change the password via dscl
    if dscl . -passwd "/Users/$CURRENT_USER" "$DEFAULT_PASSWORD" "$NEW_PASS" &>/dev/null; then
        osascript \
            -e "tell application \"System Events\" to activate" \
            -e "display dialog \"Your password has been changed successfully.\" buttons {\"OK\"} default button \"OK\" with title \"Success\" with icon note" \
            2>/dev/null
        break
    else
        show_dialog "Failed to change password. Please try again." "OK"
    fi
done

exit 0
