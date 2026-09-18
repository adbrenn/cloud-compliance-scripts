# GCP Storage Bucket Lifecycle Policy Checker

This script checks the lifecycle policy configuration for Google Cloud Storage buckets. It reads bucket information from a CSV file and outputs detailed lifecycle policy information.

## Prerequisites

1. **Google Cloud SDK**: Must be installed and configured
   - Installation: https://cloud.google.com/sdk/docs/install
   - Authentication: `gcloud auth login` and `gcloud auth application-default login`
   - Ensure you have permissions to read bucket configurations

2. **jq** (optional but recommended): For better JSON parsing
   - macOS: `brew install jq`
   - Linux: `sudo apt-get install jq`
   - The script will work without jq but uses a fallback text parsing method

3. **Required IAM Permissions**:
   - `storage.buckets.get`
   - `storage.buckets.get`

## Installation

1. Make the script executable:
   ```bash
   chmod +x check_gcp_lifecycle_from_csv.sh
   ```

2. Ensure Google Cloud SDK is configured:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

## Usage

### Basic Usage

Create an input CSV file with headers:
```csv
project,bucket_name
my-gcp-project,my-bucket-01
production-project,backup-bucket
```

Run the script:
```bash
./check_gcp_lifecycle_from_csv.sh input.csv output.csv
```

## Input CSV Format

```csv
project,bucket_name
my-gcp-project,my-bucket-01
production-project,backup-bucket
```

## Output Format

The output CSV contains the following columns:

- `project`: GCP project ID
- `bucket_name`: Storage bucket name
- `lifecycle_enabled`: `True` or `False`
- `lifecycle_rules_count`: Number of lifecycle rules configured
- `lifecycle_actions`: Semicolon-separated list of action types (e.g., `Delete`, `SetStorageClass`)

### Example Output

```csv
project,bucket_name,lifecycle_enabled,lifecycle_rules_count,lifecycle_actions
my-gcp-project,my-bucket-01,True,2,Delete;SetStorageClass
production-project,backup-bucket,False,0,
```

## GCP Lifecycle Actions

GCP Storage lifecycle policies support various actions:

- **Delete**: Permanently delete objects
- **SetStorageClass**: Change object storage class (e.g., to Nearline, Coldline, Archive)
- **AbortIncompleteMultipartUpload**: Clean up incomplete multipart uploads

## Error Handling

The script handles various error conditions:

- **Bucket not found**: Outputs `ERROR_BUCKET_NOT_FOUND`
- **No lifecycle configured**: Outputs `False` for `lifecycle_enabled` with `0` rules

## Examples

### Check lifecycle policies for buckets
```bash
./check_gcp_lifecycle_from_csv.sh gcp_lifecycle_input.csv results.csv
```

### Verify lifecycle compliance
After running the script, you can filter results to find buckets without lifecycle policies:
```bash
# Find buckets without lifecycle policies
grep "False" results.csv

# Find buckets with lifecycle policies
grep "True" results.csv
```

## Troubleshooting

### "Google Cloud SDK is not installed"
Install Google Cloud SDK following the official documentation: https://cloud.google.com/sdk/docs/install

### "Bucket not found or no access"
- Verify the bucket name is correct
- Check your GCP credentials: `gcloud auth list`
- Verify you have `storage.buckets.get` permission
- Ensure you're using the correct project

### "Permission denied"
- Check you have the necessary IAM permissions
- Verify the project ID is correct
- Ensure you're authenticated: `gcloud auth application-default print-access-token`

## Notes

- The script processes buckets sequentially to avoid rate limiting
- Large CSV files may take some time to process
- The script automatically handles CRLF line endings
- Debug output is printed to stderr for troubleshooting
- Lifecycle policies are checked at the bucket level
