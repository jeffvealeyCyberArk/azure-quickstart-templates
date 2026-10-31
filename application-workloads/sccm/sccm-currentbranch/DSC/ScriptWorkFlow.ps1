Param($DomainFullName,$CM,$CMUser,$DPMPName,$ClientName,$Config,$CurrentRole,$LogFolder,$CSName,$PSName)

$CSRole = "CAS"
$PSRole = "PS1"

$Role = $PSRole
if($CurrentRole -eq "CS")
{
    $Role = $CSRole
}
$ProvisionToolPath = "$env:windir\temp\ProvisionScript"
if(!(Test-Path $ProvisionToolPath))
{
    New-Item $ProvisionToolPath -ItemType directory | Out-Null
}

$ConfigurationFile = Join-Path -Path $ProvisionToolPath -ChildPath "$Role.json"

if (Test-Path -Path $ConfigurationFile) 
{
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
} 
else 
{
    if($Config -eq "Standalone")
    {
        [hashtable]$Actions = @{
            InstallSCCM = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
            UpgradeSCCM = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
            InstallDP = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
            InstallMP = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
            InstallClient = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
        }
    }
    else 
    {
        if($CurrentRole -eq "CS")
        {
            [hashtable]$Actions = @{
                InstallSCCM = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                UpgradeSCCM = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                PSReadytoUse = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
            }
        }
        elseif($CurrentRole -eq "PS") 
        {
            [hashtable]$Actions = @{
                WaitingForCASFinsihedInstall = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                InstallSCCM = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                InstallDP = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                InstallMP = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                InstallClient = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
            }
        }
    }
    $Configuration = New-Object -TypeName psobject -Property $Actions
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
}

if($Config -eq "Standalone")
{
    #Install CM and Config
    if($Configuration.InstallSCCM.Status -ne 'Completed' -or $Configuration.UpgradeSCCM.Status -ne 'Completed')
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Starting InstallAndUpdateSCCM..." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallAndUpdateSCCM.ps1"
        . $ScriptFile $DomainFullName $CM $CMUser $Role $ProvisionToolPath
    }
    else
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Skipping InstallAndUpdateSCCM - already completed." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
    }

    # Reload configuration in case it was updated
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

    #Install DP
    if($Configuration.InstallDP.Status -ne 'Completed')
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Starting InstallDP..." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallDP.ps1"
        . $ScriptFile $DomainFullName $DPMPName $Role $ProvisionToolPath
    }
    else
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Skipping InstallDP - already completed." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
    }

    # Reload configuration
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

    #Install MP
    if($Configuration.InstallMP.Status -ne 'Completed')
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Starting InstallMP..." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallMP.ps1"
        . $ScriptFile $DomainFullName $DPMPName $Role $ProvisionToolPath
    }
    else
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Skipping InstallMP - already completed." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
    }

    # Reload configuration
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

    #Install Client
    if($Configuration.InstallClient.Status -ne 'Completed')
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Starting InstallClient..." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallClient.ps1"
        . $ScriptFile $DomainFullName $CMUser $ClientName $DPMPName $Role $ProvisionToolPath
    }
    else
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Skipping InstallClient - already completed." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
    }
}
else {
    if($CurrentRole -eq "CS")
    {
        #Install CM and Config
        if($Configuration.InstallSCCM.Status -ne 'Completed' -or $Configuration.UpgradeSCCM.Status -ne 'Completed' -or $Configuration.PSReadytoUse.Status -ne 'Completed')
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Starting InstallCSForHierarchy..." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
            $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallCSForHierarchy.ps1"
            . $ScriptFile $DomainFullName $CM $CMUser $Role $ProvisionToolPath $LogFolder $PSName $PSRole
        }
        else
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Skipping InstallCSForHierarchy - already completed." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
        }
    }
    elseif($CurrentRole -eq "PS")
    {
        #Install CM and Config
        if($Configuration.WaitingForCASFinsihedInstall.Status -ne 'Completed' -or $Configuration.InstallSCCM.Status -ne 'Completed')
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Starting InstallPSForHierarchy..." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
            $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallPSForHierarchy.ps1"
            . $ScriptFile $DomainFullName $CM $CMUser $Role $ProvisionToolPath $CSName $CSRole $LogFolder
        }
        else
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Skipping InstallPSForHierarchy - already completed." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
        }

        # Reload configuration
        $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
    
        #Install DP
        if($Configuration.InstallDP.Status -ne 'Completed')
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Starting InstallDP..." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
            $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallDP.ps1"
            . $ScriptFile $DomainFullName $DPMPName $Role $ProvisionToolPath
        }
        else
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Skipping InstallDP - already completed." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
        }

        # Reload configuration
        $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
    
        #Install MP
        if($Configuration.InstallMP.Status -ne 'Completed')
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Starting InstallMP..." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
            $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallMP.ps1"
            . $ScriptFile $DomainFullName $DPMPName $Role $ProvisionToolPath
        }
        else
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Skipping InstallMP - already completed." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
        }

        # Reload configuration
        $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

        #Install Client
        if($Configuration.InstallClient.Status -ne 'Completed')
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Starting InstallClient..." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
            $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallClient.ps1"
            . $ScriptFile $DomainFullName $CMUser $ClientName $DPMPName $Role $ProvisionToolPath
        }
        else
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Skipping InstallClient - already completed." | Out-File -Append "$ProvisionToolPath\ScriptWorkFlow.log"
        }
    }
}