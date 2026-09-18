# AWS Disk Encryption Checker

This script checks the encryption status of EBS volumes attached to AWS EC2 instances. It reads instance information from a CSV file and outputs detailed encryption information for each volume.

## Prerequisites

1. **AWS CLI**: Must be installed and configured
   - Installation: https://aws.amazon.com/cli/
   - Configuration: `aws configure` or `aws sso login`
   - Ensure you have permissions to describe EC2 instances and volumes

2. **jq** (optional but recommended): For better JSON parsing
   - macOS: `brew install jq`
   - Linux: `sudo apt-get install jq` or `sudo yum install jq`
   - The script will work without jq but uses a fallback text parsing method

3. **Required IAM Permissions**:
   - `ec2:DescribeInstances`
   - `ec2:DescribeVolumes`
   - `kms:DescribeKey` (optional, for KMS key details)

## Installation

1. Make the script executable:
   ```bash
   chmod +x check_aws_encryption_from_csv.sh
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
region,instance_id
us-east-1,i-0123456789abcdef0
us-west-2,i-0987654321fedcba0
```

Run the script:
```bash
./check_aws_encryption_from_csv.sh input.csv output.csv
```

### Multi-Account Usage

If you need to check instances across multiple AWS accounts/profiles, use the 3-column format:
```csv
account,region,instance_id
my-profile,us-east-1,i-0123456789abcdef0
production,us-west-2,i-0987654321fedcba0
```

The `account` column should match your AWS CLI profile name.

## Input CSV Format

### Format 1: Region and Instance ID
```csv
region,instance_id
us-east-1,i-0123456789abcdef0
us-west-2,i-0987654321fedcba0
```

### Format 2: Account, Region, and Instance ID
```csv
account,region,instance_id
my-aws-profile,us-east-1,i-0123456789abcdef0
production,us-west-2,i-0987654321fedcba0
```

## Output Format

The output CSV contains the following columns:

- `account` (if using multi-account format)
- `region`: AWS region
- `instance_id`: EC2 instance ID
- `volume_id`: EBS volume ID
- `device_name`: Device name (e.g., /dev/sda1)
- `encrypted`: `True` or `False`
- `encryption_type`: One of:
  - `NOT_ENCRYPTED`: Volume is not encrypted
  - `AWS_MANAGED`: Encrypted with AWS-managed key
  - `CUSTOMER_MANAGED_KMS`: Encrypted with customer-managed KMS key
- `kms_key_id`: KMS key ID or ARN (if encrypted)

### Example Output

```csv
region,instance_id,volume_id,device_name,encrypted,encryption_type,kms_key_id
us-east-1,i-0123456789abcdef0,vol-0123456789abcdef0,/dev/sda1,True,CUSTOMER_MANAGED_KMS,arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012
us-east-1,i-0123456789abcdef0,vol-0987654321fedcba0,/dev/xvdf,True,AWS_MANAGED,aws/ebs
us-west-2,i-0987654321fedcba0,vol-abcdef0123456789,/dev/sda1,False,NOT_ENCRYPTED,
```

## Error Handling

The script handles various error conditions:

- **Instance not found**: Outputs `INSTANCE_NOT_FOUND_OR_NO_ACCESS`
- **No volumes attached**: Outputs `NO_VOLUMES_FOUND`
- **Volume info unavailable**: Outputs `UNKNOWN` for encryption status

## Examples

### Check instances in a single region
```bash
./check_aws_encryption_from_csv.sh us-east-1-instances.csv results.csv
```

### Check instances across multiple accounts
```bash
./check_aws_encryption_from_csv.sh multi-account-instances.csv results.csv
```

### Verify encryption compliance
After running the script, you can filter results to find unencrypted volumes:
```bash
# Find unencrypted volumes
grep "NOT_ENCRYPTED" results.csv

# Find volumes not using customer-managed KMS
grep -v "CUSTOMER_MANAGED_KMS" results.csv | grep -v "NOT_ENCRYPTED"
```

## Troubleshooting

### "AWS CLI is not installed"
Install AWS CLI following the official documentation: https://aws.amazon.com/cli/

### "Instance not found or no access"
- Verify the instance ID is correct
- Check your AWS credentials: `aws sts get-caller-identity`
- Verify you have `ec2:DescribeInstances` permission
- Ensure you're using the correct region

### "Could not retrieve volume info"
- Check you have `ec2:DescribeVolumes` permission
- Verify the volume ID is correct
- Ensure the volume exists in the specified region

## Notes

- The script processes instances sequentially to avoid rate limiting
- Large CSV files may take some time to process
- The script automatically handles CRLF line endings
- Debug output is printed to stderr for troubleshooting
