#!/bin/bash
# check_default_password.sh
#
# Checks if the current user's password matches a known default/test password.
# If it does, prompts the user to change it. The user may dismiss the prompt
# at any point and will be reminded again at every login until the password
# is changed.
#
# DEPLOY via JAMF: see JAMF_Deployment_Instructions.md
#
# CONFIGURE: Change DEFAULT_PASSWORD below to the test/default password to detect.

DEFAULT_PASSWORD="ChangeMe123"

# ── Helpers ────────────────────────────────────────────────────────────────────

get_logged_in_user() {
    stat -f "%Su" /dev/console
}

# Displays a dialog. $1=message $2=primary button $3=cancel button label (omit to hide cancel).
# Returns 0 if primary clicked, 1 if cancelled.
show_dialog() {
    local message="$1"
    local ok_button="${2:-OK}"
    local cancel_label="$3"

    local buttons cancel_clause
    if [[ -n "$cancel_label" ]]; then
        buttons="{\"$cancel_label\", \"$ok_button\"}"
        cancel_clause="cancel button \"$cancel_label\""
    else
        buttons="{\"$ok_button\"}"
        cancel_clause=""
    fi

    osascript \
        -e "tell application \"System Events\" to activate" \
        -e "display dialog \"$message\" buttons $buttons default button \"$ok_button\" $cancel_clause with title \"Password Change Required\" with icon caution" \
        &>/dev/null
    return $?
}

# Prompts for a hidden password input with Cancel and Continue buttons.
# Prints the entered text on success. Returns 1 if the user cancels.
prompt_hidden() {
    local prompt="$1"
    local result exit_code

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
    exit_code=$?

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
    exit 0
fi

# Show initial warning — exit if user clicks "Remind Me Later"
show_dialog "Your account is using a temporary default password.\n\nYou will be reminded at every login until your password is changed." "Change Password" "Remind Me Later" || exit 0

while true; do
    NEW_PASS=$(prompt_hidden "Enter your NEW password:")
    [[ $? -ne 0 ]] && exit 0

    if [[ -z "$NEW_PASS" ]]; then
        show_dialog "Password cannot be empty. Please try again." "Try Again" "Cancel" || exit 0
        continue
    fi

    if [[ "$NEW_PASS" == "$DEFAULT_PASSWORD" ]]; then
        show_dialog "Your new password cannot match the temporary password.\nPlease choose a different one." "Try Again" "Cancel" || exit 0
        continue
    fi

    CONFIRM_PASS=$(prompt_hidden "Confirm your NEW password:")
    [[ $? -ne 0 ]] && exit 0

    if [[ "$NEW_PASS" != "$CONFIRM_PASS" ]]; then
        show_dialog "Passwords do not match. Please try again." "Try Again" "Cancel" || exit 0
        continue
    fi

    if dscl . -passwd "/Users/$CURRENT_USER" "$DEFAULT_PASSWORD" "$NEW_PASS" &>/dev/null; then
        osascript \
            -e "tell application \"System Events\" to activate" \
            -e "display dialog \"Your password has been changed successfully.\" buttons {\"OK\"} default button \"OK\" with title \"Success\" with icon note" \
            2>/dev/null
        break
    else
        show_dialog "Failed to change password. Please try again." "Try Again" "Cancel" || exit 0
    fi
done

exit 0
