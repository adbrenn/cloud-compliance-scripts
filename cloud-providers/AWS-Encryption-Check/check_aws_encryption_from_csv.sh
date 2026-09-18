#!/bin/bash
##
## Run the following command to auth to AWS:
##
##   aws configure
##   # or
##   aws sso login
##
## Create an input csv file with headers:
##
##   region,instance_id
##
## Or optionally include account/profile:
##
##   account,region,instance_id
##
## To run the script:
##
##   ./check_aws_encryption_from_csv.sh input.csv output.csv
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

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed. Please install it first."
    echo "Visit: https://aws.amazon.com/cli/"
    exit 1
fi

# Normalize CSV (remove CRLF)
CLEANED_CSV=$(mktemp)
tr -d '\r' < "$INPUT_CSV" > "$CLEANED_CSV"

# Detect CSV format by reading first data line
FIRST_LINE=$(tail -n +2 "$CLEANED_CSV" | head -n 1)
NUM_COLUMNS=$(echo "$FIRST_LINE" | awk -F',' '{print NF}')

if [[ $NUM_COLUMNS -eq 2 ]]; then
    # Format: region,instance_id
    HAS_ACCOUNT=false
    OUTPUT_HEADER="region,instance_id,volume_id,device_name,encrypted,encryption_type,kms_key_id"
elif [[ $NUM_COLUMNS -eq 3 ]]; then
    # Format: account,region,instance_id
    HAS_ACCOUNT=true
    OUTPUT_HEADER="account,region,instance_id,volume_id,device_name,encrypted,encryption_type,kms_key_id"
else
    echo "Error: CSV must have 2 columns (region,instance_id) or 3 columns (account,region,instance_id)"
    exit 1
fi

# Output header
echo "$OUTPUT_HEADER" > "$OUTPUT_CSV"

# Use input redirect — NOT a pipe — to avoid subshell issues
{
    read  # skip header row
    while IFS=',' read -r COL1 COL2 COL3; do

        if [[ "$HAS_ACCOUNT" == "true" ]]; then
            ACCOUNT=$(echo "$COL1" | xargs)
            REGION=$(echo "$COL2" | xargs)
            INSTANCE_ID=$(echo "$COL3" | xargs)
        else
            ACCOUNT=""
            REGION=$(echo "$COL1" | xargs)
            INSTANCE_ID=$(echo "$COL2" | xargs)
        fi

        echo "DEBUG: ACCOUNT='$ACCOUNT' REGION='$REGION' INSTANCE_ID='$INSTANCE_ID'"

        if [[ -z "$REGION" || -z "$INSTANCE_ID" ]]; then
            echo "Skipping empty/malformed line"
            continue
        fi

        # Build AWS CLI command with optional profile
        AWS_CMD="aws ec2 describe-instances"
        if [[ -n "$ACCOUNT" ]]; then
            AWS_CMD="$AWS_CMD --profile $ACCOUNT"
        fi
        AWS_CMD="$AWS_CMD --region $REGION --instance-ids $INSTANCE_ID"

        # Get instance details and attached volumes using JSON for better parsing
        INSTANCE_JSON=$($AWS_CMD --output json 2>/dev/null)

        if [[ -z "$INSTANCE_JSON" ]] || echo "$INSTANCE_JSON" | grep -q '"Reservations": \[\]'; then
            echo "WARN: Instance not found or no access: $REGION,$INSTANCE_ID"
            if [[ "$HAS_ACCOUNT" == "true" ]]; then
                echo "$ACCOUNT,$REGION,$INSTANCE_ID,,,INSTANCE_NOT_FOUND_OR_NO_ACCESS,," >> "$OUTPUT_CSV"
            else
                echo "$REGION,$INSTANCE_ID,,,INSTANCE_NOT_FOUND_OR_NO_ACCESS,," >> "$OUTPUT_CSV"
            fi
            continue
        fi

        # Extract volume attachments using jq if available, otherwise use grep/awk
        if command -v jq &> /dev/null; then
            # Use jq for reliable JSON parsing
            VOLUME_COUNT=$(echo "$INSTANCE_JSON" | jq -r '.Reservations[0].Instances[0].BlockDeviceMappings | length' 2>/dev/null)
            
            if [[ "$VOLUME_COUNT" == "0" ]] || [[ -z "$VOLUME_COUNT" ]]; then
                echo "WARN: No volumes found for instance: $REGION,$INSTANCE_ID"
                if [[ "$HAS_ACCOUNT" == "true" ]]; then
                    echo "$ACCOUNT,$REGION,$INSTANCE_ID,,,NO_VOLUMES_FOUND,," >> "$OUTPUT_CSV"
                else
                    echo "$REGION,$INSTANCE_ID,,,NO_VOLUMES_FOUND,," >> "$OUTPUT_CSV"
                fi
                continue
            fi

            # Process each volume attachment
            for ((i=0; i<VOLUME_COUNT; i++)); do
                DEVICE_NAME=$(echo "$INSTANCE_JSON" | jq -r ".Reservations[0].Instances[0].BlockDeviceMappings[$i].DeviceName" 2>/dev/null)
                VOLUME_ID=$(echo "$INSTANCE_JSON" | jq -r ".Reservations[0].Instances[0].BlockDeviceMappings[$i].Ebs.VolumeId" 2>/dev/null)

                if [[ -z "$VOLUME_ID" ]] || [[ "$VOLUME_ID" == "null" ]]; then
                    continue
                fi

                echo "DEBUG: Checking volume $VOLUME_ID (device: $DEVICE_NAME)"

                # Get volume encryption details
                VOLUME_CMD="aws ec2 describe-volumes"
                if [[ -n "$ACCOUNT" ]]; then
                    VOLUME_CMD="$VOLUME_CMD --profile $ACCOUNT"
                fi
                VOLUME_CMD="$VOLUME_CMD --region $REGION --volume-ids $VOLUME_ID"

                VOLUME_INFO=$($VOLUME_CMD --query 'Volumes[0].[Encrypted,KmsKeyId]' --output text 2>/dev/null)

                if [[ -z "$VOLUME_INFO" ]]; then
                    echo "WARN: Could not retrieve volume info: $VOLUME_ID"
                    ENCRYPTED="UNKNOWN"
                    ENCRYPTION_TYPE="UNKNOWN"
                    KMS_KEY_ID=""
                else
                    ENCRYPTED=$(echo "$VOLUME_INFO" | awk '{print $1}')
                    KMS_KEY_ID=$(echo "$VOLUME_INFO" | awk '{print $2}')

                    if [[ "$ENCRYPTED" == "True" ]]; then
                        if [[ -n "$KMS_KEY_ID" && "$KMS_KEY_ID" != "None" ]]; then
                            # Check if it's a customer-managed key or AWS-managed key
                            if [[ "$KMS_KEY_ID" == *"alias/aws/ebs"* ]]; then
                                ENCRYPTION_TYPE="AWS_MANAGED"
                            else
                                ENCRYPTION_TYPE="CUSTOMER_MANAGED_KMS"
                            fi
                        else
                            ENCRYPTION_TYPE="AWS_MANAGED"
                            KMS_KEY_ID="aws/ebs"
                        fi
                    else
                        ENCRYPTION_TYPE="NOT_ENCRYPTED"
                        KMS_KEY_ID=""
                    fi
                fi

                echo "DEBUG: Volume $VOLUME_ID - Encrypted: $ENCRYPTED, Type: $ENCRYPTION_TYPE, KMS: $KMS_KEY_ID"

                # Write result
                if [[ "$HAS_ACCOUNT" == "true" ]]; then
                    echo "$ACCOUNT,$REGION,$INSTANCE_ID,$VOLUME_ID,$DEVICE_NAME,$ENCRYPTED,$ENCRYPTION_TYPE,$KMS_KEY_ID" >> "$OUTPUT_CSV"
                else
                    echo "$REGION,$INSTANCE_ID,$VOLUME_ID,$DEVICE_NAME,$ENCRYPTED,$ENCRYPTION_TYPE,$KMS_KEY_ID" >> "$OUTPUT_CSV"
                fi
            done
        else
            # Fallback to text parsing if jq is not available
            VOLUME_ATTACHMENTS=$($AWS_CMD --query 'Reservations[0].Instances[0].BlockDeviceMappings[*].[DeviceName,Ebs.VolumeId]' --output text 2>/dev/null)

            if [[ -z "$VOLUME_ATTACHMENTS" ]]; then
                echo "WARN: No volumes found for instance: $REGION,$INSTANCE_ID"
                if [[ "$HAS_ACCOUNT" == "true" ]]; then
                    echo "$ACCOUNT,$REGION,$INSTANCE_ID,,,NO_VOLUMES_FOUND,," >> "$OUTPUT_CSV"
                else
                    echo "$REGION,$INSTANCE_ID,,,NO_VOLUMES_FOUND,," >> "$OUTPUT_CSV"
                fi
                continue
            fi

            # Process each volume attachment
            while IFS=$'\t' read -r DEVICE_NAME VOLUME_ID; do
                if [[ -z "$VOLUME_ID" ]] || [[ "$VOLUME_ID" == "None" ]]; then
                    continue
                fi

                echo "DEBUG: Checking volume $VOLUME_ID (device: $DEVICE_NAME)"

                # Get volume encryption details
                VOLUME_CMD="aws ec2 describe-volumes"
                if [[ -n "$ACCOUNT" ]]; then
                    VOLUME_CMD="$VOLUME_CMD --profile $ACCOUNT"
                fi
                VOLUME_CMD="$VOLUME_CMD --region $REGION --volume-ids $VOLUME_ID"

                VOLUME_INFO=$($VOLUME_CMD --query 'Volumes[0].[Encrypted,KmsKeyId]' --output text 2>/dev/null)

                if [[ -z "$VOLUME_INFO" ]]; then
                    echo "WARN: Could not retrieve volume info: $VOLUME_ID"
                    ENCRYPTED="UNKNOWN"
                    ENCRYPTION_TYPE="UNKNOWN"
                    KMS_KEY_ID=""
                else
                    ENCRYPTED=$(echo "$VOLUME_INFO" | awk '{print $1}')
                    KMS_KEY_ID=$(echo "$VOLUME_INFO" | awk '{print $2}')

                    if [[ "$ENCRYPTED" == "True" ]]; then
                        if [[ -n "$KMS_KEY_ID" && "$KMS_KEY_ID" != "None" ]]; then
                            # Check if it's a customer-managed key or AWS-managed key
                            if [[ "$KMS_KEY_ID" == *"alias/aws/ebs"* ]]; then
                                ENCRYPTION_TYPE="AWS_MANAGED"
                            else
                                ENCRYPTION_TYPE="CUSTOMER_MANAGED_KMS"
                            fi
                        else
                            ENCRYPTION_TYPE="AWS_MANAGED"
                            KMS_KEY_ID="aws/ebs"
                        fi
                    else
                        ENCRYPTION_TYPE="NOT_ENCRYPTED"
                        KMS_KEY_ID=""
                    fi
                fi

                echo "DEBUG: Volume $VOLUME_ID - Encrypted: $ENCRYPTED, Type: $ENCRYPTION_TYPE, KMS: $KMS_KEY_ID"

                # Write result
                if [[ "$HAS_ACCOUNT" == "true" ]]; then
                    echo "$ACCOUNT,$REGION,$INSTANCE_ID,$VOLUME_ID,$DEVICE_NAME,$ENCRYPTED,$ENCRYPTION_TYPE,$KMS_KEY_ID" >> "$OUTPUT_CSV"
                else
                    echo "$REGION,$INSTANCE_ID,$VOLUME_ID,$DEVICE_NAME,$ENCRYPTED,$ENCRYPTION_TYPE,$KMS_KEY_ID" >> "$OUTPUT_CSV"
                fi
            done <<< "$VOLUME_ATTACHMENTS"
        fi

    done
} < "$CLEANED_CSV"

# Cleanup temp file
rm -f "$CLEANED_CSV"

echo "✔ Done! Output written to: $OUTPUT_CSV"
