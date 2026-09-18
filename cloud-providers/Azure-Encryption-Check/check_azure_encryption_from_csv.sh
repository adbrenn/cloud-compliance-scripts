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
##   resource_group,vm_name
##
## Or optionally include subscription:
##
##   subscription,resource_group,vm_name
##
## To run the script:
##
##   ./check_azure_encryption_from_csv.sh input.csv output.csv
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

if [[ $NUM_COLUMNS -eq 2 ]]; then
    # Format: resource_group,vm_name
    HAS_SUBSCRIPTION=false
    OUTPUT_HEADER="resource_group,vm_name,disk_name,disk_type,encrypted,encryption_type,encryption_set_id"
elif [[ $NUM_COLUMNS -eq 3 ]]; then
    # Format: subscription,resource_group,vm_name
    HAS_SUBSCRIPTION=true
    OUTPUT_HEADER="subscription,resource_group,vm_name,disk_name,disk_type,encrypted,encryption_type,encryption_set_id"
else
    echo "Error: CSV must have 2 columns (resource_group,vm_name) or 3 columns (subscription,resource_group,vm_name)"
    exit 1
fi

# Output header
echo "$OUTPUT_HEADER" > "$OUTPUT_CSV"

# Use input redirect — NOT a pipe — to avoid subshell issues
{
    read  # skip header row
    while IFS=',' read -r COL1 COL2 COL3; do

        if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
            SUBSCRIPTION=$(echo "$COL1" | xargs)
            RESOURCE_GROUP=$(echo "$COL2" | xargs)
            VM_NAME=$(echo "$COL3" | xargs)
        else
            SUBSCRIPTION=""
            RESOURCE_GROUP=$(echo "$COL1" | xargs)
            VM_NAME=$(echo "$COL2" | xargs)
        fi

        echo "DEBUG: SUBSCRIPTION='$SUBSCRIPTION' RESOURCE_GROUP='$RESOURCE_GROUP' VM_NAME='$VM_NAME'"

        if [[ -z "$RESOURCE_GROUP" || -z "$VM_NAME" ]]; then
            echo "Skipping empty/malformed line"
            continue
        fi

        # Set subscription if provided
        if [[ -n "$SUBSCRIPTION" ]]; then
            az account set --subscription "$SUBSCRIPTION" >/dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                echo "WARN: Could not set subscription: $SUBSCRIPTION"
                if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                    echo "$SUBSCRIPTION,$RESOURCE_GROUP,$VM_NAME,,,SUBSCRIPTION_ERROR,," >> "$OUTPUT_CSV"
                else
                    echo "$RESOURCE_GROUP,$VM_NAME,,,SUBSCRIPTION_ERROR,," >> "$OUTPUT_CSV"
                fi
                continue
            fi
        fi

        # Build Azure CLI command
        AZ_CMD="az vm show"
        AZ_CMD="$AZ_CMD --resource-group $RESOURCE_GROUP"
        AZ_CMD="$AZ_CMD --name $VM_NAME"

        # Get VM details and attached disks using JSON for better parsing
        VM_JSON=$($AZ_CMD --output json 2>/dev/null)

        if [[ -z "$VM_JSON" ]] || echo "$VM_JSON" | grep -q '"error"'; then
            echo "WARN: VM not found or no access: $RESOURCE_GROUP,$VM_NAME"
            if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                echo "$SUBSCRIPTION,$RESOURCE_GROUP,$VM_NAME,,,VM_NOT_FOUND_OR_NO_ACCESS,," >> "$OUTPUT_CSV"
            else
                echo "$RESOURCE_GROUP,$VM_NAME,,,VM_NOT_FOUND_OR_NO_ACCESS,," >> "$OUTPUT_CSV"
            fi
            continue
        fi

        # Extract disk attachments using jq if available, otherwise use grep/awk
        if command -v jq &> /dev/null; then
            # Use jq for reliable JSON parsing
            # Get OS disk
            OS_DISK_ID=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.managedDisk.id // empty' 2>/dev/null)
            OS_DISK_NAME=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.name // empty' 2>/dev/null)
            
            # Get data disks count
            DATA_DISK_COUNT=$(echo "$VM_JSON" | jq -r '.storageProfile.dataDisks | length' 2>/dev/null)
            
            if [[ -z "$OS_DISK_ID" && -z "$OS_DISK_NAME" ]] && [[ "$DATA_DISK_COUNT" == "0" ]]; then
                echo "WARN: No disks found for VM: $RESOURCE_GROUP,$VM_NAME"
                if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                    echo "$SUBSCRIPTION,$RESOURCE_GROUP,$VM_NAME,,,NO_DISKS_FOUND,," >> "$OUTPUT_CSV"
                else
                    echo "$RESOURCE_GROUP,$VM_NAME,,,NO_DISKS_FOUND,," >> "$OUTPUT_CSV"
                fi
                continue
            fi

            # Process OS disk
            if [[ -n "$OS_DISK_ID" ]] || [[ -n "$OS_DISK_NAME" ]]; then
                # Extract resource group and disk name from ID or use provided name
                if [[ -n "$OS_DISK_ID" ]]; then
                    DISK_NAME=$(echo "$OS_DISK_ID" | sed 's|.*/disks/||')
                    DISK_RG=$(echo "$OS_DISK_ID" | sed 's|.*/resourceGroups/||' | sed 's|/.*||')
                else
                    DISK_NAME="$OS_DISK_NAME"
                    DISK_RG="$RESOURCE_GROUP"
                fi
                
                echo "DEBUG: Checking OS disk $DISK_NAME (resource group: $DISK_RG)"

                # Get disk encryption details
                DISK_JSON=$(az disk show --resource-group "$DISK_RG" --name "$DISK_NAME" --output json 2>/dev/null)

                if [[ -z "$DISK_JSON" ]] || echo "$DISK_JSON" | grep -q '"error"'; then
                    echo "WARN: Could not retrieve disk info: $DISK_NAME"
                    ENCRYPTED="UNKNOWN"
                    ENCRYPTION_TYPE="UNKNOWN"
                    ENCRYPTION_SET_ID=""
                    DISK_TYPE="OS"
                else
                    ENCRYPTION_TYPE_RAW=$(echo "$DISK_JSON" | jq -r '.encryption.type // empty' 2>/dev/null)
                    ENCRYPTION_SET_ID=$(echo "$DISK_JSON" | jq -r '.encryption.diskEncryptionSetId // empty' 2>/dev/null)
                    
                    if [[ -n "$ENCRYPTION_TYPE_RAW" ]]; then
                        ENCRYPTED="True"
                        if [[ -n "$ENCRYPTION_SET_ID" ]] && [[ "$ENCRYPTION_SET_ID" != "null" ]]; then
                            ENCRYPTION_TYPE="CUSTOMER_MANAGED"
                        else
                            ENCRYPTION_TYPE="PLATFORM_MANAGED"
                        fi
                    else
                        # Check if encryption is enabled at VM level (older encryption methods)
                        ENCRYPTION_ENABLED=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.encryptionSettings.enabled // false' 2>/dev/null)
                        if [[ "$ENCRYPTION_ENABLED" == "true" ]]; then
                            ENCRYPTED="True"
                            ENCRYPTION_TYPE="VM_LEVEL_ENCRYPTION"
                        else
                            ENCRYPTED="False"
                            ENCRYPTION_TYPE="NOT_ENCRYPTED"
                        fi
                        ENCRYPTION_SET_ID=""
                    fi
                    DISK_TYPE="OS"
                fi

                echo "DEBUG: Disk $DISK_NAME - Encrypted: $ENCRYPTED, Type: $ENCRYPTION_TYPE, Set: $ENCRYPTION_SET_ID"

                # Write result
                if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                    echo "$SUBSCRIPTION,$RESOURCE_GROUP,$VM_NAME,$DISK_NAME,$DISK_TYPE,$ENCRYPTED,$ENCRYPTION_TYPE,$ENCRYPTION_SET_ID" >> "$OUTPUT_CSV"
                else
                    echo "$RESOURCE_GROUP,$VM_NAME,$DISK_NAME,$DISK_TYPE,$ENCRYPTED,$ENCRYPTION_TYPE,$ENCRYPTION_SET_ID" >> "$OUTPUT_CSV"
                fi
            fi

            # Process data disks
            if [[ "$DATA_DISK_COUNT" != "0" ]] && [[ "$DATA_DISK_COUNT" != "null" ]]; then
                for ((i=0; i<DATA_DISK_COUNT; i++)); do
                    DATA_DISK_ID=$(echo "$VM_JSON" | jq -r ".storageProfile.dataDisks[$i].managedDisk.id // empty" 2>/dev/null)
                    DATA_DISK_NAME=$(echo "$VM_JSON" | jq -r ".storageProfile.dataDisks[$i].name // empty" 2>/dev/null)

                    if [[ -z "$DATA_DISK_ID" ]] && [[ -z "$DATA_DISK_NAME" ]]; then
                        continue
                    fi

                    # Extract resource group and disk name from ID or use provided name
                    if [[ -n "$DATA_DISK_ID" ]]; then
                        DISK_NAME=$(echo "$DATA_DISK_ID" | sed 's|.*/disks/||')
                        DISK_RG=$(echo "$DATA_DISK_ID" | sed 's|.*/resourceGroups/||' | sed 's|/.*||')
                    else
                        DISK_NAME="$DATA_DISK_NAME"
                        DISK_RG="$RESOURCE_GROUP"
                    fi

                    echo "DEBUG: Checking data disk $DISK_NAME (resource group: $DISK_RG)"

                    # Get disk encryption details
                    DISK_JSON=$(az disk show --resource-group "$DISK_RG" --name "$DISK_NAME" --output json 2>/dev/null)

                    if [[ -z "$DISK_JSON" ]] || echo "$DISK_JSON" | grep -q '"error"'; then
                        echo "WARN: Could not retrieve disk info: $DISK_NAME"
                        ENCRYPTED="UNKNOWN"
                        ENCRYPTION_TYPE="UNKNOWN"
                        ENCRYPTION_SET_ID=""
                        DISK_TYPE="Data"
                    else
                        ENCRYPTION_TYPE_RAW=$(echo "$DISK_JSON" | jq -r '.encryption.type // empty' 2>/dev/null)
                        ENCRYPTION_SET_ID=$(echo "$DISK_JSON" | jq -r '.encryption.diskEncryptionSetId // empty' 2>/dev/null)
                        
                        if [[ -n "$ENCRYPTION_TYPE_RAW" ]]; then
                            ENCRYPTED="True"
                            if [[ -n "$ENCRYPTION_SET_ID" ]] && [[ "$ENCRYPTION_SET_ID" != "null" ]]; then
                                ENCRYPTION_TYPE="CUSTOMER_MANAGED"
                            else
                                ENCRYPTION_TYPE="PLATFORM_MANAGED"
                            fi
                        else
                            ENCRYPTED="False"
                            ENCRYPTION_TYPE="NOT_ENCRYPTED"
                            ENCRYPTION_SET_ID=""
                        fi
                        DISK_TYPE="Data"
                    fi

                    echo "DEBUG: Disk $DISK_NAME - Encrypted: $ENCRYPTED, Type: $ENCRYPTION_TYPE, Set: $ENCRYPTION_SET_ID"

                    # Write result
                    if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                        echo "$SUBSCRIPTION,$RESOURCE_GROUP,$VM_NAME,$DISK_NAME,$DISK_TYPE,$ENCRYPTED,$ENCRYPTION_TYPE,$ENCRYPTION_SET_ID" >> "$OUTPUT_CSV"
                    else
                        echo "$RESOURCE_GROUP,$VM_NAME,$DISK_NAME,$DISK_TYPE,$ENCRYPTED,$ENCRYPTION_TYPE,$ENCRYPTION_SET_ID" >> "$OUTPUT_CSV"
                    fi
                done
            fi
        else
            # Fallback to text parsing if jq is not available (simplified)
            echo "WARN: jq is not installed. For best results, please install jq."
            echo "      macOS: brew install jq"
            echo "      Linux: sudo apt-get install jq"
            
            # Try to get basic info without jq
            VM_STATE=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query "provisioningState" --output tsv 2>/dev/null)
            
            if [[ -z "$VM_STATE" ]]; then
                echo "WARN: VM not found or no access: $RESOURCE_GROUP,$VM_NAME"
                if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                    echo "$SUBSCRIPTION,$RESOURCE_GROUP,$VM_NAME,,,VM_NOT_FOUND_OR_NO_ACCESS,," >> "$OUTPUT_CSV"
                else
                    echo "$RESOURCE_GROUP,$VM_NAME,,,VM_NOT_FOUND_OR_NO_ACCESS,," >> "$OUTPUT_CSV"
                fi
                continue
            fi
            
            # Without jq, we can't easily parse all disk details
            # Output a note that jq is required
            if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
                echo "$SUBSCRIPTION,$RESOURCE_GROUP,$VM_NAME,,,JQ_REQUIRED_FOR_DETAILED_PARSING,," >> "$OUTPUT_CSV"
            else
                echo "$RESOURCE_GROUP,$VM_NAME,,,JQ_REQUIRED_FOR_DETAILED_PARSING,," >> "$OUTPUT_CSV"
            fi
        fi

    done
} < "$CLEANED_CSV"

# Cleanup temp file
rm -f "$CLEANED_CSV"

echo "✔ Done! Output written to: $OUTPUT_CSV"
