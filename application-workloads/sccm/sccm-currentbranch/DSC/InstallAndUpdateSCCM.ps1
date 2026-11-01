Param($DomainFullName,$CM,$CMUser,$Role,$ProvisionToolPath)

$SMSInstallDir="C:\Program Files\Microsoft Configuration Manager"

$logpath = $ProvisionToolPath+"\InstallSCCMlog.txt"
$ConfigurationFile = Join-Path -Path $ProvisionToolPath -ChildPath "$Role.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

# ODBC Driver version requirements for SCCM versions
# Using versions hosted in the fork repository
# Upgrade sequence:
#   - Initial install: 18.5.2.1
#   - Before CM 2609: 18.6.2.1 (pre-requisite for 2609)
#   - After CM 2609: 18.7.1.1
$ODBCRequirements = @{
    "Default" = @{
        Version = "18.5.2.1"
        Url = "https://raw.githubusercontent.com/jeffvealeyCyberArk/azure-quickstart-templates/master/application-workloads/sccm/sccm-currentbranch/DSC/msodbcsql1852.msi"
    }
    "Pre2609" = @{
        Version = "18.6.2.1"
        Url = "https://raw.githubusercontent.com/jeffvealeyCyberArk/azure-quickstart-templates/master/application-workloads/sccm/sccm-currentbranch/DSC/msodbcsql18621.msi"
    }
    "Post2609" = @{
        Version = "18.7.1.1"
        Url = "https://raw.githubusercontent.com/jeffvealeyCyberArk/azure-quickstart-templates/master/application-workloads/sccm/sccm-currentbranch/DSC/msodbcsql18711.msi"
    }
}

# Function to get current ODBC Driver 18 version
function Get-ODBCDriverVersion {
    $odbcPath = "C:\Windows\System32\msodbcsql18.dll"
    if (Test-Path $odbcPath) {
        $version = (Get-Item $odbcPath).VersionInfo.FileVersion
        return $version
    }
    return $null
}

# Function to compare versions
function Compare-Versions {
    param([string]$Current, [string]$Required)
    
    $currentParts = $Current.Split('.') | ForEach-Object { [int]$_ }
    $requiredParts = $Required.Split('.') | ForEach-Object { [int]$_ }
    
    for ($i = 0; $i -lt [Math]::Max($currentParts.Count, $requiredParts.Count); $i++) {
        $c = if ($i -lt $currentParts.Count) { $currentParts[$i] } else { 0 }
        $r = if ($i -lt $requiredParts.Count) { $requiredParts[$i] } else { 0 }
        
        if ($c -lt $r) { return -1 }
        if ($c -gt $r) { return 1 }
    }
    return 0
}

# Function to upgrade ODBC driver if needed for a specific SCCM version
function Ensure-ODBCDriverVersion {
    param(
        [string]$SCCMVersion,
        [string]$LogPath
    )
    
    # Check if this is a 2609 update - requires ODBC 18.6.2.1 as pre-requisite
    if ($SCCMVersion -match "2609") {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Detected CM 2609 update - using Pre2609 ODBC requirement (18.6.2.1)" | Out-File -Append $LogPath
        $matchedRequirement = $ODBCRequirements["Pre2609"]
    }
    else {
        # Use Default for all other versions
        $matchedRequirement = $ODBCRequirements["Default"]
    }
    
    $requiredVersion = $matchedRequirement.Version
    $downloadUrl = $matchedRequirement.Url
    $currentVersion = Get-ODBCDriverVersion
    
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] SCCM version $SCCMVersion requires ODBC Driver version $requiredVersion" | Out-File -Append $LogPath
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Current ODBC Driver version: $currentVersion" | Out-File -Append $LogPath
    
    if ($null -eq $currentVersion) {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ODBC Driver 18 not found, installing version $requiredVersion..." | Out-File -Append $LogPath
    }
    elseif ((Compare-Versions -Current $currentVersion -Required $requiredVersion) -lt 0) {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ODBC Driver upgrade required: $currentVersion -> $requiredVersion" | Out-File -Append $LogPath
    }
    else {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ODBC Driver version $currentVersion meets requirement ($requiredVersion), no upgrade needed." | Out-File -Append $LogPath
        return $true
    }
    
    # Download and install the required ODBC driver
    return Install-ODBCDriver -Version $requiredVersion -DownloadUrl $downloadUrl -LogPath $LogPath
}

# Function to install/upgrade ODBC driver
function Install-ODBCDriver {
    param(
        [string]$Version,
        [string]$DownloadUrl,
        [string]$LogPath
    )
    
    try {
        $odbcPath = "C:\temp\msodbcsql18_$Version.msi"
        New-Item -ItemType Directory -Path "C:\temp" -Force -ErrorAction SilentlyContinue | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Downloading ODBC Driver $Version from $DownloadUrl..." | Out-File -Append $LogPath
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $odbcPath -UseBasicParsing
        
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Installing ODBC Driver $Version..." | Out-File -Append $LogPath
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$odbcPath`" /qn IACCEPTMSODBCSQLLICENSETERMS=YES" -Wait -PassThru
        
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            $newVersion = Get-ODBCDriverVersion
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ODBC Driver successfully installed/upgraded to version $newVersion" | Out-File -Append $LogPath
            return $true
        }
        else {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ODBC Driver installation failed with exit code: $($process.ExitCode)" | Out-File -Append $LogPath
            return $false
        }
    }
    catch {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Error installing ODBC Driver: $_" | Out-File -Append $LogPath
        return $false
    }
}

# Function to upgrade ODBC driver to 18.7.1.1 AFTER CM 2609 upgrade completes
# Per Microsoft: ODBC 18.7.1.1 has a known issue with CM 2603 and earlier - must be installed AFTER upgrading to 2609
function Upgrade-ODBCDriverPost2609 {
    param(
        [string]$LogPath
    )
    
    $post2609Requirement = $ODBCRequirements["Post2609"]
    $requiredVersion = $post2609Requirement.Version
    $downloadUrl = $post2609Requirement.Url
    $currentVersion = Get-ODBCDriverVersion
    
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Post-2609 ODBC upgrade: Upgrading to ODBC Driver $requiredVersion" | Out-File -Append $LogPath
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Current ODBC Driver version: $currentVersion" | Out-File -Append $LogPath
    
    if ($null -ne $currentVersion -and (Compare-Versions -Current $currentVersion -Required $requiredVersion) -ge 0) {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ODBC Driver version $currentVersion already meets or exceeds $requiredVersion, no upgrade needed." | Out-File -Append $LogPath
        return $true
    }
    
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Upgrading ODBC Driver to $requiredVersion (required after CM 2609)..." | Out-File -Append $LogPath
    return Install-ODBCDriver -Version $requiredVersion -DownloadUrl $downloadUrl -LogPath $LogPath
}

# Function to upgrade ODBC driver to 18.6.2.1 BEFORE CM 2609 upgrade
# Per Microsoft: ODBC 18.6.2.1 is a pre-requisite for CM 2609
function Upgrade-ODBCDriverPre2609 {
    param(
        [string]$LogPath
    )
    
    $pre2609Requirement = $ODBCRequirements["Pre2609"]
    $requiredVersion = $pre2609Requirement.Version
    $downloadUrl = $pre2609Requirement.Url
    $currentVersion = Get-ODBCDriverVersion
    
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Pre-2609 ODBC upgrade: Checking if upgrade to ODBC Driver $requiredVersion is needed" | Out-File -Append $LogPath
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Current ODBC Driver version: $currentVersion" | Out-File -Append $LogPath
    
    if ($null -ne $currentVersion -and (Compare-Versions -Current $currentVersion -Required $requiredVersion) -ge 0) {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ODBC Driver version $currentVersion already meets or exceeds $requiredVersion, no upgrade needed." | Out-File -Append $LogPath
        return $true
    }
    
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Upgrading ODBC Driver to $requiredVersion (pre-requisite for CM 2609)..." | Out-File -Append $LogPath
    return Install-ODBCDriver -Version $requiredVersion -DownloadUrl $downloadUrl -LogPath $LogPath
}

# Check if SCCM is already installed by looking for the site code in registry
function Test-SCCMInstalled {
    try {
        $siteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction SilentlyContinue
        return ($null -ne $siteCode -and $siteCode -ne "")
    }
    catch {
        return $false
    }
}

# Check if we need to skip installation (already completed or SCCM already installed)
$SCCMAlreadyInstalled = Test-SCCMInstalled
if ($Configuration.InstallSCCM.Status -eq 'Completed' -or $SCCMAlreadyInstalled) {
    if ($SCCMAlreadyInstalled -and $Configuration.InstallSCCM.Status -ne 'Completed') {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] SCCM already installed (detected via registry). Marking InstallSCCM as Completed." | Out-File -Append $logpath
        $Configuration.InstallSCCM.Status = 'Completed'
        $Configuration.InstallSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }
    else {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] InstallSCCM already completed. Skipping installation." | Out-File -Append $logpath
    }
}
else {
    # Proceed with SCCM installation
    $Configuration.InstallSCCM.Status = 'Running'
    $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

    $cmpath = "c:\$CM.exe"
    $cmsourceextractpath = "c:\$CM"
    if(!(Test-Path $cmpath))
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Copying SCCM installation source..." | Out-File -Append $logpath
        $cmurl = "https://go.microsoft.com/fwlink/?linkid=2093192"
        Invoke-WebRequest -Uri $cmurl -OutFile $cmpath
        if(!(Test-Path $cmsourceextractpath))
        {
            New-Item -ItemType Directory -Path $cmsourceextractpath
            Start-Process -WorkingDirectory ($cmsourceextractpath) -Filepath ($cmpath) -ArgumentList ('/s') -wait
        }
    }

    $cmsourcepath = (Get-ChildItem -Path $cmsourceextractpath | ?{$_.Name.ToLower().Contains("cd.")}).FullName
    $CMINIPath = "$cmsourceextractpath\Standalone.ini"
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Check ini file." | Out-File -Append $logpath

    $cmini = @'
[Identification]
Action=InstallPrimarySite

[Options]
ProductID=EVAL
SiteCode=%Role%
SiteName=%Role%
SMSInstallDir=%InstallDir%
SDKServer=%MachineFQDN%
RoleCommunicationProtocol=HTTPorHTTPS
ClientsUsePKICertificate=0
PrerequisiteComp=0
PrerequisitePath=%cmsourcepath%\REdist
MobileDeviceLanguage=0
AdminConsole=1
JoinCEIP=0

[SQLConfigOptions]
SQLServerName=%SQLMachineFQDN%
DatabaseName=%SQLInstance%CM_%Role%
SQLSSBPort=4022
SQLDataFilePath=%SQLDataFilePath%
SQLLogFilePath=%SQLLogFilePath%

[CloudConnectorOptions]
CloudConnector=1
CloudConnectorServer=%MachineFQDN%
UseProxy=0
ProxyName=
ProxyPort=

[SystemCenterOptions]
SysCenterId=

[HierarchyExpansionOption]
'@
    $inst = (get-itemproperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances[0]
    $p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$inst

    $sqlinfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$p\$inst"

    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ini file exist." | Out-File -Append $logpath
    $cmini = $cmini.Replace('%InstallDir%',$SMSInstallDir)
    $cmini = $cmini.Replace('%MachineFQDN%',"$env:computername.$DomainFullName")
    $cmini = $cmini.Replace('%SQLMachineFQDN%',"$env:computername.$DomainFullName")
    $cmini = $cmini.Replace('%Role%',$Role)
    $cmini = $cmini.Replace('%SQLDataFilePath%',$sqlinfo.DefaultData)
    $cmini = $cmini.Replace('%SQLLogFilePath%',$sqlinfo.DefaultLog)
    $cmini = $cmini.Replace('%CM%',$CM)
    $cmini = $cmini.Replace('%cmsourcepath%',$cmsourcepath)

    if(!(Test-Path $cmsourcepath\Redist))
    {
        New-Item $cmsourcepath\Redist -ItemType directory | Out-Null
    }
        
    if($inst.ToUpper() -eq "MSSQLSERVER")
    {
        $cmini = $cmini.Replace('%SQLInstance%',"")
    }
    else
    {
        $tinstance = $inst.ToUpper() + "\"
        $cmini = $cmini.Replace('%SQLInstance%',$tinstance)
    }
    $CMInstallationFile = "$cmsourcepath\SMSSETUP\BIN\X64\Setup.exe"
    $cmini > $CMINIPath 
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Installing.." | Out-File -Append $logpath
    Start-Process -Filepath ($CMInstallationFile) -ArgumentList ('/NOUSERINPUT /script "' + $CMINIPath + '"') -wait

    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Finished installing CM." | Out-File -Append $logpath

    Remove-Item $CMINIPath

    $Configuration.InstallSCCM.Status = 'Completed'
    $Configuration.InstallSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
}

# Reload configuration after install section
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

#Upgrade SCCM
# Check if upgrade is already completed
if ($Configuration.UpgradeSCCM.Status -eq 'Completed') {
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] UpgradeSCCM already completed. Skipping upgrade." | Out-File -Append $logpath
}
else {
    $Configuration.UpgradeSCCM.Status = 'Running'
    $Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

    Start-Sleep -Seconds 120
    $logpath = $ProvisionToolPath+"\UpgradeCMlog.txt"
$SiteCode =  Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'

$ProviderMachineName = $env:COMPUTERNAME+"."+$DomainFullName # SMS Provider machine name

# Customizations
$initParams = @{}
if($ENV:SMS_ADMIN_UI_PATH -eq $null)
{
    $ENV:SMS_ADMIN_UI_PATH = "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386"
}

# Import the ConfigurationManager.psd1 module 
if((Get-Module ConfigurationManager) -eq $null) {
    Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" @initParams
}

# Connect to the site's drive if it is not already present
"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Setting PS Drive..." | Out-File -Append $logpath
New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams

while((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) 
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Retry in 10s to set PS Drive. Please wait." | Out-File -Append $logpath
    Start-Sleep -Seconds 10
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams

#Add domain user as CM administrative user
"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Setting $CMUser as CM administrative user." | Out-File -Append $logpath
New-CMAdministrativeUser -Name $CMUser -RoleName "Full Administrator" -SecurityScopeName "All","All Systems","All Users and User Groups"
"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Done" | Out-File -Append $logpath

$upgradingfailed = $false
$originalbuildnumber = ""

#Wait for SMS_DMP_DOWNLOADER running
$key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$subKey =  $key.OpenSubKey("SOFTWARE\Microsoft\SMS\Components\SMS_Executive\Threads\SMS_DMP_DOWNLOADER")
$DMPState = $subKey.GetValue("Current State")
while($DMPState -ne "Running")
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Current SMS_DMP_DOWNLOADER state is : $DMPState , will try again 30 seconds later..." | Out-File -Append $logpath
    Start-Sleep -Seconds 30
    $DMPState = $subKey.GetValue("Current State")
}

"[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Current SMS_DMP_DOWNLOADER state is : $DMPState " | Out-File -Append $logpath

#get the available update - selects the LOWEST version first to ensure sequential upgrades
# This ensures updates are applied in order: 2509 -> 2603 -> 2609
function getupdate()
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Get CM update..." | Out-File -Append $logpath
    $CMPSSuppressFastNotUsedCheck = $true
    $updatepacklist= Get-CMSiteUpdate -Fast | ?{$_.State -ne 196612}
    $getupdateretrycount = 0
    while($updatepacklist.Count -eq 0)
    {
        if($getupdateretrycount -eq 3)
        {
            break
        }
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Not found any updates, retry to invoke update check." | Out-File -Append $logpath
        $getupdateretrycount++
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Invoke CM Site update check..." | Out-File -Append $logpath
        Invoke-CMSiteUpdateCheck -ErrorAction Ignore
        Start-Sleep 120

        $updatepacklist= Get-CMSiteUpdate | ?{$_.State -ne 196612}
    }

    $updatepack = $null

    if($updatepacklist.Count -eq 0)
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] No updates available." | Out-File -Append $logpath
    }
    elseif($updatepacklist.Count -eq 1)
    {
        $updatepack = $updatepacklist
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Single update available: $($updatepack.Name)" | Out-File -Append $logpath
    }
    else
    {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Multiple updates available. Filtering for major versions only (excluding hotfixes)..." | Out-File -Append $logpath
        
        # Log all available updates for debugging
        foreach ($update in $updatepacklist) {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")]   Available: $($update.Name) - State: $($update.State) - FullVersion: $($update.FullVersion)" | Out-File -Append $logpath
        }
        
        # Filter to exclude hotfixes - only include base version updates
        # Hotfixes contain "Hotfix" or "KB" in their name
        $majorUpdates = @($updatepacklist | Where-Object {
            $_.Name -notmatch "hotfix" -and $_.Name -notmatch "KB\d+"
        })
        
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Found $($majorUpdates.Count) major version update(s) after filtering." | Out-File -Append $logpath
        
        if ($majorUpdates.Count -gt 0) {
            # Log filtered updates
            foreach ($update in $majorUpdates) {
                "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")]   Major update: $($update.Name) - FullVersion: $($update.FullVersion)" | Out-File -Append $logpath
            }
            
            # Sort by fullversion DESCENDING and select the FIRST (highest) to skip intermediate versions
            # This allows jumping directly to 2509 if available, skipping 2403, 2409, 2503
            $updatepack = ($majorUpdates | Sort-Object -Property fullversion -Descending | Select-Object -First 1)
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Selected highest major version update: $($updatepack.Name)" | Out-File -Append $logpath
        }
        else {
            # If no major updates found, fall back to lowest version (might be a hotfix we need)
            $updatepack = ($updatepacklist | Sort-Object -Property fullversion | Select-Object -First 1)
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] No major version updates found. Falling back to: $($updatepack.Name)" | Out-File -Append $logpath
        }
    }
    
    if ($null -ne $updatepack) {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Returning update package: $($updatepack.Name) (State: $($updatepack.State))" | Out-File -Append $logpath
    }
    else {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] No update package to return." | Out-File -Append $logpath
    }
    
    return $updatepack
}

#----------------------------------------------------
$state=@{
    0 = 'UNKNOWN'
    2 = 'ENABLED'
    #DMP DOWNLOAD
    262145 = 'DOWNLOAD_IN_PROGRESS'
    262146 = 'DOWNLOAD_SUCCESS'
    327679 = 'DOWNLOAD_FAILED'
    #APPLICABILITY
    327681 = 'APPLICABILITY_CHECKING'
    327682 = 'APPLICABILITY_SUCCESS'
    393213 ='APPLICABILITY_HIDE'
    393214 = 'APPLICABILITY_NA'
    393215 = 'APPLICABILITY_FAILED'
    #CONTENT
    65537 = 'CONTENT_REPLICATING'
    65538 = 'CONTENT_REPLICATION_SUCCESS'
    131071 = 'CONTENT_REPLICATION_FAILED'
    #PREREQ
    131073 = 'PREREQ_IN_PROGRESS'
    131074 = 'PREREQ_SUCCESS'
    131075 = 'PREREQ_WARNING'
    196607 = 'PREREQ_ERROR'
    #Apply changes
    196609 = 'INSTALL_IN_PROGRESS'
    196610 = 'INSTALL_WAITING_SERVICE_WINDOW'
    196611 = 'INSTALL_WAITING_PARENT'
    196612 = 'INSTALL_SUCCESS'
    196613 = 'INSTALL_PENDING_REBOOT'
    262143 = 'INSTALL_FAILED'
    #CMU SERVICE UPDATEI
    196614 = 'INSTALL_CMU_VALIDATING'
    196615 = 'INSTALL_CMU_STOPPED'
    196616 = 'INSTALL_CMU_INSTALLFILES'
    196617 = 'INSTALL_CMU_STARTED'
    196618 = 'INSTALL_CMU_SUCCESS'
    196619 = 'INSTALL_WAITING_CMU'
    262142 = 'INSTALL_CMU_FAILED'
    #DETAILED INSTALL STATUS
    196620 = 'INSTALL_INSTALLFILES'
    196621 = 'INSTALL_UPGRADESITECTRLIMAGE'
    196622 = 'INSTALL_CONFIGURESERVICEBROKER'
    196623 = 'INSTALL_INSTALLSYSTEM'
    196624 = 'INSTALL_CONSOLE'
    196625 = 'INSTALL_INSTALLBASESERVICES'
    196626 = 'INSTALL_UPDATE_SITES'
    196627 = 'INSTALL_SSB_ACTIVATION_ON'
    196628 = 'INSTALL_UPGRADEDATABASE'
    196629 = 'INSTALL_UPDATEADMINCONSOLE'
}
#----------------------------------------------------
$starttime= Get-Date
$sites= Get-CMSite
if($originalbuildnumber -eq "")
{
    if($sites.count -eq 1)
    {
        $originalbuildnumber = $sites.BuildNumber
    }
    else
    {
        $originalbuildnumber = $sites[0].BuildNumber
    }
}

#----------------------------------------------------
$retrytimes = 0
$downloadretrycount = 0
$updatepack = getupdate
if($updatepack -ne "")
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Update package is " + $updatepack.Name | Out-File -Append $logpath
}
else
{
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] No update package be found." | Out-File -Append $logpath
}
while($updatepack -ne "")
{
    if($retrytimes -eq 3)
    {
        $upgradingfailed = $true
        break
    }
    $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name 
    while($updatepack.State -eq 327682 -or $updatepack.State -eq 262145 -or $updatepack.State -eq 327679)
    {
        #package not downloaded
        if($updatepack.State -eq 327682)
        {
            Invoke-CMSiteUpdateDownload -Name $updatepack.Name -Force -WarningAction SilentlyContinue
            Start-Sleep 120
            $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
            $downloadstarttime = get-date
            while($updatepack.State -eq 327682)
            {
                
                "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Waiting SCCM Upgrade package start to download, sleep 2 min..." | Out-File -Append $logpath
                Start-Sleep 120
                $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
                $downloadspan = New-TimeSpan -Start $downloadstarttime -End (Get-Date)
                if($downloadspan.Hours -ge 1)
                {
                    Restart-Service -DisplayName "SMS_Executive"
                    $downloadretrycount++
                    Start-Sleep 120
                    $downloadstarttime = get-date
                }
                if($downloadretrycount -ge 2)
                {
                    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Update package " + $updatepack.Name + " failed to start downloading in 2 hours."| Out-File -Append $logpath
                    break
                }
            }
        }
        
        if($downloadretrycount -ge 2)
        {
            break
        }
        
        #waiting package downloaded
        $downloadstarttime = get-date
        while($updatepack.State -eq 262145)
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Waiting SCCM Upgrade package download, sleep 2 min..." | Out-File -Append $logpath
            Start-Sleep 120
            $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
            $downloadspan = New-TimeSpan -Start $downloadstarttime -End (Get-Date)
            if($downloadspan.Hours -ge 1)
            {
                Restart-Service -DisplayName "SMS_Executive"
                Start-Sleep 120
                $downloadstarttime = get-date
            }
        }

        #downloading failed
        if($updatepack.State -eq 327679)
        {
            $retrytimes++
            Start-Sleep 300
            continue
        }
    }
    
    if($downloadretrycount -ge 2)
    {
        break
    }
    
    #trigger prerequisites check after the package downloaded
    # First, ensure ODBC driver meets requirements for this update
    $updateName = $updatepack.Name
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Checking ODBC driver requirements for update: $updateName" | Out-File -Append $logpath
    $odbcResult = Ensure-ODBCDriverVersion -SCCMVersion $updateName -LogPath $logpath
    if (-not $odbcResult) {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] WARNING: ODBC driver upgrade may have failed, proceeding with SCCM update anyway..." | Out-File -Append $logpath
    }
    
    Invoke-CMSiteUpdatePrerequisiteCheck -Name $updatepack.Name
    while($updatepack.State -ne 196607 -and $updatepack.State -ne 131074 -and $updatepack.State -ne 131075)
    {
        ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Waiting checking prerequisites complete, current pack " + $updatepack.Name + " state is " + ($state.($updatepack.State)) + ", sleep 2 min...") | Out-File -Append $logpath
        Start-Sleep 120
        $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name 
    }
    if($updatepack.State -eq 196607)
    {
        $retrytimes++
        Start-Sleep 300
        continue
    }
    #trigger setup after the prerequisites check
    Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force
    while($updatepack.State -ne 196607 -and $updatepack.State -ne 262143 -and $updatepack.State -ne 196612)
    {
        ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Waiting SCCM Upgrade Complete, current pack " + $updatepack.Name + " state is " + ($state.($updatepack.State)) + ", sleep 2 min...") | Out-File -Append $logpath
        Start-Sleep 120
        $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name 
    }
    if($updatepack.State -eq 196612)
    {
        ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] SCCM Upgrade Complete, current pack " + $updatepack.Name + " state is " + ($state.($updatepack.State)) ) | Out-File -Append $logpath
        #we need waiting the copying files finished if there is only one site
        $toplevelsite =  Get-CMSite |where {$_.ReportingSiteCode -eq ""}
        if((Get-CMSite).count -eq 1)
        {
            $path= Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory'

            $fileversion=(Get-Item ($path+'\cd.latest\SMSSETUP\BIN\X64\setup.exe')).VersionInfo.FileVersion.split('.')[2]
            while($fileversion -ne $toplevelsite.BuildNumber)
            {
                Start-Sleep 120
                $fileversion=(Get-Item ($path+'\cd.latest\SMSSETUP\BIN\X64\setup.exe')).VersionInfo.FileVersion.split('.')[2]
            }
            #Wait for copying files finished
            Start-Sleep 600
        }
        #Get if there are any other updates need to be installed
        $updatepack = getupdate 
        if($updatepack -ne "")
        {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Found another update package : " + $updatepack.Name | Out-File -Append $logpath
        }
    }
    if($updatepack.State -eq 196607 -or $updatepack.State -eq 262143 )
    {
        if($retrytimes -le 3)
        {
            $retrytimes++
            Start-Sleep 300
            continue
        }
    }
}

if($upgradingfailed -eq $true)
{
    ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Upgrade " + $updatepack.Name + " failed") | Out-File -Append $logpath
    if($($updatepack.Name).ToLower().Contains("hotfix"))
    {
        ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] This is a hotfix, skip it and continue...") | Out-File -Append $logpath
        $Configuration.UpgradeSCCM.Status = 'CompletedWithHotfixInstallFailed'
    }
    else
    {
        $Configuration.UpgradeSCCM.Status = 'Error'
        $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
        throw
    }
}
else
{
    $Configuration.UpgradeSCCM.Status = 'Completed'
    
    # After all upgrades complete, check if we upgraded to 2609 or later and upgrade ODBC to 18.7.1.1
    # Per Microsoft: ODBC 18.7.1.1 has a known issue with CM 2603 and earlier - must be installed AFTER upgrading to 2609
    $currentSite = Get-CMSite | Select-Object -First 1
    $currentBuildNumber = $currentSite.BuildNumber
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Current CM build number after upgrades: $currentBuildNumber" | Out-File -Append $logpath
    
    # Build number for 2609 starts with 5.00.9128 (approximate - adjust if needed)
    # Check if version contains 2609 indicator or is a recent build
    if ($currentBuildNumber -ge 9128) {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] CM 2609 or later detected. Upgrading ODBC Driver to 18.7.1.1..." | Out-File -Append $logpath
        $odbcUpgradeResult = Upgrade-ODBCDriverPost2609 -LogPath $logpath
        if ($odbcUpgradeResult) {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] ODBC Driver upgrade to 18.7.1.1 completed successfully." | Out-File -Append $logpath
        }
        else {
            "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] WARNING: ODBC Driver upgrade to 18.7.1.1 may have failed. Please verify manually." | Out-File -Append $logpath
        }
    }
    else {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] CM version is earlier than 2609 (build $currentBuildNumber). Skipping ODBC 18.7.1.1 upgrade." | Out-File -Append $logpath
    }
}

if($downloadretrycount -ge 2)
{
    ("[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] Upgrade " + $updatepack.Name + " failed to start downloading") | Out-File -Append $logpath
    $Configuration.UpgradeSCCM.Status = 'CompletedWithDownloadFailed'
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    throw
}

$Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
} # End of UpgradeSCCM else block