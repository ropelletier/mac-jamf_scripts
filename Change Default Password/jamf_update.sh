#!/bin/bash
# jamf_update.sh
#
# Updates the "Deploy - Check Default Password" script and policy in JAMF Pro
# using the Jamf Pro API. Run this whenever JAMF_deploy_check_password.sh changes.
#
# USAGE:
#   ./jamf_update.sh
#
# CREDENTIALS (set as env vars to avoid interactive prompts):
#   export JAMF_URL="https://yourorg.jamfcloud.com"
#   export JAMF_USER="apiuser"
#   export JAMF_PASS="apipassword"

SCRIPT_NAME="Deploy - Check Default Password"
POLICY_NAME="Deploy - Check Default Password"
SCRIPT_FILE="$(dirname "$0")/JAMF_deploy_check_password.sh"

# ── Credentials ────────────────────────────────────────────────────────────────

if [[ -z "$JAMF_URL" ]]; then
    read -rp "JAMF URL (e.g. https://yourorg.jamfcloud.com): " JAMF_URL
fi
JAMF_URL="${JAMF_URL%/}"  # strip trailing slash

if [[ -z "$JAMF_USER" ]]; then
    read -rp "JAMF username: " JAMF_USER
fi

if [[ -z "$JAMF_PASS" ]]; then
    read -rsp "JAMF password: " JAMF_PASS
    echo
fi

# ── Validate script file ───────────────────────────────────────────────────────

if [[ ! -f "$SCRIPT_FILE" ]]; then
    echo "ERROR: Script file not found: $SCRIPT_FILE"
    exit 1
fi

# ── Auth — get bearer token ────────────────────────────────────────────────────

echo "Authenticating with JAMF Pro..."

TOKEN=$(curl -sf -X POST \
    -u "$JAMF_USER:$JAMF_PASS" \
    "$JAMF_URL/api/v1/auth/token" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])" 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: Failed to authenticate. Check your JAMF URL and credentials."
    exit 1
fi

echo "Authenticated."

# ── Helpers ────────────────────────────────────────────────────────────────────

invalidate_token() {
    curl -sf -X DELETE \
        -H "Authorization: Bearer $TOKEN" \
        "$JAMF_URL/api/v1/auth/invalidate-token" &>/dev/null
}

api_get() {
    curl -sf \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" \
        "$JAMF_URL$1"
}

api_put_json() {
    local endpoint="$1"
    local payload="$2"
    curl -sf -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$JAMF_URL$endpoint"
}

classic_get() {
    curl -sf \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" \
        "$JAMF_URL/JSSResource$1"
}

classic_put_xml() {
    local endpoint="$1"
    local payload="$2"
    curl -sf -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/xml" \
        -d "$payload" \
        "$JAMF_URL/JSSResource$endpoint" &>/dev/null
}

# ── Update script ──────────────────────────────────────────────────────────────

echo ""
echo "── Updating script: \"$SCRIPT_NAME\" ──"

# Find the script ID by name
SCRIPT_ID=$(api_get "/api/v1/scripts?page-size=500" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for s in data.get('results', []):
    if s['name'] == '$SCRIPT_NAME':
        print(s['id'])
        break
" 2>/dev/null)

if [[ -z "$SCRIPT_ID" ]]; then
    echo "ERROR: Script \"$SCRIPT_NAME\" not found in JAMF."
    echo "       Create it first by following JAMF_Deployment_Instructions.md, then re-run this script."
    invalidate_token
    exit 1
fi

echo "Found script ID: $SCRIPT_ID"

# Build JSON payload with the script contents safely encoded via Python
PAYLOAD=$(python3 -c "
import json, sys

with open('$SCRIPT_FILE', 'r') as f:
    contents = f.read()

print(json.dumps({'scriptContents': contents}))
")

RESPONSE=$(api_put_json "/api/v1/scripts/$SCRIPT_ID" "$PAYLOAD")

if [[ -z "$RESPONSE" ]]; then
    echo "ERROR: Failed to update script."
    invalidate_token
    exit 1
fi

echo "Script updated successfully."

# ── Update policy ──────────────────────────────────────────────────────────────

echo ""
echo "── Verifying policy: \"$POLICY_NAME\" ──"

# Find policy ID using the Classic API
POLICY_ID=$(classic_get "/policies/name/$POLICY_NAME" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data['policy']['general']['id'])
" 2>/dev/null)

if [[ -z "$POLICY_ID" ]]; then
    echo "WARNING: Policy \"$POLICY_NAME\" not found. Skipping policy update."
else
    echo "Found policy ID: $POLICY_ID"

    # Verify the policy references the correct script
    POLICY_SCRIPT=$(classic_get "/policies/id/$POLICY_ID" \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
scripts = data['policy'].get('scripts', {}).get('script', [])
if isinstance(scripts, dict):
    scripts = [scripts]
for s in scripts:
    if s.get('name') == '$SCRIPT_NAME':
        print('linked')
        break
" 2>/dev/null)

    if [[ "$POLICY_SCRIPT" == "linked" ]]; then
        echo "Policy is correctly linked to the script."
    else
        echo "WARNING: Policy does not appear to reference \"$SCRIPT_NAME\"."
        echo "         Verify the policy manually in JAMF Pro."
    fi

    # Flush the policy log so it will re-run on managed computers
    read -rp "Flush policy logs so the policy re-runs on all computers? (y/N): " FLUSH
    if [[ "$FLUSH" =~ ^[Yy]$ ]]; then
        classic_put_xml "/policies/id/$POLICY_ID" \
            "<policy><general><enabled>true</enabled></general></policy>"
        curl -sf -X DELETE \
            -H "Authorization: Bearer $TOKEN" \
            "$JAMF_URL/JSSResource/policies/id/$POLICY_ID/flush" &>/dev/null
        echo "Policy logs flushed. The policy will re-run on next check-in."
    fi
fi

# ── Done ───────────────────────────────────────────────────────────────────────

invalidate_token
echo ""
echo "Done."
