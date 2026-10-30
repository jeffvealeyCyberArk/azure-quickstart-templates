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
    $CurrentRole = "PS"
    if($Configuration -ne "Standalone")
    {
        $CSComputerAccount = "$DName\$CSName$"
    }
    $DPMPComputerAccount = "$DName\$DPMPName$"
    $Clients = [system.String]::Join(",", $ClientName)
    
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
            NAME = "PS"
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

        DownloadAndInstallvcredist DownloadAndInstallvcredist
        {
            Ensure = "Present"
            DependsOn = "[InstallADK]ADKInstall"
        }

        DownloadAndInstallODBC DownloadAndInstallODBC
        {
            Ensure = "Present"
            DependsOn = "[DownloadAndInstallvcredist]DownloadAndInstallvcredist"
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

        # Install latest ODBC Driver 18 for SQL Server
        Script InstallODBCDriver18
        {
            GetScript = {
                $odbc18 = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server" -ErrorAction SilentlyContinue
                @{ Result = ($null -ne $odbc18) }
            }
            SetScript = {
                $odbcUrl = "https://download.microsoft.com/download/d624e1c6-293b-4d6f-91b8-6e515a5d6a77/amd64/1033/msodbcsql.msi"
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

        if($Configuration -eq "Standalone")
        {
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

            FileReadAccessShare DomainSMBShare
            {
                Name = $LogFolder
                Path = $LogPath
                Account = $DCComputerAccount
                DependsOn = "[File]ShareFolder"
            }

            FileReadAccessShare CMSourceSMBShare
            {
                Name = $CM
                Path = "c:\$CM"
                Account = $DCComputerAccount
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
            }

            RegisterTaskScheduler InstallAndUpdateSCCM
            {
                TaskName = "ScriptWorkFlow"
                ScriptName = "ScriptWorkFlow.ps1"
                ScriptPath = $PSScriptRoot
                ScriptArgument = "$DomainName $CM $DName\$($Admincreds.UserName) $DPMPName $Clients $Configuration $CurrentRole $LogFolder $CSName $PSName"
                Ensure = "Present"
                DependsOn = "[FileReadAccessShare]CMSourceSMBShare"
            }
        }
        else 
        {
            SetDNS DnsServerAddress
            {
                DNSIPAddress = $DNSIPAddress
                Ensure = "Present"
                DependsOn = "[Script]InstallODBCDriver18"
            }

            WaitForConfigurationFile WaitCSJoinDomain
            {
                Role = "DC"
                MachineName = $DCName
                LogFolder = $LogFolder
                ReadNode = "CSJoinDomain"
                Ensure = "Present"
                DependsOn = "[File]ShareFolder"
            }

            FileReadAccessShare DomainSMBShare
            {
                Name = $LogFolder
                Path = $LogPath
                Account = $DCComputerAccount,$CSComputerAccount
                DependsOn = "[WaitForConfigurationFile]WaitCSJoinDomain"
            }

            RegisterTaskScheduler InstallAndUpdateSCCM
            {
                TaskName = "ScriptWorkFlow"
                ScriptName = "ScriptWorkFlow.ps1"
                ScriptPath = $PSScriptRoot
                ScriptArgument = "$DomainName $CM $DName\$($Admincreds.UserName) $DPMPName $Clients $Configuration $CurrentRole $LogFolder $CSName $PSName"
                Ensure = "Present"
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
            }
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
        
        OpenFirewallPortForSCCM OpenFirewall
        {
            Name = "PS"
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
    }
}