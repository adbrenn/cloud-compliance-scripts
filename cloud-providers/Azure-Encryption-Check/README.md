# Azure Disk Encryption Checker

This script checks the encryption status of managed disks attached to Azure VMs. It reads VM information from a CSV file and outputs detailed encryption information for each disk (OS and data disks).

## Prerequisites

1. **Azure CLI**: Must be installed and configured
   - Installation: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
   - Authentication: `az login` or `az login --use-device-code`
   - Ensure you have permissions to read VM and disk information

2. **jq** (required): For JSON parsing
   - macOS: `brew install jq`
   - Linux: `sudo apt-get install jq` or `sudo yum install jq`
   - Windows: Download from https://stedolan.github.io/jq/download/

3. **Required Azure Permissions**:
   - `Microsoft.Compute/virtualMachines/read`
   - `Microsoft.Compute/disks/read`

## Installation

1. Make the script executable:
   ```bash
   chmod +x check_azure_encryption_from_csv.sh
   ```

2. Ensure Azure CLI is configured:
   ```bash
   az login
   # or for specific subscription
   az account set --subscription "subscription-name-or-id"
   ```

3. Install jq (required):
   ```bash
   # macOS
   brew install jq
   
   # Linux (Ubuntu/Debian)
   sudo apt-get install jq
   
   # Linux (RHEL/CentOS)
   sudo yum install jq
   ```

## Usage

### Basic Usage (Single Subscription)

Create an input CSV file with headers:
```csv
resource_group,vm_name
my-resource-group,my-vm-01
production-rg,web-server-01
```

Run the script:
```bash
./check_azure_encryption_from_csv.sh input.csv output.csv
```

### Multi-Subscription Usage

If you need to check VMs across multiple Azure subscriptions, use the 3-column format:
```csv
subscription,resource_group,vm_name
my-subscription-id,my-resource-group,my-vm-01
production-sub,production-rg,web-server-01
```

The `subscription` column should match your Azure subscription ID or name.

## Input CSV Format

### Format 1: Resource Group and VM Name
```csv
resource_group,vm_name
my-resource-group,my-vm-01
production-rg,web-server-01
```

### Format 2: Subscription, Resource Group, and VM Name
```csv
subscription,resource_group,vm_name
my-subscription-id,my-resource-group,my-vm-01
production-sub,production-rg,web-server-01
```

## Output Format

The output CSV contains the following columns:

- `subscription` (if using multi-subscription format)
- `resource_group`: Azure resource group name
- `vm_name`: Virtual machine name
- `disk_name`: Managed disk name
- `disk_type`: Either "OS" or "Data"
- `encrypted`: `True` or `False`
- `encryption_type`: One of:
  - `NOT_ENCRYPTED`: Disk is not encrypted
  - `PLATFORM_MANAGED`: Encrypted with Azure platform-managed keys
  - `CUSTOMER_MANAGED`: Encrypted with customer-managed keys (Disk Encryption Set)
  - `VM_LEVEL_ENCRYPTION`: Encrypted using VM-level encryption (older method like Azure Disk Encryption)
- `encryption_set_id`: Disk Encryption Set ID or ARN (if customer-managed)

### Example Output

```csv
resource_group,vm_name,disk_name,disk_type,encrypted,encryption_type,encryption_set_id
my-resource-group,my-vm-01,my-vm-01_OsDisk_1_abc123,OS,True,CUSTOMER_MANAGED,/subscriptions/xxx/resourceGroups/xxx/providers/Microsoft.Compute/diskEncryptionSets/xxx
my-resource-group,my-vm-01,my-vm-01_DataDisk_0,Data,True,PLATFORM_MANAGED,
production-rg,web-server-01,web-server-01_OsDisk_1_def456,OS,False,NOT_ENCRYPTED,
```

## Azure Disk Encryption Types

Azure supports several disk encryption methods:

1. **Platform-Managed Encryption**: Default encryption at rest using Azure-managed keys
2. **Customer-Managed Keys (CMK)**: Encryption using customer-managed keys stored in Azure Key Vault via Disk Encryption Sets
3. **VM-Level Encryption**: Older encryption methods like Azure Disk Encryption (ADE) that encrypt at the VM level

The script detects all of these methods and reports accordingly.

## Error Handling

The script handles various error conditions:

- **VM not found**: Outputs `VM_NOT_FOUND_OR_NO_ACCESS`
- **No disks attached**: Outputs `NO_DISKS_FOUND`
- **Disk info unavailable**: Outputs `UNKNOWN` for encryption status
- **Subscription error**: Outputs `SUBSCRIPTION_ERROR` if subscription cannot be set

## Examples

### Check VMs in a single subscription
```bash
./check_azure_encryption_from_csv.sh azure_input.csv results.csv
```

### Check VMs across multiple subscriptions
```bash
./check_azure_encryption_from_csv.sh multi-subscription-input.csv results.csv
```

### Verify encryption compliance
After running the script, you can filter results to find unencrypted disks:
```bash
# Find unencrypted disks
grep "NOT_ENCRYPTED" results.csv

# Find disks not using customer-managed keys
grep -v "CUSTOMER_MANAGED" results.csv | grep -v "NOT_ENCRYPTED"
```

## Troubleshooting

### "Azure CLI is not installed"
Install Azure CLI following the official documentation: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli

### "jq is not installed"
The script requires jq for JSON parsing. Install it using:
- macOS: `brew install jq`
- Linux: `sudo apt-get install jq` or `sudo yum install jq`

### "VM not found or no access"
- Verify the VM name and resource group are correct
- Check your Azure credentials: `az account show`
- Verify you have `Microsoft.Compute/virtualMachines/read` permission
- Ensure you're using the correct subscription

### "Could not retrieve disk info"
- Check you have `Microsoft.Compute/disks/read` permission
- Verify the disk exists in the specified resource group
- Ensure the disk is a managed disk (not unmanaged)

### "Could not set subscription"
- Verify the subscription ID or name is correct
- Check you have access to the subscription: `az account list`
- Ensure you're logged in: `az account show`

## Notes

- The script processes VMs sequentially to avoid rate limiting
- Large CSV files may take some time to process
- The script automatically handles CRLF line endings
- Debug output is printed to stderr for troubleshooting
- The script checks both OS disks and data disks
- For VMs with many data disks, processing may take longer

## Differences from AWS/GCP Scripts

- Azure uses resource groups instead of regions for organization
- Azure has both OS disks and data disks (both are checked)
- Azure supports Disk Encryption Sets for customer-managed keys
- Azure CLI requires explicit subscription context (can be set per-row in CSV)
