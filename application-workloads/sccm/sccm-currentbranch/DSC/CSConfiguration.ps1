configuration Configuration
{
   param
   (
        [Parameter(Mandatory)]
        [String]$DomainName,
        [Parameter(Mandatory)]
        [String]$DCName,
        [Parameter(Mandatory)]
        [String]$DPMPName,
        [Parameter(Mandatory)]
        [String]$CSName,
        [Parameter(Mandatory)]
        [String]$PSName,
        [Parameter(Mandatory)]
        [System.Array]$ClientName,
        [Parameter(Mandatory)]
        [String]$Configuration,
        [Parameter(Mandatory)]
        [String]$DNSIPAddress,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )
    Import-DscResource -ModuleName TemplateHelpDSC
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    
    $LogFolder = "TempLog"
    $CM = "CMCB"
    $LogPath = "c:\$LogFolder"
    $DName = $DomainName.Split(".")[0]
    $DCComputerAccount = "$DName\$DCName$"
    $PSComputerAccount = "$DName\$PSName$"
    $DPMPComputerAccount = "$DName\$DPMPName$"
    [String]$Clients = [system.String]::Join(",", $ClientName)
    $CurrentRole = "CS"
    $PrimarySiteName = $PSName.split(".")[0] + "$"
    
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node LOCALHOST
    {
        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }
        SetCustomPagingFile PagingSettings
        {
            Drive       = 'C:'
            InitialSize = '8192'
            MaximumSize = '8192'
        }

        AddBuiltinPermission AddSQLPermission
        {
            Ensure = "Present"
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        InstallFeatureForSCCM InstallFeature
        {
            NAME = "CS"
            Role = "Site Server"
            DependsOn = "[AddBuiltinPermission]AddSQLPermission"
        }

        InstallADK ADKInstall
        {
            ADKPath = "C:\adksetup.exe"
            ADKWinPEPath = "c:\adksetupwinpe.exe"
            Ensure = "Present"
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
        }

        DownloadAndInstallODBC DownloadAndInstallODBC
        {
            Ensure = "Present"
            DependsOn = "[InstallADK]ADKInstall"
        }

        # Install .NET Framework 4.8
        Script InstallDotNet48
        {
            GetScript = {
                $release = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Release
                @{ Result = ($release -ge 528040) }
            }
            SetScript = {
                $dotnetUrl = "https://go.microsoft.com/fwlink/?linkid=2088631"
                $dotnetPath = "C:\temp\ndp48-x86-x64-allos-enu.exe"
                New-Item -ItemType Directory -Path "C:\temp" -Force -ErrorAction SilentlyContinue
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $dotnetUrl -OutFile $dotnetPath -UseBasicParsing
                Start-Process -FilePath $dotnetPath -ArgumentList "/q /norestart" -Wait
            }
            TestScript = {
                $release = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Release
                return ($release -ge 528040)  # 528040 = .NET 4.8
            }
            DependsOn = "[DownloadAndInstallODBC]DownloadAndInstallODBC"
        }

        # Install ODBC Driver 18.5.2.1 for SQL Server (required for SCCM)
        Script InstallODBCDriver18
        {
            GetScript = {
                $odbc18 = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server" -ErrorAction SilentlyContinue
                if ($odbc18) {
                    $version = $odbc18.DriverODBCVer
                    @{ Result = "ODBC Driver 18 installed, version: $version" }
                } else {
                    @{ Result = "ODBC Driver 18 not installed" }
                }
            }
            SetScript = {
                # ODBC Driver 18.5.2.1
                $odbcUrl = "https://raw.githubusercontent.com/jeffvealeyCyberArk/azure-quickstart-templates/master/application-workloads/sccm/sccm-currentbranch/DSC/msodbcsql1852.msi"
                $odbcPath = "C:\temp\msodbcsql18.msi"
                New-Item -ItemType Directory -Path "C:\temp" -Force -ErrorAction SilentlyContinue
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $odbcUrl -OutFile $odbcPath -UseBasicParsing
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$odbcPath`" /qn IACCEPTMSODBCSQLLICENSETERMS=YES" -Wait
            }
            TestScript = {
                $odbc18 = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server" -ErrorAction SilentlyContinue
                return ($null -ne $odbc18)
            }
            DependsOn = "[Script]InstallDotNet48"
        }

        DownloadSCCM DownLoadSCCM
        {
            CM = $CM
            Ensure = "Present"
            DependsOn = "[Script]InstallODBCDriver18"
        }

        SetDNS DnsServerAddress
        {
            DNSIPAddress = $DNSIPAddress
            Ensure = "Present"
            DependsOn = "[DownloadSCCM]DownLoadSCCM"
        }

        WaitForDomainReady WaitForDomain
        {
            Ensure = "Present"
            DCName = $DCName
            WaitSeconds = 0
            DependsOn = "[SetDNS]DnsServerAddress"
        }

        JoinDomain JoinDomain
        {
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn = "[WaitForDomainReady]WaitForDomain"
        }
        
        File ShareFolder
        {            
            DestinationPath = $LogPath     
            Type = 'Directory'            
            Ensure = 'Present'
            DependsOn = "[JoinDomain]JoinDomain"
        }

        WaitForConfigurationFile WaitPSJoinDomain
        {
            Role = "DC"
            MachineName = $DCName
            LogFolder = $LogFolder
            ReadNode = "PSJoinDomain"
            Ensure = "Present"
            DependsOn = "[File]ShareFolder"
        }

        FileReadAccessShare DomainSMBShare
        {
            Name = $LogFolder
            Path = $LogPath
            Account = $DCComputerAccount,$PSComputerAccount
            DependsOn = "[WaitForConfigurationFile]WaitPSJoinDomain"
        }
        
        OpenFirewallPortForSCCM OpenFirewall
        {
            Name = "CS"
            Role = "Site Server"
            DependsOn = "[JoinDomain]JoinDomain"
        }

        WaitForConfigurationFile DelegateControl
        {
            Role = "DC"
            MachineName = $DCName
            LogFolder = $LogFolder
            ReadNode = "DelegateControl"
            Ensure = "Present"
            DependsOn = "[OpenFirewallPortForSCCM]OpenFirewall"
        }

        ChangeSQLServicesAccount ChangeToLocalSystem
        {
            SQLInstanceName = "MSSQLSERVER"
            Ensure = "Present"
            DependsOn = "[WaitForConfigurationFile]DelegateControl"
        }

        FileReadAccessShare CMSourceSMBShare
        {
            Name = $CM
            Path = "c:\$CM"
            Account = $DCComputerAccount
            DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
        }

        AddUserToLocalAdminGroup AddADComputerToLocalAdminGroup {
            Name = "$PrimarySiteName"
            DomainName = $DomainName
            DependsOn = "[FileReadAccessShare]CMSourceSMBShare"
        }

        RegisterTaskScheduler InstallAndUpdateSCCM
        {
            TaskName = "ScriptWorkFlow"
            ScriptName = "ScriptWorkFlow.ps1"
            ScriptPath = $PSScriptRoot
            ScriptArgument = "$DomainName $CM $DName\$($Admincreds.UserName) $DPMPName $Clients $Configuration $CurrentRole $LogFolder $CSName $PSName"
            Ensure = "Present"
            DependsOn = "[AddUserToLocalAdminGroup]AddADComputerToLocalAdminGroup"
        }
    }
}