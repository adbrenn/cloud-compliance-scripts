# cloud-compliance-scripts

Collection of operational and GRC automation scripts. The current focus is CSV-driven compliance checks for major cloud providers.

## Repository structure

```text
cloud-compliance-scripts/
├── README.md
└── cloud-providers/
    ├── AWS-Encryption-Check/
    ├── AWS-Lifecycle-Check/
    ├── Azure-Encryption-Check/
    ├── Azure-Lifecycle-Check/
    ├── GCP-Encryption-Check/
    └── GCP-Lifecycle-Check/
```

### `cloud-providers/`

Scripts that validate encryption and lifecycle configuration across AWS, Azure, and Google Cloud. Each folder is self-contained and typically includes:

- A shell script that accepts an input CSV and writes an output CSV
- A sample input CSV with the expected headers
- A README with prerequisites, usage, output fields, and troubleshooting

| Folder | Purpose |
| --- | --- |
| [AWS-Encryption-Check](cloud-providers/AWS-Encryption-Check) | Check EBS volume encryption for EC2 instances |
| [AWS-Lifecycle-Check](cloud-providers/AWS-Lifecycle-Check) | Check S3 bucket lifecycle policies |
| [Azure-Encryption-Check](cloud-providers/Azure-Encryption-Check) | Check managed disk encryption for Azure VMs |
| [Azure-Lifecycle-Check](cloud-providers/Azure-Lifecycle-Check) | Check Blob Storage lifecycle management policies |
| [GCP-Encryption-Check](cloud-providers/GCP-Encryption-Check) | Check persistent disk encryption for GCE VMs |
| [GCP-Lifecycle-Check](cloud-providers/GCP-Lifecycle-Check) | Check Cloud Storage bucket lifecycle policies |

## Common usage pattern

1. Authenticate with the relevant cloud CLI (`aws`, `az`, or `gcloud`).
2. Fill the sample input CSV for the check you want to run.
3. Make the script executable and run it:

```bash
cd cloud-providers/<check-folder>
chmod +x check_*.sh
./check_*.sh input.csv output.csv
```

See each folder’s README for provider-specific auth, required permissions, CSV formats, and output columns.
