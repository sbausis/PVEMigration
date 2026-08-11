#Version: 0.5
#Description: PVEMigration - VMware to Proxmox migration helper
#Company: Tec4D GmbH
#Product: PVEMigration
#Copyright: Tec4D GmbH (BAU 2026)
#
#Changelog:
# 0.5 - DNSServers immer als Array gespeichert (@($dns))
#       VirtIOIsoUrl als Parameter ausgelagert (eigener Webserver möglich)
# 0.4 - Multi-NIC Sicherung mit MAC als Schlüssel
#       Summary.json wird nach jedem Schritt aktualisiert
#       MakeEXE direkt ins Script integriert (-MakeEXE, -DevconPath)
#       Cleanup Flag Mechanismus (READY_FOR_CLEANUP)
#       Devcon-Prüfung am Anfang beider Phasen
#       Write-Error -ForegroundColor korrigiert
# 0.3 - Erste vollständig überarbeitete Version (Basis: Original v0.2)
#       Hypervisor-Erkennung, Structured Summary, Transcript Logging
# 0.2 - Original (a&f systems ag) - VMware Tools, VirtIO, Netzwerk-Backup,
#       Scheduled Task, Ghost Device Cleanup, Netzwerk-Wiederherstellung

param(
    [switch]$wait       = $true,
    [switch]$MakeEXE,
    [string]$DevconPath = "",
    [string]$VirtIOIsoUrl = "https://xxxx.xxx/pve/virtio-win-0.1.271.iso"
)

################################################################################
#region Build (MakeEXE)

if ($MakeEXE) {

    if (-not $PSCommandPath -or $PSCommandPath -notmatch '\.ps1$') {
        Write-Host "ERROR: -MakeEXE can only be used when running as a .ps1 script, not from a compiled EXE." -ForegroundColor Red
        exit 1
    }

    # Read metadata from script header
    $scriptContent = Get-Content $PSCommandPath -Raw
    $meta = @{}
    foreach ($line in ($scriptContent -split "`n")) {
        if ($line -match '^#(\w+):\s*(.+)') { $meta[$Matches[1]] = $Matches[2].Trim() }
    }
    $buildVersion   = if ($meta['Version'])     { $meta['Version'] }     else { "0.0" }
    $buildDesc      = if ($meta['Description']) { $meta['Description'] } else { "PVEMigration" }
    $buildCompany   = if ($meta['Company'])     { $meta['Company'] }     else { "" }
    $buildProduct   = if ($meta['Product'])     { $meta['Product'] }     else { "PVEMigration" }
    $buildCopyright = if ($meta['Copyright'])   { $meta['Copyright'] }   else { "" }

    Write-Host "=== Building PVEMigration.exe v$buildVersion ===" -ForegroundColor Cyan

    # Resolve devcon files
    $devconSrc  = if ($DevconPath) { $DevconPath } else { Split-Path $PSCommandPath }
    $devcon64   = Join-Path $devconSrc "devcon.exe"
    $devcon32   = Join-Path $devconSrc "devcon32.exe"
    $icoFile    = Join-Path (Split-Path $PSCommandPath) "Proxmox.ico"
    $outputFile = Join-Path (Split-Path $PSCommandPath) "PVEMigration.exe"

    foreach ($f in @($devcon64, $devcon32)) {
        if (-not (Test-Path $f)) {
            Write-Host "ERROR: Required file not found: $f" -ForegroundColor Red
            Write-Host "       Use -DevconPath to specify the folder containing devcon.exe and devcon32.exe." -ForegroundColor Yellow
            exit 1
        }
    }

    if (-not (Test-Path $icoFile)) {
        Write-Host "WARNING: Proxmox.ico not found at $icoFile. Building without icon." -ForegroundColor Yellow
        $icoFile = $null
    }

    # Install ps2exe if needed
    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        Write-Host " - Installing ps2exe from PSGallery..." -ForegroundColor Yellow
        Install-Module ps2exe -Repository PSGallery -Force -Scope CurrentUser
    }
    Import-Module ps2exe

    $embedFiles = @{
        "C:\TEMP\devcon.exe"   = $devcon64
        "C:\TEMP\devcon32.exe" = $devcon32
    }

    $ps2exeArgs = @{
        inputFile    = $PSCommandPath
        outputFile   = $outputFile
        exitOnCancel = $true
        requireAdmin = $true
        title        = $buildProduct
        description  = $buildDesc
        company      = $buildCompany
        product      = $buildProduct
        copyright    = $buildCopyright
        version      = $buildVersion
        embedFiles   = $embedFiles
        verbose      = $true
    }
    if ($icoFile) { $ps2exeArgs['iconFile'] = $icoFile }

    Invoke-ps2exe @ps2exeArgs

    if (Test-Path $outputFile) {
        Write-Host "=== Build successful: $outputFile ===" -ForegroundColor Green
    } else {
        Write-Host "ERROR: Build failed. Output file not found." -ForegroundColor Red
        exit 1
    }
    exit 0
}

#endregion
################################################################################
#region Functions

function Convert-PrefixToMask {
    param([ValidateRange(0,32)][int]$PrefixLength)
    $mask = [uint32]0
    for ($i = 0; $i -lt $PrefixLength; $i++) { $mask = $mask -bor (1 -shl (31 - $i)) }
    $bytes = [BitConverter]::GetBytes($mask)
    [Array]::Reverse($bytes)
    return ($bytes -join '.')
}

function Normalize-DnsArray {
    param($DnsList)
    if ($DnsList -is [string]) { $DnsList = @($DnsList) }
    return @($DnsList | Where-Object { $_ -and $_.ToString().Trim() -ne '' } | ForEach-Object { $_.ToString().Trim() })
}

function Test-ArrayEqual {
    param([array]$A, [array]$B)
    if ($A.Count -ne $B.Count) { return $false }
    for ($i = 0; $i -lt $A.Count; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function AnalyzeProducts {
    param($Path, $Arch)
    Get-ItemProperty $Path -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.DisplayName -or $_.Version) {
            [PSCustomObject]@{
                Architecture = $Arch
                Name         = $_.DisplayName
                Version      = $_.DisplayVersion
                Install      = $_.InstallDate
                Uninstall    = $_.UninstallString
            }
        }
    }
}

function Write-Step {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Update-Summary {
    param([hashtable]$Updates)
    foreach ($k in $Updates.Keys) { $script:Summary[$k] = $Updates[$k] }
    $script:Summary | ConvertTo-Json -Depth 5 | Out-File $SummaryPath -Encoding UTF8 -Force
}

#endregion
################################################################################
#region Paths & Variables

$WorkingPath   = "C:\TEMP"
$LogPath       = $WorkingPath
$LogName       = "PVEMigration"
$NetConfigPath = "$WorkingPath\VMware_NetConfig.json"
$DriversPath   = "$WorkingPath\Drivers"
$SummaryPath   = "$WorkingPath\PVEMigration_Summary.json"

#endregion
################################################################################
#region Summary Init

$script:Summary = [ordered]@{
    Hostname                = $env:COMPUTERNAME
    Phase                   = "Unknown"
    Timestamp               = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    Hypervisor              = "Unknown"
    WindowsBuild            = ""
    WindowsVersion          = ""
    Architecture            = $env:PROCESSOR_ARCHITECTURE
    VirtIODriverInstalled   = $false
    VirtIOPackageInstalled  = $false
    QemuGuestAgentInstalled = $false
    VMwareToolsRemoved      = $false
    NICs                    = @()
    ScheduledTaskCreated    = $false
    GhostDevicesRemoved     = $false
    NetworkRestored         = $false
    NetworkVerified         = $false
    CleanupDone             = $false
    ExitCode                = -1
    Errors                  = @()
}

# Merge existing summary if present (preserves Phase 1 data into Phase 2)
if (Test-Path $SummaryPath) {
    try {
        $existing = Get-Content $SummaryPath -Raw | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties) {
            if ($script:Summary.Contains($prop.Name)) {
                $script:Summary[$prop.Name] = $prop.Value
            }
        }
    } catch {
        Write-Step " - Could not read existing Summary. Starting fresh." Yellow
    }
}

#endregion
################################################################################

try {
    Start-Transcript -Path "$LogPath\$LogName-$(Get-Date -Format yyyy.MM.dd-HHmmss).log" -IncludeInvocationHeader

    # Detect hypervisor
    $hypervisor = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
    Update-Summary @{ Hypervisor = $hypervisor; Timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss") }

    ############################################################################
    #region === VMWARE PHASE ===
    ############################################################################

    if ($hypervisor -match "vmware") {

        Update-Summary @{ Phase = "VMware" }
        Write-Step "=== VMware Phase ===" Cyan

        ########################################################################
        # Architecture & Windows Version

        if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
            $Devcon     = "$WorkingPath\devcon.exe"
            $DriverMSI  = "$DriversPath\virtio-win-gt-x64.msi"
            $ArchFolder = "amd64"
        } else {
            $Devcon     = "$WorkingPath\devcon32.exe"
            $DriverMSI  = "$DriversPath\virtio-win-gt-x86.msi"
            $ArchFolder = "x86"
        }

        $Build = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild
        $VersionMap = @{
            "6001"  = "2k8";    "7601"  = "2k8r2";  "9200"  = "2k12"
            "9600"  = "2k12r2"; "14393" = "2k16";   "17763" = "2k19"
            "20348" = "2k22";   "25398" = "2k25";   "19041" = "w10"
            "22000" = "w11";    "22621" = "w11"
        }
        $Version = if ([int]$Build -ge 26100) { "w11" } else { $VersionMap[$Build] }
        $VirtIOSCSIDriver = "$DriversPath\vioscsi\$Version\$ArchFolder\vioscsi.inf"

        Update-Summary @{ WindowsBuild = $Build; WindowsVersion = $Version }

        Write-Step "   Architecture : $($env:PROCESSOR_ARCHITECTURE)"
        Write-Step "   Windows Build : $Build ($Version)"
        Write-Step "   Driver Path   : $VirtIOSCSIDriver"

        ########################################################################
        # Validate devcon

        if (-not (Test-Path $Devcon)) {
            $msg = "devcon.exe not found at $Devcon. Cannot continue."
            $script:Summary.Errors += $msg
            Update-Summary @{}
            throw $msg
        }

        ########################################################################
        # VirtIO Drivers Download & Extract

        $ISOUrl  = $VirtIOIsoUrl
        $ISOPath = "$WorkingPath\virtio-win.iso"

        # Per-version ISO map: older Windows versions need older VirtIO builds
        $VirtIOIsoMap = @{
            "2k8"    = "https://xxxx.xxx/pve/virtio-win-0.1.160.iso"
            "2k8r2"  = "https://xxxx.xxx/pve/virtio-win-0.1.172.iso"
            "2k12"   = "https://xxxx.xxx/pve/virtio-win-0.1.189.iso"
            "2k12r2" = "https://xxxx.xxx/pve/virtio-win-0.1.215.iso"
        }
        if ($VirtIOIsoMap.ContainsKey($Version)) {
            $ISOUrl = $VirtIOIsoMap[$Version]
            Write-Step " - Using legacy VirtIO ISO for $Version : $ISOUrl" Yellow
        }

        # Derive ISO filename from URL so it's recognizable in C:\TEMP
        $ISOFileName = $ISOUrl.Split('/')[-1]
        $ISOPath     = "$WorkingPath\$ISOFileName"
        if (-not (Test-Path $DriversPath)) { New-Item -ItemType Directory -Path $DriversPath -Force | Out-Null }

        if (-not (Test-Path "$DriversPath\vioscsi")) {
            Write-Step " - Downloading VirtIO ISO..." Yellow
            $ProgressPreference = 'SilentlyContinue'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            if (-not (Test-Path $ISOPath)) { Invoke-WebRequest -Uri $ISOUrl -OutFile $ISOPath -UseBasicParsing }

            Write-Step " - Mounting and extracting ISO..." Yellow
            $MountObject = Mount-DiskImage -ImagePath $ISOPath -PassThru
            $DriveLetter = ($MountObject | Get-Volume).DriveLetter
            Copy-Item -Path "${DriveLetter}:\*" -Destination $DriversPath -Recurse -Force
            Dismount-DiskImage -ImagePath $ISOPath
            Remove-Item -Path $ISOPath -Force
            Write-Step " - Drivers extracted to $DriversPath" Green
        } else {
            Write-Step " - Drivers already present in $DriversPath" Green
        }

        ########################################################################
        # Installed Products

        Write-Step " - Scanning installed products..." Yellow
        $Products = @()
        $Products += AnalyzeProducts 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' '64bit'
        $Products += AnalyzeProducts 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' '32bit'

        ########################################################################
        # Network Configuration Backup (all NICs, MAC as key)

        # Network Configuration Backup (WMI-based, compatible with Server 2012 R2+)

        if (Test-Path $NetConfigPath) {
            Write-Step " - Network config backup already exists. Skipping." Green
        } else {
            Write-Step " - Backing up network configuration (all active NICs)..." Yellow

            # Use WMI - works on all Windows versions without extra modules
            $nicList = @()
            $wmiAdapters = Get-WmiObject Win32_NetworkAdapterConfiguration |
                Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -ne $null }

            foreach ($adapter in $wmiAdapters) {
                # Find IPv4 address (skip 169.254.x and IPv6)
                $ipv4 = $adapter.IPAddress | Where-Object {
                    $_ -notlike '169.254.*' -and $_ -notmatch ':' -and $_ -ne '0.0.0.0'
                } | Select-Object -First 1

                if (-not $ipv4) { continue }

                # Get corresponding prefix length from subnet mask
                $maskIndex = [Array]::IndexOf($adapter.IPAddress, $ipv4)
                $subnetMask = if ($adapter.IPSubnet -and $maskIndex -ge 0) {
                    $adapter.IPSubnet[$maskIndex]
                } else { "255.255.255.0" }

                # Convert subnet mask to prefix length
                $prefixLength = 0
                foreach ($octet in ($subnetMask -split '\.')) {
                    $byte = [int]$octet
                    while ($byte -gt 0) {
                        $prefixLength += ($byte -band 1)
                        $byte = $byte -shr 1
                    }
                }

                # Gateway
                $gateway = if ($adapter.DefaultIPGateway) { $adapter.DefaultIPGateway[0] } else { $null }

                # DNS
                $dns = @()
                if ($adapter.DNSServerSearchOrder) {
                    $dns = @($adapter.DNSServerSearchOrder | Where-Object { $_ -and $_.Trim() -ne '' })
                }

                # Get MAC from Win32_NetworkAdapter by index
                $mac = (Get-WmiObject Win32_NetworkAdapter |
                    Where-Object { $_.Index -eq $adapter.Index }).MACAddress

                $nicList += [PSCustomObject]@{
                    MAC           = $mac
                    InterfaceName = $adapter.Description
                    Description   = $adapter.Description
                    IPAddress     = $ipv4
                    PrefixLength  = $prefixLength
                    Gateway       = $gateway
                    DNSServers    = $dns
                }
                Write-Step "   Saved NIC : $($adapter.Description) [$mac] -> $ipv4/$prefixLength" White
            }

            if ($nicList.Count -eq 0) {
                Write-Host " - No active NICs with valid IPv4 found." -ForegroundColor Red
                $script:Summary.Errors += "No active NICs found during backup"
            } else {
                $nicList | ConvertTo-Json -Depth 3 | Out-File $NetConfigPath -Encoding UTF8
                Write-Step " - Network config saved ($($nicList.Count) NIC(s)) to $NetConfigPath" Green
                Update-Summary @{ NICs = $nicList }
            }
        }

        ########################################################################
        # Uninstall VMware Tools

        $VMwareTools = $Products | Where-Object { $_.Name -eq "VMware Tools" }
        if ($null -ne $VMwareTools) {
            $guid = $VMwareTools.Uninstall -replace '.*(\{.*\})', '$1'
            Write-Step " - Uninstalling $($VMwareTools.Name) $($VMwareTools.Version)..." Yellow
            $p = Start-Process msiexec.exe -ArgumentList "/X$guid /qn /norestart /L*V $LogPath\$LogName-VMTools_Uninstall.log" -Wait -PassThru
            switch ($p.ExitCode) {
                0       { Write-Step " - VMware Tools removed successfully." Green;  Update-Summary @{ VMwareToolsRemoved = $true } }
                3010    { Write-Step " - VMware Tools removed. Reboot required." Yellow; Update-Summary @{ VMwareToolsRemoved = $true } }
                1605    { Write-Step " - VMware Tools already uninstalled." Cyan }
                default {
                    $msg = "VMware Tools uninstall failed with exit code $($p.ExitCode)"
                    Write-Host " - $msg" -ForegroundColor Red
                    $script:Summary.Errors += $msg
                }
            }
        } else {
            Write-Step " - VMware Tools not found. Skipping." Cyan
            Update-Summary @{ VMwareToolsRemoved = $true }
        }

        ########################################################################
        # Import driver certificate for older Windows versions (2k12r2 and below)
        # Prevents "Would you like to install this device software?" dialog

        $legacyVersions = @("2k8", "2k8r2", "2k12", "2k12r2")
        if ($legacyVersions -contains $Version) {
            $catFile = "$DriversPath\vioscsi\$Version\$ArchFolder\vioscsi.cat"
            if (Test-Path $catFile) {
                Write-Step " - Importing VirtIO driver certificate to TrustedPublisher store..." Yellow
                $certResult = certutil -addstore "TrustedPublisher" $catFile 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Step " - Certificate imported successfully." Green
                } else {
                    Write-Host " - Certificate import failed: $certResult" -ForegroundColor Yellow
                }
            } else {
                Write-Host " - Certificate file not found at $catFile" -ForegroundColor Yellow
            }
        }

        ########################################################################
        # VirtIO SCSI Driver

        Write-Step " - Installing VirtIO SCSI Driver..." Yellow
        $p1 = Start-Process $Devcon -ArgumentList @("-r", "install", $VirtIOSCSIDriver, "PCI\VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00") -Wait -PassThru
        if ($p1.ExitCode -eq 0 -or $p1.ExitCode -eq 1) {
            Write-Step " - VirtIO SCSI installed (code $($p1.ExitCode))." Green
            Update-Summary @{ VirtIODriverInstalled = $true }
        } else {
            $msg = "VirtIO SCSI install failed with code $($p1.ExitCode)"
            Write-Host " - $msg" -ForegroundColor Red
            $script:Summary.Errors += $msg
        }

        ########################################################################
        # VirtIO Driver Package (MSI)

        $VirtIOPkg = $Products | Where-Object { $_.Name -eq "Virtio-win-driver-installer" }
        if ($null -ne $VirtIOPkg) {
            Write-Step " - VirtIO Driver Package already installed ($($VirtIOPkg.Version))." Green
            Update-Summary @{ VirtIOPackageInstalled = $true }
        } else {
            Write-Step " - Installing VirtIO Driver Package..." Yellow
            $p2 = Start-Process msiexec.exe -ArgumentList "/i", $DriverMSI, "/qn" -Wait -PassThru
            if ($p2.ExitCode -eq 0 -or $p2.ExitCode -eq 3010) {
                Write-Step " - VirtIO Driver Package installed." Green
                Update-Summary @{ VirtIOPackageInstalled = $true }
            } else {
                $msg = "VirtIO MSI failed with code $($p2.ExitCode)"
                Write-Host " - $msg" -ForegroundColor Red
                $script:Summary.Errors += $msg
            }
        }

        ########################################################################
        # QEMU Guest Agent

        $QemuAgent = $Products | Where-Object { $_.Name -eq "QEMU guest agent" }
        if ($null -ne $QemuAgent) {
            Write-Step " - QEMU Guest Agent already installed ($($QemuAgent.Version))." Green
            Update-Summary @{ QemuGuestAgentInstalled = $true }
        } else {
            Write-Step " - Installing QEMU Guest Agent..." Yellow
            $p3 = Start-Process "$DriversPath\virtio-win-guest-tools.exe" -ArgumentList "/install", "/quiet", "/norestart", "ACCEPTEULA=1" -Wait -PassThru
            if ($p3.ExitCode -eq 0 -or $p3.ExitCode -eq 3010) {
                Write-Step " - QEMU Guest Agent installed." Green
                Update-Summary @{ QemuGuestAgentInstalled = $true }
            } else {
                $msg = "QEMU Guest Agent failed with code $($p3.ExitCode)"
                Write-Host " - $msg" -ForegroundColor Red
                $script:Summary.Errors += $msg
            }
        }

        ########################################################################
        # Scheduled Task

        $Task = Get-ScheduledTask -TaskName $LogName -ErrorAction SilentlyContinue
        if (-not $Task) {
            Write-Step " - Creating Scheduled Task '$LogName'..." Yellow
            $Action    = New-ScheduledTaskAction -Execute "C:\TEMP\PVEMigration.exe" -Argument "-wait:$false"
            $Trigger   = New-ScheduledTaskTrigger -AtStartup
            $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
            Register-ScheduledTask -TaskName $LogName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
            Write-Step " - Scheduled Task created." Green
            Update-Summary @{ ScheduledTaskCreated = $true }
        } else {
            Write-Step " - Scheduled Task '$LogName' already exists." Green
            Update-Summary @{ ScheduledTaskCreated = $true }
        }

        Update-Summary @{ ExitCode = 0 }
        Write-Step "=== VMware Phase complete. VM is ready for migration. ===" Green
    }

    ############################################################################
    #region === PROXMOX PHASE ===
    ############################################################################

    elseif ($hypervisor -match "QEMU") {

        Update-Summary @{ Phase = "Proxmox"; Timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss") }
        Write-Step "=== Proxmox Phase ===" Cyan

        if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") { $Devcon = "$WorkingPath\devcon.exe" }
        else { $Devcon = "$WorkingPath\devcon32.exe" }

        ########################################################################
        # Remove VMware Ghost Devices

        if (-not (Test-Path $Devcon)) {
            $msg = "devcon.exe not found at $Devcon. Cannot remove ghost devices."
            Write-Host " - $msg" -ForegroundColor Red
            $script:Summary.Errors += $msg
        } else {
            Write-Step " - Scanning for VMware ghost devices (VEN_15AD)..." Yellow
            $DevconLines = & "$Devcon" findall "PCI\VEN_15AD*"
            $InstanceIDs = foreach ($line in $DevconLines) {
                if ($line -match "PCI\\VEN_15AD[^:]+") { $Matches[0].Trim() }
            }

            if ($InstanceIDs) {
                foreach ($id in $InstanceIDs) {
                    Write-Step "   Removing: $id" Yellow
                    & "$Devcon" remove "@$id" | Out-Null
                }
                Write-Step " - Ghost device cleanup complete." Green
            } else {
                Write-Step " - No VMware ghost devices found." Gray
            }
            Update-Summary @{ GhostDevicesRemoved = $true }
        }

        ########################################################################
        # Network Restore (MAC-based)

        if (-not (Test-Path $NetConfigPath)) {
            Write-Step " - No network config backup found. Skipping restore." Yellow
        } else {
            Write-Step " - Restoring network configuration from backup..." Yellow
            $savedNICs = Get-Content $NetConfigPath -Raw | ConvertFrom-Json
            if ($savedNICs -isnot [array]) { $savedNICs = @($savedNICs) }

            foreach ($cfg in $savedNICs) {
                if (-not $cfg.IPAddress -or -not $cfg.Gateway) {
                    Write-Host " - Skipping NIC entry: missing IPAddress or Gateway." -ForegroundColor Yellow
                    continue
                }

                $targetMAC = ($cfg.MAC -replace '[-:]', '').ToUpper()

                $adapter = Get-NetAdapter | Where-Object {
                    ($_.InterfaceDescription -like "Red Hat VirtIO Ethernet Adapter*") -and
                    (($_.MacAddress -replace '[-:]', '').ToUpper() -eq $targetMAC)
                } | Select-Object -First 1

                if (-not $adapter) {
                    $msg = "No VirtIO adapter found matching MAC $($cfg.MAC). Skipping."
                    Write-Host " - $msg" -ForegroundColor Red
                    $script:Summary.Errors += $msg
                    continue
                }

                $alias      = $adapter.Name
                $ifIndex    = $adapter.ifIndex
                $subnetMask = Convert-PrefixToMask -PrefixLength ([int]$cfg.PrefixLength)
                $desiredIP  = $cfg.IPAddress.ToString().Trim()
                $desiredGW  = $cfg.Gateway.ToString().Trim()
                $desiredDns = Normalize-DnsArray $cfg.DNSServers

                Write-Step "   Adapter : $alias (Index $ifIndex)" White
                Write-Step "   Target  : $desiredIP / $subnetMask via $desiredGW  DNS: $($desiredDns -join ', ')" White

                # Read current config via WMI (compatible with PS 4.0)
                $wmiAdapter = Get-WmiObject Win32_NetworkAdapterConfiguration |
                    Where-Object { $_.Index -eq $ifIndex -and $_.IPEnabled -eq $true } |
                    Select-Object -First 1

                $currentIP   = $null
                $currentMask = $null
                $currentGW   = $null

                if ($wmiAdapter) {
                    $currentIP   = $wmiAdapter.IPAddress | Where-Object { $_ -notlike '169.254.*' -and $_ -notmatch ':' } | Select-Object -First 1
                    $currentMask = if ($wmiAdapter.IPSubnet) { $wmiAdapter.IPSubnet[0] } else { $null }
                    $currentGW   = if ($wmiAdapter.DefaultIPGateway) { $wmiAdapter.DefaultIPGateway[0] } else { $null }
                }
                $currentDns = Normalize-DnsArray (
                    (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                )

                Write-Step "   Current : $currentIP / $currentMask via $currentGW  DNS: $($currentDns -join ', ')" White

                $already = ($currentIP   -eq $desiredIP) -and
                           ($currentMask -eq $subnetMask) -and
                           ($currentGW   -eq $desiredGW)  -and
                           (Test-ArrayEqual -A $currentDns -B $desiredDns)

                if ($already) {
                    Write-Step " - [$alias] Network already correct. No changes needed." Green
                    Update-Summary @{ NetworkRestored = $true; NetworkVerified = $true }
                    continue
                }

                # Apply IP / Gateway
                $out = netsh interface ipv4 set address name="$alias" static $desiredIP $subnetMask $desiredGW 1 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Error setting IP on [$alias]: $out" }

                # Apply DNS
                if ($desiredDns.Count -gt 0) {
                    netsh interface ipv4 set dnsservers name="$alias" static $desiredDns[0] primary 2>&1 | Out-Null
                    for ($i = 1; $i -lt $desiredDns.Count; $i++) {
                        netsh interface ipv4 add dnsservers name="$alias" $desiredDns[$i] index=($i + 1) 2>&1 | Out-Null
                    }
                }

                Start-Sleep -Seconds 2

                # Verify via WMI
                $wmiAfter = Get-WmiObject Win32_NetworkAdapterConfiguration |
                    Where-Object { $_.Index -eq $ifIndex -and $_.IPEnabled -eq $true } |
                    Select-Object -First 1

                $newIP   = $wmiAfter.IPAddress | Where-Object { $_ -notlike '169.254.*' -and $_ -notmatch ':' } | Select-Object -First 1
                $newMask = if ($wmiAfter.IPSubnet) { $wmiAfter.IPSubnet[0] } else { $null }
                $newGW   = if ($wmiAfter.DefaultIPGateway) { $wmiAfter.DefaultIPGateway[0] } else { $null }
                $newDns  = Normalize-DnsArray (
                    (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                )

                if ($newIP -eq $desiredIP -and $newMask -eq $subnetMask -and $newGW -eq $desiredGW -and (Test-ArrayEqual -A $newDns -B $desiredDns)) {
                    Write-Step " - [$alias] Network configuration applied and verified." Green
                    Update-Summary @{ NetworkRestored = $true; NetworkVerified = $true }
                } else {
                    $msg = "[$alias] Network applied but verification failed. Check manually."
                    Write-Host " - $msg" -ForegroundColor Red
                    $script:Summary.Errors += $msg
                    Update-Summary @{ NetworkRestored = $true; NetworkVerified = $false }
                }
            }
        }

        ########################################################################
        # Remove Scheduled Task

        Write-Step " - Removing Scheduled Task '$LogName'..." Yellow
        Unregister-ScheduledTask -TaskName $LogName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Step " - Scheduled Task removed." Green

        ########################################################################
        # Cleanup (triggered by Orchestrator flag)

        Update-Summary @{ ExitCode = 0 }
        Write-Step "=== Proxmox Phase complete. ===" Green
        Write-Step " - Logs and Summary remain in $WorkingPath for collection by Orchestrator." Yellow

        $CleanupFlag = "$WorkingPath\READY_FOR_CLEANUP"
        if (Test-Path $CleanupFlag) {
            Write-Step " - Cleanup flag detected. Removing C:\TEMP contents..." Yellow
            Get-ChildItem $WorkingPath -Exclude "*.log", "PVEMigration_Summary.json" |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $CleanupFlag -Force -ErrorAction SilentlyContinue
            Update-Summary @{ CleanupDone = $true }
            Write-Step " - Cleanup complete." Green
        }
    }

    ############################################################################

    else {
        Write-Host " - Unknown hypervisor: $hypervisor. Script cannot determine phase." -ForegroundColor Red
        $script:Summary.Errors += "Unknown hypervisor: $hypervisor"
        Update-Summary @{ ExitCode = 1 }
    }

} catch {
    $msg = $_.Exception.Message
    Write-Host "FATAL: $msg" -ForegroundColor Red
    $script:Summary.Errors += "FATAL: $msg"
    Update-Summary @{ ExitCode = 1 }
    exit 1
} finally {
    Stop-Transcript
}

if ($wait) { Read-Host -Prompt "Press Enter to exit" }
exit 0