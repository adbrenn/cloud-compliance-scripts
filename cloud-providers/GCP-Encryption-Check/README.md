# GCP Disk Encryption Checker

This script checks the encryption status of persistent disks attached to Google Cloud Compute Engine VMs. It reads instance information from a CSV file and outputs the encryption type for each disk.

## Prerequisites

1. **Google Cloud SDK**: Must be installed and configured
   - Installation: https://cloud.google.com/sdk/docs/install
   - Authentication: `gcloud auth login` and `gcloud auth application-default login`
   - Ensure you have permissions to describe Compute Engine instances and disks

2. **Required IAM Permissions**:
   - `compute.instances.get`
   - `compute.disks.get`

## Installation

1. Make the script executable:
   ```bash
   chmod +x check_gcp_encryption_from_csv.sh
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
project,zone,instance
my-gcp-project,us-central1-a,my-vm-01
production-project,us-east1-b,web-server-01
```

Run the script:
```bash
./check_gcp_encryption_from_csv.sh input.csv output.csv
```

A sample input file (`gcp_input.csv`) is included in this folder.

## Input CSV Format

```csv
project,zone,instance
my-gcp-project,us-central1-a,my-vm-01
production-project,us-east1-b,web-server-01
```

- `project`: GCP project ID
- `zone`: Compute Engine zone (e.g., `us-central1-a`)
- `instance`: VM instance name

## Output Format

The output CSV contains the following columns:

- `project`: GCP project ID
- `zone`: Compute Engine zone
- `instance`: VM instance name
- `disk`: Persistent disk device name
- `encryption_type`: One of:
  - `GOOGLE_MANAGED`: Encrypted with Google-managed encryption keys (default at rest)
  - `CMEK`: Encrypted with customer-managed encryption keys (Cloud KMS)
  - `CSEK`: Encrypted with customer-supplied encryption keys

### Example Output

```csv
project,zone,instance,disk,encryption_type
my-gcp-project,us-central1-a,my-vm-01,my-vm-01,GOOGLE_MANAGED
my-gcp-project,us-central1-a,my-vm-01,my-vm-01-data,CMEK
production-project,us-east1-b,web-server-01,web-server-01,CSEK
```

## GCP Disk Encryption Types

GCP Compute Engine disks support several encryption methods:

1. **Google-Managed Encryption**: Default encryption at rest using Google-managed keys
2. **Customer-Managed Encryption Keys (CMEK)**: Encryption using keys stored in Cloud KMS
3. **Customer-Supplied Encryption Keys (CSEK)**: Encryption using keys supplied by the customer

The script inspects each attached disk's `diskEncryptionKey` field and reports accordingly.

## Error Handling

The script handles various error conditions:

- **Instance not found or no disks**: Outputs `INSTANCE_NOT_FOUND_OR_NO_DISKS`
- **Empty or malformed CSV rows**: Skipped with a warning

## Examples

### Check encryption for VM disks
```bash
./check_gcp_encryption_from_csv.sh gcp_input.csv results.csv
```

### Verify encryption compliance
After running the script, you can filter results to find disks not using customer-managed keys:
```bash
# Find disks using Google-managed encryption
grep "GOOGLE_MANAGED" results.csv

# Find disks using CMEK
grep "CMEK" results.csv

# Find disks using customer-supplied keys
grep "CSEK" results.csv
```

## Troubleshooting

### "Google Cloud SDK is not installed"
Install Google Cloud SDK following the official documentation: https://cloud.google.com/sdk/docs/install

### "Instance not found or no disks"
- Verify the project ID, zone, and instance name are correct
- Check your GCP credentials: `gcloud auth list`
- Verify you have `compute.instances.get` permission
- Ensure the instance exists in the specified zone

### "Permission denied"
- Check you have `compute.instances.get` and `compute.disks.get` permissions
- Verify the project ID is correct
- Ensure you're authenticated: `gcloud auth application-default print-access-token`

### Authentication issues
Re-authenticate with:
```bash
gcloud auth login
gcloud auth application-default login
```

## Notes

- The script processes instances sequentially to avoid rate limiting
- Large CSV files may take some time to process
- The script automatically handles CRLF line endings
- Debug output is printed to the console for troubleshooting
- All attached disks for each instance are checked
- Unlike AWS/Azure counterparts, this script does not require `jq` (it parses gcloud JSON output with `grep`)

## Differences from AWS/Azure Scripts

- GCP uses project + zone + instance name instead of region/instance ID or resource group/VM name
- Encryption types are reported as `GOOGLE_MANAGED`, `CMEK`, or `CSEK`
- Google-managed encryption is the default for disks at rest (there is typically no "unencrypted" state for persistent disks)
- Does not require `jq`
