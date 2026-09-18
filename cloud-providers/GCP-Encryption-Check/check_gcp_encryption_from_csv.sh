#!/bin/bash
##
## Run the following command to auth to gcloud:
##
##   gcloud auth login
##   gcloud auth application-default login
##
## Create an input csv file with headers:
##
##   project,zone,instance
##
## To run the script:
##
##   ./check_gcp_encryption_from_csv.sh input.csv output.csv
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

# Normalize CSV (remove CRLF)
CLEANED_CSV=$(mktemp)
tr -d '\r' < "$INPUT_CSV" > "$CLEANED_CSV"

# Output header
echo "project,zone,instance,disk,encryption_type" > "$OUTPUT_CSV"

# Use input redirect — NOT a pipe — to avoid subshell issues
{
    read  # skip header row
    while IFS=',' read -r PROJECT ZONE INSTANCE; do

        # Trim whitespace
        PROJECT=$(echo "$PROJECT" | xargs)
        ZONE=$(echo "$ZONE" | xargs)
        INSTANCE=$(echo "$INSTANCE" | xargs)

        echo "DEBUG: PROJECT='$PROJECT' ZONE='$ZONE' INSTANCE='$INSTANCE'"

        if [[ -z "$PROJECT" || -z "$ZONE" || -z "$INSTANCE" ]]; then
            echo "Skipping empty/malformed line"
            continue
        fi

        DISKS=$(gcloud compute instances describe "$INSTANCE" \
            --project="$PROJECT" \
            --zone="$ZONE" \
            --format="value(disks.deviceName)" 2>/dev/null)

        echo "DEBUG: DISKS='$DISKS'"

        if [[ -z "$DISKS" ]]; then
            echo "WARN: No disks found or instance missing: $PROJECT,$ZONE,$INSTANCE"
            echo "$PROJECT,$ZONE,$INSTANCE,,INSTANCE_NOT_FOUND_OR_NO_DISKS" >> "$OUTPUT_CSV"
            continue
        fi

        for DISK in $DISKS; do
            ENC=$(gcloud compute disks describe "$DISK" \
                --zone="$ZONE" \
                --project="$PROJECT" \
                --format="json(diskEncryptionKey)" 2>/dev/null)

            echo "DEBUG: ENC='$ENC'"

            if echo "$ENC" | grep -q "kmsKeyName"; then
                ENC_TYPE="CMEK"
            elif echo "$ENC" | grep -q "sha256"; then
                ENC_TYPE="CSEK"
            else
                ENC_TYPE="GOOGLE_MANAGED"
            fi

            echo "$PROJECT,$ZONE,$INSTANCE,$DISK,$ENC_TYPE" >> "$OUTPUT_CSV"

        done

    done
} < "$CLEANED_CSV"

echo "✔ Done! Output written to: $OUTPUT_CSV"
