# Azure Blob Storage Lifecycle Policy Checker

This script checks the lifecycle management policy configuration for Azure Blob Storage containers. It reads storage account and container information from a CSV file and outputs detailed lifecycle policy information.

## Prerequisites

1. **Azure CLI**: Must be installed and configured
   - Installation: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
   - Authentication: `az login` or `az login --use-device-code`
   - Ensure you have permissions to read storage account and management policy information

2. **jq** (required): For JSON parsing
   - macOS: `brew install jq`
   - Linux: `sudo apt-get install jq` or `sudo yum install jq`
   - Windows: Download from https://stedolan.github.io/jq/download/

3. **Required Azure Permissions**:
   - `Microsoft.Storage/storageAccounts/read`
   - `Microsoft.Storage/storageAccounts/blobServices/read`
   - `Microsoft.Storage/storageAccounts/managementPolicies/read`

## Installation

1. Make the script executable:
   ```bash
   chmod +x check_azure_lifecycle_from_csv.sh
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
resource_group,storage_account,container_name
my-resource-group,mystorageaccount,my-container
production-rg,prodstorage,backup-container
```

Run the script:
```bash
./check_azure_lifecycle_from_csv.sh input.csv output.csv
```

### Multi-Subscription Usage

If you need to check containers across multiple Azure subscriptions, use the 4-column format:
```csv
subscription,resource_group,storage_account,container_name
my-subscription-id,my-resource-group,mystorageaccount,my-container
production-sub,production-rg,prodstorage,backup-container
```

The `subscription` column should match your Azure subscription ID or name.

## Input CSV Format

### Format 1: Resource Group, Storage Account, and Container Name
```csv
resource_group,storage_account,container_name
my-resource-group,mystorageaccount,my-container
production-rg,prodstorage,backup-container
```

### Format 2: Subscription, Resource Group, Storage Account, and Container Name
```csv
subscription,resource_group,storage_account,container_name
my-subscription-id,my-resource-group,mystorageaccount,my-container
production-sub,production-rg,prodstorage,backup-container
```

## Output Format

The output CSV contains the following columns:

- `subscription` (if using multi-subscription format)
- `resource_group`: Azure resource group name
- `storage_account`: Storage account name
- `container_name`: Blob container name
- `lifecycle_enabled`: `True` or `False`
- `lifecycle_rules_count`: Number of lifecycle rules configured
- `lifecycle_actions`: Semicolon-separated list of action types

### Example Output

```csv
resource_group,storage_account,container_name,lifecycle_enabled,lifecycle_rules_count,lifecycle_actions
my-resource-group,mystorageaccount,my-container,True,2,tierToArchive;tierToCool;delete
production-rg,prodstorage,backup-container,False,0,
```

## Azure Lifecycle Actions

Azure Blob Storage lifecycle management policies support various actions:

- **tierToArchive**: Move blobs to Archive storage tier
- **tierToCool**: Move blobs to Cool storage tier
- **delete**: Permanently delete blobs
- **delete** (snapshot): Delete blob snapshots
- **delete** (version): Delete blob versions

## Error Handling

The script handles various error conditions:

- **Storage account not found**: Outputs `ERROR_STORAGE_ACCOUNT_NOT_FOUND`
- **Container not found**: Outputs `ERROR_CONTAINER_NOT_FOUND`
- **Subscription error**: Outputs `SUBSCRIPTION_ERROR` if subscription cannot be set
- **No lifecycle configured**: Outputs `False` for `lifecycle_enabled` with `0` rules (this is normal - not all containers have lifecycle policies)

## Examples

### Check lifecycle policies for containers
```bash
./check_azure_lifecycle_from_csv.sh azure_lifecycle_input.csv results.csv
```

### Check containers across multiple subscriptions
```bash
./check_azure_lifecycle_from_csv.sh azure_lifecycle_input_with_subscription.csv results.csv
```

### Verify lifecycle compliance
After running the script, you can filter results to find containers without lifecycle policies:
```bash
# Find containers without lifecycle policies
grep "False" results.csv

# Find containers with lifecycle policies
grep "True" results.csv

# Find containers with delete actions
grep "delete" results.csv
```

## Troubleshooting

### "Azure CLI is not installed"
Install Azure CLI following the official documentation: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli

### "jq is not installed"
The script requires jq for JSON parsing. Install it using:
- macOS: `brew install jq`
- Linux: `sudo apt-get install jq` or `sudo yum install jq`

### "Storage account not found or no access"
- Verify the storage account name and resource group are correct
- Check your Azure credentials: `az account show`
- Verify you have `Microsoft.Storage/storageAccounts/read` permission
- Ensure you're using the correct subscription

### "Container not found"
- Verify the container name is correct
- Check the container exists in the specified storage account
- Ensure you have access to the container

### "Could not set subscription"
- Verify the subscription ID or name is correct
- Check you have access to the subscription: `az account list`
- Ensure you're logged in: `az account show`

## Notes

- The script processes containers sequentially to avoid rate limiting
- Large CSV files may take some time to process
- The script automatically handles CRLF line endings
- Debug output is printed to stderr for troubleshooting
- Lifecycle policies are configured at the storage account level (not container level), but the script reports per-container for easier tracking
- Azure lifecycle management policies apply to all containers in a storage account
- The script checks for management policies which are the modern way to configure lifecycle in Azure

## Differences from AWS/GCP Scripts

- Azure uses storage accounts and containers instead of just buckets
- Lifecycle policies are configured at the storage account level (not container level)
- Requires resource group information
- Supports subscription switching per CSV row
- Uses Azure Management Policies for lifecycle configuration
