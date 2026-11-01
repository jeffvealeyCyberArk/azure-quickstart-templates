# Automated SCCM/ConfigMgr Deployment - Azure ARM Template

This ARM template deploys a fully automated Microsoft Configuration Manager (SCCM/ConfigMgr) environment in Azure, including automatic upgrades to the latest version (CM 2609).

## Overview

The template creates a complete SCCM lab environment with:
- **Domain Controller (DC01)** - Windows Server 2022
- **Primary Site Server (PS01)** - SQL Server 2019 on Windows Server 2019
- **Distribution Point / Management Point (DPMP01)** - Windows Server 2022
- **Client machines (Cl01, Cl02, Cl03)** - Windows 11 Enterprise

## Features

### Fully Automated Deployment
- Installs SCCM baseline and automatically upgrades to the latest version
- Skips intermediate versions (e.g., jumps from 2509 directly to 2609)
- Handles all ODBC driver prerequisites automatically
- Silent CM console upgrades after each site update
- Resumes after reboots using state tracking

### ODBC Driver Management
The scripts automatically manage ODBC driver versions required by different CM versions:
| CM Version | ODBC Requirement | Action |
|------------|------------------|--------|
| Base - 2509 | 18.5.2.1 | Installed during initial setup |
| Before 2609 | 18.6.2.1 | Upgraded before 2609 install |
| After 2609 | 18.7.1.1 | Upgraded after 2609 completes |

## Prerequisites

1. **Azure Subscription** with permissions to create resources
2. **Resource Group** in a supported Azure region (recommended: `Successlab-sccm-lab`)
3. **Sufficient quota** for the VM sizes specified

## Security Warning

> **IMPORTANT**: The default Network Security Group (NSG) allows RDP (port 3389) from **any source IP address**. This is insecure for production or long-running lab environments.
>
> **After deployment, immediately update the NSG to restrict RDP access:**
> 1. Navigate to your Resource Group in Azure Portal
> 2. Select the NSG (named `<prefix>nsg`, e.g., `slab-nsg`)
> 3. Click "Inbound security rules"
> 4. Edit the `default-allow-rdp` rule
> 5. Change "Source" from "Any" to "IP Addresses"
> 6. Enter your public IP address(es) in the "Source IP addresses/CIDR ranges" field
> 7. Click "Save"
>
> To find your public IP: https://whatismyipaddress.com/

## Deployment Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `prefix` | Prefix for all resource names (2-12 chars) | Required |
| `ClientsCount` | Number of client VMs (1-3) | 1 |
| `configuration` | Standalone or Hierarchy | Standalone |
| `vmSize` | Size for DC, DPMP, and clients | Standard_B2s |
| `SQLVmSize` | Size for Primary Site (SQL) | Standard_B2ms |
| `adminUsername` | Administrator username | Required |
| `adminPassword` | Administrator password | Required |
| `_artifactsLocation` | Base URL for deployment artifacts | GitHub raw URL |

## Deployment Steps

### Option 1: Azure Portal
1. Click the "Deploy to Azure" button or upload the template
2. Fill in the required parameters
3. Review and create

### Option 2: Azure CLI
```bash
az deployment group create \
  --resource-group Successlab-sccm-lab \
  --template-file sccm_quickstart_successlab.json \
  --parameters prefix=slab- adminUsername=youradmin adminPassword=<your-password>
```

### Option 3: PowerShell
```powershell
New-AzResourceGroupDeployment `
  -ResourceGroupName "Successlab-sccm-lab" `
  -TemplateFile sccm_quickstart_successlab.json `
  -prefix "slab-" `
  -adminUsername "youradmin" `
  -adminPassword (ConvertTo-SecureString "<your-password>" -AsPlainText -Force)
```

## VMs Created

For a Standalone deployment with prefix "slab-":

| VM Name | Role | IP Address | OS |
|---------|------|------------|-----|
| slab-dc01 | Domain Controller | 172.16.0.4 | Windows Server 2022 |
| slab-dpmp01 | Distribution/Management Point | 172.16.0.5 | Windows Server 2022 |
| slab-ps01 | Primary Site Server | 172.16.0.6 | SQL Server 2019 |
| slab-cl01 | Client | 172.16.0.7 | Windows 11 |

## Monitoring Deployment Progress

### Key Log Files on PS01 (Primary Site Server)

Connect via RDP to the PS01 server and monitor these logs:

```powershell
# Navigate to the provisioning scripts folder
cd C:\Windows\Temp\ProvisionScript

# Monitor SCCM installation log
Get-Content -Wait .\InstallSCCMlog.txt

# Monitor upgrade progress
Get-Content -Wait .\UpgradeCMlog.txt

# Check workflow status
Get-Content .\PS1.json | ConvertFrom-Json | Format-List
```

### Deployment Phases

1. **Phase 1: DSC Configuration** (~30-45 minutes)
   - Domain join
   - Prerequisites installation (.NET 4.8, ODBC drivers, ADK, etc.)
   - SQL configuration
   - Log: Check Azure portal for DSC extension status

2. **Phase 2: SCCM Installation** (~45-60 minutes)
   - Base SCCM installation
   - Log: `InstallSCCMlog.txt`

3. **Phase 3: SCCM Upgrades** (~2-4 hours)
   - Upgrade to CM 2509
   - Console upgrade
   - ODBC 18.6.2.1 installation
   - Upgrade to CM 2609
   - Console upgrade
   - ODBC 18.7.1.1 installation
   - Log: `UpgradeCMlog.txt`

4. **Phase 4: Site System Roles** (~30 minutes)
   - Distribution Point installation
   - Management Point installation
   - Client push installation
   - Logs: `InstallDP.log`, `InstallMP.log`, `InstallClient.log`

### Expected Log Messages

**Successful upgrade flow:**
```
[timestamp] Update package is Configuration Manager 2509
[timestamp] SCCM Upgrade Complete, current pack Configuration Manager 2509 state is INSTALL_SUCCESS
[timestamp] Upgrading CM Console to match site version...
[timestamp] CM Console upgrade completed. Reloading CM module...
[timestamp] Selected highest major version update: Configuration Manager 2609
[timestamp] Detected CM 2609 update - using Pre2609 ODBC requirement (18.6.2.1)
[timestamp] ODBC Driver upgrade required: 18.5.2.1 -> 18.6.2.1
[timestamp] ODBC Driver successfully installed/upgraded to version 18.6.2.1
[timestamp] SCCM Upgrade Complete, current pack Configuration Manager 2609 state is INSTALL_SUCCESS
[timestamp] CM 2609 or later detected. Upgrading ODBC Driver to 18.7.1.1...
[timestamp] ODBC Driver upgrade to 18.7.1.1 completed successfully.
[timestamp] Final CM Console upgrade completed successfully.
```

## Troubleshooting

### DSC Extension Fails
- Check Azure portal for detailed error messages
- Verify `_artifactsLocation` URL is accessible
- Ensure the ZIP file contains `TemplateHelpDSC` folder

### SCCM Upgrade Stuck
1. RDP to PS01
2. Check `UpgradeCMlog.txt` for current state
3. If stuck at "ENABLED" state, restart SMS_EXECUTIVE service:
   ```powershell
   Restart-Service -Name "SMS_EXECUTIVE" -Force
   ```

### Console Version Mismatch
The scripts automatically upgrade the console, but if manual intervention is needed:
```powershell
$CMInstallPath = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory'
Start-Process "$CMInstallPath\tools\ConsoleSetup\ConsoleSetup.exe" -ArgumentList "/q" -Wait
```

### Check Workflow Status
```powershell
Get-Content C:\Windows\Temp\ProvisionScript\PS1.json | ConvertFrom-Json
```

Status values:
- `NotStart` - Step hasn't begun
- `Running` - Step in progress
- `Completed` - Step finished successfully
- `Error` - Step failed

## Post-Deployment

After successful deployment:

1. **Access CM Console**: RDP to PS01, open Configuration Manager Console
2. **Verify Site Status**: Administration > Site Configuration > Sites
3. **Check Components**: Monitoring > System Status > Component Status
4. **Verify Client**: Check that Cl01 appears in Assets and Compliance > Devices

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Azure Virtual Network                     │
│                      172.16.0.0/16                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │    DC01     │  │   DPMP01    │  │    PS01     │         │
│  │ 172.16.0.4  │  │ 172.16.0.5  │  │ 172.16.0.6  │         │
│  │             │  │             │  │             │         │
│  │ - AD DS     │  │ - DP Role   │  │ - Site Svr  │         │
│  │ - DNS       │  │ - MP Role   │  │ - SQL 2019  │         │
│  │ - DHCP      │  │             │  │ - Console   │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
│                                                             │
│  ┌─────────────┐                                           │
│  │    Cl01     │  (Additional clients: Cl02, Cl03)         │
│  │ 172.16.0.7  │                                           │
│  │             │                                           │
│  │ - Win 11    │                                           │
│  │ - CM Client │                                           │
│  └─────────────┘                                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Files in This Template

| File | Description |
|------|-------------|
| `azuredeploy.json` | Main ARM template |
| `DSC/DCConfiguration.zip` | DSC configurations and scripts |
| `DSC/PSConfiguration.ps1` | Primary Site DSC configuration |
| `DSC/InstallAndUpdateSCCM.ps1` | SCCM install and upgrade script |
| `DSC/ScriptWorkFlow.ps1` | Workflow orchestrator |
| `DSC/TemplateHelpDSC/` | Custom DSC resources |

## Version History

- **Current**: Supports automatic upgrade to CM 2609
- Includes ODBC driver management (18.5.2.1 → 18.6.2.1 → 18.7.1.1)
- Silent console upgrades after each site update
- Resume-after-reboot capability

## License

This template is provided as-is for lab and testing purposes.

## Contributing

Issues and pull requests are welcome at the GitHub repository.
