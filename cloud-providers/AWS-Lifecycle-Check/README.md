# AWS S3 Bucket Lifecycle Policy Checker

This script checks the lifecycle policy configuration for AWS S3 buckets. It reads bucket information from a CSV file and outputs detailed lifecycle policy information.

## Prerequisites

1. **AWS CLI**: Must be installed and configured
   - Installation: https://aws.amazon.com/cli/
   - Configuration: `aws configure` or `aws sso login`
   - Ensure you have permissions to read bucket lifecycle configurations

2. **jq** (optional but recommended): For better JSON parsing
   - macOS: `brew install jq`
   - Linux: `sudo apt-get install jq` or `sudo yum install jq`
   - The script will work without jq but uses a fallback text parsing method

3. **Required IAM Permissions**:
   - `s3:GetLifecycleConfiguration`
   - `s3:GetBucketLocation` (optional, for validation)

## Installation

1. Make the script executable:
   ```bash
   chmod +x check_aws_lifecycle_from_csv.sh
   ```

2. Ensure AWS CLI is configured:
   ```bash
   aws configure
   # or for SSO
   aws sso login
   ```

## Usage

### Basic Usage (Single AWS Account)

Create an input CSV file with headers:
```csv
region,bucket_name
us-east-1,my-s3-bucket
us-west-2,backup-bucket
```

Run the script:
```bash
./check_aws_lifecycle_from_csv.sh input.csv output.csv
```

### Multi-Account Usage

If you need to check buckets across multiple AWS accounts/profiles, use the 3-column format:
```csv
account,region,bucket_name
my-profile,us-east-1,my-s3-bucket
production,us-west-2,backup-bucket
```

The `account` column should match your AWS CLI profile name.

## Input CSV Format

### Format 1: Region and Bucket Name
```csv
region,bucket_name
us-east-1,my-s3-bucket
us-west-2,backup-bucket
```

### Format 2: Account, Region, and Bucket Name
```csv
account,region,bucket_name
my-aws-profile,us-east-1,my-s3-bucket
production,us-west-2,backup-bucket
```

## Output Format

The output CSV contains the following columns:

- `account` (if using multi-account format)
- `region`: AWS region
- `bucket_name`: S3 bucket name
- `lifecycle_enabled`: `True` or `False`
- `lifecycle_rules_count`: Number of lifecycle rules configured
- `lifecycle_actions`: Semicolon-separated list of action types

### Example Output

```csv
region,bucket_name,lifecycle_enabled,lifecycle_rules_count,lifecycle_actions
us-east-1,my-s3-bucket,True,2,Enabled;Transition-STANDARD_IA;Expiration
us-west-2,backup-bucket,False,0,
```

## AWS Lifecycle Actions

AWS S3 lifecycle policies support various actions:

- **Transition**: Move objects to different storage classes (e.g., STANDARD_IA, GLACIER, DEEP_ARCHIVE)
- **Expiration**: Permanently delete objects after a specified time
- **NoncurrentVersionTransition**: Transition noncurrent object versions to different storage classes
- **NoncurrentVersionExpiration**: Permanently delete noncurrent object versions
- **AbortIncompleteMultipartUpload**: Clean up incomplete multipart uploads

## Error Handling

The script handles various error conditions:

- **Bucket not found**: Outputs `ERROR_BUCKET_NOT_FOUND`
- **No lifecycle configured**: Outputs `False` for `lifecycle_enabled` with `0` rules (this is normal - not all buckets have lifecycle policies)

## Examples

### Check lifecycle policies for buckets
```bash
./check_aws_lifecycle_from_csv.sh aws_lifecycle_input.csv results.csv
```

### Check buckets across multiple accounts
```bash
./check_aws_lifecycle_from_csv.sh aws_lifecycle_input_with_account.csv results.csv
```

### Verify lifecycle compliance
After running the script, you can filter results to find buckets without lifecycle policies:
```bash
# Find buckets without lifecycle policies
grep "False" results.csv

# Find buckets with lifecycle policies
grep "True" results.csv

# Find buckets with expiration rules
grep "Expiration" results.csv
```

## Troubleshooting

### "AWS CLI is not installed"
Install AWS CLI following the official documentation: https://aws.amazon.com/cli/

### "Bucket not found or no access"
- Verify the bucket name is correct
- Check your AWS credentials: `aws sts get-caller-identity`
- Verify you have `s3:GetLifecycleConfiguration` permission
- Ensure you're using the correct region

### "NoSuchLifecycleConfiguration"
This is normal - it means the bucket doesn't have a lifecycle policy configured. The script will report `lifecycle_enabled=False` in this case.

### "Access Denied"
- Check you have the necessary IAM permissions
- Verify the bucket exists and you have access
- Ensure your AWS credentials are valid

## Notes

- The script processes buckets sequentially to avoid rate limiting
- Large CSV files may take some time to process
- The script automatically handles CRLF line endings
- Debug output is printed to stderr for troubleshooting
- Lifecycle policies are checked at the bucket level
- The script distinguishes between "no lifecycle" (normal) and "error accessing bucket" (actual error)
