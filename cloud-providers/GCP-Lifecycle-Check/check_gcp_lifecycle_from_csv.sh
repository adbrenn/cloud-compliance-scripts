#!/bin/bash
##
## Run the following command to auth to gcloud:
##
##   gcloud auth login
##   gcloud auth application-default login
##
## Create an input csv file with headers:
##
##   project,bucket_name
##
## To run the script:
##
##   ./check_gcp_lifecycle_from_csv.sh input.csv output.csv
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

# Check if gcloud CLI is installed
if ! command -v gcloud &> /dev/null; then
    echo "Error: Google Cloud SDK is not installed. Please install it first."
    echo "Visit: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Normalize CSV (remove CRLF)
CLEANED_CSV=$(mktemp)
tr -d '\r' < "$INPUT_CSV" > "$CLEANED_CSV"

# Output header
echo "project,bucket_name,lifecycle_enabled,lifecycle_rules_count,lifecycle_actions" > "$OUTPUT_CSV"

# Use input redirect — NOT a pipe — to avoid subshell issues
{
    read  # skip header row
    while IFS=',' read -r PROJECT BUCKET_NAME; do

        # Trim whitespace
        PROJECT=$(echo "$PROJECT" | xargs)
        BUCKET_NAME=$(echo "$BUCKET_NAME" | xargs)

        echo "DEBUG: PROJECT='$PROJECT' BUCKET_NAME='$BUCKET_NAME'"

        if [[ -z "$PROJECT" || -z "$BUCKET_NAME" ]]; then
            echo "Skipping empty/malformed line"
            continue
        fi

        # Get bucket lifecycle configuration
        LIFECYCLE_JSON=$(gcloud storage buckets describe "gs://$BUCKET_NAME" \
            --project="$PROJECT" \
            --format="json(lifecycle)" 2>/dev/null)

        if [[ -z "$LIFECYCLE_JSON" ]] || echo "$LIFECYCLE_JSON" | grep -q "ERROR"; then
            echo "WARN: Bucket not found or no access: $PROJECT,$BUCKET_NAME"
            echo "$PROJECT,$BUCKET_NAME,ERROR_BUCKET_NOT_FOUND,0," >> "$OUTPUT_CSV"
            continue
        fi

        echo "DEBUG: LIFECYCLE_JSON='$LIFECYCLE_JSON'"

        # Check if lifecycle is configured
        if echo "$LIFECYCLE_JSON" | grep -q "null" || [[ -z "$LIFECYCLE_JSON" ]]; then
            LIFECYCLE_ENABLED="False"
            RULES_COUNT="0"
            ACTIONS=""
        else
            # Parse lifecycle rules
            if command -v jq &> /dev/null; then
                RULES_COUNT=$(echo "$LIFECYCLE_JSON" | jq -r '.rule | length' 2>/dev/null)
                
                if [[ "$RULES_COUNT" == "null" ]] || [[ -z "$RULES_COUNT" ]] || [[ "$RULES_COUNT" == "0" ]]; then
                    LIFECYCLE_ENABLED="False"
                    RULES_COUNT="0"
                    ACTIONS=""
                else
                    LIFECYCLE_ENABLED="True"
                    # Extract action types
                    ACTIONS=$(echo "$LIFECYCLE_JSON" | jq -r '.rule[] | .action.type' 2>/dev/null | sort -u | tr '\n' ';' | sed 's/;$//')
                    
                    if [[ -z "$ACTIONS" ]]; then
                        ACTIONS="UNKNOWN"
                    fi
                fi
            else
                # Fallback parsing without jq
                if echo "$LIFECYCLE_JSON" | grep -q "rule"; then
                    LIFECYCLE_ENABLED="True"
                    RULES_COUNT=$(echo "$LIFECYCLE_JSON" | grep -o '"type"' | wc -l | xargs)
                    ACTIONS=$(echo "$LIFECYCLE_JSON" | grep -o '"type":"[^"]*"' | sed 's/"type":"//g' | sed 's/"//g' | sort -u | tr '\n' ';' | sed 's/;$//')
                    
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

        echo "$PROJECT,$BUCKET_NAME,$LIFECYCLE_ENABLED,$RULES_COUNT,$ACTIONS" >> "$OUTPUT_CSV"

    done
} < "$CLEANED_CSV"

# Cleanup temp file
rm -f "$CLEANED_CSV"

echo "✔ Done! Output written to: $OUTPUT_CSV"
