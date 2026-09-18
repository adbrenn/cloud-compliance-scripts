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
##   region,bucket_name
##
## Or optionally include account/profile:
##
##   account,region,bucket_name
##
## To run the script:
##
##   ./check_aws_lifecycle_from_csv.sh input.csv output.csv
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
    # Format: region,bucket_name
    HAS_ACCOUNT=false
    OUTPUT_HEADER="region,bucket_name,lifecycle_enabled,lifecycle_rules_count,lifecycle_actions"
elif [[ $NUM_COLUMNS -eq 3 ]]; then
    # Format: account,region,bucket_name
    HAS_ACCOUNT=true
    OUTPUT_HEADER="account,region,bucket_name,lifecycle_enabled,lifecycle_rules_count,lifecycle_actions"
else
    echo "Error: CSV must have 2 columns (region,bucket_name) or 3 columns (account,region,bucket_name)"
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
            BUCKET_NAME=$(echo "$COL3" | xargs)
        else
            ACCOUNT=""
            REGION=$(echo "$COL1" | xargs)
            BUCKET_NAME=$(echo "$COL2" | xargs)
        fi

        echo "DEBUG: ACCOUNT='$ACCOUNT' REGION='$REGION' BUCKET_NAME='$BUCKET_NAME'"

        if [[ -z "$REGION" || -z "$BUCKET_NAME" ]]; then
            echo "Skipping empty/malformed line"
            continue
        fi

        # Build AWS CLI command with optional profile
        AWS_CMD="aws s3api get-bucket-lifecycle-configuration"
        if [[ -n "$ACCOUNT" ]]; then
            AWS_CMD="$AWS_CMD --profile $ACCOUNT"
        fi
        AWS_CMD="$AWS_CMD --bucket $BUCKET_NAME --region $REGION"

        # Get lifecycle configuration using JSON
        LIFECYCLE_JSON=$($AWS_CMD --output json 2>/dev/null)
        LIFECYCLE_ERROR=$?

        if [[ $LIFECYCLE_ERROR -ne 0 ]]; then
            # Check if it's a "NoSuchLifecycleConfiguration" error (no lifecycle) or actual error
            ERROR_MSG=$(aws s3api get-bucket-lifecycle-configuration \
                ${ACCOUNT:+--profile $ACCOUNT} \
                --bucket "$BUCKET_NAME" \
                --region "$REGION" 2>&1)
            
            if echo "$ERROR_MSG" | grep -q "NoSuchLifecycleConfiguration"; then
                LIFECYCLE_ENABLED="False"
                RULES_COUNT="0"
                ACTIONS=""
            else
                echo "WARN: Bucket not found or no access: $REGION,$BUCKET_NAME"
                if [[ "$HAS_ACCOUNT" == "true" ]]; then
                    echo "$ACCOUNT,$REGION,$BUCKET_NAME,ERROR_BUCKET_NOT_FOUND,0," >> "$OUTPUT_CSV"
                else
                    echo "$REGION,$BUCKET_NAME,ERROR_BUCKET_NOT_FOUND,0," >> "$OUTPUT_CSV"
                fi
                continue
            fi
        else
            # Parse lifecycle rules
            if command -v jq &> /dev/null; then
                RULES_COUNT=$(echo "$LIFECYCLE_JSON" | jq -r '.Rules | length' 2>/dev/null)
                
                if [[ "$RULES_COUNT" == "null" ]] || [[ -z "$RULES_COUNT" ]] || [[ "$RULES_COUNT" == "0" ]]; then
                    LIFECYCLE_ENABLED="False"
                    RULES_COUNT="0"
                    ACTIONS=""
                else
                    LIFECYCLE_ENABLED="True"
                    # Extract action types from all rules
                    ACTIONS=$(echo "$LIFECYCLE_JSON" | jq -r '.Rules[] | .Status' 2>/dev/null | sort -u | tr '\n' ';' | sed 's/;$//')
                    
                    # Also get transition and expiration actions
                    TRANSITIONS=$(echo "$LIFECYCLE_JSON" | jq -r '.Rules[] | select(.Transitions != null) | .Transitions[] | "Transition-\(.StorageClass)"' 2>/dev/null | sort -u | tr '\n' ';' | sed 's/;$//')
                    EXPIRATIONS=$(echo "$LIFECYCLE_JSON" | jq -r '.Rules[] | select(.Expiration != null) | "Expiration"' 2>/dev/null | sort -u | tr '\n' ';' | sed 's/;$//')
                    NONCURRENT=$(echo "$LIFECYCLE_JSON" | jq -r '.Rules[] | select(.NoncurrentVersionTransitions != null or .NoncurrentVersionExpiration != null) | "NoncurrentVersion"' 2>/dev/null | sort -u | tr '\n' ';' | sed 's/;$//')
                    
                    # Combine all actions
                    ALL_ACTIONS=""
                    [[ -n "$ACTIONS" ]] && ALL_ACTIONS="${ACTIONS}"
                    [[ -n "$TRANSITIONS" ]] && ALL_ACTIONS="${ALL_ACTIONS}${ALL_ACTIONS:+;}$TRANSITIONS"
                    [[ -n "$EXPIRATIONS" ]] && ALL_ACTIONS="${ALL_ACTIONS}${ALL_ACTIONS:+;}$EXPIRATIONS"
                    [[ -n "$NONCURRENT" ]] && ALL_ACTIONS="${ALL_ACTIONS}${ALL_ACTIONS:+;}$NONCURRENT"
                    
                    ACTIONS="$ALL_ACTIONS"
                    
                    if [[ -z "$ACTIONS" ]]; then
                        ACTIONS="UNKNOWN"
                    fi
                fi
            else
                # Fallback parsing without jq
                if echo "$LIFECYCLE_JSON" | grep -q '"Rules"'; then
                    LIFECYCLE_ENABLED="True"
                    RULES_COUNT=$(echo "$LIFECYCLE_JSON" | grep -o '"Id"' | wc -l | xargs)
                    
                    # Extract action types
                    ACTIONS=""
                    if echo "$LIFECYCLE_JSON" | grep -q "Transitions"; then
                        ACTIONS="${ACTIONS}Transition"
                    fi
                    if echo "$LIFECYCLE_JSON" | grep -q "Expiration"; then
                        ACTIONS="${ACTIONS}${ACTIONS:+;}Expiration"
                    fi
                    if echo "$LIFECYCLE_JSON" | grep -q "NoncurrentVersion"; then
                        ACTIONS="${ACTIONS}${ACTIONS:+;}NoncurrentVersion"
                    fi
                    
                    if [[ -z "$ACTIONS" ]]; then
                        ACTIONS="UNKNOWN"
                    fi
                else
                    LIFECYCLE_ENABLED="False"
                    RULES_COUNT="0"
                    ACTIONS=""
                fi
            fi
        fi

        echo "DEBUG: Bucket $BUCKET_NAME - Lifecycle: $LIFECYCLE_ENABLED, Rules: $RULES_COUNT, Actions: $ACTIONS"

        # Write result
        if [[ "$HAS_ACCOUNT" == "true" ]]; then
            echo "$ACCOUNT,$REGION,$BUCKET_NAME,$LIFECYCLE_ENABLED,$RULES_COUNT,$ACTIONS" >> "$OUTPUT_CSV"
        else
            echo "$REGION,$BUCKET_NAME,$LIFECYCLE_ENABLED,$RULES_COUNT,$ACTIONS" >> "$OUTPUT_CSV"
        fi

    done
} < "$CLEANED_CSV"

# Cleanup temp file
rm -f "$CLEANED_CSV"

echo "✔ Done! Output written to: $OUTPUT_CSV"
