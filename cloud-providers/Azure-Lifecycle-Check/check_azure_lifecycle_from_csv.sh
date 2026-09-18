#!/bin/bash
##
## Run the following command to auth to Azure:
##
##   az login
##   # or for specific subscription
##   az account set --subscription "subscription-name-or-id"
##
## Create an input csv file with headers:
##
##   resource_group,storage_account,container_name
##
## Or optionally include subscription:
##
##   subscription,resource_group,storage_account,container_name
##
## To run the script:
##
##   ./check_azure_lifecycle_from_csv.sh input.csv output.csv
##
## Where input.csv is the input file.
##

INPUT_CSV="$1"
OUTPUT_CSV="$2"

if [[ -z "$INPUT_CSV" || -z "$OUTPUT_CSV" ]]; then
    echo "Usage: $0 <input.csv> <output.csv>"
    exit 1
fi

if [[ ! -f "$INPUT_CSV" ]]; then
    echo "Input file not found: $INPUT_CSV"
    exit 1
fi

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI is not installed. Please install it first."
    echo "Visit: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# Normalize CSV (remove CRLF)
CLEANED_CSV=$(mktemp)
tr -d '\r' < "$INPUT_CSV" > "$CLEANED_CSV"

# Detect CSV format by reading first data line
FIRST_LINE=$(tail -n +2 "$CLEANED_CSV" | head -n 1)
NUM_COLUMNS=$(echo "$FIRST_LINE" | awk -F',' '{print NF}')

if [[ $NUM_COLUMNS -eq 3 ]]; then
    # Format: resource_group,storage_account,container_name
    HAS_SUBSCRIPTION=false
    OUTPUT_HEADER="resource_group,storage_account,container_name,lifecycle_enabled,lifecycle_rules_count,lifecycle_actions"
elif [[ $NUM_COLUMNS -eq 4 ]]; then
    # Format: subscription,resource_group,storage_account,container_name
    HAS_SUBSCRIPTION=true
    OUTPUT_HEADER="subscription,resource_group,storage_account,container_name,lifecycle_enabled,lifecycle_rules_count,lifecycle_actions"
else
    echo "Error: CSV must have 3 columns (resource_group,storage_account,container_name) or 4 columns (subscription,resource_group,storage_account,container_name)"
    exit 1
fi

# Output header
echo "$OUTPUT_HEADER" > "$OUTPUT_CSV"

# Use input redirect — NOT a pipe — to avoid subshell issues
{
    read  # skip header row
    while IFS=',' read -r COL1 COL2 COL3 COL4; do

        if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
            SUBSCRIPTION=$(echo "$COL1" | xargs)
            RESOURCE_GROUP=$(echo "$COL2" | xargs)
            STORAGE_ACCOUNT=$(echo "$COL3" | xargs)
            CONTAINER_NAME=$(echo "$COL4" | xargs)
        else
            SUBSCRIPTION=""
            RESOURCE_GROUP=$(echo "$COL1" | xargs)
            STORAGE_ACCOUNT=$(echo "$COL2" | xargs)
            CONTAINER_NAME=$(echo "$COL3" | xargs)
        fi

        echo "DEBUG: SUBSCRIPTION='$SUBSCRIPTION' RESOURCE_GROUP='$RESOURCE_GROUP' STORAGE_ACCOUNT='$STORAGE_ACCOUNT' CONTAINER_NAME='$CONTAINER_NAME'"

        if [[ -z "$RESOURCE_GROUP" || -z "$STORAGE_ACCOUNT" || -z "$CONTAINER_NAME" ]]; then
            echo "Skipping empty/malformed line"
            continue
        fi

        # Set subscription if provided
        if [[ -n "$SUBSCRIPTION" ]]; then
            az account set --subscription "$SUBSCRIPTION" >/dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                echo "WARN: Could not set subscription: $SUBSCRIPTION"
                if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                    echo "$SUBSCRIPTION,$RESOURCE_GROUP,$STORAGE_ACCOUNT,$CONTAINER_NAME,SUBSCRIPTION_ERROR,0," >> "$OUTPUT_CSV"
                else
                    echo "$RESOURCE_GROUP,$STORAGE_ACCOUNT,$CONTAINER_NAME,SUBSCRIPTION_ERROR,0," >> "$OUTPUT_CSV"
                fi
                continue
            fi
        fi

        # Get blob service properties (lifecycle management is part of blob service properties)
        BLOB_PROPERTIES_JSON=$(az storage blob service-properties show \
            --account-name "$STORAGE_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --output json 2>/dev/null)

        if [[ -z "$BLOB_PROPERTIES_JSON" ]] || echo "$BLOB_PROPERTIES_JSON" | grep -q '"error"'; then
            echo "WARN: Storage account not found or no access: $RESOURCE_GROUP,$STORAGE_ACCOUNT"
            if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                echo "$SUBSCRIPTION,$RESOURCE_GROUP,$STORAGE_ACCOUNT,$CONTAINER_NAME,ERROR_STORAGE_ACCOUNT_NOT_FOUND,0," >> "$OUTPUT_CSV"
            else
                echo "$RESOURCE_GROUP,$STORAGE_ACCOUNT,$CONTAINER_NAME,ERROR_STORAGE_ACCOUNT_NOT_FOUND,0," >> "$OUTPUT_CSV"
            fi
            continue
        fi

        # Check if container exists
        CONTAINER_CHECK=$(az storage container show \
            --account-name "$STORAGE_ACCOUNT" \
            --name "$CONTAINER_NAME" \
            --auth-mode login \
            --output json 2>/dev/null)

        if [[ -z "$CONTAINER_CHECK" ]] || echo "$CONTAINER_CHECK" | grep -q '"error"'; then
            echo "WARN: Container not found: $CONTAINER_NAME"
            if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                echo "$SUBSCRIPTION,$RESOURCE_GROUP,$STORAGE_ACCOUNT,$CONTAINER_NAME,ERROR_CONTAINER_NOT_FOUND,0," >> "$OUTPUT_CSV"
            else
                echo "$RESOURCE_GROUP,$STORAGE_ACCOUNT,$CONTAINER_NAME,ERROR_CONTAINER_NOT_FOUND,0," >> "$OUTPUT_CSV"
            fi
            continue
        fi

        # Parse lifecycle management rules
        if command -v jq &> /dev/null; then
            # Check for deleteRetentionPolicy (soft delete) and lifecycle management
            LIFECYCLE_POLICY=$(echo "$BLOB_PROPERTIES_JSON" | jq -r '.deleteRetentionPolicy.enabled // false' 2>/dev/null)
            
            # Azure lifecycle management is configured via management policies
            # Get management policy
            MANAGEMENT_POLICY_JSON=$(az storage account blob-service-properties show \
                --account-name "$STORAGE_ACCOUNT" \
                --resource-group "$RESOURCE_GROUP" \
                --query "deleteRetentionPolicy,containerDeleteRetentionPolicy" \
                --output json 2>/dev/null)
            
            # Try to get management policy rules (lifecycle management)
            POLICY_RULES_JSON=$(az storage account management-policy show \
                --account-name "$STORAGE_ACCOUNT" \
                --resource-group "$RESOURCE_GROUP" \
                --output json 2>/dev/null)
            
            if [[ -n "$POLICY_RULES_JSON" ]] && ! echo "$POLICY_RULES_JSON" | grep -q '"error"'; then
                RULES_COUNT=$(echo "$POLICY_RULES_JSON" | jq -r '.policy.rules | length' 2>/dev/null)
                
                if [[ "$RULES_COUNT" == "null" ]] || [[ -z "$RULES_COUNT" ]] || [[ "$RULES_COUNT" == "0" ]]; then
                    LIFECYCLE_ENABLED="False"
                    RULES_COUNT="0"
                    ACTIONS=""
                else
                    LIFECYCLE_ENABLED="True"
                    # Extract action types - check all possible action locations
                    ACTIONS_LIST=""
                    
                    # Check baseBlob actions
                    TIER_TO_ARCHIVE=$(echo "$POLICY_RULES_JSON" | jq -r '.policy.rules[] | select(.definition.actions.baseBlob.tierToArchive != null) | "tierToArchive"' 2>/dev/null | head -n 1)
                    TIER_TO_COOL=$(echo "$POLICY_RULES_JSON" | jq -r '.policy.rules[] | select(.definition.actions.baseBlob.tierToCool != null) | "tierToCool"' 2>/dev/null | head -n 1)
                    BASE_BLOB_DELETE=$(echo "$POLICY_RULES_JSON" | jq -r '.policy.rules[] | select(.definition.actions.baseBlob.delete != null) | "delete"' 2>/dev/null | head -n 1)
                    
                    # Check snapshot actions
                    SNAPSHOT_DELETE=$(echo "$POLICY_RULES_JSON" | jq -r '.policy.rules[] | select(.definition.actions.snapshot.delete != null) | "snapshot.delete"' 2>/dev/null | head -n 1)
                    
                    # Check version actions
                    VERSION_DELETE=$(echo "$POLICY_RULES_JSON" | jq -r '.policy.rules[] | select(.definition.actions.version.delete != null) | "version.delete"' 2>/dev/null | head -n 1)
                    
                    # Build actions list
                    [[ -n "$TIER_TO_ARCHIVE" ]] && ACTIONS_LIST="${ACTIONS_LIST}${ACTIONS_LIST:+;}tierToArchive"
                    [[ -n "$TIER_TO_COOL" ]] && ACTIONS_LIST="${ACTIONS_LIST}${ACTIONS_LIST:+;}tierToCool"
                    [[ -n "$BASE_BLOB_DELETE" ]] && ACTIONS_LIST="${ACTIONS_LIST}${ACTIONS_LIST:+;}delete"
                    [[ -n "$SNAPSHOT_DELETE" ]] && ACTIONS_LIST="${ACTIONS_LIST}${ACTIONS_LIST:+;}snapshot.delete"
                    [[ -n "$VERSION_DELETE" ]] && ACTIONS_LIST="${ACTIONS_LIST}${ACTIONS_LIST:+;}version.delete"
                    
                    ACTIONS="$ACTIONS_LIST"
                    
                    if [[ -z "$ACTIONS" ]]; then
                        ACTIONS="UNKNOWN"
                    fi
                fi
            else
                # No management policy found
                LIFECYCLE_ENABLED="False"
                RULES_COUNT="0"
                ACTIONS=""
            fi
        else
            # Fallback parsing without jq
            echo "WARN: jq is not installed. For best results, please install jq."
            echo "      macOS: brew install jq"
            echo "      Linux: sudo apt-get install jq"
            
            # Try to check for management policy
            POLICY_CHECK=$(az storage account management-policy show \
                --account-name "$STORAGE_ACCOUNT" \
                --resource-group "$RESOURCE_GROUP" \
                --output json 2>/dev/null)
            
            if [[ -n "$POLICY_CHECK" ]] && ! echo "$POLICY_CHECK" | grep -q '"error"'; then
                LIFECYCLE_ENABLED="True"
                RULES_COUNT="UNKNOWN"
                ACTIONS="UNKNOWN"
            else
                LIFECYCLE_ENABLED="False"
                RULES_COUNT="0"
                ACTIONS=""
            fi
        fi

        echo "DEBUG: Container $CONTAINER_NAME - Lifecycle: $LIFECYCLE_ENABLED, Rules: $RULES_COUNT, Actions: $ACTIONS"

        # Write result
        if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
            echo "$SUBSCRIPTION,$RESOURCE_GROUP,$STORAGE_ACCOUNT,$CONTAINER_NAME,$LIFECYCLE_ENABLED,$RULES_COUNT,$ACTIONS" >> "$OUTPUT_CSV"
        else
            echo "$RESOURCE_GROUP,$STORAGE_ACCOUNT,$CONTAINER_NAME,$LIFECYCLE_ENABLED,$RULES_COUNT,$ACTIONS" >> "$OUTPUT_CSV"
        fi

    done
} < "$CLEANED_CSV"

# Cleanup temp file
rm -f "$CLEANED_CSV"

echo "✔ Done! Output written to: $OUTPUT_CSV"
