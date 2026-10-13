﻿#requires -Version 5.1
<#
InternetX v2.7 - MAX TUNING ALL
Windows 10/11. Diagnostics measure connectivity; they do not create lag or desynchronization.
Menus 4/7/9 change supported adapter options and have a rollback manifest with verified restore.
Menu 8 opens the Network Adapter Tweaker window (original values are backed up on first open).
#>

$ErrorActionPreference = 'Continue'

function Test-IXAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Re-launch from the saved file with Administrator rights for reliable backup/restore.
if (-not (Test-IXAdmin)) {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath) -and (Test-Path -LiteralPath $PSCommandPath)) {
        try {
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
            Start-Process -FilePath $psExe -ArgumentList $argLine -Verb RunAs | Out-Null
        } catch {
            Write-Host 'Could not request Administrator permission. Right-click PowerShell > Run as administrator.' -ForegroundColor Red
            Read-Host 'Press Enter to exit' | Out-Null
        }
        exit
    }
}

$script:IXAdmin = Test-IXAdmin
$script:IXRoot = Join-Path $env:ProgramData 'InternetX'
try {
    New-Item -ItemType Directory -Path $script:IXRoot -Force -ErrorAction Stop | Out-Null
} catch {
    $script:IXRoot = Join-Path $env:LOCALAPPDATA 'InternetX'
    New-Item -ItemType Directory -Path $script:IXRoot -Force -ErrorAction SilentlyContinue | Out-Null
}
$script:IXLogDir = Join-Path $script:IXRoot 'Logs'
$script:IXReportDir = Join-Path $script:IXRoot 'Reports'
$script:IXBackupDir = Join-Path $script:IXRoot 'Backups'
New-Item -ItemType Directory -Path $script:IXLogDir,$script:IXReportDir,$script:IXBackupDir -Force -ErrorAction SilentlyContinue | Out-Null
$script:IXLogPath = Join-Path $script:IXLogDir ('InternetX_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
$script:IXStatePath = Join-Path $script:IXRoot 'InternetX-state.json'
$script:IXState = $null

function Write-IXLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $script:IXLogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message) -Encoding UTF8
    } catch { }
}

function Save-IXState {
    try {
        $json = $script:IXState | ConvertTo-Json -Depth 8
        Set-Content -LiteralPath $script:IXStatePath -Value $json -Encoding UTF8
    } catch {
        Write-Host ('Could not save rollback manifest: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-IXLog ('ERROR saving state: ' + $_.Exception.Message)
    }
}

function Load-IXState {
    if (Test-Path -LiteralPath $script:IXStatePath) {
        try { $script:IXState = Get-Content -LiteralPath $script:IXStatePath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $script:IXState = $null }
    }
    if ($null -eq $script:IXState -or $null -eq $script:IXState.Entries) {
        $script:IXState = [pscustomobject]@{ Version = 1; Created = (Get-Date).ToString('s'); Entries = @() }
    }
    if ($null -eq $script:IXState.Entries) { $script:IXState.Entries = @() }
}
Load-IXState

# ---------------------------------------------------------------------------
# Console theme. One palette for every screen, and colour carries meaning:
#   Heading = cyan      Border = blue        Advanced = purple
#   Ok      = green     Warn   = amber       Err      = red
#   Text    = gray      Strong = white       Muted    = dark gray
# Native console colours only (no escape sequences). Set NO_COLOR or
# INTERNETX_MONO=1, or press M on the dashboard, for monochrome output.
# ---------------------------------------------------------------------------
$script:IXTheme = $null
$script:IXMono = $false
$script:IXColorMap = @{}
$script:IXLastNet = $null
$script:IXOsInfo = $null
$script:IXAdapterCache = $null
$script:IXLiveOpen = $false
$script:IXLiveCount = 0

function Initialize-IXTheme {
    $script:IXTheme = @{ Heading = 'Cyan'; Border = 'Blue'; Advanced = 'Magenta'; Ok = 'Green'; Warn = 'Yellow'; Err = 'Red'; Text = 'Gray'; Strong = 'White'; Muted = 'DarkGray' }
    $script:IXColorMap = @{}
    if ($env:NO_COLOR -or $env:INTERNETX_MONO -eq '1') { $script:IXMono = $true }
    $background = $null
    try { $background = [string]$Host.UI.RawUI.BackgroundColor } catch { $script:IXMono = $true }
    if (@('DarkMagenta','DarkBlue','Blue') -contains $background) {
        # Classic blue PowerShell window: blue and dark purple text would disappear into the background.
        $script:IXTheme.Border = 'DarkCyan'
        $script:IXColorMap = @{ 'Blue' = 'Cyan'; 'DarkBlue' = 'DarkCyan'; 'DarkMagenta' = 'Magenta' }
    } elseif (@('White','Gray','Yellow','Cyan','Green') -contains $background) {
        # Light background: white and yellow text would be unreadable, so use the console's own text colour.
        $script:IXMono = $true
    }
}

function Write-Host {
    # Wraps the built-in cmdlet so every existing message follows the theme and the monochrome switch.
    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)][AllowNull()][object]$Object,
        [switch]$NoNewline,
        [AllowNull()][object]$Separator,
        [System.ConsoleColor]$ForegroundColor,
        [System.ConsoleColor]$BackgroundColor
    )
    process {
        if ($null -eq $script:IXTheme) { Initialize-IXTheme }
        $arguments = @{}
        if ($PSBoundParameters.ContainsKey('Object')) { $arguments['Object'] = $Object }
        if ($NoNewline) { $arguments['NoNewline'] = $true }
        if ($PSBoundParameters.ContainsKey('Separator')) { $arguments['Separator'] = $Separator }
        if (-not $script:IXMono) {
            if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
                $name = [string]$ForegroundColor
                if ($script:IXColorMap.ContainsKey($name)) { $name = [string]$script:IXColorMap[$name] }
                $arguments['ForegroundColor'] = $name
            }
            if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $arguments['BackgroundColor'] = $BackgroundColor }
        }
        Microsoft.PowerShell.Utility\Write-Host @arguments
    }
}

function Get-IXColor {
    param([string]$Role)
    if ($null -eq $script:IXTheme) { Initialize-IXTheme }
    if ($script:IXTheme.ContainsKey($Role)) { return [string]$script:IXTheme[$Role] }
    return 'Gray'
}

function Get-IXWidth {
    # Never assumes the window can be resized; fits what is there, capped so wide windows stay tidy.
    $width = 80
    try { $width = [int]$Host.UI.RawUI.WindowSize.Width } catch { }
    if ($width -lt 40) { $width = 80 }
    return [math]::Min(78,$width - 1)
}

function Format-IXFit {
    param([AllowNull()][string]$Text,[int]$Width)
    $value = [string]$Text
    if ($Width -lt 4) { return $value }
    if ($value.Length -gt $Width) { return ($value.Substring(0,$Width - 2) + '..') }
    return $value
}

function Write-IXRule {
    param([switch]$Thin)
    if ($Thin) { Write-Host (' ' + ('-' * ((Get-IXWidth) - 1))) -ForegroundColor (Get-IXColor 'Muted') }
    else { Write-Host (' ' + ('=' * ((Get-IXWidth) - 1))) -ForegroundColor (Get-IXColor 'Border') }
}

function Write-IXTitle {
    param([string]$Text,[switch]$Advanced)
    Write-Host (' ' + $Text) -ForegroundColor (Get-IXColor $(if ($Advanced) { 'Advanced' } else { 'Heading' }))
}

function Write-IXSection {
    param([string]$Text)
    Write-Host (' ' + $Text) -ForegroundColor (Get-IXColor 'Heading')
}

function Write-IXTagged {
    # The tag keeps the meaning readable in monochrome mode.
    param([string]$Tag,[string]$Role,[string]$Text)
    Write-Host (' ' + $Tag + ' ') -ForegroundColor (Get-IXColor $Role) -NoNewline
    Write-Host $Text -ForegroundColor (Get-IXColor 'Strong')
}
function Write-IXOk { param([string]$Text) Write-IXTagged -Tag '[ OK ]' -Role 'Ok' -Text $Text }
function Write-IXWarn { param([string]$Text) Write-IXTagged -Tag '[ !! ]' -Role 'Warn' -Text $Text }
function Write-IXErr { param([string]$Text) Write-IXTagged -Tag '[FAIL]' -Role 'Err' -Text $Text }
function Write-IXInfo { param([string]$Text) Write-IXTagged -Tag '[ .. ]' -Role 'Heading' -Text $Text }
function Write-IXAdv { param([string]$Text) Write-IXTagged -Tag '[ADV ]' -Role 'Advanced' -Text $Text }

function Write-IXStatus {
    param([string]$Label,[AllowNull()][string]$Value,[string]$Role = 'Text',[int]$LabelWidth = 16)
    Write-Host ('  ' + ($Label + ':').PadRight($LabelWidth)) -ForegroundColor (Get-IXColor 'Muted') -NoNewline
    Write-Host ([string]$Value) -ForegroundColor (Get-IXColor $Role)
}

function Write-IXMenuItem {
    # Kind: Normal, Advanced (purple), Apply (can change settings; amber hint), Exit (muted).
    param([string]$Key,[string]$Text,[string]$Hint = '',[ValidateSet('Normal','Advanced','Apply','Exit')][string]$Kind = 'Normal')
    $width = Get-IXWidth
    $textRole = switch ($Kind) { 'Advanced' { 'Advanced' } 'Exit' { 'Muted' } default { 'Strong' } }
    $hintRole = if ($Kind -eq 'Apply' -or $Hint -like 'changes*') { 'Warn' } else { 'Muted' }
    Write-Host ('  [' + $Key + ']  ') -ForegroundColor (Get-IXColor 'Border') -NoNewline
    if ($Hint -and $width -ge 70) {
        $textWidth = 46
        Write-Host ((Format-IXFit -Text $Text -Width $textWidth).PadRight($textWidth + 1)) -ForegroundColor (Get-IXColor $textRole) -NoNewline
        Write-Host (Format-IXFit -Text $Hint -Width ($width - $textWidth - 9)) -ForegroundColor (Get-IXColor $hintRole)
    } else {
        Write-Host (Format-IXFit -Text $Text -Width ($width - 8)) -ForegroundColor (Get-IXColor $textRole)
    }
}

function Read-IXChoice {
    param([string]$Prompt = 'Choose an option')
    Write-Host ' > ' -ForegroundColor (Get-IXColor 'Border') -NoNewline
    return ([string](Read-Host $Prompt)).Trim()
}

function Clear-IXLive {
    if ($script:IXLiveOpen) {
        if ($Host.Name -eq 'ConsoleHost') { Write-Host ("`r" + (' ' * (Get-IXWidth)) + "`r") -NoNewline }
        $script:IXLiveOpen = $false
    }
}

function Write-IXLive {
    # One status line that is rewritten in place, so long tests do not scroll hundreds of lines.
    param([string]$Text,[string]$Role = 'Heading')
    if ($Host.Name -ne 'ConsoleHost') {
        # Hosts that cannot rewrite a line get one ordinary line every 10 updates instead.
        if (($script:IXLiveCount % 10) -eq 0) { Write-Host $Text -ForegroundColor (Get-IXColor $Role) }
        $script:IXLiveCount++
        return
    }
    $width = Get-IXWidth
    Write-Host ("`r" + (Format-IXFit -Text $Text -Width $width).PadRight($width)) -ForegroundColor (Get-IXColor $Role) -NoNewline
    $script:IXLiveOpen = $true
}

function Get-IXProgressBar {
    param([double]$Done,[double]$Total,[int]$Cells = 16)
    $filled = 0
    if ($Total -gt 0) { $filled = [int][math]::Floor($Cells * [math]::Min(1.0,[math]::Max(0.0,$Done / $Total))) }
    return ('[' + ('#' * $filled) + ('.' * ($Cells - $filled)) + ']')
}

function Get-IXActiveChangeCount {
    try { return @($script:IXState.Entries | Where-Object { $_.Status -in @('Applied','Pending') }).Count } catch { return 0 }
}

function Write-IXSafetyNote {
    # Shown before every confirmation prompt that can change a setting.
    $admin = Test-IXAdmin
    Write-IXStatus -Label 'Backup' -Value ('saved before any change (rollback entries stored now: {0})' -f (Get-IXActiveChangeCount)) -Role 'Text'
    Write-IXStatus -Label 'Administrator' -Value $(if ($admin) { 'required - you are running as Administrator' } else { 'required - NOT running as Administrator' }) -Role $(if ($admin) { 'Ok' } else { 'Err' })
    Write-IXWarn 'Nothing is changed until you confirm below.'
}

function Write-IXWrapped {
    # Word-wraps to the console width so long sentences never break in the middle of a word.
    param([string]$Text,[int]$Indent = 2,[string]$Role = 'Text')
    $limit = [math]::Max(20,(Get-IXWidth) - $Indent)
    $line = ''
    foreach ($word in @(([string]$Text) -split '\s+' | Where-Object { $_ })) {
        if ($line.Length -gt 0 -and ($line.Length + 1 + $word.Length) -gt $limit) {
            Write-Host ((' ' * $Indent) + $line) -ForegroundColor (Get-IXColor $Role)
            $line = $word
        } elseif ($line.Length -eq 0) { $line = $word } else { $line += ' ' + $word }
    }
    if ($line.Length -gt 0) { Write-Host ((' ' * $Indent) + $line) -ForegroundColor (Get-IXColor $Role) }
}

function Write-IXChangePreview {
    # Items need: Name, Current, Proposed, Reason.
    param([AllowNull()][object[]]$Items)
    $width = Get-IXWidth
    $nameWidth = [math]::Min(34,[math]::Max(18,[int]($width * 0.42)))
    $valueWidth = [math]::Max(8,[int](($width - $nameWidth - 9) / 2))
    Write-Host ('  ' + 'Setting'.PadRight($nameWidth) + ' ' + 'Current'.PadRight($valueWidth) + '    ' + 'Proposed') -ForegroundColor (Get-IXColor 'Heading')
    Write-IXRule -Thin
    foreach ($item in @($Items)) {
        Write-Host ('  ' + (Format-IXFit -Text ([string]$item.Name) -Width $nameWidth).PadRight($nameWidth) + ' ') -ForegroundColor (Get-IXColor 'Strong') -NoNewline
        Write-Host ((Format-IXFit -Text ([string]$item.Current) -Width $valueWidth).PadRight($valueWidth)) -ForegroundColor (Get-IXColor 'Text') -NoNewline
        Write-Host ' -> ' -ForegroundColor (Get-IXColor 'Border') -NoNewline
        Write-Host (Format-IXFit -Text ([string]$item.Proposed) -Width $valueWidth) -ForegroundColor (Get-IXColor 'Warn')
        if (-not [string]::IsNullOrWhiteSpace([string]$item.Reason)) { Write-IXWrapped -Text ('why: ' + [string]$item.Reason) -Indent 6 -Role 'Muted' }
        if ($item.PSObject.Properties['TradeOff'] -and -not [string]::IsNullOrWhiteSpace([string]$item.TradeOff)) { Write-IXWrapped -Text ('trade-off: ' + [string]$item.TradeOff) -Indent 6 -Role 'Muted' }
    }
    Write-IXRule -Thin
    Write-IXSafetyNote
}

function Set-IXLastNetwork {
    # Remembers the most recent real measurement for the dashboard. Nothing is ever invented.
    param([string]$Target,[AllowNull()][object]$AvgMs,[AllowNull()][object]$JitterMs,[AllowNull()][object]$LossPct)
    if ($null -eq $AvgMs -and $null -eq $LossPct) { return }
    $script:IXLastNet = [pscustomobject]@{ Target = $Target; AvgMs = $AvgMs; JitterMs = $JitterMs; LossPct = $LossPct; Time = (Get-Date) }
}

function Get-IXOsInfo {
    if ($null -eq $script:IXOsInfo) {
        $caption = 'Windows'; $build = 'Unknown'
        try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $caption = ([string]$os.Caption -replace '^Microsoft\s+','').Trim(); $build = [string]$os.BuildNumber } catch { }
        $script:IXOsInfo = [pscustomobject]@{ Caption = $caption; Build = $build }
    }
    return $script:IXOsInfo
}

function Get-IXCachedAdapter {
    # For headers only; operations always query the adapter fresh.
    if ($null -eq $script:IXAdapterCache -or ((Get-Date) - $script:IXAdapterCache.Time).TotalSeconds -gt 15) {
        $adapter = Get-IXPrimaryAdapter
        $mtu = $null; $isWifi = $false
        if ($adapter) {
            try { $ipInterface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1; if ($ipInterface -and $null -ne $ipInterface.NlMtu) { $mtu = [int]$ipInterface.NlMtu } } catch { }
            $isWifi = ($adapter.Name -match 'Wi-?Fi|Wireless|WLAN') -or ($adapter.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11')
        }
        $script:IXAdapterCache = [pscustomobject]@{ Adapter = $adapter; Mtu = $mtu; IsWifi = $isWifi; Time = (Get-Date) }
    }
    return $script:IXAdapterCache
}

function Get-IXDashboardInfo {
    $os = Get-IXOsInfo
    $cache = Get-IXCachedAdapter
    $admin = [bool]$script:IXAdmin
    $network = [ordered]@{
        Latency = @('Not tested','Muted'); Jitter = @('Not tested','Muted'); Loss = @('Not tested','Muted'); Status = @('Not tested','Muted')
    }
    $last = $script:IXLastNet
    if ($last) {
        if ($null -ne $last.AvgMs) { $network.Latency = @(('{0} ms' -f $last.AvgMs),'Strong') } else { $network.Latency = @('No reply','Warn') }
        if ($null -ne $last.JitterMs) { $network.Jitter = @(('{0} ms' -f $last.JitterMs),$(if ([double]$last.JitterMs -ge 15) { 'Warn' } else { 'Strong' })) } else { $network.Jitter = @('Unknown','Muted') }
        if ($null -ne $last.LossPct) { $network.Loss = @(('{0} %' -f $last.LossPct),$(if ([double]$last.LossPct -gt 0) { 'Warn' } else { 'Strong' })) } else { $network.Loss = @('Unknown','Muted') }
        $attention = ($null -eq $last.AvgMs) -or ($null -ne $last.LossPct -and [double]$last.LossPct -gt 0) -or ($null -ne $last.JitterMs -and [double]$last.JitterMs -ge 15)
        $network.Status = $(if ($attention) { @('Needs attention','Warn') } else { @('Healthy','Ok') })
    }
    $connection = [ordered]@{ Adapter = @('Not detected','Warn'); Type = @('Unknown','Muted'); Link = @('Unknown','Muted'); MTU = @('Unknown','Muted') }
    if ($cache.Adapter) {
        $connection.Adapter = @([string]$cache.Adapter.Name,'Strong')
        $connection.Type = $(if ($cache.IsWifi) { @('Wi-Fi','Warn') } else { @('Ethernet','Strong') })
        $connection.Link = @([string]$cache.Adapter.LinkSpeed,'Strong')
        if ($null -ne $cache.Mtu) { $connection.MTU = @([string]$cache.Mtu,$(if ($cache.Mtu -gt 1500) { 'Warn' } else { 'Strong' })) }
    }
    $changes = Get-IXActiveChangeCount
    $system = [ordered]@{
        Admin = $(if ($admin) { @('YES','Ok') } else { @('NO','Warn') })
        OS = @($(if ([string]$os.Caption -match '^(Windows(?: Server)? \d+)') { $Matches[1] } else { [string]$os.Caption }),'Strong'); Build = @([string]$os.Build,'Strong')
        Tuning = $(if ($changes -gt 0) { @(('{0} active' -f $changes),'Advanced') } else { @('None applied','Muted') })
    }
    return [pscustomobject]@{ Network = $network; Connection = $connection; System = $system; Last = $last; Os = $os }
}

function Show-IXDashboard {
    Clear-Host
    $script:IXLiveOpen = $false
    $width = Get-IXWidth
    $info = Get-IXDashboardInfo
    if ($width -ge 50) {
        $banner = @(
            '  ___       _                       _  __  __',
            ' |_ _|_ __ | |_ ___ _ __ _ __   ___| |_\ \/ /',
            '  | || ''_ \| __/ _ \ ''__| ''_ \ / _ \ __|\  /',
            '  | || | | | ||  __/ |  | | | |  __/ |_ /  \',
            ' |___|_| |_|\__\___|_|  |_| |_|\___|\__/_/\_\'
        )
        foreach ($line in $banner) { Write-Host (' ' + $line) -ForegroundColor (Get-IXColor 'Heading') }
    } else {
        Write-Host ' INTERNETX' -ForegroundColor (Get-IXColor 'Heading')
    }
    Write-Host '  v2.7 MAX TUNING ALL' -ForegroundColor (Get-IXColor 'Strong') -NoNewline
    Write-Host '  |  FiveM Network Utility' -ForegroundColor (Get-IXColor 'Muted')
    Write-IXRule

    $cards = @(
        @{ Title = '[ NETWORK ]'; Data = $info.Network },
        @{ Title = '[ CONNECTION ]'; Data = $info.Connection },
        @{ Title = '[ SYSTEM ]'; Data = $info.System }
    )
    if ($width -ge 76) {
        # Three cards side by side.
        $column = [int][math]::Floor(($width - 1) / 3)
        Write-Host ' ' -NoNewline
        foreach ($card in $cards) { Write-Host ($card.Title.PadRight($column)) -ForegroundColor (Get-IXColor 'Heading') -NoNewline }
        Write-Host ''
        for ($row = 0; $row -lt 4; $row++) {
            Write-Host ' ' -NoNewline
            foreach ($card in $cards) {
                $key = [string]@($card.Data.Keys)[$row]
                $cell = $card.Data[$key]
                Write-Host (($key + ':').PadRight(9)) -ForegroundColor (Get-IXColor 'Muted') -NoNewline
                Write-Host ((Format-IXFit -Text ([string]$cell[0]) -Width ($column - 11)).PadRight($column - 9)) -ForegroundColor (Get-IXColor ([string]$cell[1])) -NoNewline
            }
            Write-Host ''
        }
    } else {
        # Narrow window: the same information stacked.
        foreach ($card in $cards) {
            Write-IXSection ($card.Title.Trim('[',']',' '))
            foreach ($key in @($card.Data.Keys)) { Write-IXStatus -Label ([string]$key) -Value ([string]$card.Data[[string]$key][0]) -Role ([string]$card.Data[[string]$key][1]) -LabelWidth 10 }
        }
    }
    if ($info.Last) { Write-Host (Format-IXFit -Text ('  {0} (build {1})  |  last test {2} at {3}' -f $info.Os.Caption,$info.Os.Build,$info.Last.Target,$info.Last.Time.ToString('HH:mm')) -Width $width) -ForegroundColor (Get-IXColor 'Muted') }
    else { Write-Host (Format-IXFit -Text ('  {0} (build {1})  |  not tested yet: run [2]' -f $info.Os.Caption,$info.Os.Build) -Width $width) -ForegroundColor (Get-IXColor 'Muted') }
    Write-IXRule -Thin
    Write-IXSection 'MAIN MENU'
    Write-IXMenuItem -Key '1' -Text 'Quick Network Scan' -Hint 'read-only'
    Write-IXMenuItem -Key '2' -Text 'Ping, Jitter & Packet Loss Monitor' -Hint 'read-only, before/after'
    Write-IXMenuItem -Key '3' -Text 'Path MTU Diagnostics' -Hint 'read-only'
    Write-IXMenuItem -Key '4' -Text 'Optimization Preview / Apply / Restore' -Hint 'changes after YES' -Kind Apply
    Write-IXMenuItem -Key '5' -Text 'Hit Registration & Rubberbanding Diagnostics' -Hint 'read-only' -Kind Advanced
    Write-IXMenuItem -Key '6' -Text 'Reports, Logs & Self-Test' -Hint 'read-only'
    Write-IXMenuItem -Key '7' -Text 'Advanced Network Tuning' -Hint 'changes after YES' -Kind Advanced
    Write-IXMenuItem -Key '8' -Text 'Network Adapter Tweaker' -Hint 'opens a window' -Kind Advanced
    Write-IXMenuItem -Key '9' -Text 'EXTREME Low Ping / Low Jitter Profile' -Hint 'changes after YES' -Kind Apply
    Write-IXMenuItem -Key 'D' -Text 'FiveM Desync Diagnostics' -Hint 'read-only + report' -Kind Advanced
    Write-IXMenuItem -Key '0' -Text 'Exit' -Kind Exit
    Write-IXRule -Thin
    Write-Host ('  M = monochrome {0}' -f $(if ($script:IXMono) { 'off' } else { 'on' })) -ForegroundColor (Get-IXColor 'Muted')
}

function Show-IXHeader {
    # Compact header for every screen below the dashboard.
    Clear-Host
    $script:IXLiveOpen = $false
    $cache = Get-IXCachedAdapter
    $right = 'Admin: ' + $(if ($script:IXAdmin) { 'YES' } else { 'NO' })
    if ($cache.Adapter) { $right += ('  |  {0}  {1}' -f $cache.Adapter.Name,$cache.Adapter.LinkSpeed) } else { $right += '  |  no adapter detected' }
    Write-Host ' InternetX' -ForegroundColor (Get-IXColor 'Heading') -NoNewline
    Write-Host ' v2.7 MAX TUNING ALL' -ForegroundColor (Get-IXColor 'Strong') -NoNewline
    Write-Host ('   ' + (Format-IXFit -Text $right -Width ([math]::Max(10,(Get-IXWidth) - 34)))) -ForegroundColor (Get-IXColor 'Muted')
    Write-IXRule
}

function Get-IXActiveAdapters {
    $all = @()
    try { $all = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) } catch { }
    if ($all.Count -eq 0) { return @() }
    $configs = @()
    try { $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -or $_.IPv6DefaultGateway }) } catch { }
    $routeIndices = @($configs | ForEach-Object { [int]$_.InterfaceIndex } | Select-Object -Unique)
    if ($routeIndices.Count -gt 0) {
        $routed = @($all | Where-Object { $routeIndices -contains [int]$_.ifIndex })
        if ($routed.Count -gt 0) { return $routed }
    }
    return @($all)
}

function Get-IXPrimaryAdapter {
    $active = @(Get-IXActiveAdapters)
    if ($active.Count -eq 0) { return $null }
    $configs = @()
    try { $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -or $_.IPv6DefaultGateway }) } catch { }
    foreach ($cfg in $configs) {
        $idx = [int]$cfg.InterfaceIndex
        $match = $active | Where-Object { [int]$_.ifIndex -eq $idx } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $active[0]
}

function Get-IXIPv4Gateway {
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        if ($cfg) { return [string]$cfg.IPv4DefaultGateway.NextHop }
    } catch { }
    return $null
}

function Resolve-IXIPv4 {
    param([Parameter(Mandatory=$true)][string]$Target)
    $value = $Target.Trim()
    if ($value -match '[\s;&|<>`"]') { return $null }
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($value,[ref]$parsed)) {
        if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { return $parsed.IPAddressToString }
        return $null
    }
    try {
        $found = [System.Net.Dns]::GetHostAddresses($value) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
        if ($found) { return $found.IPAddressToString }
    } catch { }
    return $null
}

function Wait-IXReturn {
    [void](Read-Host 'Press Enter to return to the menu (do not enter a menu number here)')
}

function Add-IXReportRows {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Destination
    )
    if ($null -eq $Value) { return }

    # Flatten arrays/lists recursively but keep strings, dictionaries, and row objects intact.
    $isContainer = ($Value -is [System.Collections.IEnumerable]) -and
                   ($Value -isnot [string]) -and
                   ($Value -isnot [System.Collections.IDictionary]) -and
                   ($Value -isnot [System.Management.Automation.PSCustomObject])
    if ($isContainer) {
        foreach ($entry in $Value) {
            Add-IXReportRows -Value $entry -Destination $Destination
        }
    } else {
        [void]$Destination.Add($Value)
    }
}

function Save-IXReport {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [AllowNull()][object]$Lines,
        [AllowNull()][object]$Rows
    )

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = ($Name -replace '[^A-Za-z0-9_-]','_')
    $txt = Join-Path $script:IXReportDir ('{0}_{1}.txt' -f $safeName,$stamp)
    $lineList = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $Lines) {
        if ($Lines -is [string]) {
            [void]$lineList.Add([string]$Lines)
        } else {
            foreach ($line in $Lines) {
                if ($null -ne $line) { [void]$lineList.Add([string]$line) }
            }
        }
    }

    $textSaved = $false
    try {
        if ($lineList.Count -gt 0) {
            Set-Content -LiteralPath $txt -Value $lineList.ToArray() -Encoding UTF8 -ErrorAction Stop
        } else {
            Set-Content -LiteralPath $txt -Value '' -Encoding UTF8 -ErrorAction Stop
        }
        $textSaved = $true
        Write-Host ('Report: {0}' -f $txt) -ForegroundColor Green
        Write-IXLog ('Report saved: ' + $txt)
    } catch {
        Write-Host ('Report could not be saved: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-IXLog ('ERROR saving report text: ' + $_.Exception.Message)
    }

    $rowList = New-Object 'System.Collections.Generic.List[object]'
    Add-IXReportRows -Value $Rows -Destination $rowList
    $csv = $null
    $csvSaved = $false
    if ($rowList.Count -gt 0) {
        $csv = Join-Path $script:IXReportDir ('{0}_{1}.csv' -f $safeName,$stamp)
        try {
            $rowArray = $rowList.ToArray()
            $rowArray | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            $csvSaved = $true
            Write-Host ('CSV: {0} ({1} rows)' -f $csv,$rowList.Count) -ForegroundColor Green
            Write-IXLog ('CSV saved: ' + $csv + '; rows=' + $rowList.Count)
        } catch {
            Write-Host ('CSV export failed: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
            Write-IXLog ('ERROR saving report CSV: ' + $_.Exception.Message)
        }
    } else {
        Write-Host 'No tabular rows supplied; CSV skipped.' -ForegroundColor DarkGray
    }
}

function Test-IXReportWriter {
    Show-IXHeader
    Write-IXTitle 'REPORT WRITER SELF-TEST'
    Write-Host 'Checks arrays, Generic.List, nested-list input, and null rows using temporary files.' -ForegroundColor DarkGray
    $testRoot = Join-Path $env:TEMP ('InternetX-ReportSelfTest-' + [guid]::NewGuid().ToString('N'))
    $allPassed = $true
    try {
        New-Item -ItemType Directory -Path $testRoot -Force -ErrorAction Stop | Out-Null
        $rowA = [pscustomobject]@{ Name='alpha'; Value=1 }
        $rowB = [pscustomobject]@{ Name='beta'; Value=2 }
        $generic = New-Object 'System.Collections.Generic.List[object]'
        [void]$generic.Add($rowA); [void]$generic.Add($rowB)
        $nested = New-Object 'System.Object[]' 1
        $nested[0] = $generic
        $cases = New-Object 'System.Collections.Generic.List[object]'
        [void]$cases.Add([pscustomobject]@{ Name='GenericList'; Rows=$generic; Expected=2 })
        [void]$cases.Add([pscustomobject]@{ Name='Array'; Rows=@($rowA,$rowB); Expected=2 })
        [void]$cases.Add([pscustomobject]@{ Name='NestedList'; Rows=$nested; Expected=2 })
        [void]$cases.Add([pscustomobject]@{ Name='NullRows'; Rows=$null; Expected=0 })

        $originalReportDir = $script:IXReportDir
        $script:IXReportDir = $testRoot
        try {
            foreach ($case in $cases) {
                $testName = 'SelfTest-' + $case.Name
                $caseLines = @('InternetX report-writer self-test',('Case: ' + $case.Name))
                Save-IXReport -Name $testName -Lines $caseLines -Rows $case.Rows
                $txtFiles = @(Get-ChildItem -LiteralPath $testRoot -Filter ($testName + '_*.txt') -File -ErrorAction SilentlyContinue)
                $csvFiles = @(Get-ChildItem -LiteralPath $testRoot -Filter ($testName + '_*.csv') -File -ErrorAction SilentlyContinue)
                $ok = ($txtFiles.Count -eq 1)
                if ([int]$case.Expected -gt 0) {
                    if ($csvFiles.Count -ne 1) { $ok = $false }
                    else {
                        try {
                            $roundTrip = @(Import-Csv -LiteralPath $csvFiles[0].FullName -ErrorAction Stop)
                            $ok = $ok -and ($roundTrip.Count -eq [int]$case.Expected)
                        } catch { $ok = $false }
                    }
                } elseif ($csvFiles.Count -ne 0) { $ok = $false }
                Write-Host ('{0,-12} {1}' -f $case.Name, $(if ($ok) {'PASS'} else {'FAIL'})) -ForegroundColor $(if ($ok) {'Green'} else {'Red'})
                if (-not $ok) { $allPassed = $false }
            }
        } finally {
            $script:IXReportDir = $originalReportDir
        }
    } catch {
        $allPassed = $false
        Write-Host ('Self-test error: {0}' -f $_.Exception.Message) -ForegroundColor Red
    } finally {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($allPassed) {
        Write-Host 'Report writer self-test passed.' -ForegroundColor Green
        Write-IXLog 'Report writer self-test passed.'
    } else {
        Write-Host 'Report writer self-test FAILED. Do not distribute until fixed.' -ForegroundColor Red
        Write-IXLog 'Report writer self-test FAILED.'
    }
    Wait-IXReturn
}

function Invoke-IXQuickScan {
    Show-IXHeader
    Write-IXTitle 'QUICK PC / NETWORK SCAN'
    $adapters = @(Get-IXActiveAdapters)
    if ($adapters.Count -eq 0) {
        Write-Host 'No active network adapter was detected.' -ForegroundColor Red
    } else {
        foreach ($a in $adapters) {
            Write-Host ''
            Write-Host ('Adapter: {0}' -f $a.Name) -ForegroundColor Cyan
            Write-Host ('  Device : {0}' -f $a.InterfaceDescription)
            Write-Host ('  Link   : {0} | Status: {1}' -f $a.LinkSpeed,$a.Status)
            try {
                $nic = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.NetConnectionID -eq $a.Name } | Select-Object -First 1
                if ($nic) { Write-Host ('  Driver : {0} | Version: {1}' -f $nic.DriverName,$nic.DriverVersion) }
            } catch { }
            try {
                $rss = Get-NetAdapterRss -Name $a.Name -ErrorAction Stop | Select-Object -First 1
                if ($rss) { Write-Host ('  RSS    : {0}' -f $rss.Enabled) }
            } catch { Write-Host '  RSS    : not exposed by this adapter/driver' -ForegroundColor DarkYellow }
            try {
                $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -AllProperties -ErrorAction Stop | Where-Object { $_.DisplayName -match 'Energy Efficient Ethernet|Green Ethernet|Advanced EEE' })
                foreach ($p in $props) { Write-Host ('  Power  : {0} = {1}' -f $p.DisplayName,$p.DisplayValue) -ForegroundColor Gray }
            } catch { }
        }
    }
    Write-Host ''
    Write-Host 'TCP global settings (read-only):' -ForegroundColor Cyan
    $tcp = @(& netsh.exe interface tcp show global 2>&1 | ForEach-Object { [string]$_ })
    $tcp | Select-Object -First 14 | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor Gray }
    $lines = @('InternetX Quick Scan',('Time: ' + (Get-Date -Format 's')))
    foreach ($a in $adapters) { $lines += ('Adapter: {0}; Device: {1}; Link: {2}; Status: {3}' -f $a.Name,$a.InterfaceDescription,$a.LinkSpeed,$a.Status) }
    $lines += 'TCP global settings:'; $lines += $tcp
    Save-IXReport -Name 'QuickScan' -Lines $lines -Rows $adapters
    Write-Host ''
    Write-Host 'Review note: adapter speed and scan results do not prove FiveM server latency.' -ForegroundColor DarkGray
    Wait-IXReturn
}

function Invoke-IXPingSummary {
    param([string]$Target,[int]$Count = 15,[int]$TimeoutMs = 1000)
    $ip = Resolve-IXIPv4 -Target $Target
    if (-not $ip) {
        return [pscustomobject]@{ Target=$Target; Resolved='N/A'; Sent=$Count; Received=0; Lost=$Count; LossPct=100.0; MinMs=$null; AvgMs=$null; MaxMs=$null; JitterMs=$null; Result='DNS / IPv4 resolution failed' }
    }
    $rtts = New-Object 'System.Collections.Generic.List[double]'
    $sentStatuses = New-Object 'System.Collections.Generic.List[string]'
    $sampleRtts = New-Object 'System.Collections.Generic.List[object]'
    $pinger = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($i=0; $i -lt $Count; $i++) {
            try {
                $reply = $pinger.Send($ip,$TimeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $sample = [double]$reply.RoundtripTime
                    [void]$rtts.Add($sample)
                    [void]$sampleRtts.Add($sample)
                    [void]$sentStatuses.Add('Success')
                } else {
                    [void]$sampleRtts.Add($null)
                    [void]$sentStatuses.Add([string]$reply.Status)
                }
            } catch {
                [void]$sampleRtts.Add($null)
                [void]$sentStatuses.Add('Error')
            }
            if ($i -lt ($Count-1)) { Start-Sleep -Milliseconds 80 }
        }
    } finally { $pinger.Dispose() }
    $received = $rtts.Count
    $lost = $Count - $received
    $lossPct = [math]::Round(($lost / [double]$Count) * 100,1)
    $min = $null; $avg = $null; $max = $null; $jitter = $null
    if ($received -gt 0) {
        $stats = $rtts | Measure-Object -Minimum -Average -Maximum
        $min = [math]::Round([double]$stats.Minimum,1)
        $avg = [math]::Round([double]$stats.Average,1)
        $max = [math]::Round([double]$stats.Maximum,1)
    }
    if ($Count -ge 2) {
        $diffs = New-Object 'System.Collections.Generic.List[double]'
        for ($j=1; $j -lt $sampleRtts.Count; $j++) {
            # Only compare truly adjacent probes; do not bridge over a timeout/error.
            if ($null -ne $sampleRtts[$j] -and $null -ne $sampleRtts[$j-1]) {
                [void]$diffs.Add([math]::Abs([double]$sampleRtts[$j] - [double]$sampleRtts[$j-1]))
            }
        }
        if ($diffs.Count -gt 0) { $jitter = [math]::Round((($diffs | Measure-Object -Average).Average),1) }
    }
    $result = 'Sample complete; compare destinations and repeat during gameplay'
    if ($received -eq 0) { $result = 'No ICMP replies; ICMP may be blocked or target unreachable' }
    elseif ($lossPct -ge 5) { $result = 'Packet loss observed in this sample' }
    elseif ($null -ne $jitter -and $jitter -ge 15) { $result = 'High RTT variation in this sample (heuristic)' }
    elseif ($lossPct -eq 0) { $result = 'No packet loss observed in this sample' }
    return [pscustomobject]@{ Target=$Target; Resolved=$ip; Sent=$Count; Received=$received; Lost=$lost; LossPct=$lossPct; MinMs=$min; AvgMs=$avg; MaxMs=$max; JitterMs=$jitter; Result=$result }
}

function Invoke-IXLiveMonitor {
    Show-IXHeader
    Write-IXTitle 'LIVE PING / JITTER / PACKET-LOSS MONITOR'
    Write-Host 'Use this while playing FiveM to record network changes. It does not create lag.' -ForegroundColor DarkGray
    Write-Host 'Prefer the actual game endpoint if you know it; ICMP may be blocked.' -ForegroundColor DarkGray
    $inputTarget = Read-Host 'Target IPv4 host/IP (Enter = 1.1.1.1)'
    if ([string]::IsNullOrWhiteSpace($inputTarget)) { $inputTarget = '1.1.1.1' }
    $ip = Resolve-IXIPv4 -Target $inputTarget
    if (-not $ip) {
        Write-Host 'Could not resolve a valid IPv4 target.' -ForegroundColor Red
        Wait-IXReturn
        return
    }

    $durationText = Read-Host 'Duration in seconds [30/60/180/300] (Enter = 60)'
    $duration = 60
    if (-not [string]::IsNullOrWhiteSpace($durationText)) {
        $parsedDuration = 0
        if ([int]::TryParse($durationText, [ref]$parsedDuration) -and @(30,60,180,300) -contains $parsedDuration) {
            $duration = $parsedDuration
        } else {
            Write-Host 'Invalid duration; using 60 seconds.' -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host ('Target: {0} ({1}) | Duration: {2}s | One probe about each second' -f $inputTarget,$ip,$duration) -ForegroundColor Cyan
    Write-Host 'Keep the game running. Stop downloads only if you want an idle baseline; repeat during your usual load for comparison.' -ForegroundColor DarkGray
    Write-Host ''
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $rtts = New-Object 'System.Collections.Generic.List[double]'
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $start = Get-Date
    $end = $start.AddSeconds($duration)
    $sequence = 0
    try {
        while ((Get-Date) -lt $end) {
            $sequence++
            $stamp = Get-Date
            $status = 'Error'
            $rtt = $null
            try {
                $reply = $pinger.Send($ip, 900)
                $status = [string]$reply.Status
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $rtt = [double]$reply.RoundtripTime
                    [void]$rtts.Add($rtt)
                }
            } catch {
                $status = 'Error'
            }
            $row = [pscustomobject]@{
                Timestamp = $stamp.ToString('yyyy-MM-dd HH:mm:ss.fff')
                Sequence = $sequence
                Target = $inputTarget
                ResolvedIPv4 = $ip
                Status = $status
                RTTms = $rtt
            }
            [void]$rows.Add($row)
            # Normal replies rewrite one status line; slow replies and timeouts stay on screen.
            $elapsed = [int]((Get-Date) - $start).TotalSeconds
            if ($status -eq 'Success' -and $rtt -lt 100) {
                Write-IXLive -Text (' {0} {1,3}/{2}s | probe {3} | {4} ms' -f (Get-IXProgressBar -Done $elapsed -Total $duration),$elapsed,$duration,$sequence,$rtt)
            } elseif ($status -eq 'Success') {
                Clear-IXLive
                Write-Host ('[{0}] {1,5} ms  slow reply' -f $stamp.ToString('HH:mm:ss'),$rtt) -ForegroundColor Yellow
            } else {
                Clear-IXLive
                Write-Host ('[{0}] no reply ({1})' -f $stamp.ToString('HH:mm:ss'),$status) -ForegroundColor Yellow
            }
            Start-Sleep -Milliseconds 100
        }
    } finally {
        $pinger.Dispose()
        Clear-IXLive
    }

    $sent = $rows.Count
    $received = @($rows | Where-Object { $_.Status -eq 'Success' }).Count
    $lost = $sent - $received
    $lossPct = if ($sent -gt 0) { [math]::Round(($lost / [double]$sent) * 100,1) } else { 0 }
    $min = $null; $avg = $null; $max = $null; $median = $null; $p95 = $null; $jitter = $null; $spikes = 0
    if ($received -gt 0) {
        $stats = $rtts | Measure-Object -Minimum -Average -Maximum
        $min = [math]::Round([double]$stats.Minimum,1)
        $avg = [math]::Round([double]$stats.Average,1)
        $max = [math]::Round([double]$stats.Maximum,1)
        $sorted = @($rtts | Sort-Object)
        $mid = [int][math]::Floor(($sorted.Count - 1) / 2)
        if (($sorted.Count % 2) -eq 1) { $median = [double]$sorted[$mid] }
        else { $median = ([double]$sorted[$mid] + [double]$sorted[$mid + 1]) / 2.0 }
        $p95Index = [int][math]::Ceiling(0.95 * $sorted.Count) - 1
        if ($p95Index -lt 0) { $p95Index = 0 }
        if ($p95Index -ge $sorted.Count) { $p95Index = $sorted.Count - 1 }
        $p95 = [math]::Round([double]$sorted[$p95Index],1)
        $diffs = New-Object 'System.Collections.Generic.List[double]'
        for ($i=1; $i -lt $rows.Count; $i++) {
            if ($rows[$i].Status -eq 'Success' -and $rows[$i-1].Status -eq 'Success' -and
                [int]$rows[$i].Sequence -eq ([int]$rows[$i-1].Sequence + 1)) {
                [void]$diffs.Add([math]::Abs([double]$rows[$i].RTTms - [double]$rows[$i-1].RTTms))
            }
        }
        if ($diffs.Count -gt 0) { $jitter = [math]::Round((($diffs | Measure-Object -Average).Average),1) }
        $spikeThreshold = [double]$median + 20.0
        $spikes = @($rtts | Where-Object { $_ -gt $spikeThreshold }).Count
    }

    $verdict = 'Sample complete; compare idle vs gameplay/load tests.'
    if ($received -eq 0) { $verdict = 'INCONCLUSIVE: target gave no ICMP replies; it may block or rate-limit ICMP.' }
    elseif ($lossPct -gt 0) { $verdict = 'Packet loss/timeouts observed. Repeat and compare gateway, external target, and actual game route if known.' }
    elseif ($spikes -gt 0) { $verdict = 'RTT spikes observed relative to this sample median; this alone does not prove FiveM desync.' }
    else { $verdict = 'No loss or >20ms-over-median RTT spikes observed in this sample; game-server issues are not ruled out.' }

    Write-Host ''
    Set-IXLastNetwork -Target $inputTarget -AvgMs $avg -JitterMs $jitter -LossPct $lossPct
    Write-Host '========== INTERNETX LIVE SUMMARY ==========' -ForegroundColor Cyan
    Write-Host ('Target / IPv4 : {0} / {1}' -f $inputTarget,$ip)
    Write-Host ('Duration      : {0}s | probes: {1} | replies: {2} | lost/timeouts: {3} ({4}%)' -f $duration,$sent,$received,$lost,$lossPct)
    Write-Host ('RTT min/avg/max: {0} / {1} / {2} ms' -f $(if ($null -ne $min) {$min} else {'N/A'}),$(if ($null -ne $avg) {$avg} else {'N/A'}),$(if ($null -ne $max) {$max} else {'N/A'}))
    Write-Host ('RTT median / p95: {0} / {1} ms' -f $(if ($null -ne $median) {[math]::Round($median,1)} else {'N/A'}),$(if ($null -ne $p95) {$p95} else {'N/A'}))
    Write-Host ('Mean abs. RTT change: {0} ms | RTT samples > median + 20ms: {1}' -f $(if ($null -ne $jitter) {$jitter} else {'N/A'}),$spikes)
    Write-Host ('Assessment: {0}' -f $verdict) -ForegroundColor $(if ($received -eq 0 -or $lossPct -gt 0) {'Yellow'} elseif ($spikes -gt 0) {'Yellow'} else {'Green'})
    Write-Host 'Reminder: ICMP does not guarantee the same path/priority as FiveM game traffic.' -ForegroundColor DarkGray

    $lines = @(
        'InternetX Live Network Monitor',
        ('Time started: ' + $start.ToString('s')),
        ('Time ended: ' + (Get-Date).ToString('s')),
        ('Target: {0}; ResolvedIPv4: {1}; DurationSeconds: {2}' -f $inputTarget,$ip,$duration),
        ('Sent: {0}; Received: {1}; LostOrTimeout: {2}; LossPct: {3}' -f $sent,$received,$lost,$lossPct),
        ('MinMs: {0}; AvgMs: {1}; MaxMs: {2}; MedianMs: {3}; P95Ms: {4}; MeanAbsRTTChangeMs: {5}; SpikesOverMedianPlus20Ms: {6}' -f $min,$avg,$max,$median,$p95,$jitter,$spikes),
        ('Assessment: ' + $verdict),
        'Interpretation: this is ICMP telemetry, not direct proof of FiveM server tick/sync performance.'
    )
    Save-IXReport -Name 'Live-Monitor' -Lines $lines -Rows ($rows.ToArray())
    Wait-IXReturn
}

function Invoke-IXMultiPathMonitor {
    Show-IXHeader
    Write-IXTitle 'MULTI-PATH LIVE MONITOR'
    Write-Host 'Compares your local gateway with multiple external targets in the same sampling cycle.' -ForegroundColor DarkGray
    Write-Host 'This helps separate local-link symptoms from external-path symptoms; ICMP is not FiveM telemetry.' -ForegroundColor DarkGray

    $targets = New-Object 'System.Collections.Generic.List[object]'
    $gateway = Get-IXIPv4Gateway
    if ($gateway) {
        [void]$targets.Add([pscustomobject]@{ Label='Gateway'; Input=$gateway; IP=$gateway })
    } else {
        Write-Host 'No IPv4 gateway found; local gateway test will be skipped.' -ForegroundColor Yellow
    }

    foreach ($defaultTarget in @('1.1.1.1','8.8.8.8')) {
        if (@($targets | Where-Object { $_.IP -eq $defaultTarget }).Count -eq 0) {
            [void]$targets.Add([pscustomobject]@{ Label=$defaultTarget; Input=$defaultTarget; IP=$defaultTarget })
        }
    }

    $custom = Read-Host 'Optional extra target (game endpoint hostname/IP if known; Enter to skip)'
    if (-not [string]::IsNullOrWhiteSpace($custom)) {
        $customIP = Resolve-IXIPv4 -Target $custom
        if (-not $customIP) {
            Write-Host 'Could not resolve that target to IPv4; skipping it.' -ForegroundColor Yellow
        } elseif (@($targets | Where-Object { $_.IP -eq $customIP }).Count -gt 0) {
            Write-Host 'That IP is already in the test list; duplicate skipped.' -ForegroundColor DarkGray
        } else {
            [void]$targets.Add([pscustomobject]@{ Label=$custom; Input=$custom; IP=$customIP })
        }
    }

    $durationText = Read-Host 'Duration in seconds [30/60/180/300] (Enter = 60)'
    $duration = 60
    if (-not [string]::IsNullOrWhiteSpace($durationText)) {
        $parsedDuration = 0
        if ([int]::TryParse($durationText,[ref]$parsedDuration) -and @(30,60,180,300) -contains $parsedDuration) {
            $duration = $parsedDuration
        } else {
            Write-Host 'Invalid duration; using 60 seconds.' -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host 'Targets:' -ForegroundColor Cyan
    $targets | Select-Object Label,IP | Format-Table -AutoSize
    Write-Host ('Monitoring for {0}s; probes to all targets start together about once per second.' -f $duration) -ForegroundColor Cyan
    Write-Host 'Tip: run once idle, then repeat while playing FiveM / during the symptom. Do not run a network speed test on a shared connection unless permitted.' -ForegroundColor DarkGray
    Write-Host ''

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $start = Get-Date
    $end = $start.AddSeconds($duration)
    $cycle = 0
    while ((Get-Date) -lt $end) {
        $cycle++
        $cycleWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $launchTime = Get-Date
        $pending = New-Object 'System.Collections.Generic.List[object]'

        foreach ($target in $targets) {
            $pinger = $null
            try {
                $pinger = New-Object System.Net.NetworkInformation.Ping
                $task = $pinger.SendPingAsync([string]$target.IP,800)
                [void]$pending.Add([pscustomobject]@{ Target=$target; Pinger=$pinger; Task=$task })
            } catch {
                if ($pinger) { $pinger.Dispose() }
                [void]$rows.Add([pscustomobject]@{ Timestamp=$launchTime.ToString('yyyy-MM-dd HH:mm:ss.fff'); Cycle=$cycle; Label=$target.Label; Target=$target.Input; IPv4=$target.IP; Status='Error'; RTTms=$null })
            }
        }

        foreach ($item in $pending) {
            $status = 'Error'
            $rtt = $null
            try {
                $completed = $item.Task.Wait(1500)
                if ($completed) {
                    $reply = $item.Task.Result
                    $status = [string]$reply.Status
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $rtt = [double]$reply.RoundtripTime
                        Write-Host ('[{0}] {1,-14} {2,5} ms' -f $launchTime.ToString('HH:mm:ss'),$item.Target.Label,$rtt) -ForegroundColor $(if ($rtt -ge 100) { 'Yellow' } else { 'Gray' })
                    } else {
                        Write-Host ('[{0}] {1,-14} {2}' -f $launchTime.ToString('HH:mm:ss'),$item.Target.Label,$status) -ForegroundColor Yellow
                    }
                } else {
                    $status = 'Timeout'
                    Write-Host ('[{0}] {1,-14} Timeout' -f $launchTime.ToString('HH:mm:ss'),$item.Target.Label) -ForegroundColor Yellow
                }
            } catch {
                $status = 'Error'
            } finally {
                try { $item.Pinger.Dispose() } catch { }
            }
            [void]$rows.Add([pscustomobject]@{ Timestamp=$launchTime.ToString('yyyy-MM-dd HH:mm:ss.fff'); Cycle=$cycle; Label=$item.Target.Label; Target=$item.Target.Input; IPv4=$item.Target.IP; Status=$status; RTTms=$rtt })
        }

        $cycleWatch.Stop()
        $remaining = 1000 - [int]$cycleWatch.ElapsedMilliseconds
        if ($remaining -gt 0 -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds $remaining }
    }

    Write-Host ''
    Write-Host '============== MULTI-PATH SUMMARY ==============' -ForegroundColor Cyan
    $summaryRows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in $targets) {
        $targetRows = @($rows | Where-Object { $_.IPv4 -eq $target.IP })
        $successRows = @($targetRows | Where-Object { $_.Status -eq 'Success' -and $null -ne $_.RTTms })
        $rtts = @($successRows | ForEach-Object { [double]$_.RTTms })
        $sent = $targetRows.Count
        $received = $successRows.Count
        $failed = $sent - $received
        $failurePct = if ($sent -gt 0) { [math]::Round(100.0 * $failed / $sent,1) } else { 0.0 }
        $min = $null; $avg = $null; $max = $null; $median = $null; $p95 = $null; $jitter = $null; $spikes = 0; $goodPairs = 0
        if ($received -gt 0) {
            $stats = $rtts | Measure-Object -Minimum -Average -Maximum
            $min = [math]::Round([double]$stats.Minimum,1)
            $avg = [math]::Round([double]$stats.Average,1)
            $max = [math]::Round([double]$stats.Maximum,1)
            $sorted = @($rtts | Sort-Object)
            $mid = [int][math]::Floor(($sorted.Count - 1) / 2)
            if (($sorted.Count % 2) -eq 1) { $median = [double]$sorted[$mid] }
            else { $median = ([double]$sorted[$mid] + [double]$sorted[$mid+1]) / 2.0 }
            $p95Index = [int][math]::Ceiling(0.95 * $sorted.Count) - 1
            $p95Index = [math]::Max(0,[math]::Min($p95Index,$sorted.Count-1))
            $p95 = [math]::Round([double]$sorted[$p95Index],1)
            $targetOrdered = @($targetRows | Sort-Object Cycle)
            $diffs = New-Object 'System.Collections.Generic.List[double]'
            for ($i=1; $i -lt $targetOrdered.Count; $i++) {
                if ($targetOrdered[$i].Status -eq 'Success' -and $targetOrdered[$i-1].Status -eq 'Success' -and
                    [int]$targetOrdered[$i].Cycle -eq ([int]$targetOrdered[$i-1].Cycle + 1)) {
                    [void]$diffs.Add([math]::Abs([double]$targetOrdered[$i].RTTms - [double]$targetOrdered[$i-1].RTTms))
                }
            }
            $goodPairs = $diffs.Count
            if ($goodPairs -gt 0) { $jitter = [math]::Round((($diffs | Measure-Object -Average).Average),1) }
            $spikes = @($rtts | Where-Object { $_ -gt ($median + 20.0) }).Count
        }
        $summary = [pscustomobject]@{
            Label=$target.Label; IPv4=$target.IP; Probes=$sent; Replies=$received; Failures=$failed; FailurePct=$failurePct
            MinMs=$min; AvgMs=$avg; MaxMs=$max; MedianMs=$(if ($null -ne $median) {[math]::Round($median,1)} else {$null})
            P95Ms=$p95; MeanAbsJitterMs=$jitter; ConsecutivePairs=$goodPairs; SpikesOverMedianPlus20ms=$spikes
        }
        [void]$summaryRows.Add($summary)
    }
    $summaryRows | Format-Table Label,Probes,Replies,FailurePct,MinMs,AvgMs,MaxMs,MedianMs,P95Ms,MeanAbsJitterMs,SpikesOverMedianPlus20ms -AutoSize -Wrap

    $gatewaySummary = @($summaryRows | Where-Object { $_.Label -eq 'Gateway' } | Select-Object -First 1)
    $externalSummaries = @($summaryRows | Where-Object { $_.Label -ne 'Gateway' })
    Write-Host ''
    Write-Host 'Interpretation (heuristic, not a definitive diagnosis):' -ForegroundColor Cyan
    if ($gatewaySummary.Count -gt 0 -and ($gatewaySummary[0].FailurePct -ge 5 -or ($null -ne $gatewaySummary[0].MeanAbsJitterMs -and $gatewaySummary[0].MeanAbsJitterMs -ge 5))) {
        Write-Host 'Gateway probes show failures or variation. Check Ethernet/Wi-Fi, router load, cable, and adapter driver first.' -ForegroundColor Yellow
    } elseif (@($externalSummaries | Where-Object { $_.FailurePct -ge 5 -or ($null -ne $_.MeanAbsJitterMs -and $_.MeanAbsJitterMs -ge 15) -or ($null -ne $_.P95Ms -and $null -ne $_.AvgMs -and ($_.P95Ms - $_.AvgMs) -ge 25) }).Count -gt 0) {
        Write-Host 'External targets show failures or spikes while gateway is comparatively stable. Compare a different target and test the actual game route if possible.' -ForegroundColor Yellow
    } else {
        Write-Host 'No strong issue was detected in this ICMP sample. This does not rule out FiveM routing, server sync, ICMP filtering, or client FPS problems.' -ForegroundColor Green
    }
    Write-Host 'A public host may rate-limit or block ICMP; failures here are not proof of equivalent loss in FiveM traffic.' -ForegroundColor DarkGray

    $lines = @(
        'InternetX v2.4 Multi-Path Monitor',
        ('Started: ' + $start.ToString('s')),
        ('Ended: ' + (Get-Date).ToString('s')),
        ('DurationSeconds: ' + $duration),
        'Metric note: FailurePct counts all non-success ICMP statuses/timeouts, not confirmed application packet loss.',
        'RTT jitter is mean absolute RTT difference for consecutive successful samples only.',
        'Public-host ICMP does not prove FiveM route latency or entity synchronization.'
    )
    foreach ($summary in $summaryRows) {
        $lines += ('Target={0}; IPv4={1}; Probes={2}; Replies={3}; Failures={4}; FailurePct={5}; MinMs={6}; AvgMs={7}; MaxMs={8}; MedianMs={9}; P95Ms={10}; MeanAbsJitterMs={11}; ConsecutivePairs={12}; SpikesOverMedianPlus20ms={13}' -f $summary.Label,$summary.IPv4,$summary.Probes,$summary.Replies,$summary.Failures,$summary.FailurePct,$summary.MinMs,$summary.AvgMs,$summary.MaxMs,$summary.MedianMs,$summary.P95Ms,$summary.MeanAbsJitterMs,$summary.ConsecutivePairs,$summary.SpikesOverMedianPlus20ms)
    }
    Save-IXReport -Name 'Multi-Path-Monitor' -Lines $lines -Rows ($rows.ToArray())
    Wait-IXReturn
}

function Invoke-IXLatencyTest {
    Show-IXHeader
    Write-IXTitle 'PING / JITTER / PACKET LOSS'
    Write-IXMenuItem -Key '1' -Text 'Quick summary (gateway + public targets)' -Hint 'about 10 seconds'
    Write-IXMenuItem -Key '2' -Text 'Single-target live monitor' -Hint '30-300 seconds'
    Write-IXMenuItem -Key '3' -Text 'Multi-path live monitor (gateway + two targets)' -Hint '30-300 seconds'
    Write-IXMenuItem -Key '4' -Text 'Before / after comparison (ping, jitter, loss, DNS)' -Hint 'same targets twice'
    Write-IXRule -Thin
    $mode = Read-IXChoice 'Choose 1-4 (Enter = 1, anything else = back)'
    if ($mode -eq '2') { Invoke-IXLiveMonitor; return }
    if ($mode -eq '3') { Invoke-IXMultiPathMonitor; return }
    if ($mode -eq '4') { Invoke-IXBeforeAfter; return }
    if ($mode -ne '' -and $mode -ne '1') {
        Write-IXErr 'Invalid choice. Enter 1, 2, 3, or 4.'
        Start-Sleep -Seconds 1
        return
    }
    Write-Host 'Quick mode tests each target with 15 probes. For longer monitoring, choose option 2.' -ForegroundColor DarkGray
    Write-Host 'Public-host tests are not the same as the actual FiveM server route.' -ForegroundColor DarkGray
    $tests = New-Object 'System.Collections.Generic.List[object]'
    $gw = Get-IXIPv4Gateway
    if ($gw) {
        Write-Host ("Testing local gateway {0}..." -f $gw) -ForegroundColor Cyan
        [void]$tests.Add((Invoke-IXPingSummary -Target $gw))
    } else { Write-Host 'No IPv4 default gateway found; gateway test skipped.' -ForegroundColor Yellow }
    foreach ($hostName in @('1.1.1.1','8.8.8.8')) {
        Write-Host ("Testing {0}..." -f $hostName) -ForegroundColor Cyan
        [void]$tests.Add((Invoke-IXPingSummary -Target $hostName))
    }
    $extra = Read-Host 'Optional additional hostname/IP (Enter to skip; use the game endpoint if known)'
    if (-not [string]::IsNullOrWhiteSpace($extra)) {
        Write-Host ("Testing {0}..." -f $extra) -ForegroundColor Cyan
        [void]$tests.Add((Invoke-IXPingSummary -Target $extra))
    }
    Write-Host ''
    Write-Host 'SUMMARY (milliseconds; values depend on destination)' -ForegroundColor Cyan
    $tests | Select-Object Target,Resolved,Sent,Received,LossPct,MinMs,AvgMs,MaxMs,JitterMs,Result | Format-Table -AutoSize -Wrap
    $dashboardRow = @($tests | Where-Object { $_.Resolved -ne 'N/A' -and (-not $gw -or $_.Resolved -ne $gw) } | Select-Object -First 1)
    if ($dashboardRow.Count -gt 0) { Set-IXLastNetwork -Target $dashboardRow[0].Target -AvgMs $dashboardRow[0].AvgMs -JitterMs $dashboardRow[0].JitterMs -LossPct $dashboardRow[0].LossPct }

    # Heuristic triage for rubberbanding / position-sync symptoms; not a definitive diagnosis.
    $gatewayResult = $null
    if ($gw) { $gatewayResult = @($tests | Where-Object { $_.Resolved -eq $gw } | Select-Object -First 1) }
    $externalResults = @($tests | Where-Object { -not $gw -or $_.Resolved -ne $gw })
    Write-Host ''
    Write-Host 'FIVEM RUBBERBANDING TRIAGE (heuristic)' -ForegroundColor Cyan
    if ($gatewayResult -and $gatewayResult.Count -gt 0 -and ($gatewayResult[0].LossPct -gt 0 -or ($null -ne $gatewayResult[0].JitterMs -and $gatewayResult[0].JitterMs -ge 5))) {
        $triage = 'Local link / Wi-Fi / router queue may be contributing. Compare wired LAN and test while the connection is idle.'
        Write-Host $triage -ForegroundColor Yellow
    } elseif (@($externalResults | Where-Object { $_.LossPct -ge 5 -or ($null -ne $_.JitterMs -and $_.JitterMs -ge 15) }).Count -gt 0) {
        $triage = 'External-path variation was observed. ISP routing, congestion, ICMP filtering/rate limiting, or destination behavior may be involved.'
        Write-Host $triage -ForegroundColor Yellow
    } else {
        $triage = 'No clear issue was detected in these ICMP samples. This does not rule out the actual FiveM route, server synchronization, or client FPS timing.'
        Write-Host $triage -ForegroundColor Green
    }

    # Compare with the previous saved ping report when one exists. Different test conditions limit conclusions.
    $previousCsv = Get-ChildItem -LiteralPath $script:IXReportDir -Filter 'Ping-Jitter-Loss_*.csv' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($previousCsv) {
        try {
            $previousRows = @(Import-Csv -LiteralPath $previousCsv.FullName -ErrorAction Stop)
            Write-Host ''
            Write-Host 'CHANGE VS PREVIOUS SAVED TEST (informational only)' -ForegroundColor Cyan
            foreach ($t in $tests) {
                $old = $previousRows | Where-Object { $_.Resolved -eq $t.Resolved } | Select-Object -First 1
                if ($old -and $null -ne $t.AvgMs -and $old.AvgMs -match '^\d+(\.\d+)?$') {
                    $avgDelta = [math]::Round(([double]$t.AvgMs - [double]$old.AvgMs),1)
                    $lossDelta = [math]::Round(([double]$t.LossPct - [double]$old.LossPct),1)
                    $jitterDelta = 'N/A'
                    if ($null -ne $t.JitterMs -and $old.JitterMs -match '^\d+(\.\d+)?$') { $jitterDelta = [string][math]::Round(([double]$t.JitterMs - [double]$old.JitterMs),1) }
                    Write-Host ('{0}: Avg ping delta {1} ms | loss delta {2} pp | jitter delta {3} ms' -f $t.Target,$avgDelta,$lossDelta,$jitterDelta) -ForegroundColor Gray
                }
            }
            Write-Host ('Compared with: {0}; test conditions may differ.' -f $previousCsv.Name) -ForegroundColor DarkGray
        } catch { Write-Host 'Previous report could not be compared.' -ForegroundColor DarkYellow }
    } else {
        Write-Host 'No earlier report exists yet; this run becomes the baseline.' -ForegroundColor DarkGray
    }

    $lines = @('InternetX Ping / Jitter / Packet Loss Report',('Time: ' + (Get-Date -Format 's')),'Jitter = mean absolute difference between consecutive successful RTT samples.','ICMP measurements do not prove latency to FiveM server.',('Triage: ' + $triage))
    foreach ($t in $tests) { $lines += ('Target={0}; Resolved={1}; Sent={2}; Received={3}; Lost={4}; LossPct={5}; MinMs={6}; AvgMs={7}; MaxMs={8}; JitterMs={9}; Result={10}' -f $t.Target,$t.Resolved,$t.Sent,$t.Received,$t.Lost,$t.LossPct,$t.MinMs,$t.AvgMs,$t.MaxMs,$t.JitterMs,$t.Result) }
    Save-IXReport -Name 'Ping-Jitter-Loss' -Lines $lines -Rows ($tests.ToArray())
    Write-Host 'Tip: compare gateway vs external results, then repeat with downloads/uploads stopped and during FiveM.' -ForegroundColor DarkGray
    Wait-IXReturn
}

function Test-IXDFPayload {
    param([string]$Target,[int]$PayloadBytes,[int]$Attempts=3,[int]$TimeoutMs=1000)
    $pass = 0; $tooBig = 0; $other = 0; $details = @()
    $pingExe = Join-Path $env:SystemRoot 'System32\ping.exe'
    for ($i=0; $i -lt $Attempts; $i++) {
        $raw = @(& $pingExe -4 -n 1 -w $TimeoutMs -f -l $PayloadBytes $Target 2>&1)
        $exitCode = $LASTEXITCODE
        $message = ($raw | ForEach-Object { [string]$_ }) -join ' '
        if ($message) { $details += $message }
        $fragmentRegex = '(?i)(fragment|packet.{0,20}(too large|large|fragment)|needs to be fragmented|must be fragmented|datagram.{0,20}large|分片|分割|分段|需要分片|需要分段|需要分割|แบ่งส่วน|แยกส่วน)'
        if ($message -match $fragmentRegex) { $tooBig++ }
        elseif ($exitCode -eq 0) { $pass++ }
        else { $other++ }
    }
    $state = 'INCONCLUSIVE'
    if ($pass -eq $Attempts) { $state = 'PASS' }
    elseif ($tooBig -eq $Attempts) { $state = 'TOO_BIG_CONFIRMED' }
    elseif ($pass -gt 0 -or $tooBig -gt 0) { $state = 'INCONSISTENT' }
    $detail = ''; if ($details.Count -gt 0) { $detail = $details[0]; if ($detail.Length -gt 240) { $detail = $detail.Substring(0,240) } }
    return [pscustomobject]@{ Target=$Target; PayloadBytes=$PayloadBytes; IPv4PacketBytes=($PayloadBytes+28); Attempts=$Attempts; Replies=$pass; TooBig=$tooBig; OtherFailures=$other; Result=$state; Detail=$detail }
}

function Invoke-IXMtuTest {
    Show-IXHeader
    Write-IXTitle 'PATH MTU TEST (diagnostic only; no settings changed)'
    Write-Host 'Timeouts are inconclusive, not proof that the packet is too large.' -ForegroundColor DarkGray
    $inputTarget = Read-Host 'Target IPv4 host/IP (Enter = 1.1.1.1)'
    if ([string]::IsNullOrWhiteSpace($inputTarget)) { $inputTarget = '1.1.1.1' }
    $target = Resolve-IXIPv4 -Target $inputTarget
    if (-not $target) { Write-Host 'Could not resolve a valid IPv4 target.' -ForegroundColor Red; Wait-IXReturn; return }
    Write-Host ("Target: {0} ({1})" -f $inputTarget,$target) -ForegroundColor Cyan
    Write-Host 'Checking small-packet reachability...' -ForegroundColor Yellow
    $baseline = Test-IXDFPayload -Target $target -PayloadBytes 32 -Attempts 3 -TimeoutMs 1200
    Write-Host ("Small probe: {0}/3 replies; {1}" -f $baseline.Replies,$baseline.Result) -ForegroundColor $(if ($baseline.Result -eq 'PASS') { 'Green' } else { 'Yellow' })
    $rows = New-Object 'System.Collections.Generic.List[object]'
    [void]$rows.Add($baseline)
    $largestPass = $null; $firstTooBig = $null; $conclusive = ($baseline.Result -eq 'PASS'); $reason = ''
    if (-not $conclusive) {
        $reason = 'The target did not reliably answer small ICMP probes. ICMP filtering, loss, or target restrictions can prevent MTU estimation.'
    } else {
        $samples = @(548,900,1100,1200,1280,1360,1400,1420,1440,1452,1464,1472)
        foreach ($sz in $samples) {
            Write-Host ("Probe payload {0} bytes..." -f $sz) -ForegroundColor DarkCyan
            $r = Test-IXDFPayload -Target $target -PayloadBytes $sz -Attempts 3 -TimeoutMs 1200
            [void]$rows.Add($r)
            Write-Host ("  Reply {0}/3 | Too-big {1}/3 | {2}" -f $r.Replies,$r.TooBig,$r.Result) -ForegroundColor $(if ($r.Result -eq 'PASS') { 'Green' } elseif ($r.Result -eq 'TOO_BIG_CONFIRMED') { 'Yellow' } else { 'DarkYellow' })
            if ($r.Result -eq 'PASS') { $largestPass = $sz; continue }
            if ($r.Result -eq 'TOO_BIG_CONFIRMED') { $firstTooBig = $sz; break }
            $conclusive = $false; $reason = ('Probe at {0} bytes was inconclusive; its timeout/error is not proof of an MTU boundary.' -f $sz); break
        }
        if ($conclusive -and $largestPass -eq 1472 -and $null -eq $firstTooBig) {
            $reason = 'A 1500-byte IPv4 packet passed. Exact maximum not established because the test ceiling is 1500 bytes.'
        } elseif ($conclusive -and $null -ne $largestPass -and $null -ne $firstTooBig) {
            while (($firstTooBig - $largestPass) -gt 1) {
                $mid = [int][math]::Floor(($firstTooBig + $largestPass)/2.0)
                Write-Host ("Narrowing boundary: payload {0} bytes..." -f $mid) -ForegroundColor DarkCyan
                $r = Test-IXDFPayload -Target $target -PayloadBytes $mid -Attempts 3 -TimeoutMs 1200
                [void]$rows.Add($r)
                Write-Host ("  {0}" -f $r.Result) -ForegroundColor $(if ($r.Result -eq 'PASS') { 'Green' } elseif ($r.Result -eq 'TOO_BIG_CONFIRMED') { 'Yellow' } else { 'DarkYellow' })
                if ($r.Result -eq 'PASS') { $largestPass = $mid }
                elseif ($r.Result -eq 'TOO_BIG_CONFIRMED') { $firstTooBig = $mid }
                else { $conclusive = $false; $reason = 'Boundary probe had inconsistent results; exact MTU not confirmed.'; break }
            }
            if ($conclusive -and (($firstTooBig - $largestPass) -eq 1)) {
                $lowVerify = Test-IXDFPayload -Target $target -PayloadBytes $largestPass -Attempts 3 -TimeoutMs 1200
                $highVerify = Test-IXDFPayload -Target $target -PayloadBytes $firstTooBig -Attempts 3 -TimeoutMs 1200
                [void]$rows.Add($lowVerify); [void]$rows.Add($highVerify)
                if ($lowVerify.Result -ne 'PASS' -or $highVerify.Result -ne 'TOO_BIG_CONFIRMED') {
                    $conclusive = $false; $reason = 'Final boundary verification was not consistent; report the candidate as provisional.'
                }
            }
        } elseif ($conclusive -and $null -eq $largestPass) {
            $conclusive = $false; $reason = 'No stable passing payload and explicit too-big boundary were established.'
        }
    }
    Write-Host ''
    Write-Host '================ MTU SUMMARY ================' -ForegroundColor Cyan
    Write-Host ('Target: {0}' -f $target)
    if ($conclusive -and $largestPass -eq 1472 -and $null -eq $firstTooBig) {
        Write-Host 'Result: supports at least MTU 1500 bytes to this test target; exact upper limit unknown.' -ForegroundColor Green
        Write-Host 'Reported lower bound: 1500 bytes' -ForegroundColor Green
        Write-Host 'Confidence: HIGH that 1500-byte IPv4 packets passed in this test, not an exact maximum.' -ForegroundColor Green
    } elseif ($conclusive -and $null -ne $largestPass -and $null -ne $firstTooBig) {
        $candidateMtu = $largestPass + 28
        if ($firstTooBig - $largestPass -eq 1) {
            Write-Host ("Estimated path MTU: {0} bytes (candidate; payload boundary confirmed twice)" -f $candidateMtu) -ForegroundColor Green
            Write-Host 'Confidence: HIGH for this ICMP path test; server route may differ.' -ForegroundColor Green
        } else {
            Write-Host ("Largest stable passing packet size: {0} bytes (MTU lower bound)" -f $candidateMtu) -ForegroundColor Yellow
            Write-Host 'Confidence: LOW / PROVISIONAL' -ForegroundColor Yellow
        }
    } else {
        Write-Host 'Result: INCONCLUSIVE. Do not change MTU based on this run.' -ForegroundColor Yellow
        Write-Host ('Reason: {0}' -f $reason) -ForegroundColor Yellow
    }
    Write-Host 'IPv4 packet size = ICMP payload + 28 bytes of IPv4/ICMP headers.' -ForegroundColor DarkGray
    Write-Host 'This tests the selected endpoint, not necessarily the FiveM server. No settings were changed.' -ForegroundColor DarkGray

    # Recommendation from this run's measurements only; InternetX never sets MTU itself.
    $interfaceMtu = $null
    $primaryAdapter = Get-IXPrimaryAdapter
    if ($primaryAdapter) { $interfaceMtu = Get-IXInterfaceMtu -Adapter $primaryAdapter }
    $recommendation = 'No recommendation: the test was inconclusive, so keep the current MTU.'
    if ($conclusive -and $largestPass -eq 1472 -and $null -eq $firstTooBig) {
        if ($null -ne $interfaceMtu -and $interfaceMtu -gt 1500) { $recommendation = ('1500-byte packets pass. Your interface MTU is {0} (jumbo). Turn off Jumbo Packet (Low Ping Profile) so it returns to the 1500 standard; do not type an MTU by hand.' -f $interfaceMtu) }
        elseif ($null -ne $interfaceMtu -and $interfaceMtu -lt 1500) { $recommendation = ('1500-byte packets pass, but your interface MTU is {0}. Find out what lowered it (VPN, PPPoE, an earlier tweak) before changing it.' -f $interfaceMtu) }
        else { $recommendation = 'Keep MTU 1500. No change recommended.' }
    } elseif ($conclusive -and $null -ne $largestPass -and $null -ne $firstTooBig -and (($firstTooBig - $largestPass) -eq 1)) {
        $measured = $largestPass + 28
        if ($null -ne $interfaceMtu -and $interfaceMtu -gt $measured) { $recommendation = ('Measured path MTU is {0}; your interface MTU is {1}. Windows normally adapts by itself. Consider {0} only if large transfers stall, and re-test first.' -f $measured,$interfaceMtu) }
        else { $recommendation = ('Measured path MTU is {0} and your interface MTU already fits. No change recommended.' -f $measured) }
    }
    if ($null -ne $interfaceMtu) { Write-Host ('Current interface MTU (IPv4): {0}' -f $interfaceMtu) -ForegroundColor Gray }
    Write-Host ('Recommendation: {0}' -f $recommendation) -ForegroundColor Cyan
    $reason = ($reason + ' Recommendation: ' + $recommendation).Trim()
    $lines = @('InternetX Path MTU Report',('Time: ' + (Get-Date -Format 's')),('Target: ' + $target),('Baseline: ' + $baseline.Result),('Conclusive: ' + $conclusive),('Largest pass payload: ' + $largestPass),('First confirmed too-big payload: ' + $firstTooBig),('Summary/limitation: ' + $reason),'IPv4 packet size = payload + 28 bytes. No settings changed.')
    Save-IXReport -Name 'Path-MTU' -Lines $lines -Rows ($rows.ToArray())
    Wait-IXReturn
}

function Get-IXStateEntry {
    param([string]$Key)
    return @($script:IXState.Entries | Where-Object { $_.Key -eq $Key -and $_.Status -in @('Pending','Applied') } | Select-Object -First 1)
}

function Add-IXStateEntry {
    param([object]$Entry)
    $existing = @(Get-IXStateEntry -Key ([string]$Entry.Key))
    if ($existing.Count -gt 0) { return $existing[0] }
    $script:IXState.Entries = @($script:IXState.Entries) + @($Entry)
    Save-IXState
    return $Entry
}

function Set-IXEntryStatus {
    param([object]$Entry,[string]$Status)
    $Entry.Status = $Status
    $Entry.LastUpdated = (Get-Date).ToString('s')
    Save-IXState
}

function Invoke-IXPreview {
    Show-IXHeader
    Write-IXTitle 'OPTIMIZATION PREVIEW (read-only)'
    $adapters = @(Get-IXActiveAdapters)
    if ($adapters.Count -eq 0) { Write-Host 'No active adapters found.' -ForegroundColor Red }
    foreach ($a in $adapters) {
        Write-Host ("`nAdapter: {0} | {1}" -f $a.Name,$a.LinkSpeed) -ForegroundColor Cyan
        try {
            $rss = Get-NetAdapterRss -Name $a.Name -ErrorAction Stop | Select-Object -First 1
            if ($rss.Enabled) { Write-Host '  RSS: already enabled (no change needed)' -ForegroundColor Green }
            else { Write-Host '  RSS: disabled; can be enabled only if driver supports it' -ForegroundColor Yellow }
        } catch { Write-Host '  RSS: not exposed; InternetX will skip it' -ForegroundColor DarkYellow }
        $isWifi = ($a.Name -match 'Wi-?Fi|Wireless|WLAN') -or ($a.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11')
        if ($isWifi) { Write-Host '  EEE: skipped (wireless interface)' -ForegroundColor DarkGray }
        else {
            try {
                $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -AllProperties -ErrorAction Stop | Where-Object { $_.DisplayName -match 'Energy Efficient Ethernet|Green Ethernet|Advanced EEE' })
                if ($props.Count -eq 0) { Write-Host '  EEE: no exposed matching property' -ForegroundColor DarkGray }
                foreach ($p in $props) {
                    $valid = @($p.ValidDisplayValues | ForEach-Object { [string]$_ })
                    if ($valid -contains 'Disabled' -and [string]$p.DisplayValue -ne 'Disabled') { Write-Host ("  EEE option: {0} = {1}; optional disable available" -f $p.DisplayName,$p.DisplayValue) -ForegroundColor Yellow }
                    else { Write-Host ("  EEE option: {0} = {1}; no supported change proposed" -f $p.DisplayName,$p.DisplayValue) -ForegroundColor Gray }
                }
            } catch { Write-Host '  EEE: property query unsupported' -ForegroundColor DarkGray }
        }
    }
    Write-Host ''
    Write-Host 'InternetX intentionally leaves MTU, DNS, registry, Flow Control and TCP congestion algorithms unchanged.' -ForegroundColor DarkGray
    Write-Host 'Reason: no universal value is best for all drivers, routers and ISP routes.' -ForegroundColor DarkGray
    Wait-IXReturn
}

function Invoke-IXApplyRSS {
    Show-IXHeader
    if (-not (Test-IXAdmin)) { Write-Host 'Administrator permission required.' -ForegroundColor Red; Wait-IXReturn; return }
    $adapters = @(Get-IXActiveAdapters)
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($a in $adapters) {
        try {
            $rss = Get-NetAdapterRss -Name $a.Name -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $rss) { continue }
            if (-not [bool]$rss.Enabled) { [void]$candidates.Add([pscustomobject]@{ Name=$a.Name; OriginalEnabled=[bool]$rss.Enabled }) }
            else { Write-Host ("RSS already enabled: {0}" -f $a.Name) -ForegroundColor DarkGray }
        } catch { Write-Host ("Skipped unsupported RSS adapter: {0}" -f $a.Name) -ForegroundColor DarkYellow }
    }
    if ($candidates.Count -eq 0) {
        Write-Host 'No supported active adapter needs RSS changes. Nothing changed.' -ForegroundColor Green
        Wait-IXReturn; return
    }
    Write-Host 'The following adapter(s) will be changed:' -ForegroundColor Yellow
    $candidates | Format-Table Name,OriginalEnabled -AutoSize
    Write-Host 'RSS can improve packet processing on supported adapters, but results vary by driver.' -ForegroundColor DarkGray
    Write-IXSafetyNote
    $confirm = Read-Host 'Type YES to enable RSS on the listed adapters'
    if ($confirm -cne 'YES') { Write-Host 'Cancelled; no changes made.' -ForegroundColor Yellow; Wait-IXReturn; return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $snapshotPath = Join-Path $script:IXBackupDir ('RSS-before-{0}.json' -f $stamp)
    $candidates | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $snapshotPath -Encoding UTF8
    Write-IXLog ('RSS change approval confirmed. Backup snapshot: ' + $snapshotPath)
    foreach ($candidate in $candidates) {
        $key = 'RSS|' + $candidate.Name
        $entry = [pscustomobject]@{ Key=$key; Type='RSS'; AdapterName=$candidate.Name; OriginalEnabled=[bool]$candidate.OriginalEnabled; Status='Pending'; Created=(Get-Date).ToString('s'); LastUpdated=(Get-Date).ToString('s') }
        $entry = Add-IXStateEntry -Entry $entry
        try {
            Set-NetAdapterRss -Name $candidate.Name -Enabled $true -NoRestart -ErrorAction Stop | Out-Null
            Set-IXEntryStatus -Entry $entry -Status 'Applied'
            Write-Host ("RSS enabled: {0}" -f $candidate.Name) -ForegroundColor Green
            Write-IXLog ('RSS enabled: ' + $candidate.Name)
        } catch {
            Set-IXEntryStatus -Entry $entry -Status 'Failed'
            Write-Host ("RSS change failed: {0} | {1}" -f $candidate.Name,$_.Exception.Message) -ForegroundColor Red
            Write-IXLog ('RSS failed: ' + $candidate.Name + ' | ' + $_.Exception.Message)
        }
    }
    Write-Host 'Only RSS was changed. No MTU or TCP registry settings were modified.' -ForegroundColor DarkGray
    Wait-IXReturn
}

function Invoke-IXDisableEEE {
    Show-IXHeader
    if (-not (Test-IXAdmin)) { Write-Host 'Administrator permission required.' -ForegroundColor Red; Wait-IXReturn; return }
    $changes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($a in @(Get-IXActiveAdapters)) {
        $isWifi = ($a.Name -match 'Wi-?Fi|Wireless|WLAN') -or ($a.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11')
        if ($isWifi) { continue }
        try {
            $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -AllProperties -ErrorAction Stop | Where-Object { $_.DisplayName -match 'Energy Efficient Ethernet|Green Ethernet|Advanced EEE' })
            foreach ($p in $props) {
                $valid = @($p.ValidDisplayValues | ForEach-Object { [string]$_ })
                if (($valid -contains 'Disabled') -and ([string]$p.DisplayValue -ne 'Disabled')) {
                    [void]$changes.Add([pscustomobject]@{ AdapterName=$a.Name; DisplayName=[string]$p.DisplayName; RegistryKeyword=[string]$p.RegistryKeyword; OriginalDisplayValue=[string]$p.DisplayValue })
                }
            }
        } catch { }
    }
    if ($changes.Count -eq 0) { Write-Host 'No supported wired EEE/Green Ethernet property needs changing.' -ForegroundColor Green; Wait-IXReturn; return }
    Write-Host 'Optional power-saving setting changes detected:' -ForegroundColor Yellow
    $changes | Format-Table AdapterName,DisplayName,OriginalDisplayValue -AutoSize -Wrap
    Write-Host 'Disabling EEE may raise power use and may not improve every connection. Rollback is recorded.' -ForegroundColor DarkGray
    Write-IXSafetyNote
    $confirm = Read-Host 'Type YES to disable the listed wired EEE properties'
    if ($confirm -cne 'YES') { Write-Host 'Cancelled; no changes made.' -ForegroundColor Yellow; Wait-IXReturn; return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $snapshotPath = Join-Path $script:IXBackupDir ('EEE-before-{0}.json' -f $stamp)
    $changes | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $snapshotPath -Encoding UTF8
    foreach ($change in $changes) {
        $key = 'PROP|' + $change.AdapterName + '|' + $change.RegistryKeyword
        $entry = [pscustomobject]@{ Key=$key; Type='AdapterProperty'; AdapterName=$change.AdapterName; DisplayName=$change.DisplayName; RegistryKeyword=$change.RegistryKeyword; OriginalDisplayValue=$change.OriginalDisplayValue; Status='Pending'; Created=(Get-Date).ToString('s'); LastUpdated=(Get-Date).ToString('s') }
        $entry = Add-IXStateEntry -Entry $entry
        try {
            Set-NetAdapterAdvancedProperty -Name $change.AdapterName -DisplayName $change.DisplayName -DisplayValue 'Disabled' -NoRestart -ErrorAction Stop
            Set-IXEntryStatus -Entry $entry -Status 'Applied'
            Write-Host ("Disabled: {0} / {1}" -f $change.AdapterName,$change.DisplayName) -ForegroundColor Green
            Write-IXLog ('EEE disabled: ' + $change.AdapterName + ' / ' + $change.DisplayName)
        } catch {
            Set-IXEntryStatus -Entry $entry -Status 'Failed'
            Write-Host ("Failed: {0} / {1} | {2}" -f $change.AdapterName,$change.DisplayName,$_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Host 'Some drivers require adapter restart/reboot before the setting takes effect.' -ForegroundColor Yellow
    Wait-IXReturn
}

function Invoke-IXRestore {
    Show-IXHeader
    if (-not (Test-IXAdmin)) { Write-Host 'Administrator permission required.' -ForegroundColor Red; Wait-IXReturn; return }
    Load-IXState
    $entries = @($script:IXState.Entries | Where-Object { $_.Status -in @('Applied','Pending') })
    if ($entries.Count -eq 0) { Write-Host 'No active InternetX changes are recorded.' -ForegroundColor Green; Wait-IXReturn; return }
    Write-Host 'InternetX will restore only settings recorded in its own state file:' -ForegroundColor Yellow
    $entries | Select-Object Type,AdapterName,Status | Format-Table -AutoSize
    $confirm = Read-Host 'Type RESTORE to continue'
    if ($confirm -cne 'RESTORE') { Write-Host 'Cancelled; no changes made.' -ForegroundColor Yellow; Wait-IXReturn; return }
    foreach ($entry in $entries) {
        $adapter = Get-NetAdapter -Name $entry.AdapterName -ErrorAction SilentlyContinue
        if (-not $adapter) { Write-Host ("Adapter missing; cannot restore: {0}" -f $entry.AdapterName) -ForegroundColor Yellow; continue }
        try {
            if ([string]$entry.Type -eq 'RSS') {
                Set-NetAdapterRss -Name $entry.AdapterName -Enabled ([bool]$entry.OriginalEnabled) -NoRestart -ErrorAction Stop | Out-Null
            } elseif ([string]$entry.Type -eq 'AdapterProperty') {
                $hasRegistryValue = ($entry.PSObject.Properties['OriginalRegistryValue'] -and -not [string]::IsNullOrWhiteSpace([string]$entry.OriginalRegistryValue) -and -not [string]::IsNullOrWhiteSpace([string]$entry.RegistryKeyword))
                if ($hasRegistryValue) {
                    Set-NetAdapterAdvancedProperty -Name $entry.AdapterName -RegistryKeyword $entry.RegistryKeyword -RegistryValue ([string]$entry.OriginalRegistryValue) -NoRestart -ErrorAction Stop
                } else {
                    Set-NetAdapterAdvancedProperty -Name $entry.AdapterName -DisplayName $entry.DisplayName -DisplayValue ([string]$entry.OriginalDisplayValue) -NoRestart -ErrorAction Stop
                }
            } else { continue }
            $label = if ([string]$entry.Type -eq 'RSS') { 'RSS' } else { [string]$entry.DisplayName }
            if (Test-IXEntryRestored -Entry $entry) {
                Set-IXEntryStatus -Entry $entry -Status 'Restored'
                Write-Host ("Restored + VERIFIED: {0} / {1}" -f $entry.AdapterName,$label) -ForegroundColor Green
                Write-IXLog ('Restored and verified: ' + $entry.AdapterName + ' / ' + $label)
            } else {
                # Left as active so Restore can be tried again.
                Write-Host ("Restore sent but NOT VERIFIED: {0} / {1}. Restart the adapter, then run Restore again." -f $entry.AdapterName,$label) -ForegroundColor Yellow
                Write-IXLog ('Restore not verified: ' + $entry.AdapterName + ' / ' + $label)
            }
        } catch {
            Write-Host ("Restore failed: {0} | {1}" -f $entry.AdapterName,$_.Exception.Message) -ForegroundColor Red
            Write-IXLog ('Restore failed: ' + $entry.AdapterName + ' | ' + $_.Exception.Message)
        }
    }
    Write-Host 'Rollback attempted only for settings tracked by InternetX; some drivers may require reboot.' -ForegroundColor DarkGray
    Wait-IXReturn
}

function Invoke-IXHitRegMonitor {
    Show-IXHeader
    Write-IXTitle 'HITREG / RUBBERBAND SYMPTOM MONITOR' -Advanced
    Write-Host 'This records user-marked symptom times and network ICMP samples; it cannot read authoritative hit registration.' -ForegroundColor DarkGray
    Write-Host 'Press H when you notice the symptom, Q to stop. It does not modify network settings.' -ForegroundColor DarkGray

    $targets = New-Object 'System.Collections.Generic.List[object]'
    $gateway = Get-IXIPv4Gateway
    if ($gateway) { [void]$targets.Add([pscustomobject]@{ Label='Gateway'; Input=$gateway; IP=$gateway }) }
    foreach ($ip in @('1.1.1.1','8.8.8.8')) {
        if (@($targets | Where-Object { $_.IP -eq $ip }).Count -eq 0) {
            [void]$targets.Add([pscustomobject]@{ Label=$ip; Input=$ip; IP=$ip })
        }
    }
    $extra = Read-Host 'Optional FiveM endpoint hostname/IP (Enter to skip; many endpoints do not respond to ping)'
    if (-not [string]::IsNullOrWhiteSpace($extra)) {
        $extraIP = Resolve-IXIPv4 -Target $extra
        if ($extraIP -and @($targets | Where-Object { $_.IP -eq $extraIP }).Count -eq 0) {
            [void]$targets.Add([pscustomobject]@{ Label=$extra; Input=$extra; IP=$extraIP })
        } else {
            Write-Host 'Target could not be resolved or is already listed; skipped.' -ForegroundColor Yellow
        }
    }
    $durationText = Read-Host 'Duration [60/180/300] seconds (Enter = 180)'
    $duration = 180
    if ($durationText -in @('60','180','300')) { $duration = [int]$durationText }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $markers = New-Object 'System.Collections.Generic.List[object]'
    $latest = @{}
    $sampleIndex = @{}
    $start = Get-Date
    $end = $start.AddSeconds($duration)
    $stopRequested = $false
    $keySupportWarned = $false
    Write-Host ''
    $targets | Select-Object Label,IP | Format-Table -AutoSize
    Write-Host ('Monitoring for {0}s. Keep FiveM open. Press H to mark a symptom, Q to stop.' -f $duration) -ForegroundColor Green
    Write-Host ''

    while ((Get-Date) -lt $end -and -not $stopRequested) {
        try {
            while ($Host.UI.RawUI.KeyAvailable) {
                $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                $char = [string]$keyInfo.Character
                if ($char -match '^[hH]$') {
                    $marker = [pscustomobject]@{
                        Timestamp=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                        Event='UserMarkedHitRegOrRubberband'
                        LatestGatewayRTTms=$latest['Gateway']
                        LatestCloudflareRTTms=$latest['1.1.1.1']
                        LatestGoogleRTTms=$latest['8.8.8.8']
                        Note='User-marked time; correlation only, not proof of causation.'
                    }
                    [void]$markers.Add($marker)
                    Write-Host ('[{0}] H marker recorded ({1} total)' -f (Get-Date -Format 'HH:mm:ss.fff'),$markers.Count) -ForegroundColor Magenta
                } elseif ($char -match '^[qQ]$') {
                    $stopRequested = $true
                    break
                }
            }
        } catch {
            if (-not $keySupportWarned) {
                Write-Host 'Keyboard marker input is unavailable in this host; sample collection will continue until the timer ends.' -ForegroundColor Yellow
                $keySupportWarned = $true
            }
        }
        if ($stopRequested) { break }

        foreach ($target in $targets) {
            if ($stopRequested -or (Get-Date) -ge $end) { break }
            try {
                while ($Host.UI.RawUI.KeyAvailable) {
                    $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                    $char = [string]$keyInfo.Character
                    if ($char -match '^[hH]$') {
                        [void]$markers.Add([pscustomobject]@{
                            Timestamp=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'); Event='UserMarkedHitRegOrRubberband'
                            LatestGatewayRTTms=$latest['Gateway']; LatestCloudflareRTTms=$latest['1.1.1.1']; LatestGoogleRTTms=$latest['8.8.8.8']
                            Note='User-marked time; correlation only, not proof of causation.'
                        })
                        Write-Host ('[{0}] H marker recorded ({1} total)' -f (Get-Date -Format 'HH:mm:ss.fff'),$markers.Count) -ForegroundColor Magenta
                    } elseif ($char -match '^[qQ]$') { $stopRequested=$true; break }
                }
            } catch { }
            if ($stopRequested) { break }
            $pinger = $null; $status='Error'; $rtt=$null; $stamp=Get-Date
            try {
                $pinger = New-Object System.Net.NetworkInformation.Ping
                $reply = $pinger.Send([string]$target.IP,800)
                $status = [string]$reply.Status
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $rtt = [double]$reply.RoundtripTime
                    $latest[$target.Label] = $rtt
                    Write-Host ('[{0}] {1,-14} {2,5} ms' -f $stamp.ToString('HH:mm:ss'),$target.Label,$rtt) -ForegroundColor $(if ($rtt -ge 100) {'Yellow'} else {'Gray'})
                } else {
                    Write-Host ('[{0}] {1,-14} {2}' -f $stamp.ToString('HH:mm:ss'),$target.Label,$status) -ForegroundColor Yellow
                }
            } catch { $status='Error' }
            finally { if ($pinger) { try { $pinger.Dispose() } catch {} } }
            if (-not $sampleIndex.ContainsKey($target.IP)) { $sampleIndex[$target.IP] = 0 }
            $sampleIndex[$target.IP] = [int]$sampleIndex[$target.IP] + 1
            [void]$rows.Add([pscustomobject]@{
                Timestamp=$stamp.ToString('yyyy-MM-dd HH:mm:ss.fff'); SampleIndex=$sampleIndex[$target.IP]
                Label=$target.Label; InputTarget=$target.Input; IPv4=$target.IP; Status=$status; RTTms=$rtt
            })
        }
        Start-Sleep -Milliseconds 100
    }

    Write-Host ''
    Write-Host '=============== HITREG MONITOR SUMMARY ===============' -ForegroundColor Cyan
    $summaries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in $targets) {
        $targetRows = @($rows | Where-Object { $_.IPv4 -eq $target.IP } | Sort-Object SampleIndex)
        $successful = @($targetRows | Where-Object { $_.Status -eq 'Success' -and $null -ne $_.RTTms })
        $rtts = @($successful | ForEach-Object { [double]$_.RTTms } | Sort-Object)
        $count = $targetRows.Count; $replies = $successful.Count
        $lossPct = if ($count -gt 0) { [math]::Round(100.0 * ($count-$replies) / $count,1) } else { 0.0 }
        $min=$null; $avg=$null; $max=$null; $median=$null; $p95=$null; $jitter=$null; $spikes=0
        if ($rtts.Count -gt 0) {
            $stats = $rtts | Measure-Object -Minimum -Average -Maximum
            $min=[math]::Round([double]$stats.Minimum,1); $avg=[math]::Round([double]$stats.Average,1); $max=[math]::Round([double]$stats.Maximum,1)
            $mid=[int][math]::Floor(($rtts.Count-1)/2)
            if (($rtts.Count % 2) -eq 1) { $median=[double]$rtts[$mid] } else { $median=([double]$rtts[$mid]+[double]$rtts[$mid+1])/2.0 }
            $pi=[int][math]::Ceiling(.95*$rtts.Count)-1; $pi=[math]::Max(0,[math]::Min($pi,$rtts.Count-1)); $p95=[math]::Round([double]$rtts[$pi],1)
            $diffs=New-Object 'System.Collections.Generic.List[double]'
            for ($i=1; $i -lt $targetRows.Count; $i++) {
                if ($targetRows[$i].Status -eq 'Success' -and $targetRows[$i-1].Status -eq 'Success' -and [int]$targetRows[$i].SampleIndex -eq ([int]$targetRows[$i-1].SampleIndex+1)) {
                    [void]$diffs.Add([math]::Abs([double]$targetRows[$i].RTTms-[double]$targetRows[$i-1].RTTms))
                }
            }
            if ($diffs.Count -gt 0) { $jitter=[math]::Round((($diffs | Measure-Object -Average).Average),1) }
            $spikes=@($rtts | Where-Object { $null -ne $median -and $_ -gt ($median+20.0) }).Count
        }
        [void]$summaries.Add([pscustomobject]@{ Target=$target.Label; IPv4=$target.IP; Probes=$count; Replies=$replies; NoReplyPct=$lossPct; MinMs=$min; AvgMs=$avg; MaxMs=$max; MedianMs=$(if ($null -ne $median) {[math]::Round($median,1)} else {$null}); P95Ms=$p95; MeanAbsJitterMs=$jitter; SpikesOverMedianPlus20ms=$spikes })
    }
    $summaries | Format-Table -AutoSize -Wrap
    Write-Host ('Manual symptom markers: {0}' -f $markers.Count) -ForegroundColor Magenta
    Write-Host 'ICMP samples and user markers help compare timing; they cannot prove server-side hit registration.' -ForegroundColor DarkGray

    $summaryLines = @(
        'InternetX HitReg / Rubberband Monitor Summary',
        ('Started: ' + $start.ToString('s')),
        ('Ended: ' + (Get-Date).ToString('s')),
        ('DurationLimitSeconds: ' + $duration),
        ('ManualSymptomMarkers: ' + $markers.Count),
        'NoReplyPct counts non-success ICMP statuses/timeouts; it is not confirmed FiveM packet loss.',
        'A symptom marker close to an RTT spike is correlation only and does not prove causation.'
    )
    foreach ($s in $summaries) {
        $summaryLines += ('Target={0}; IPv4={1}; Probes={2}; Replies={3}; NoReplyPct={4}; MinMs={5}; AvgMs={6}; MaxMs={7}; MedianMs={8}; P95Ms={9}; MeanAbsJitterMs={10}; Spikes={11}' -f $s.Target,$s.IPv4,$s.Probes,$s.Replies,$s.NoReplyPct,$s.MinMs,$s.AvgMs,$s.MaxMs,$s.MedianMs,$s.P95Ms,$s.MeanAbsJitterMs,$s.SpikesOverMedianPlus20ms)
    }
    Save-IXReport -Name 'HitReg-Samples' -Lines $summaryLines -Rows ($rows.ToArray())
    if ($markers.Count -gt 0) {
        Save-IXReport -Name 'HitReg-Markers' -Lines @('User-marked symptom timestamps; correlation only.') -Rows ($markers.ToArray())
    } else {
        Write-Host 'No H markers were recorded during this run.' -ForegroundColor DarkGray
    }
    Wait-IXReturn
}

function Invoke-IXReportsMenu {
    while ($true) {
        Show-IXHeader
        Write-IXTitle 'REPORTS & SELF-TEST'
        Write-IXMenuItem -Key '1' -Text 'Open InternetX report folder'
        Write-IXMenuItem -Key '2' -Text 'Test report writer (array/list/null)'
        Write-IXMenuItem -Key '3' -Text 'Show recent log entries'
        Write-IXMenuItem -Key '0' -Text 'Back' -Kind Exit
        Write-IXRule -Thin
        $choice = Read-IXChoice 'Choose 0-3'
        switch ($choice) {
            '1' {
                try { Invoke-Item -LiteralPath $script:IXReportDir -ErrorAction Stop }
                catch { Write-Host ('Could not open folder: {0}' -f $_.Exception.Message) -ForegroundColor Yellow; Wait-IXReturn }
            }
            '2' { Test-IXReportWriter }
            '3' {
                Show-IXHeader
                if (Test-Path -LiteralPath $script:IXLogPath) { Get-Content -LiteralPath $script:IXLogPath -Tail 35 }
                else { Write-Host 'No log entries yet.' -ForegroundColor DarkGray }
                Wait-IXReturn
            }
            '0' { return }
            default { Write-IXErr 'Invalid choice. Enter 0, 1, 2 or 3.'; Start-Sleep -Milliseconds 900 }
        }
    }
}

function Get-IXAdapterTweakerPlan {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('InterruptModeration','DisableEEE','MaxReceiveBuffers','MaxTransmitBuffers','WifiRoamingLowest','WifiMimoNoSMPS')]
        [string]$Mode
    )

    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($adapter in @(Get-IXActiveAdapters)) {
        $isWifi = ($adapter.Name -match 'Wi-?Fi|Wireless|WLAN') -or ($adapter.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11')
        if ($Mode -eq 'DisableEEE' -and $isWifi) { continue }
        if (($Mode -eq 'WifiRoamingLowest' -or $Mode -eq 'WifiMimoNoSMPS') -and -not $isWifi) { continue }
        try {
            $properties = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -AllProperties -ErrorAction Stop)
        } catch { continue }

        foreach ($property in $properties) {
            $displayName = [string]$property.DisplayName
            $match = $false
            switch ($Mode) {
                'InterruptModeration' { $match = ($displayName -match 'Interrupt Moderation') }
                'DisableEEE' { $match = ($displayName -match 'Energy Efficient Ethernet|Green Ethernet|Advanced EEE') }
                'MaxReceiveBuffers' { $match = ($displayName -match 'Receive Buffers|Rx Buffers|Receive Buffer') -and ($displayName -notmatch 'Transmit') }
                'MaxTransmitBuffers' { $match = ($displayName -match 'Transmit Buffers|Tx Buffers|Transmit Buffer') }
                'WifiRoamingLowest' { $match = ($displayName -match 'Roaming Aggressiveness') }
                'WifiMimoNoSMPS' { $match = ($displayName -match 'MIMO Power Save|SMPS') }
            }
            if (-not $match) { continue }

            $validValues = @($property.ValidDisplayValues | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($validValues.Count -eq 0) { continue }
            $target = $null
            switch ($Mode) {
                { $_ -in @('InterruptModeration','DisableEEE') } {
                    $target = $validValues | Where-Object { $_ -match '^(?i:Disabled|Disable|Off)$' } | Select-Object -First 1
                }
                { $_ -in @('MaxReceiveBuffers','MaxTransmitBuffers') } {
                    $numericValues = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($value in $validValues) {
                        $number = 0
                        if ([int]::TryParse($value, [ref]$number)) {
                            [void]$numericValues.Add([pscustomobject]@{ Label=$value; Number=$number })
                        }
                    }
                    if ($numericValues.Count -gt 0) {
                        $target = ($numericValues | Sort-Object Number -Descending | Select-Object -First 1).Label
                    }
                }
                'WifiRoamingLowest' {
                    $target = $validValues | Where-Object { $_ -match '(?i)lowest' } | Select-Object -First 1
                }
                'WifiMimoNoSMPS' {
                    $target = $validValues | Where-Object { $_ -match '(?i)^\s*No\s*SMPS\s*$' } | Select-Object -First 1
                }
            }
            if ([string]::IsNullOrWhiteSpace([string]$target)) { continue }
            if ([string]::Equals([string]$property.DisplayValue, [string]$target, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            $featureLabel = switch ($Mode) {
                'InterruptModeration' { 'Disable Interrupt Moderation (optional; may increase CPU overhead)' }
                'DisableEEE' { 'Disable wired Energy Efficient / Green Ethernet' }
                'MaxReceiveBuffers' { 'Set Receive Buffers to the highest listed numeric value' }
                'MaxTransmitBuffers' { 'Set Transmit Buffers to the highest listed numeric value' }
                'WifiRoamingLowest' { 'Set Wi-Fi Roaming Aggressiveness to Lowest' }
                'WifiMimoNoSMPS' { 'Set Wi-Fi MIMO power-save to No SMPS (if exposed)' }
            }
            [void]$plan.Add([pscustomobject]@{
                Mode = $Mode
                Feature = $featureLabel
                AdapterName = [string]$adapter.Name
                AdapterDescription = [string]$adapter.InterfaceDescription
                DisplayName = $displayName
                RegistryKeyword = [string]$property.RegistryKeyword
                OriginalDisplayValue = [string]$property.DisplayValue
                TargetDisplayValue = [string]$target
                SupportedValues = ($validValues -join ' | ')
            })
        }
    }
    return $plan.ToArray()
}

function Invoke-IXAdapterTweakerScan {
    Show-IXHeader
    Write-IXTitle 'NETWORK ADAPTER TWEAKER - SCAN ONLY' -Advanced
    Write-Host 'This scan reads adapter settings only. Nothing will be changed.' -ForegroundColor DarkGray
    $patterns = @(
        'Interrupt Moderation',
        'Energy Efficient Ethernet|Green Ethernet|Advanced EEE',
        'Receive Buffers|Rx Buffers|Receive Buffer',
        'Transmit Buffers|Tx Buffers|Transmit Buffer',
        'Roaming Aggressiveness',
        'MIMO Power Save|SMPS'
    )
    $adapters = @(Get-IXActiveAdapters)
    if ($adapters.Count -eq 0) {
        Write-Host 'No active adapter found.' -ForegroundColor Red
        Wait-IXReturn
        return
    }
    foreach ($adapter in $adapters) {
        $isWifi = ($adapter.Name -match 'Wi-?Fi|Wireless|WLAN') -or ($adapter.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11')
        Write-Host ("`nAdapter: {0} | {1} | {2}" -f $adapter.Name,$adapter.LinkSpeed,$adapter.InterfaceDescription) -ForegroundColor Cyan
        try {
            $props = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -AllProperties -ErrorAction Stop | Where-Object {
                $name = [string]$_.DisplayName
                (($patterns | Where-Object { $name -match $_ } | Measure-Object).Count -gt 0)
            })
            if ($props.Count -eq 0) {
                Write-Host '  No matching advanced properties exposed by this driver.' -ForegroundColor DarkYellow
                continue
            }
            foreach ($p in $props) {
                $allowed = @($p.ValidDisplayValues | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | '
                Write-Host ("  {0}: {1}" -f $p.DisplayName,$p.DisplayValue) -ForegroundColor Gray
                if ($allowed) { Write-Host ("    Supported: {0}" -f $allowed) -ForegroundColor DarkGray }
            }
        } catch {
            Write-Host '  Could not read advanced properties on this adapter.' -ForegroundColor Yellow
        }
        if ($isWifi) { Write-Host '  Adapter type: Wi-Fi' -ForegroundColor DarkCyan }
        else { Write-Host '  Adapter type: wired / non-Wi-Fi' -ForegroundColor DarkCyan }
    }
    Write-Host "`nOnly settings explicitly exposed by the installed driver can be changed." -ForegroundColor DarkGray
    Wait-IXReturn
}

function Invoke-IXAdapterTweakerApply {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('InterruptModeration','DisableEEE','MaxReceiveBuffers','MaxTransmitBuffers','WifiRoamingLowest','WifiMimoNoSMPS')]
        [string]$Mode
    )
    Show-IXHeader
    if (-not (Test-IXAdmin)) {
        Write-Host 'Administrator permission required.' -ForegroundColor Red
        Wait-IXReturn
        return
    }
    $plan = @(Get-IXAdapterTweakerPlan -Mode $Mode)
    if ($plan.Count -eq 0) {
        Write-Host 'No supported change found for this option.' -ForegroundColor Green
        Write-Host 'The property may be unsupported, already at target, or exposed under another driver-specific name.' -ForegroundColor DarkGray
        Wait-IXReturn
        return
    }
    Write-IXTitle 'NETWORK ADAPTER TWEAKER - CHANGE PREVIEW' -Advanced
    Write-IXChangePreview -Items @($plan | ForEach-Object { [pscustomobject]@{ Name = ($_.AdapterName + ': ' + $_.DisplayName); Current = $_.OriginalDisplayValue; Proposed = $_.TargetDisplayValue; Reason = $_.Feature } })
    switch ($Mode) {
        'InterruptModeration' { Write-Host 'Note: disabling interrupt moderation can increase CPU interrupts and may reduce throughput under load.' -ForegroundColor Yellow }
        'DisableEEE' { Write-Host 'Note: disabling EEE can increase power use; results depend on NIC, switch/router and driver.' -ForegroundColor Yellow }
        'MaxReceiveBuffers' { Write-Host 'Note: higher receive buffers can help with bursts but do not guarantee lower ping.' -ForegroundColor DarkGray }
        'MaxTransmitBuffers' { Write-Host 'Note: higher transmit buffers can affect queuing; test before/after and revert if worse.' -ForegroundColor Yellow }
        'WifiRoamingLowest' { Write-Host 'Note: lowest roaming may delay switching access points; use mainly for a stationary PC.' -ForegroundColor Yellow }
        'WifiMimoNoSMPS' { Write-Host 'Note: No SMPS may increase Wi-Fi power use; use only if your driver exposes this exact value.' -ForegroundColor Yellow }
    }
    Write-Host 'No changes occur until you confirm.' -ForegroundColor Cyan
    $confirmation = Read-Host 'Type YES to apply these adapter changes'
    if ($confirmation -cne 'YES') {
        Write-Host 'Cancelled. No adapter settings changed.' -ForegroundColor Yellow
        Wait-IXReturn
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $script:IXBackupDir ('AdapterTweaker-{0}-{1}.json' -f $Mode,$stamp)
    try {
        ConvertTo-Json -InputObject @($plan) -Depth 6 | Set-Content -LiteralPath $backupPath -Encoding UTF8 -ErrorAction Stop
        Write-Host ("Backup saved: {0}" -f $backupPath) -ForegroundColor Green
    } catch {
        Write-Host 'Backup could not be written; changes cancelled for safety.' -ForegroundColor Red
        Wait-IXReturn
        return
    }
    foreach ($item in $plan) {
        $keyPart = [string]$item.RegistryKeyword
        if ([string]::IsNullOrWhiteSpace($keyPart)) { $keyPart = [string]$item.DisplayName }
        $key = 'PROP|' + [string]$item.AdapterName + '|' + $keyPart
        $entry = [pscustomobject]@{
            Key=$key; Type='AdapterProperty'; AdapterName=[string]$item.AdapterName
            DisplayName=[string]$item.DisplayName; RegistryKeyword=[string]$item.RegistryKeyword
            OriginalDisplayValue=[string]$item.OriginalDisplayValue; TargetDisplayValue=[string]$item.TargetDisplayValue
            Status='Pending'; Created=(Get-Date).ToString('s'); LastUpdated=(Get-Date).ToString('s')
        }
        $entry = Add-IXStateEntry -Entry $entry
        try {
            Set-NetAdapterAdvancedProperty -Name $item.AdapterName -DisplayName $item.DisplayName -DisplayValue $item.TargetDisplayValue -NoRestart -ErrorAction Stop | Out-Null
            Set-IXEntryStatus -Entry $entry -Status 'Applied'
            Write-Host ("APPLIED: {0} | {1}: {2} -> {3}" -f $item.AdapterName,$item.DisplayName,$item.OriginalDisplayValue,$item.TargetDisplayValue) -ForegroundColor Green
            Write-IXLog ('Adapter Tweaker applied: ' + $item.AdapterName + ' | ' + $item.DisplayName + ' => ' + $item.TargetDisplayValue)
        } catch {
            Set-IXEntryStatus -Entry $entry -Status 'Failed'
            Write-Host ("FAILED: {0} | {1} | {2}" -f $item.AdapterName,$item.DisplayName,$_.Exception.Message) -ForegroundColor Red
            Write-IXLog ('Adapter Tweaker failed: ' + $item.AdapterName + ' | ' + $item.DisplayName + ' | ' + $_.Exception.Message)
        }
    }
    Write-Host 'Some drivers require a network-adapter restart or Windows restart before changes take effect.' -ForegroundColor Yellow
    Write-Host 'If the connection gets worse, use Restore InternetX changes in the same tool.' -ForegroundColor DarkGray
    Wait-IXReturn
}

function Invoke-IXApplyAllAdapterTweaks {
    Show-IXHeader
    if (-not (Test-IXAdmin)) {
        Write-Host 'Administrator permission required.' -ForegroundColor Red
        Wait-IXReturn
        return
    }

    Write-IXTitle 'ALL - PREVIEW OF SUPPORTED ADAPTER TWEAKS' -Advanced
    Write-Host 'The preset only includes options exposed by the installed driver and not already at the target value.' -ForegroundColor DarkGray
    Write-Host 'Important: ALL is not guaranteed to be optimal on every PC. Review the plan before confirming.' -ForegroundColor Yellow

    $modes = @('InterruptModeration','DisableEEE','MaxReceiveBuffers','MaxTransmitBuffers','WifiRoamingLowest','WifiMimoNoSMPS')
    $planList = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($mode in $modes) {
        foreach ($item in @(Get-IXAdapterTweakerPlan -Mode $mode)) {
            $keyPart = [string]$item.RegistryKeyword
            if ([string]::IsNullOrWhiteSpace($keyPart)) { $keyPart = [string]$item.DisplayName }
            $uniqueKey = ([string]$item.AdapterName) + '|' + $keyPart
            if (-not $seen.ContainsKey($uniqueKey)) {
                $seen[$uniqueKey] = $true
                [void]$planList.Add($item)
            }
        }
    }

    $plan = @($planList.ToArray())
    if ($plan.Count -eq 0) {
        Write-Host 'No supported changes are needed or exposed by the driver. Nothing changed.' -ForegroundColor Green
        Wait-IXReturn
        return
    }

    Write-IXChangePreview -Items @($plan | ForEach-Object { [pscustomobject]@{ Name = ($_.AdapterName + ': ' + $_.DisplayName); Current = $_.OriginalDisplayValue; Proposed = $_.TargetDisplayValue; Reason = $_.Feature } })
    Write-Host ''
    Write-Host 'Potential trade-offs:' -ForegroundColor Yellow
    Write-Host '- Interrupt Moderation disabled may increase CPU interrupt load.' -ForegroundColor Yellow
    Write-Host '- Higher buffer counts can affect queueing and do not guarantee lower latency.' -ForegroundColor Yellow
    Write-Host '- Disabling wired EEE may increase power use; Wi-Fi options can increase power use or change roaming.' -ForegroundColor Yellow
    Write-Host '- Test before/after and use Restore InternetX changes if performance worsens.' -ForegroundColor DarkGray

    $confirm = Read-Host 'Type ALL to back up and apply every listed change'
    if ($confirm -cne 'ALL') {
        Write-Host 'Cancelled. No adapter settings changed.' -ForegroundColor Gray
        Wait-IXReturn
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $script:IXBackupDir ('AdapterTweaker-ALL-{0}.json' -f $stamp)
    try {
        ConvertTo-Json -InputObject @($plan) -Depth 8 | Set-Content -LiteralPath $backupPath -Encoding UTF8 -ErrorAction Stop
        Write-Host ("Backup saved: {0}" -f $backupPath) -ForegroundColor Green
    } catch {
        Write-Host 'Could not save the backup; ALL cancelled for safety.' -ForegroundColor Red
        Write-IXLog ('ALL backup failed: ' + $_.Exception.Message)
        Wait-IXReturn
        return
    }

    $applied = 0
    $failed = 0
    foreach ($item in $plan) {
        $keyPart = [string]$item.RegistryKeyword
        if ([string]::IsNullOrWhiteSpace($keyPart)) { $keyPart = [string]$item.DisplayName }
        $key = 'PROP|' + [string]$item.AdapterName + '|' + $keyPart
        $entry = [pscustomobject]@{
            Key=$key
            Type='AdapterProperty'
            AdapterName=[string]$item.AdapterName
            DisplayName=[string]$item.DisplayName
            RegistryKeyword=[string]$item.RegistryKeyword
            OriginalDisplayValue=[string]$item.OriginalDisplayValue
            TargetDisplayValue=[string]$item.TargetDisplayValue
            Status='Pending'
            Created=(Get-Date).ToString('s')
            LastUpdated=(Get-Date).ToString('s')
        }
        $entry = Add-IXStateEntry -Entry $entry
        try {
            Set-NetAdapterAdvancedProperty -Name $item.AdapterName -DisplayName $item.DisplayName -DisplayValue $item.TargetDisplayValue -NoRestart -ErrorAction Stop | Out-Null
            Set-IXEntryStatus -Entry $entry -Status 'Applied'
            $applied++
            Write-Host ("APPLIED: {0} | {1}: {2} -> {3}" -f $item.AdapterName,$item.DisplayName,$item.OriginalDisplayValue,$item.TargetDisplayValue) -ForegroundColor Green
            Write-IXLog ('Adapter Tweaker ALL applied: ' + $item.AdapterName + ' | ' + $item.DisplayName + ' => ' + $item.TargetDisplayValue)
        } catch {
            $failed++
            try { Set-IXEntryStatus -Entry $entry -Status 'Failed' } catch {}
            Write-Host ("FAILED: {0} | {1} | {2}" -f $item.AdapterName,$item.DisplayName,$_.Exception.Message) -ForegroundColor Red
            Write-IXLog ('Adapter Tweaker ALL failed: ' + $item.AdapterName + ' | ' + $item.DisplayName + ' | ' + $_.Exception.Message)
        }
    }

    Write-Host ''
    Write-Host ("ALL completed. Applied: {0} | Failed: {1}" -f $applied,$failed) -ForegroundColor Cyan
    Write-Host 'A driver or Windows restart may be required for some changes. Compare actual ping/jitter before and after.' -ForegroundColor Yellow
    Write-Host 'If performance worsens, use the Restore InternetX changes menu.' -ForegroundColor DarkGray
    Wait-IXReturn
}

function Invoke-IXAdapterTweakerMenu {
    while ($true) {
        Show-IXHeader
        Write-IXTitle 'NETWORK ADAPTER TWEAKER (OPTIONAL)' -Advanced
        Write-Host 'Nothing is changed automatically. Preview first, then opt in per tweak.' -ForegroundColor DarkGray
        Write-IXMenuItem -Key '1' -Text 'Scan supported NIC properties' -Hint 'read-only'
        Write-IXMenuItem -Key '2' -Text 'Disable Interrupt Moderation (optional)' -Hint 'changes after YES' -Kind Apply
        Write-IXMenuItem -Key '3' -Text 'Disable wired EEE / Green Ethernet (optional)' -Hint 'changes after YES' -Kind Apply
        Write-IXMenuItem -Key '4' -Text 'Maximize Receive Buffers (if listed by driver)' -Hint 'changes after YES' -Kind Apply
        Write-IXMenuItem -Key '5' -Text 'Maximize Transmit Buffers (if listed by driver)' -Hint 'changes after YES' -Kind Apply
        Write-IXMenuItem -Key '6' -Text 'Wi-Fi Roaming Aggressiveness = Lowest' -Hint 'Wi-Fi only' -Kind Apply
        Write-IXMenuItem -Key '7' -Text 'Wi-Fi MIMO Power Save = No SMPS' -Hint 'Wi-Fi only' -Kind Apply
        Write-IXMenuItem -Key '8' -Text 'Restore InternetX changes' -Hint 'verified rollback'
        Write-IXMenuItem -Key '9' -Text 'ALL - apply all supported tweaks' -Hint 'preview, then ALL' -Kind Advanced
        Write-IXMenuItem -Key '0' -Text 'Back to main menu' -Kind Exit
        Write-IXRule -Thin
        $choice = Read-IXChoice 'Choose 0-9'
        switch ($choice) {
            '1' { Invoke-IXAdapterTweakerScan }
            '2' { Invoke-IXAdapterTweakerApply -Mode 'InterruptModeration' }
            '3' { Invoke-IXAdapterTweakerApply -Mode 'DisableEEE' }
            '4' { Invoke-IXAdapterTweakerApply -Mode 'MaxReceiveBuffers' }
            '5' { Invoke-IXAdapterTweakerApply -Mode 'MaxTransmitBuffers' }
            '6' { Invoke-IXAdapterTweakerApply -Mode 'WifiRoamingLowest' }
            '7' { Invoke-IXAdapterTweakerApply -Mode 'WifiMimoNoSMPS' }
            '8' { Invoke-IXRestore }
            '9' { Invoke-IXApplyAllAdapterTweaks }
            '0' { return }
            default { Write-IXErr 'Invalid choice. Enter 0-8.'; Start-Sleep -Milliseconds 900 }
        }
    }
}

function Invoke-IXOptimizationMenu {
    while ($true) {
        Show-IXHeader
        Write-IXTitle 'OPTIMIZATION & RESTORE'
        Write-IXMenuItem -Key '1' -Text 'Preview supported settings' -Hint 'read-only'
        Write-IXMenuItem -Key '2' -Text 'Enable RSS where supported' -Hint 'changes after YES' -Kind Apply
        Write-IXMenuItem -Key '3' -Text 'Optional wired EEE disable' -Hint 'changes after YES' -Kind Apply
        Write-IXMenuItem -Key '4' -Text 'Restore InternetX changes' -Hint 'verified rollback'
        Write-IXMenuItem -Key '5' -Text 'View TCP global settings' -Hint 'read-only'
        Write-IXMenuItem -Key '0' -Text 'Back to main menu' -Kind Exit
        Write-IXRule -Thin
        $choice = Read-IXChoice 'Choose 0-5'
        switch ($choice) {
            '1' { Invoke-IXPreview }
            '2' { Invoke-IXApplyRSS }
            '3' { Invoke-IXDisableEEE }
            '4' { Invoke-IXRestore }
            '5' { Show-IXHeader; netsh.exe interface tcp show global; Wait-IXReturn }
            '0' { return }
            default { Write-IXErr 'Invalid choice. Enter 0, 1, 2, 3, 4 or 5.'; Start-Sleep -Seconds 1 }
        }
    }
}

# ---------------------------------------------------------------------------
# LOW PING PROFILE + before/after comparison
# ---------------------------------------------------------------------------
function Get-IXLowPingRules {
    # Only conservative changes with a clear reason. MTU, DNS, TCP registry, Flow Control,
    # offloads and Interrupt Moderation are deliberately left alone: no single value suits every PC.
    return @{
        TurnOff = [ordered]@{
            '*JumboPacket' = 'Internet paths carry 1500-byte packets; jumbo frames only help on a LAN built for them.'
            '*EEE' = 'Energy Efficient Ethernet can add wake-up delay on a quiet link.'
            'AdvancedEEE' = 'Energy Efficient Ethernet can add wake-up delay on a quiet link.'
            'EnableGreenEthernet' = 'Green Ethernet power saving can add delay or link renegotiation.'
            '*SelectiveSuspend' = 'Lets Windows suspend the adapter when it looks idle.'
            'PowerSavingMode' = 'Adapter power saving can add delay.'
            'AutoPowerSaveModeEnabled' = 'Adapter power saving can add delay.'
            'EnableDynamicPowerGating' = 'Adapter power saving can add delay.'
            'EnableConnectedPowerGating' = 'Adapter power saving can add delay.'
            'NicAutoPowerSaver' = 'Adapter power saving can add delay.'
            'ReduceSpeedOnPowerDown' = 'Adapter power saving can lower link speed.'
            'ULPMode' = 'Ultra-low-power mode can add wake-up delay.'
        }
        BufferFloor = @{ '*ReceiveBuffers' = 512; '*TransmitBuffers' = 128 }
        BufferReason = 'Very small buffers can drop packets in bursts; raised to a modest floor, not the maximum.'
        BufferTradeOff = 'Uses slightly more memory. No other known downside at this size.'
        TradeOff = @{
            '*JumboPacket' = 'Large file copies to a jumbo-enabled NAS on your own network get slower.'
            '*SelectiveSuspend' = 'Slightly higher power use while the PC is idle.'
        }
        DefaultTradeOff = 'Slightly higher power use.'
        # Offered one by one and never included unless chosen: the benefit is small and depends on the PC.
        Optional = [ordered]@{
            '*InterruptModeration' = 'Hands each packet to Windows at once instead of in batches (usually well under 1 ms).'
            '*FlowControl' = 'Stops pause frames from the router or switch briefly halting all traffic.'
        }
        OptionalTradeOff = @{
            '*InterruptModeration' = 'More CPU interrupts. Can lower FPS on a CPU that is already near 100%.'
            '*FlowControl' = 'Under overload, packets are dropped instead of paused. Leave it on if the test shows no problem.'
        }
    }
}

function Get-IXAdapterRegistryValue {
    param([string]$AdapterName,[string]$Keyword)
    try {
        $property = Get-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $Keyword -ErrorAction Stop | Select-Object -First 1
        $values = @($property.RegistryValue)
        if ($values.Count -gt 0 -and $null -ne $values[0]) { return [string]$values[0] }
    } catch { }
    return $null
}

function Get-IXInterfaceMtu {
    param([object]$Adapter)
    try {
        $ipInterface = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        if ($ipInterface -and $null -ne $ipInterface.NlMtu) { return [int]$ipInterface.NlMtu }
    } catch { }
    return $null
}

function Get-IXLowPingPlan {
    # -Optional returns the opt-in items instead of the core profile.
    param([Parameter(Mandatory=$true)][object]$Adapter,[switch]$Optional)
    $rules = Get-IXLowPingRules
    $offTable = if ($Optional) { $rules.Optional } else { $rules.TurnOff }
    $plan = New-Object 'System.Collections.Generic.List[object]'
    $properties = @()
    try { $properties = @(Get-NetAdapterAdvancedProperty -Name $Adapter.Name -ErrorAction Stop) } catch { return @() }
    foreach ($property in $properties) {
        $keyword = [string]$property.RegistryKeyword
        if ([string]::IsNullOrWhiteSpace($keyword)) { continue }
        $currentRegistry = ''
        $currentValues = @($property.RegistryValue)
        if ($currentValues.Count -gt 0 -and $null -ne $currentValues[0]) { $currentRegistry = [string]$currentValues[0] }
        $registryValues = @($property.ValidRegistryValues | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $displayValues = @($property.ValidDisplayValues | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() })
        $targetRegistry = $null; $targetDisplay = $null; $reason = $null; $tradeOff = $null

        if ($offTable.Contains($keyword)) {
            # Only use an "off" value the driver itself lists.
            if ($registryValues.Count -gt 0 -and $registryValues.Count -eq $displayValues.Count) {
                for ($i = 0; $i -lt $registryValues.Count; $i++) {
                    if ($displayValues[$i] -match '^(?i:Disabled|Disable|Off)$') { $targetRegistry = $registryValues[$i]; $targetDisplay = $displayValues[$i]; break }
                }
            }
            $reason = [string]$offTable[$keyword]
            $tradeTable = if ($Optional) { $rules.OptionalTradeOff } else { $rules.TradeOff }
            $tradeOff = if ($tradeTable.ContainsKey($keyword)) { [string]$tradeTable[$keyword] } else { [string]$rules.DefaultTradeOff }
        } elseif (-not $Optional -and $rules.BufferFloor.ContainsKey($keyword)) {
            $floor = [int]$rules.BufferFloor[$keyword]
            $number = 0
            if ([int]::TryParse($currentRegistry,[ref]$number) -and $number -lt $floor) {
                $listed = @($registryValues | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object)
                if ($listed.Count -gt 0) {
                    $pick = @($listed | Where-Object { $_ -ge $floor } | Select-Object -First 1)
                    if ($pick.Count -gt 0) { $targetRegistry = [string]$pick[0] }
                } elseif ($null -ne $property.NumericParameterMinValue -and $null -ne $property.NumericParameterMaxValue) {
                    if ($floor -ge [int]$property.NumericParameterMinValue -and $floor -le [int]$property.NumericParameterMaxValue) { $targetRegistry = [string]$floor }
                }
                $targetDisplay = $targetRegistry
                $reason = [string]$rules.BufferReason
                $tradeOff = [string]$rules.BufferTradeOff
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$targetRegistry) -or $targetRegistry -eq $currentRegistry) { continue }
        [void]$plan.Add([pscustomobject]@{
            AdapterName = [string]$Adapter.Name
            DisplayName = [string]$property.DisplayName
            RegistryKeyword = $keyword
            OriginalDisplayValue = [string]$property.DisplayValue
            OriginalRegistryValue = $currentRegistry
            TargetDisplayValue = [string]$targetDisplay
            TargetRegistryValue = [string]$targetRegistry
            Reason = $reason
            TradeOff = $tradeOff
        })
    }
    return $plan.ToArray()
}

function Invoke-IXLowPingProfile {
    Show-IXHeader
    Write-IXTitle 'EXTREME STABILITY PROFILE (preview, then apply)'
    Write-Host 'Shows current values first. Changes only what the driver supports, after you confirm.' -ForegroundColor DarkGray
    Write-Host 'No result is guaranteed: lower ping depends mostly on your ISP route and the game server.' -ForegroundColor DarkGray
    # The guided run reads this to decide whether an after-test makes sense.
    $script:IXLastProfileResult = [pscustomobject]@{ Applied = 0; Failed = 0; Restarted = $false; AdapterName = '' }
    if (-not (Test-IXAdmin)) { Write-Host 'Administrator permission required.' -ForegroundColor Red; Wait-IXReturn; return }
    $adapter = Get-IXPrimaryAdapter
    if (-not $adapter) { Write-Host 'No active network adapter found.' -ForegroundColor Red; Wait-IXReturn; return }
    $script:IXLastProfileResult.AdapterName = [string]$adapter.Name
    $isWifi = ($adapter.Name -match 'Wi-?Fi|Wireless|WLAN') -or ($adapter.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11')
    $rules = Get-IXLowPingRules

    Write-Host ''
    Write-Host ('Adapter: {0} | {1} | {2}' -f $adapter.Name,$adapter.InterfaceDescription,$adapter.LinkSpeed) -ForegroundColor Cyan
    Write-Host 'CURRENT VALUES (read-only)' -ForegroundColor Cyan
    $watched = @($rules.TurnOff.Keys) + @($rules.BufferFloor.Keys) + @($rules.Optional.Keys)
    $shown = 0
    try {
        foreach ($property in @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop | Where-Object { $watched -contains [string]$_.RegistryKeyword })) {
            Write-Host ('  {0,-34} = {1}' -f $property.DisplayName,$property.DisplayValue) -ForegroundColor Gray
            $shown++
        }
    } catch { Write-Host '  Advanced properties could not be read on this adapter.' -ForegroundColor Yellow }
    if ($shown -eq 0) { Write-Host '  This driver exposes none of the profile settings.' -ForegroundColor DarkYellow }
    $rssCandidate = $false
    try {
        $rss = Get-NetAdapterRss -Name $adapter.Name -ErrorAction Stop | Select-Object -First 1
        if ($rss) { Write-Host ('  {0,-34} = {1}' -f 'Receive Side Scaling',$rss.Enabled) -ForegroundColor Gray; $rssCandidate = (-not [bool]$rss.Enabled) }
    } catch { Write-Host '  Receive Side Scaling: not exposed by this adapter' -ForegroundColor DarkGray }
    $mtu = Get-IXInterfaceMtu -Adapter $adapter
    if ($null -ne $mtu) { Write-Host ('  {0,-34} = {1}' -f 'Interface MTU (IPv4)',$mtu) -ForegroundColor Gray }

    Write-Host ''
    Write-Host 'NOTES (nothing below is changed by this profile)' -ForegroundColor Cyan
    if ($isWifi) { Write-Host '  - You are on Wi-Fi. A network cable usually helps more than any setting.' -ForegroundColor Yellow }
    if ($null -ne $mtu -and $mtu -gt 1500) { Write-Host ('  - Interface MTU is {0}, above the 1500 standard. It follows Jumbo Packet; run the MTU test (menu 3) after applying.' -f $mtu) -ForegroundColor Yellow }
    Write-Host '  - MTU, DNS, TCP registry values and checksum/LSO offloads are never changed here.' -ForegroundColor DarkGray
    Write-Host '  - Every proposed value is one the installed driver lists as supported.' -ForegroundColor DarkGray

    $plan = @(Get-IXLowPingPlan -Adapter $adapter)
    $optional = @(Get-IXLowPingPlan -Adapter $adapter -Optional)
    if ($plan.Count -eq 0 -and -not $rssCandidate -and $optional.Count -eq 0) {
        Write-Host ''
        Write-Host 'This adapter already matches the profile. Nothing changed.' -ForegroundColor Green
        Wait-IXReturn; return
    }
    if ($optional.Count -gt 0) {
        Write-Host ''
        Write-IXSection 'OPTIONAL ITEMS (not included unless you choose them)'
        for ($i = 0; $i -lt $optional.Count; $i++) {
            Write-Host ('  [{0}] {1}: {2} -> {3}' -f ($i + 1),$optional[$i].DisplayName,$optional[$i].OriginalDisplayValue,$optional[$i].TargetDisplayValue) -ForegroundColor Magenta
            Write-IXWrapped -Text ('benefit: ' + $optional[$i].Reason) -Indent 6 -Role 'Muted'
            Write-IXWrapped -Text ('trade-off: ' + $optional[$i].TradeOff) -Indent 6 -Role 'Muted'
        }
        $picked = ([string](Read-Host 'Optional items to include: numbers separated by commas, or Enter for none')).Trim()
        foreach ($token in @($picked -split '[,\s]+' | Where-Object { $_ })) {
            $index = 0
            if ([int]::TryParse($token,[ref]$index) -and $index -ge 1 -and $index -le $optional.Count) {
                if (@($plan | Where-Object { $_.RegistryKeyword -eq $optional[$index - 1].RegistryKeyword }).Count -eq 0) { $plan += $optional[$index - 1] }
            }
        }
    }
    if ($plan.Count -eq 0 -and -not $rssCandidate) {
        Write-Host ''
        Write-Host 'The core profile already matches this adapter and no optional item was chosen. Nothing changed.' -ForegroundColor Green
        Wait-IXReturn; return
    }
    Write-Host ''
    Write-IXSection 'PROPOSED CHANGES'
    $previewItems = @($plan | ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName; Current = $_.OriginalDisplayValue; Proposed = $_.TargetDisplayValue; Reason = $_.Reason; TradeOff = $_.TradeOff } })
    if ($rssCandidate) { $previewItems += [pscustomobject]@{ Name = 'Receive Side Scaling'; Current = 'False'; Proposed = 'True'; Reason = 'Spreads receive processing across CPU cores on supported adapters.'; TradeOff = 'None known on adapters that support it.' } }
    Write-IXChangePreview -Items $previewItems
    Write-Host 'Tip: menu 9 > 1 (guided run) records a baseline first and compares afterwards.' -ForegroundColor DarkGray
    $confirm = Read-Host 'Type YES to back up and apply the listed changes'
    if ($confirm -cne 'YES') { Write-Host 'Cancelled; no changes made.' -ForegroundColor Yellow; Wait-IXReturn; return }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $script:IXBackupDir ('LowPingProfile-before-{0}.json' -f $stamp)
    try {
        $snapshot = [pscustomobject]@{ Adapter = [string]$adapter.Name; RssWasEnabled = (-not $rssCandidate); Properties = @($plan) }
        $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupPath -Encoding UTF8 -ErrorAction Stop
        Write-Host ('Backup saved: {0}' -f $backupPath) -ForegroundColor Green
    } catch {
        Write-Host 'Backup could not be written; nothing was changed.' -ForegroundColor Red
        Wait-IXReturn; return
    }

    $applied = 0; $failed = 0
    foreach ($item in $plan) {
        $entry = [pscustomobject]@{
            Key = ('PROP|' + $item.AdapterName + '|' + $item.RegistryKeyword); Type = 'AdapterProperty'; AdapterName = $item.AdapterName
            DisplayName = $item.DisplayName; RegistryKeyword = $item.RegistryKeyword
            OriginalDisplayValue = $item.OriginalDisplayValue; OriginalRegistryValue = $item.OriginalRegistryValue
            TargetDisplayValue = $item.TargetDisplayValue
            Status = 'Pending'; Created = (Get-Date).ToString('s'); LastUpdated = (Get-Date).ToString('s')
        }
        $entry = Add-IXStateEntry -Entry $entry
        try {
            Set-NetAdapterAdvancedProperty -Name $item.AdapterName -RegistryKeyword $item.RegistryKeyword -RegistryValue $item.TargetRegistryValue -NoRestart -ErrorAction Stop | Out-Null
            $readBack = Get-IXAdapterRegistryValue -AdapterName $item.AdapterName -Keyword $item.RegistryKeyword
            if ($readBack -ne $item.TargetRegistryValue) { throw ('value read back as "{0}"' -f $readBack) }
            Set-IXEntryStatus -Entry $entry -Status 'Applied'
            $applied++
            Write-Host ('APPLIED + VERIFIED: {0} = {1}' -f $item.DisplayName,$item.TargetDisplayValue) -ForegroundColor Green
            Write-IXLog ('Low Ping Profile applied: ' + $item.AdapterName + ' | ' + $item.DisplayName + ' => ' + $item.TargetDisplayValue)
        } catch {
            $failed++
            Set-IXEntryStatus -Entry $entry -Status 'Failed'
            Write-Host ('FAILED: {0} | {1}' -f $item.DisplayName,$_.Exception.Message) -ForegroundColor Red
            Write-IXLog ('Low Ping Profile failed: ' + $item.DisplayName + ' | ' + $_.Exception.Message)
        }
    }
    if ($rssCandidate) {
        $entry = [pscustomobject]@{ Key = ('RSS|' + $adapter.Name); Type = 'RSS'; AdapterName = [string]$adapter.Name; OriginalEnabled = $false; Status = 'Pending'; Created = (Get-Date).ToString('s'); LastUpdated = (Get-Date).ToString('s') }
        $entry = Add-IXStateEntry -Entry $entry
        try {
            Set-NetAdapterRss -Name $adapter.Name -Enabled $true -NoRestart -ErrorAction Stop | Out-Null
            Set-IXEntryStatus -Entry $entry -Status 'Applied'
            $applied++
            Write-Host 'APPLIED: Receive Side Scaling enabled' -ForegroundColor Green
        } catch {
            $failed++
            Set-IXEntryStatus -Entry $entry -Status 'Failed'
            Write-Host ('FAILED: Receive Side Scaling | {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }

    Write-Host ''
    Write-Host ('Stability profile finished. Applied: {0} | Failed: {1}' -f $applied,$failed) -ForegroundColor Cyan
    Write-Host 'The driver uses the new values after the adapter restarts (or after a Windows restart).' -ForegroundColor Yellow
    $script:IXLastProfileResult.Applied = $applied
    $script:IXLastProfileResult.Failed = $failed
    if ($applied -gt 0) {
        $restart = Read-Host 'Type RESTART to restart the adapter now (internet drops for a few seconds), or Enter to skip'
        if ($restart -ceq 'RESTART') {
            try { Restart-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop; $script:IXLastProfileResult.Restarted = $true; Write-Host 'Adapter restarted.' -ForegroundColor Green }
            catch { Write-Host ('Adapter restart failed: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        }
    }
    Write-Host 'To undo: menu 9 > 7 (Restore InternetX changes). To measure: menu 9 > 5 (after test).' -ForegroundColor DarkGray
    Wait-IXReturn
}

function Measure-IXDnsLookup {
    # Asks the adapter's own DNS server directly, so the local cache does not hide slow lookups.
    param([string[]]$Names = @('cfx.re','fivem.net','www.cloudflare.com'),[int]$Attempts = 3)
    $server = $null
    try {
        $adapter = Get-IXPrimaryAdapter
        if ($adapter) {
            $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
            $server = @($dns.ServerAddresses | Where-Object { $_ })[0]
        }
    } catch { }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $Names) {
        $times = New-Object 'System.Collections.Generic.List[double]'
        $failures = 0
        for ($i = 0; $i -lt $Attempts; $i++) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if ($server) { Resolve-DnsName -Name $name -Type A -Server $server -DnsOnly -ErrorAction Stop | Out-Null }
                else { [void][System.Net.Dns]::GetHostAddresses($name) }
                $watch.Stop()
                [void]$times.Add($watch.Elapsed.TotalMilliseconds)
            } catch { $failures++ }
        }
        $avg = $null; $max = $null
        if ($times.Count -gt 0) {
            $stats = $times | Measure-Object -Average -Maximum
            $avg = [math]::Round([double]$stats.Average,1); $max = [math]::Round([double]$stats.Maximum,1)
        }
        [void]$rows.Add([pscustomobject]@{ Name = $name; DnsServer = $(if ($server) { [string]$server } else { 'system resolver' }); Attempts = $Attempts; Failures = $failures; AvgMs = $avg; MaxMs = $max })
    }
    return $rows.ToArray()
}

function Invoke-IXBenchmarkRun {
    param([string]$ExtraTarget,[int]$Count = 30)
    $ping = New-Object 'System.Collections.Generic.List[object]'
    $gateway = Get-IXIPv4Gateway
    if ($gateway) {
        Write-Host ('Testing gateway {0} ({1} probes)...' -f $gateway,$Count) -ForegroundColor Cyan
        $row = Invoke-IXPingSummary -Target $gateway -Count $Count
        $row | Add-Member -NotePropertyName Label -NotePropertyValue 'Gateway' -Force
        [void]$ping.Add($row)
    }
    $targets = @('1.1.1.1','8.8.8.8')
    if (-not [string]::IsNullOrWhiteSpace($ExtraTarget)) { $targets += $ExtraTarget.Trim() }
    foreach ($target in $targets) {
        Write-Host ('Testing {0} ({1} probes)...' -f $target,$Count) -ForegroundColor Cyan
        $row = Invoke-IXPingSummary -Target $target -Count $Count
        $row | Add-Member -NotePropertyName Label -NotePropertyValue $target -Force
        [void]$ping.Add($row)
    }
    $dashboardRow = @($ping | Where-Object { $_.Label -ne 'Gateway' -and $_.Resolved -ne 'N/A' } | Select-Object -First 1)
    if ($dashboardRow.Count -gt 0) { Set-IXLastNetwork -Target $dashboardRow[0].Label -AvgMs $dashboardRow[0].AvgMs -JitterMs $dashboardRow[0].JitterMs -LossPct $dashboardRow[0].LossPct }
    Write-Host 'Timing DNS lookups...' -ForegroundColor Cyan
    $dns = @(Measure-IXDnsLookup)
    return [pscustomobject]@{ Created = (Get-Date).ToString('s'); ExtraTarget = [string]$ExtraTarget; Count = $Count; Ping = $ping.ToArray(); Dns = $dns }
}

function Format-IXDelta {
    param([AllowNull()][object]$Before,[AllowNull()][object]$After)
    if ($null -eq $Before -or $null -eq $After -or [string]$Before -eq '' -or [string]$After -eq '') { return 'n/a' }
    $delta = [math]::Round(([double]$After - [double]$Before),1)
    if ($delta -gt 0) { return ('+' + $delta) }
    return [string]$delta
}

function Invoke-IXBeforeAfter {
    Show-IXHeader
    Write-IXTitle 'BEFORE / AFTER COMPARISON'
    Write-Host 'Runs the same targets with the same probe count, so two runs can be compared fairly.' -ForegroundColor DarkGray
    Write-Host 'Keep conditions the same for both runs (same downloads/streams running, same time of day if possible).' -ForegroundColor DarkGray
    $baselinePath = Join-Path $script:IXRoot 'Benchmark-baseline.json'
    Write-IXMenuItem -Key '1' -Text 'BEFORE - record a baseline'
    Write-IXMenuItem -Key '2' -Text 'AFTER  - test again and compare with the baseline'
    Write-IXRule -Thin
    $mode = Read-IXChoice 'Choose 1-2 (Enter = back)'

    if ($mode -eq '1') {
        $extra = Read-Host 'Optional extra hostname/IP, e.g. your FiveM server (Enter to skip)'
        if (-not [string]::IsNullOrWhiteSpace($extra) -and -not (Resolve-IXIPv4 -Target $extra)) {
            Write-Host 'That target could not be resolved to IPv4; it is skipped.' -ForegroundColor Yellow
            $extra = ''
        }
        $run = Invoke-IXBenchmarkRun -ExtraTarget $extra
        Write-Host ''
        $run.Ping | Select-Object Label,Resolved,Sent,Received,LossPct,AvgMs,MaxMs,JitterMs | Format-Table -AutoSize
        $run.Dns | Format-Table Name,DnsServer,Failures,AvgMs,MaxMs -AutoSize
        try {
            $run | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $baselinePath -Encoding UTF8 -ErrorAction Stop
            Write-Host ('Baseline saved: {0}' -f $baselinePath) -ForegroundColor Green
        } catch { Write-Host ('Baseline could not be saved: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        Save-IXReport -Name 'Benchmark-Before' -Lines @('InternetX baseline (BEFORE)',('Time: ' + $run.Created)) -Rows $run.Ping
        Wait-IXReturn
        return
    }
    if ($mode -ne '2') { return }

    if (-not (Test-Path -LiteralPath $baselinePath)) {
        Write-Host 'No baseline exists yet. Run [1] BEFORE first.' -ForegroundColor Yellow
        Wait-IXReturn; return
    }
    $before = $null
    try { $before = Get-Content -LiteralPath $baselinePath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
    if ($null -eq $before) { Write-Host 'The baseline file could not be read. Record a new one with [1].' -ForegroundColor Red; Wait-IXReturn; return }
    Write-Host ('Baseline from {0}. Re-testing the same targets...' -f $before.Created) -ForegroundColor Cyan
    $after = Invoke-IXBenchmarkRun -ExtraTarget ([string]$before.ExtraTarget) -Count ([int]$before.Count)

    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($now in $after.Ping) {
        $old = @($before.Ping | Where-Object { $_.Label -eq $now.Label } | Select-Object -First 1)
        $oldRow = if ($old.Count -gt 0) { $old[0] } else { $null }
        [void]$rows.Add([pscustomobject]@{
            Target = $now.Label
            AvgBefore = $(if ($oldRow) { $oldRow.AvgMs } else { $null }); AvgAfter = $now.AvgMs
            AvgDelta = Format-IXDelta -Before $(if ($oldRow) { $oldRow.AvgMs } else { $null }) -After $now.AvgMs
            JitterBefore = $(if ($oldRow) { $oldRow.JitterMs } else { $null }); JitterAfter = $now.JitterMs
            JitterDelta = Format-IXDelta -Before $(if ($oldRow) { $oldRow.JitterMs } else { $null }) -After $now.JitterMs
            LossBefore = $(if ($oldRow) { $oldRow.LossPct } else { $null }); LossAfter = $now.LossPct
        })
    }
    $dnsRows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($now in $after.Dns) {
        $old = @($before.Dns | Where-Object { $_.Name -eq $now.Name } | Select-Object -First 1)
        $oldAvg = if ($old.Count -gt 0) { $old[0].AvgMs } else { $null }
        [void]$dnsRows.Add([pscustomobject]@{ Name = $now.Name; AvgBefore = $oldAvg; AvgAfter = $now.AvgMs; Delta = Format-IXDelta -Before $oldAvg -After $now.AvgMs; FailuresAfter = $now.Failures })
    }
    Write-Host ''
    Write-Host 'PING (milliseconds; negative delta = lower after)' -ForegroundColor Cyan
    $rows | Format-Table -AutoSize
    Write-Host 'DNS LOOKUP TIME (milliseconds)' -ForegroundColor Cyan
    $dnsRows | Format-Table -AutoSize
    Write-Host 'Differences of about 2 ms or less are normal run-to-run variation, not proof of a change.' -ForegroundColor DarkGray
    Write-Host 'ICMP to public hosts is not the FiveM route; confirm in game as well.' -ForegroundColor DarkGray
    $lines = @('InternetX BEFORE / AFTER comparison',('Baseline: ' + $before.Created),('After: ' + $after.Created),('Probes per target: ' + $after.Count))
    Save-IXReport -Name 'Benchmark-Compare' -Lines $lines -Rows ($rows.ToArray())
    Wait-IXReturn
}

function Test-IXEntryRestored {
    # Reads the setting back from Windows and compares it with the recorded original.
    param([object]$Entry)
    try {
        if ([string]$Entry.Type -eq 'RSS') {
            $rss = Get-NetAdapterRss -Name $Entry.AdapterName -ErrorAction Stop | Select-Object -First 1
            return ([bool]$rss.Enabled -eq [bool]$Entry.OriginalEnabled)
        }
        $hasRegistryValue = ($Entry.PSObject.Properties['OriginalRegistryValue'] -and -not [string]::IsNullOrWhiteSpace([string]$Entry.OriginalRegistryValue) -and -not [string]::IsNullOrWhiteSpace([string]$Entry.RegistryKeyword))
        if ($hasRegistryValue) {
            return ((Get-IXAdapterRegistryValue -AdapterName $Entry.AdapterName -Keyword $Entry.RegistryKeyword) -eq [string]$Entry.OriginalRegistryValue)
        }
        $property = Get-NetAdapterAdvancedProperty -Name $Entry.AdapterName -DisplayName $Entry.DisplayName -ErrorAction Stop | Select-Object -First 1
        return ([string]$property.DisplayValue -eq [string]$Entry.OriginalDisplayValue)
    } catch { return $false }
}

# ---------------------------------------------------------------------------
# FiveM desync diagnostics: position ("warping"), hit registration ("sliding"),
# movement ("dancing"). Measurement and correlation only; nothing here sends game
# traffic, changes positions, damage or sync, or changes any system setting.
# ---------------------------------------------------------------------------
function Get-IXSeriesStats {
    param([AllowNull()][object[]]$Samples,[double]$SpikeOverMs = 20)
    $all = @($Samples)
    $rtts = New-Object 'System.Collections.Generic.List[double]'
    $diffs = New-Object 'System.Collections.Generic.List[double]'
    $outages = 0; $longestOutage = 0; $run = 0; $previous = $null
    foreach ($sample in $all) {
        $ok = ($sample.Status -eq 'Success' -and $null -ne $sample.RTTms -and [string]$sample.RTTms -ne '')
        if ($ok) {
            $value = [double]$sample.RTTms
            [void]$rtts.Add($value)
            if ($null -ne $previous) { [void]$diffs.Add([math]::Abs($value - $previous)) }
            $previous = $value
            if ($run -ge 2) { $outages++ }
            $run = 0
        } else {
            $previous = $null
            $run++
            if ($run -gt $longestOutage) { $longestOutage = $run }
        }
    }
    if ($run -ge 2) { $outages++ }
    $probes = $all.Count; $replies = $rtts.Count
    $lossPct = if ($probes -gt 0) { [math]::Round(100.0 * ($probes - $replies) / $probes,1) } else { 0.0 }
    $avg = $null; $median = $null; $p95 = $null; $max = $null; $jitter = $null; $spikes = 0
    if ($replies -gt 0) {
        $sorted = @($rtts | Sort-Object)
        $stats = $rtts | Measure-Object -Average -Maximum
        $avg = [math]::Round([double]$stats.Average,1); $max = [math]::Round([double]$stats.Maximum,1)
        $mid = [int][math]::Floor(($sorted.Count - 1) / 2)
        if (($sorted.Count % 2) -eq 1) { $median = [double]$sorted[$mid] } else { $median = ([double]$sorted[$mid] + [double]$sorted[$mid + 1]) / 2.0 }
        $p95Index = [math]::Max(0,[math]::Min([int][math]::Ceiling(0.95 * $sorted.Count) - 1,$sorted.Count - 1))
        $p95 = [math]::Round([double]$sorted[$p95Index],1)
        if ($diffs.Count -gt 0) { $jitter = [math]::Round((($diffs | Measure-Object -Average).Average),1) }
        $spikes = @($rtts | Where-Object { $_ -gt ($median + $SpikeOverMs) }).Count
        $median = [math]::Round($median,1)
    }
    return [pscustomobject]@{
        Probes = $probes; Replies = $replies; LossPct = $lossPct; AvgMs = $avg; MedianMs = $median; P95Ms = $p95; MaxMs = $max
        JitterMs = $jitter; Spikes = $spikes; Outages = $outages; LongestOutage = $longestOutage; SpikeOverMs = $SpikeOverMs
    }
}

function Get-IXDesyncModeInfo {
    param([ValidateSet('Warp','HitReg','Movement','Stability')][string]$Mode)
    switch ($Mode) {
        'Warp' {
            return @{ Title = 'POSITION DESYNC ("WARPING")'; Key = 'W'; Marker = 'Warp'
                Explain = @(
                    'Your client draws other players from position updates relayed by the server.',
                    'When updates arrive late or are lost, the client guesses, then snaps the player to the real position.',
                    'Possible causes: your own packet loss or jitter, the other player''s connection, a server hitch',
                    '(everyone warps at the same moment), or the route between you and the server.'
                ) }
        }
        'HitReg' {
            return @{ Title = 'HIT REGISTRATION DESYNC ("SLIDING")'; Key = 'H'; Marker = 'HitMiss'
                Explain = @(
                    'A hit you see is only a claim. Whether health drops is decided by the server and its scripts.',
                    'It depends on server-side validation and anticheat, weapon and damage settings, the latency of',
                    'both players, interpolation (you aim at where a player was), and your own FPS and frame time.',
                    'A clean network result here points to the server side, not to your connection.'
                ) }
        }
        'Stability' {
            return @{ Title = 'REAL-TIME STABILITY MONITOR'; Key = 'S'; Marker = 'Stutter'
                Explain = @(
                    'Records latency, jitter, packet loss, connection interruptions, DNS failures and adapter',
                    'status changes once per second, with timestamps, and highlights spikes.',
                    'It measures your connection only. It cannot see server tick rate or server-side positions.'
                ) }
        }
        'Movement' {
            return @{ Title = 'MOVEMENT DESYNC ("DANCING")'; Key = 'D'; Marker = 'Dancing'
                Explain = @(
                    'Sliding, stuttering or out-of-sync animation means movement updates are arriving unevenly.',
                    'Possible causes: jitter on your connection, low or unstable client FPS in crowded areas,',
                    'or server load when many players are close together.'
                ) }
        }
    }
}

function Get-IXDesyncAnalysis {
    # Pure analysis of recorded samples. Thresholds are heuristics, not proof of cause.
    param(
        [string]$Mode,[AllowNull()][object[]]$ExtraEvents,[AllowNull()][object[]]$Rows,[AllowNull()][object[]]$SystemRows,[AllowNull()][object[]]$Markers,
        [AllowNull()][object]$AdapterDelta,[AllowNull()][hashtable]$Context
    )
    if ($null -eq $Context) { $Context = @{} }
    $rowList = @($Rows); $systemList = @($SystemRows); $markerList = @($Markers)
    $targets = New-Object 'System.Collections.Generic.List[object]'
    $badCycles = @{ Local = @{}; Route = @{}; Server = @{}; Client = @{} }
    $events = New-Object 'System.Collections.Generic.List[object]'
    # Adapter status changes and DNS failures recorded by the session.
    $adapterEvents = 0; $dnsFailures = 0
    foreach ($extra in @($ExtraEvents)) {
        if ($null -eq $extra) { continue }
        [void]$events.Add([pscustomobject]@{ Timestamp = $extra.Timestamp; Cycle = [int]$extra.Cycle; Area = [string]$extra.Area; Target = [string]$extra.Target; Event = [string]$extra.Event; RTTms = $null })
        if ([string]$extra.Area -eq 'Local') { $adapterEvents++; $badCycles.Local[[int]$extra.Cycle] = $true } elseif ([string]$extra.Area -eq 'DNS') { $dnsFailures++ }
    }

    foreach ($group in @($rowList | Group-Object Label)) {
        $samples = @($group.Group | Sort-Object { [int]$_.Cycle })
        $layer = [string]$samples[0].Layer
        $spikeOver = if ($layer -eq 'Gateway') { 10 } else { 20 }
        $stats = Get-IXSeriesStats -Samples $samples -SpikeOverMs $spikeOver
        $responsive = ($stats.Replies -gt 0)
        $bad = $false
        if ($responsive) {
            if ($layer -eq 'Gateway') { $bad = ($stats.LossPct -ge 1 -or ($null -ne $stats.JitterMs -and $stats.JitterMs -ge 5) -or $stats.Spikes -ge 3 -or $stats.Outages -ge 1) }
            else { $bad = ($stats.LossPct -ge 2 -or ($null -ne $stats.JitterMs -and $stats.JitterMs -ge 10) -or $stats.Spikes -ge [math]::Max(3,[int]($stats.Probes * 0.02)) -or $stats.Outages -ge 1) }
            $area = switch ($layer) { 'Gateway' { 'Local' } 'Internet' { 'Route' } default { 'Server' } }
            foreach ($sample in $samples) {
                $failed = ($sample.Status -ne 'Success')
                $spiked = (-not $failed -and $null -ne $stats.MedianMs -and [double]$sample.RTTms -gt ($stats.MedianMs + $spikeOver))
                if ($failed -or $spiked) {
                    $badCycles[$area][[int]$sample.Cycle] = $true
                    [void]$events.Add([pscustomobject]@{
                        Timestamp = $sample.Timestamp; Cycle = [int]$sample.Cycle; Area = $area; Target = $group.Name
                        Event = $(if ($failed) { 'No reply (' + $sample.Status + ')' } else { 'Latency spike' }); RTTms = $sample.RTTms
                    })
                }
            }
        }
        [void]$targets.Add([pscustomobject]@{
            Label = $group.Name; Layer = $layer; Kind = [string]$samples[0].Kind; Responsive = $responsive; Unstable = $bad
            Probes = $stats.Probes; Replies = $stats.Replies; LossPct = $stats.LossPct; AvgMs = $stats.AvgMs; MedianMs = $stats.MedianMs
            P95Ms = $stats.P95Ms; MaxMs = $stats.MaxMs; JitterMs = $stats.JitterMs; Spikes = $stats.Spikes; Outages = $stats.Outages; LongestOutage = $stats.LongestOutage
        })
    }

    # Client load
    $cpuValues = @($systemList | Where-Object { $null -ne $_.CpuPct -and [string]$_.CpuPct -ne '' } | ForEach-Object { [double]$_.CpuPct })
    $cpuAvg = $null; $cpuMax = $null; $cpuHighPct = $null
    if ($cpuValues.Count -gt 0) {
        $cpuStats = $cpuValues | Measure-Object -Average -Maximum
        $cpuAvg = [math]::Round([double]$cpuStats.Average,0); $cpuMax = [math]::Round([double]$cpuStats.Maximum,0)
        $cpuHighPct = [math]::Round(100.0 * @($cpuValues | Where-Object { $_ -ge 90 }).Count / $cpuValues.Count,1)
        foreach ($sample in $systemList) {
            if ($null -ne $sample.CpuPct -and [string]$sample.CpuPct -ne '' -and [double]$sample.CpuPct -ge 90) {
                $badCycles.Client[[int]$sample.Cycle] = $true
                [void]$events.Add([pscustomobject]@{ Timestamp = $sample.Timestamp; Cycle = [int]$sample.Cycle; Area = 'Client'; Target = 'This PC'; Event = 'CPU at or above 90%'; RTTms = $null })
            }
        }
    }
    $gameSeen = (@($systemList | Where-Object { $_.FiveMRunning -eq $true -or [string]$_.FiveMRunning -eq 'True' }).Count -gt 0)

    # Symptom markers: was anything unstable in the 4 seconds before (or 1 second after) each one?
    $markerSummary = [ordered]@{ Local = 0; Route = 0; Server = 0; Client = 0; None = 0 }
    $markerDetails = New-Object 'System.Collections.Generic.List[object]'
    foreach ($marker in $markerList) {
        $match = 'None'
        foreach ($area in @('Local','Route','Server','Client')) {
            $hit = $false
            for ($cycle = ([int]$marker.Cycle - 4); $cycle -le ([int]$marker.Cycle + 1); $cycle++) { if ($badCycles[$area].ContainsKey($cycle)) { $hit = $true; break } }
            if ($hit) { $match = $area; break }
        }
        $markerSummary[$match] = [int]$markerSummary[$match] + 1
        [void]$markerDetails.Add([pscustomobject]@{ Timestamp = $marker.Timestamp; Cycle = [int]$marker.Cycle; Type = $marker.Type; CoincidesWith = $match })
        [void]$events.Add([pscustomobject]@{ Timestamp = $marker.Timestamp; Cycle = [int]$marker.Cycle; Area = 'Marker'; Target = 'You'; Event = ('Symptom marked: ' + $marker.Type); RTTms = $null })
    }

    $gatewayTargets = @($targets | Where-Object { $_.Layer -eq 'Gateway' })
    $internetTargets = @($targets | Where-Object { $_.Layer -eq 'Internet' -and $_.Responsive })
    $serverTargets = @($targets | Where-Object { $_.Layer -eq 'Server' -and $_.Responsive })
    $nicErrors = 0
    if ($null -ne $AdapterDelta) { $nicErrors = [long]$AdapterDelta.ReceivedErrors + [long]$AdapterDelta.ReceivedDiscards + [long]$AdapterDelta.OutboundErrors + [long]$AdapterDelta.OutboundDiscards }
    $localBad = (@($gatewayTargets | Where-Object { $_.Unstable }).Count -gt 0) -or ($nicErrors -gt 0) -or ($adapterEvents -gt 0)
    $internetBad = @($internetTargets | Where-Object { $_.Unstable })
    $serverBad = @($serverTargets | Where-Object { $_.Unstable })
    $clientBad = ($null -ne $cpuHighPct -and $cpuHighPct -ge 10)
    $cycles = @($rowList | ForEach-Object { [int]$_.Cycle } | Sort-Object -Unique).Count

    $findings = New-Object 'System.Collections.Generic.List[object]'
    if ($localBad) {
        $evidence = @()
        foreach ($target in @($gatewayTargets | Where-Object { $_.Unstable })) { $evidence += ('router {0}: loss {1}%, jitter {2} ms, {3} spike(s), {4} outage(s)' -f $target.Label,$target.LossPct,$target.JitterMs,$target.Spikes,$target.Outages) }
        if ($nicErrors -gt 0) { $evidence += ('the adapter counted {0} error/discarded packet(s) during the session' -f $nicErrors) }
        if ($adapterEvents -gt 0) { $evidence += ('the adapter changed state or link speed {0} time(s) during the session' -f $adapterEvents) }
        $fixes = @()
        if ($Context.IsWifi) { $fixes += 'You are on Wi-Fi: test with a network cable. This usually matters more than any setting.' }
        else { $fixes += 'Try another cable and another router port, then re-test.' }
        $fixes += 'Pause downloads, streams and cloud backups on every device on your network and re-test.'
        $fixes += 'Restart the router. If the gateway stays unstable, the router or its line is the suspect.'
        if ($nicErrors -gt 0) { $fixes += 'Adapter errors point to cable, port or driver: replace the cable and update the adapter driver.' }
        if ($null -ne $Context.InterfaceMtu -and [int]$Context.InterfaceMtu -gt 1500) { $fixes += ('Interface MTU is {0} (jumbo). Apply menu 9, then run the MTU test (menu 3).' -f $Context.InterfaceMtu) }
        $fixes += 'Menu 9 (Low Ping / Low Jitter profile) is reasonable here; compare with menu 2 > 4 before and after.'
        [void]$findings.Add([pscustomobject]@{ Area = 'Local network (PC, cable or Wi-Fi, router)'; Evidence = ($evidence -join '; '); Fixes = $fixes })
    }
    if ($internetBad.Count -gt 0) {
        $evidence = @($internetBad | ForEach-Object { '{0}: loss {1}%, jitter {2} ms, {3} spike(s), {4} outage(s)' -f $_.Label,$_.LossPct,$_.JitterMs,$_.Spikes,$_.Outages }) -join '; '
        if ($localBad) {
            [void]$findings.Add([pscustomobject]@{ Area = 'Internet path (cannot be separated yet)'; Evidence = $evidence; Fixes = @('Fix the local network finding first, then re-test. Problems at the router also show up on every target behind it.') })
        } else {
            [void]$findings.Add([pscustomobject]@{ Area = 'ISP / internet route'; Evidence = ('router is steady, but ' + $evidence); Fixes = @(
                'This is beyond your router. Adapter tuning is not supported by this evidence.',
                'Re-test at another time of day; evening-only problems suggest ISP congestion.',
                'Send the exported report to your ISP. A test over a different connection (e.g. a phone hotspot) can confirm it.'
            ) })
        }
    }
    if ($serverBad.Count -gt 0 -and -not $localBad -and $internetBad.Count -eq 0) {
        $evidence = @($serverBad | ForEach-Object { '{0}: loss {1}%, jitter {2} ms, {3} spike(s), {4} outage(s)' -f $_.Label,$_.LossPct,$_.JitterMs,$_.Spikes,$_.Outages }) -join '; '
        [void]$findings.Add([pscustomobject]@{ Area = 'Game server or the route to it'; Evidence = ('router and public targets are steady, but ' + $evidence); Fixes = @(
            'Your own connection looks fine in this sample. Settings on your PC are not supported by this evidence.',
            'Compare with another FiveM server. If only this server is affected, send the exported report to its staff.',
            'Ask other players whether they see the same thing at the same time.'
        ) })
    }
    if ($clientBad) {
        [void]$findings.Add([pscustomobject]@{ Area = 'Client performance (FPS / frame time)'; Evidence = ('CPU was at or above 90% in {0}% of samples (average {1}%, peak {2}%)' -f $cpuHighPct,$cpuAvg,$cpuMax); Fixes = @(
            'A saturated CPU makes frame time uneven, which looks like stutter and hurts aim and hit timing.',
            'Close background apps (browsers, recorders, overlays) and cap FPS slightly below what you can hold.',
            'Lower Extended Distance Scaling, Population Density and Variety in the game graphics settings.',
            'In the FiveM F8 console, "cl_drawperf true" shows FPS and frame time while you play.'
        ) })
    }
    if ($dnsFailures -gt 0) {
        [void]$findings.Add([pscustomobject]@{ Area = 'DNS lookups'; Evidence = ('{0} of {1} DNS check(s) failed during the session' -f $dnsFailures,$Context.DnsChecks); Fixes = @(
            'DNS is used when connecting and loading, not for in-game movement or hits, so this does not explain desync by itself.',
            'If joining servers is slow or fails, restart the router or ask your ISP. InternetX does not change DNS settings.'
        ) })
    }
    $onlyDns = ($findings.Count -eq 1 -and $dnsFailures -gt 0)
    if ($findings.Count -eq 0 -or $onlyDns) {
        $fixes = @(
            'No instability was measured on your side in this sample, so changing PC settings is not supported.',
            'Likely areas: server tick and resource load, server scripts and validation, the other player''s connection, or normal interpolation.',
            'This needs server-side data: txAdmin performance chart, "hitch warning" lines in the server console, resmon on the server.',
            'If many players warp or stutter at the same moment, it is the server.'
        )
        if ($null -ne $Context.ServerClients -and $null -ne $Context.ServerMax -and [int]$Context.ServerMax -gt 0 -and ([double]$Context.ServerClients / [double]$Context.ServerMax) -ge 0.8) {
            $fixes += ('The server reported {0}/{1} players: load-related desync is plausible, but only server metrics can confirm it.' -f $Context.ServerClients,$Context.ServerMax)
        }
        [void]$findings.Add([pscustomobject]@{ Area = 'No network or client fault seen in this sample'; Evidence = 'router, public targets, server endpoint (if it answered) and CPU all stayed within the thresholds'; Fixes = $fixes })
    }

    $notes = @()
    if ($cycles -lt 60) { $notes += ('Short sample ({0} cycles). Run at least 5 minutes while the symptom happens.' -f $cycles) }
    if ($markerList.Count -eq 0) { $notes += 'No symptom markers were recorded, so timing cannot be correlated. Press the marker key when it happens.' }
    if (@($targets | Where-Object { $_.Layer -eq 'Server' }).Count -eq 0) { $notes += 'No server endpoint was given, so the server and its route were not measured.' }
    elseif ($serverTargets.Count -eq 0) { $notes += 'The server endpoint did not answer ping or TCP, so it could not be measured from here.' }
    if ($cpuValues.Count -eq 0) { $notes += 'CPU load could not be read on this system.' }
    if (-not $gameSeen) { $notes += 'FiveM was not running during the session; run it while playing for a meaningful result.' }

    return [pscustomobject]@{
        Mode = $Mode; Cycles = $cycles; Targets = $targets.ToArray(); Findings = $findings.ToArray(); Notes = $notes
        Markers = $markerList.Count; MarkerSummary = $markerSummary; MarkerDetails = $markerDetails.ToArray()
        CpuAvg = $cpuAvg; CpuMax = $cpuMax; CpuHighPct = $cpuHighPct; GameSeen = $gameSeen
        AdapterDelta = $AdapterDelta; Context = $Context
        AdapterEvents = $adapterEvents; DnsFailures = $dnsFailures; Events = @($events | Sort-Object { [int]$_.Cycle },Timestamp)
    }
}

function Get-IXDesyncReportLines {
    param([object]$Analysis)
    $info = Get-IXDesyncModeInfo -Mode $Analysis.Mode
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('InternetX desync diagnostic: ' + $info.Title)
    [void]$lines.Add(('Generated: {0} | sampling cycles: {1}' -f (Get-Date -Format 's'),$Analysis.Cycles))
    [void]$lines.Add('')
    [void]$lines.Add('WHAT THIS SYMPTOM USUALLY MEANS')
    foreach ($text in $info.Explain) { [void]$lines.Add('  ' + $text) }
    [void]$lines.Add('')
    [void]$lines.Add('MEASUREMENTS (milliseconds)')
    [void]$lines.Add(('  {0,-24} {1,-8} {2,6} {3,6} {4,6} {5,6} {6,6} {7,6} {8,6} {9,6} {10,7}' -f 'Target','Layer','Probes','Loss%','Avg','Median','P95','Max','Jitter','Spikes','Outages'))
    foreach ($target in $Analysis.Targets) {
        if ($target.Responsive) {
            [void]$lines.Add(('  {0,-24} {1,-8} {2,6} {3,6} {4,6} {5,6} {6,6} {7,6} {8,6} {9,6} {10,7}{11}' -f $target.Label,$target.Layer,$target.Probes,$target.LossPct,$target.AvgMs,$target.MedianMs,$target.P95Ms,$target.MaxMs,$target.JitterMs,$target.Spikes,$target.Outages,$(if ($target.Unstable) { '  <-- unstable' } else { '' })))
        } else {
            [void]$lines.Add(('  {0,-24} {1,-8} {2,6}  no replies (blocked or unreachable; not counted as loss)' -f $target.Label,$target.Layer,$target.Probes))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('THIS PC')
    if ($null -ne $Analysis.CpuAvg) { [void]$lines.Add(('  CPU average {0}%, peak {1}%, at or above 90% in {2}% of samples' -f $Analysis.CpuAvg,$Analysis.CpuMax,$Analysis.CpuHighPct)) }
    else { [void]$lines.Add('  CPU load: not available') }
    [void]$lines.Add('  FiveM game process seen: ' + $(if ($Analysis.GameSeen) { 'yes' } else { 'no' }))
    [void]$lines.Add(('  Adapter status or link-speed changes: {0}' -f $Analysis.AdapterEvents))
    if ($null -ne $Analysis.Context.DnsChecks) { [void]$lines.Add(('  DNS checks: {0}, failed: {1}' -f $Analysis.Context.DnsChecks,$Analysis.DnsFailures)) }
    if ($null -ne $Analysis.AdapterDelta) {
        [void]$lines.Add(('  Adapter counters during session: receive errors {0}, receive discards {1}, send errors {2}, send discards {3}' -f $Analysis.AdapterDelta.ReceivedErrors,$Analysis.AdapterDelta.ReceivedDiscards,$Analysis.AdapterDelta.OutboundErrors,$Analysis.AdapterDelta.OutboundDiscards))
    }
    if ($null -ne $Analysis.Context.ServerClients) { [void]$lines.Add(('  Server reported players: {0}/{1}' -f $Analysis.Context.ServerClients,$Analysis.Context.ServerMax)) }
    [void]$lines.Add('  FPS and frame time cannot be read from outside the game. Use "cl_drawperf true" in the F8 console.')
    [void]$lines.Add('')
    [void]$lines.Add(('SYMPTOM MARKERS: {0}' -f $Analysis.Markers))
    if ($Analysis.Markers -gt 0) {
        [void]$lines.Add(('  Within 4 s before each marker there was: local network trouble {0}, internet route trouble {1}, server endpoint trouble {2}, CPU saturation {3}, nothing measured {4}' -f $Analysis.MarkerSummary.Local,$Analysis.MarkerSummary.Route,$Analysis.MarkerSummary.Server,$Analysis.MarkerSummary.Client,$Analysis.MarkerSummary.None))
        [void]$lines.Add('  Coinciding in time is not proof of cause.')
    }
    [void]$lines.Add('')
    [void]$lines.Add('FINDINGS')
    foreach ($finding in $Analysis.Findings) {
        [void]$lines.Add('  [' + $finding.Area + ']')
        [void]$lines.Add('    Evidence: ' + $finding.Evidence)
        foreach ($fix in $finding.Fixes) { [void]$lines.Add('    - ' + $fix) }
    }
    if (@($Analysis.Notes).Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('NOTES')
        foreach ($note in $Analysis.Notes) { [void]$lines.Add('  - ' + $note) }
    }
    [void]$lines.Add('')
    [void]$lines.Add('NOT MEASURABLE FROM A CLIENT PC (needs the server owner)')
    [void]$lines.Add('  - Server tick rate, hitch warnings and per-resource CPU time')
    [void]$lines.Add('  - The server-authoritative position of a player compared with what your client drew')
    [void]$lines.Add('  - Whether a server script or anticheat rejected a hit')
    [void]$lines.Add('')
    [void]$lines.Add('LIMITS: ping (ICMP) and TCP connect time are not FiveM game traffic. Thresholds are heuristics.')
    [void]$lines.Add('Network tuning cannot be promised to remove desync.')
    return $lines.ToArray()
}

function Get-IXNicState {
    # Fast link check through .NET (no cmdlet call per second): 'Up 1000 Mbps', 'Down', ...
    param([object]$Adapter)
    try {
        $nic = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.Id -eq [string]$Adapter.InterfaceGuid } | Select-Object -First 1
        if ($nic) {
            if ($nic.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up) { return ('Up {0} Mbps' -f [int]($nic.Speed / 1000000)) }
            return [string]$nic.OperationalStatus
        }
    } catch { }
    return 'Unknown'
}

function Get-IXFiveMProcess {
    try {
        return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^FiveM.*(GTAProcess|GameProcess)' } | Sort-Object WorkingSet64 -Descending | Select-Object -First 1)[0]
    } catch { return $null }
}

function Get-IXFiveMServerInfo {
    # Standard public FiveM endpoint; read-only.
    param([string]$HostName,[int]$Port)
    try {
        $data = Invoke-RestMethod -Uri ('http://{0}:{1}/dynamic.json' -f $HostName,$Port) -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        if ($null -ne $data.clients) { return [pscustomobject]@{ Clients = [int]$data.clients; Max = [int]$data.sv_maxclients } }
    } catch { }
    return $null
}

function Get-IXAdapterCounters {
    param([object]$Adapter)
    try {
        $stats = Get-NetAdapterStatistics -Name $Adapter.Name -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{ ReceivedErrors = [long]$stats.ReceivedPacketErrors; ReceivedDiscards = [long]$stats.ReceivedDiscardedPackets; OutboundErrors = [long]$stats.OutboundPacketErrors; OutboundDiscards = [long]$stats.OutboundDiscardedPackets }
    } catch { return $null }
}

function Read-IXMarkerKeys {
    # Returns the letters pressed since the last call (empty when the host has no keyboard).
    $keys = @()
    try {
        while ($Host.UI.RawUI.KeyAvailable) {
            $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            $char = ([string]$keyInfo.Character).ToUpperInvariant()
            if ($char -match '^[A-Z]$') { $keys += $char }
        }
    } catch { }
    return $keys
}

function Invoke-IXDesyncSession {
    param([ValidateSet('Warp','HitReg','Movement','Stability')][string]$Mode)
    $info = Get-IXDesyncModeInfo -Mode $Mode
    Show-IXHeader
    Write-IXTitle $info.Title -Advanced
    foreach ($text in $info.Explain) { Write-Host ('  ' + $text) -ForegroundColor DarkGray }
    Write-Host 'This only measures and records. It changes no settings and sends nothing to the game.' -ForegroundColor DarkGray
    Write-Host ''

    $adapter = Get-IXPrimaryAdapter
    if (-not $adapter) { Write-Host 'No active network adapter found.' -ForegroundColor Red; Wait-IXReturn; return }
    $targets = New-Object 'System.Collections.Generic.List[object]'
    $gateway = Get-IXIPv4Gateway
    if ($gateway) { [void]$targets.Add([pscustomobject]@{ Label = 'Gateway ' + $gateway; Layer = 'Gateway'; IP = $gateway }) }
    else { Write-Host 'No IPv4 gateway found; the local network cannot be separated from the internet path.' -ForegroundColor Yellow }
    foreach ($ip in @('1.1.1.1','8.8.8.8')) { [void]$targets.Add([pscustomobject]@{ Label = $ip; Layer = 'Internet'; IP = $ip }) }

    $serverHost = $null; $serverIP = $null; $serverPort = 30120
    $serverText = (Read-Host 'FiveM server IP or hostname, optionally :port (Enter to skip; cfx.re/join links do not work)').Trim()
    if ($serverText -ne '') {
        if ($serverText -match '^([A-Za-z0-9.-]+)(?::(\d{1,5}))?$') {
            $serverHost = $Matches[1]
            if ($Matches[2]) { $serverPort = [int]$Matches[2] }
            $serverIP = Resolve-IXIPv4 -Target $serverHost
        }
        if (-not $serverIP -or $serverPort -lt 1 -or $serverPort -gt 65535) {
            Write-Host 'That address could not be used; continuing without a server endpoint.' -ForegroundColor Yellow
            $serverIP = $null
        } elseif (@($targets | Where-Object { $_.IP -eq $serverIP }).Count -eq 0) {
            [void]$targets.Add([pscustomobject]@{ Label = 'Server ' + $serverIP; Layer = 'Server'; IP = $serverIP })
        }
    }
    $durationText = (Read-Host 'Duration in seconds [60/120/300/600] (Enter = 300)').Trim()
    $duration = 300
    if (@('60','120','300','600') -contains $durationText) { $duration = [int]$durationText }

    $isWifi = ($adapter.Name -match 'Wi-?Fi|Wireless|WLAN') -or ($adapter.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11')
    $context = @{ IsWifi = $isWifi; InterfaceMtu = (Get-IXInterfaceMtu -Adapter $adapter); ServerClients = $null; ServerMax = $null }
    if ($serverIP) {
        $serverInfo = Get-IXFiveMServerInfo -HostName $serverHost -Port $serverPort
        if ($serverInfo) { $context.ServerClients = $serverInfo.Clients; $context.ServerMax = $serverInfo.Max; Write-Host ('Server reports {0}/{1} players.' -f $serverInfo.Clients,$serverInfo.Max) -ForegroundColor Gray }
        else { Write-Host 'The server did not return player information (this is optional).' -ForegroundColor DarkGray }
    }
    $cpuCounter = $null
    try { $cpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor','% Processor Time','_Total'); [void]$cpuCounter.NextValue() } catch { $cpuCounter = $null }
    $countersBefore = Get-IXAdapterCounters -Adapter $adapter
    $extraEvents = New-Object 'System.Collections.Generic.List[object]'
    $nicState = Get-IXNicState -Adapter $adapter
    $dnsServer = $null; $dnsJob = $null; $dnsChecks = 0
    try { $dnsServer = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses | Where-Object { $_ })[0] } catch { }
    $dnsNames = @('cfx.re','fivem.net','www.cloudflare.com')
    $cores = [math]::Max(1,[Environment]::ProcessorCount)
    $game = Get-IXFiveMProcess
    $gameCpuLast = $null; $gameStampLast = $null
    if (-not $game) { Write-Host 'FiveM is not running yet. Start it and play while this runs.' -ForegroundColor Yellow }

    Write-Host ''
    Write-Host ('Recording for {0}s. Play normally. Keys:  {1} = mark this symptom   F = FPS stutter   Q = stop' -f $duration,$info.Key) -ForegroundColor Green
    Write-Host '(W = warp, H = hit not registered, D = sliding / dancing, S = lag or stutter are all accepted.)' -ForegroundColor DarkGray
    Write-Host ''

    $markerTypes = @{ 'W' = 'Warp'; 'H' = 'HitMiss'; 'D' = 'Dancing'; 'F' = 'FpsStutter'; 'S' = 'Stutter' }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $systemRows = New-Object 'System.Collections.Generic.List[object]'
    $markers = New-Object 'System.Collections.Generic.List[object]'
    $start = Get-Date; $end = $start.AddSeconds($duration)
    $cycle = 0; $stop = $false
    while ((Get-Date) -lt $end -and -not $stop) {
        $cycle++
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $stamp = Get-Date
        $stampText = $stamp.ToString('yyyy-MM-dd HH:mm:ss.fff')
        $pending = New-Object 'System.Collections.Generic.List[object]'
        foreach ($target in $targets) {
            $pinger = $null
            try {
                $pinger = New-Object System.Net.NetworkInformation.Ping
                [void]$pending.Add([pscustomobject]@{ Target = $target; Pinger = $pinger; Task = $pinger.SendPingAsync([string]$target.IP,800) })
            } catch {
                if ($pinger) { $pinger.Dispose() }
                [void]$rows.Add([pscustomobject]@{ Timestamp = $stampText; Cycle = $cycle; Layer = $target.Layer; Label = $target.Label; Kind = 'ICMP'; Status = 'Error'; RTTms = $null })
            }
        }
        $parts = @(); $trouble = $false
        # TCP connect time to the game port: the server itself answers this even when it ignores ping.
        if ($serverIP -and ($cycle % 2) -eq 1) {
            $tcpStatus = 'Error'; $tcpMs = $null
            $client = New-Object System.Net.Sockets.TcpClient
            $tcpWatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $connect = $client.ConnectAsync($serverIP,$serverPort)
                if ($connect.Wait(800) -and $client.Connected) { $tcpWatch.Stop(); $tcpStatus = 'Success'; $tcpMs = [math]::Round($tcpWatch.Elapsed.TotalMilliseconds,1) }
                else { $tcpStatus = 'Timeout' }
            } catch { $tcpStatus = 'Refused' }
            finally { try { $client.Close() } catch { } }
            [void]$rows.Add([pscustomobject]@{ Timestamp = $stampText; Cycle = $cycle; Layer = 'Server'; Label = ('Server TCP :' + $serverPort); Kind = 'TCP'; Status = $tcpStatus; RTTms = $tcpMs })
            if ($tcpStatus -eq 'Success') { $parts += ('TCP {0}ms' -f $tcpMs) } else { $parts += ('TCP ' + $tcpStatus) }
        }
        foreach ($item in $pending) {
            $status = 'Error'; $rtt = $null
            try {
                if ($item.Task.Wait(1200)) {
                    $status = [string]$item.Task.Result.Status
                    if ($item.Task.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $rtt = [double]$item.Task.Result.RoundtripTime }
                } else { $status = 'Timeout' }
            } catch { $status = 'Error' }
            finally { try { $item.Pinger.Dispose() } catch { } }
            [void]$rows.Add([pscustomobject]@{ Timestamp = $stampText; Cycle = $cycle; Layer = $item.Target.Layer; Label = $item.Target.Label; Kind = 'ICMP'; Status = $status; RTTms = $rtt })
            $short = switch ($item.Target.Layer) { 'Gateway' { 'GW' } 'Server' { 'SRV' } default { $item.Target.IP } }
            if ($status -eq 'Success') { $parts += ('{0} {1}ms' -f $short,$rtt) } else { $parts += ('{0} --' -f $short); if ($item.Target.Layer -ne 'Server') { $trouble = $true } }
        }

        $cpu = $null
        if ($cpuCounter) { try { $cpu = [math]::Round([double]$cpuCounter.NextValue(),0) } catch { $cpu = $null } }
        $gameCpu = $null; $gameMemory = $null
        if (-not $game -and ($cycle % 10) -eq 0) { $game = Get-IXFiveMProcess }
        if ($game) {
            try {
                $game.Refresh()
                if ($game.HasExited) { $game = $null; $gameCpuLast = $null }
                else {
                    $cpuNow = $game.TotalProcessorTime.TotalMilliseconds
                    if ($null -ne $gameCpuLast) {
                        $elapsed = ($stamp - $gameStampLast).TotalMilliseconds
                        if ($elapsed -gt 0) { $gameCpu = [math]::Round(100.0 * ($cpuNow - $gameCpuLast) / $elapsed / $cores,0) }
                    }
                    $gameCpuLast = $cpuNow; $gameStampLast = $stamp
                    $gameMemory = [math]::Round($game.WorkingSet64 / 1MB,0)
                }
            } catch { $game = $null; $gameCpuLast = $null }
        }
        [void]$systemRows.Add([pscustomobject]@{ Timestamp = $stampText; Cycle = $cycle; CpuPct = $cpu; FiveMRunning = [bool]$game; FiveMCpuPct = $gameCpu; FiveMMemoryMB = $gameMemory })
        if ($null -ne $cpu) { $parts += ('CPU {0}%' -f $cpu); if ($cpu -ge 90) { $trouble = $true } }
        # Adapter link state: a flap or renegotiated speed is a local-network event.
        $nicNow = Get-IXNicState -Adapter $adapter
        if ($nicNow -ne $nicState) {
            [void]$extraEvents.Add([pscustomobject]@{ Timestamp = $stampText; Cycle = $cycle; Area = 'Local'; Target = [string]$adapter.Name; Event = ('Adapter changed: {0} -> {1}' -f $nicState,$nicNow) })
            Clear-IXLive
            Write-Host ('[{0}] adapter changed: {1} -> {2}' -f $stamp.ToString('HH:mm:ss'),$nicState,$nicNow) -ForegroundColor Yellow
            $nicState = $nicNow
        }
        # DNS check every 15 seconds on a background runspace, so a slow lookup cannot stall sampling.
        if ($dnsServer -and -not $dnsJob -and ($cycle % 15) -eq 1) {
            try {
                $runner = [powershell]::Create()
                [void]$runner.AddScript('param($n,$s) try { Resolve-DnsName -Name $n -Type A -Server $s -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null; ''ok'' } catch { ''fail: '' + $_.Exception.Message }').AddArgument($dnsNames[$dnsChecks % $dnsNames.Count]).AddArgument([string]$dnsServer)
                $dnsJob = @{ Runner = $runner; Handle = $runner.BeginInvoke(); Name = $dnsNames[$dnsChecks % $dnsNames.Count]; Cycle = $cycle }
            } catch { $dnsJob = $null }
        }
        if ($dnsJob -and ($dnsJob.Handle.IsCompleted -or ($cycle - $dnsJob.Cycle) -ge 8)) {
            $outcome = 'fail: no answer within 8 seconds'
            if ($dnsJob.Handle.IsCompleted) {
                try { $outcome = [string](@($dnsJob.Runner.EndInvoke($dnsJob.Handle))[0]) } catch { $outcome = 'fail: ' + $_.Exception.Message }
                try { $dnsJob.Runner.Dispose() } catch { }
            } else { try { [void]$dnsJob.Runner.BeginStop($null,$null) } catch { } }
            $dnsChecks++
            if ($outcome -ne 'ok') {
                [void]$extraEvents.Add([pscustomobject]@{ Timestamp = $stampText; Cycle = $cycle; Area = 'DNS'; Target = [string]$dnsJob.Name; Event = ('DNS lookup failed (' + $outcome + ')') })
                Clear-IXLive
                Write-Host ('[{0}] DNS lookup of {1} failed' -f $stamp.ToString('HH:mm:ss'),$dnsJob.Name) -ForegroundColor Yellow
            }
            $dnsJob = $null
        }
        # Healthy cycles rewrite one status line; only trouble and markers stay on screen.
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if ($trouble) {
            Clear-IXLive
            Write-Host ('[{0}] {1}' -f $stamp.ToString('HH:mm:ss'),($parts -join ' | ')) -ForegroundColor Yellow
        } else {
            Write-IXLive -Text (' {0} {1,3}/{2}s marks {4} | {3}' -f (Get-IXProgressBar -Done $elapsed -Total $duration -Cells 10),$elapsed,$duration,($parts -join ' | '),$markers.Count)
        }

        # Keep listening for marker keys until the next one-second cycle.
        do {
            foreach ($key in @(Read-IXMarkerKeys)) {
                if ($key -eq 'Q') { $stop = $true }
                elseif ($markerTypes.ContainsKey($key)) {
                    [void]$markers.Add([pscustomobject]@{ Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'); Cycle = $cycle; Type = $markerTypes[$key] })
                    Clear-IXLive
                    Write-Host ('[{0}] marker: {1} ({2} total)' -f (Get-Date -Format 'HH:mm:ss'),$markerTypes[$key],$markers.Count) -ForegroundColor Magenta
                }
            }
            if ($stop -or $watch.ElapsedMilliseconds -ge 1000) { break }
            Start-Sleep -Milliseconds 50
        } while ($true)
    }
    if ($cpuCounter) { try { $cpuCounter.Dispose() } catch { } }
    Clear-IXLive
    Write-IXOk ('Recording finished: {0} cycle(s), {1} marker(s).' -f $cycle,$markers.Count)

    $delta = $null
    $countersAfter = Get-IXAdapterCounters -Adapter $adapter
    if ($countersBefore -and $countersAfter) {
        $delta = [pscustomobject]@{
            ReceivedErrors = [math]::Max(0,$countersAfter.ReceivedErrors - $countersBefore.ReceivedErrors); ReceivedDiscards = [math]::Max(0,$countersAfter.ReceivedDiscards - $countersBefore.ReceivedDiscards)
            OutboundErrors = [math]::Max(0,$countersAfter.OutboundErrors - $countersBefore.OutboundErrors); OutboundDiscards = [math]::Max(0,$countersAfter.OutboundDiscards - $countersBefore.OutboundDiscards)
        }
    }
    if ($dnsJob) { try { [void]$dnsJob.Runner.BeginStop($null,$null) } catch { } }
    if ($dnsServer) { $context.DnsChecks = $dnsChecks }
    $analysis = Get-IXDesyncAnalysis -Mode $Mode -ExtraEvents $extraEvents.ToArray() -Rows $rows.ToArray() -SystemRows $systemRows.ToArray() -Markers $markers.ToArray() -AdapterDelta $delta -Context $context
    $lines = @(Get-IXDesyncReportLines -Analysis $analysis)
    $public = @($analysis.Targets | Where-Object { $_.Layer -eq 'Internet' -and $_.Responsive } | Select-Object -First 1)
    if ($public.Count -gt 0) { Set-IXLastNetwork -Target $public[0].Label -AvgMs $public[0].AvgMs -JitterMs $public[0].JitterMs -LossPct $public[0].LossPct }
    Write-Host ''
    foreach ($line in $lines) {
        $color = 'Gray'
        if ($line -match '^[A-Z][A-Z ()/:0-9"]+$' -or $line -match '^SYMPTOM MARKERS') { $color = 'Cyan' }
        elseif ($line -match 'unstable|^\s+\[') { $color = 'Yellow' }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ''
    Save-IXReport -Name ('Desync-' + $Mode + '-Summary') -Lines $lines -Rows $analysis.Targets
    Save-IXReport -Name ('Desync-' + $Mode + '-Samples') -Lines @('Timestamped network samples for the session above.') -Rows ($rows.ToArray())
    Save-IXReport -Name ('Desync-' + $Mode + '-System') -Lines @('Timestamped CPU / FiveM process samples for the session above.') -Rows ($systemRows.ToArray())
    if (@($analysis.Events).Count -gt 0) { Save-IXReport -Name ('Desync-' + $Mode + '-EventLog') -Lines @('Timestamped event log: network failures, latency spikes, CPU saturation and your symptom markers.') -Rows $analysis.Events }
    Wait-IXReturn
}

function Export-IXDiagnosticReport {
    Show-IXHeader
    Write-IXTitle 'EXPORT DIAGNOSTIC REPORT'
    Write-Host 'Collects adapter settings, InternetX changes and the latest test summaries into one text file.' -ForegroundColor DarkGray
    Write-Host 'It contains your adapter names and local IP addresses. Read it before you send it to anyone.' -ForegroundColor DarkGray
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('InternetX v2.7 full diagnostic report')
    [void]$lines.Add('Generated: ' + (Get-Date -Format 's'))
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; [void]$lines.Add(('Windows: {0} (build {1})' -f $os.Caption,$os.BuildNumber)) } catch { }
    $adapter = Get-IXPrimaryAdapter
    if ($adapter) {
        [void]$lines.Add('')
        [void]$lines.Add('NETWORK ADAPTER ANALYSIS (primary adapter only)')
        [void]$lines.Add(('  {0} | {1} | link {2} | driver {3} ({4})' -f $adapter.Name,$adapter.InterfaceDescription,$adapter.LinkSpeed,$adapter.DriverVersion,$adapter.DriverDate))
        [void]$lines.Add(('  Gateway: {0} | interface MTU (IPv4): {1}' -f (Get-IXIPv4Gateway),(Get-IXInterfaceMtu -Adapter $adapter)))
        try { $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop; [void]$lines.Add('  DNS servers: ' + (@($dns.ServerAddresses) -join ', ')) } catch { }
        try { $rss = Get-NetAdapterRss -Name $adapter.Name -ErrorAction Stop | Select-Object -First 1; if ($rss) { [void]$lines.Add(('  RSS: enabled={0}, queues={1}, profile={2}' -f $rss.Enabled,$rss.NumberOfReceiveQueues,$rss.Profile)) } } catch { [void]$lines.Add('  RSS: not exposed') }
        $counters = Get-IXAdapterCounters -Adapter $adapter
        if ($counters) { [void]$lines.Add(('  Counters since adapter start: receive errors {0}, receive discards {1}, send errors {2}, send discards {3}' -f $counters.ReceivedErrors,$counters.ReceivedDiscards,$counters.OutboundErrors,$counters.OutboundDiscards)) }
        [void]$lines.Add('  Driver properties (current values):')
        try {
            foreach ($property in @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop | Where-Object { [string]$_.RegistryKeyword -ne 'NetworkAddress' } | Sort-Object DisplayName)) {
                [void]$lines.Add(('    {0,-36} = {1}' -f $property.DisplayName,$property.DisplayValue))
            }
        } catch { [void]$lines.Add('    could not be read') }
        $plan = @(Get-IXLowPingPlan -Adapter $adapter)
        [void]$lines.Add(('  Low Ping / Low Jitter profile would propose {0} change(s) on this adapter.' -f $plan.Count))
        foreach ($item in $plan) { [void]$lines.Add(('    {0}: {1} -> {2}' -f $item.DisplayName,$item.OriginalDisplayValue,$item.TargetDisplayValue)) }
    } else {
        [void]$lines.Add('No active default-route adapter was found.')
    }
    [void]$lines.Add('')
    [void]$lines.Add('TCP GLOBAL SETTINGS')
    foreach ($text in @(& netsh.exe interface tcp show global 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -ne '' })) { [void]$lines.Add('  ' + $text) }
    [void]$lines.Add('')
    [void]$lines.Add('INTERNETX CHANGES STILL ACTIVE (menu 4 > Restore undoes these)')
    Load-IXState
    $active = @($script:IXState.Entries | Where-Object { $_.Status -in @('Applied','Pending') })
    if ($active.Count -eq 0) { [void]$lines.Add('  none') }
    foreach ($entry in $active) { [void]$lines.Add(('  {0} | {1} | {2} | original: {3}' -f $entry.Type,$entry.AdapterName,$entry.DisplayName,$(if ([string]$entry.Type -eq 'RSS') { $entry.OriginalEnabled } else { $entry.OriginalDisplayValue }))) }

    $included = 0
    foreach ($pattern in @('Desync-Warp-Summary_*.txt','Desync-HitReg-Summary_*.txt','Desync-Movement-Summary_*.txt','Benchmark-Compare_*.txt','Path-MTU_*.txt','Ping-Jitter-Loss_*.txt')) {
        $file = Get-ChildItem -LiteralPath $script:IXReportDir -Filter $pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $file) { continue }
        [void]$lines.Add('')
        [void]$lines.Add(('===== LATEST {0} ({1}) =====' -f $file.Name,$file.LastWriteTime.ToString('s')))
        try { foreach ($text in @(Get-Content -LiteralPath $file.FullName -ErrorAction Stop)) { [void]$lines.Add([string]$text) }; $included++ } catch { [void]$lines.Add('  could not be read') }
    }
    if ($included -eq 0) { [void]$lines.Add(''); [void]$lines.Add('No test summaries exist yet. Run the desync monitors (menu D) or menu 2 first.') }
    Save-IXReport -Name 'Full-Diagnostic-Report' -Lines $lines.ToArray() -Rows $null
    Write-Host ('{0} earlier test summary file(s) included.' -f $included) -ForegroundColor Gray
    Wait-IXReturn
}

function Invoke-IXDesyncMenu {
    while ($true) {
        Show-IXHeader
        Write-IXTitle 'FIVEM DESYNC DIAGNOSTICS' -Advanced
        Write-Host 'Run one of these while you play and press the marker key each time the symptom happens.' -ForegroundColor DarkGray
        Write-IXMenuItem -Key '1' -Text 'Position desync - "warping"' -Hint 'players snap or jump' -Kind Advanced
        Write-IXMenuItem -Key '2' -Text 'Hit registration - "sliding"' -Hint 'hits do not reduce health' -Kind Advanced
        Write-IXMenuItem -Key '3' -Text 'Movement desync - "dancing"' -Hint 'players slide or stutter' -Kind Advanced
        Write-IXMenuItem -Key '4' -Text 'Export full diagnostic report' -Hint 'one text file'
        Write-IXMenuItem -Key '5' -Text 'Troubleshooting guide' -Hint 'read-only'
        Write-IXMenuItem -Key '0' -Text 'Back to main menu' -Kind Exit
        Write-IXRule -Thin
        $choice = Read-IXChoice 'Choose 0-5'
        switch ($choice) {
            '1' { Invoke-IXDesyncSession -Mode 'Warp' }
            '2' { Invoke-IXDesyncSession -Mode 'HitReg' }
            '3' { Invoke-IXDesyncSession -Mode 'Movement' }
            '4' { Export-IXDiagnosticReport }
            '5' { Show-IXDesyncGuide }
            '0' { return }
            default { Write-IXErr 'Invalid choice. Enter 0-5.'; Start-Sleep -Milliseconds 900 }
        }
    }
}

# ---------------------------------------------------------------------------
# EXTREME LOW PING / LOW JITTER PROFILE (menu 9): baseline, stability profile,
# real-time monitor, before/after verdict, troubleshooting guide, restore.
# "Extreme" means thorough measurement and verification, not maximum values.
# ---------------------------------------------------------------------------
function Read-IXServerEndpoint {
    # Returns @{ Host; IP; Port } or $null. Only used for ping and a TCP connect to the game port.
    $text = ([string](Read-Host 'FiveM server IP or hostname, optionally :port (Enter to skip; cfx.re/join links do not work)')).Trim()
    if ($text -eq '') { return $null }
    if ($text -match '^([A-Za-z0-9.-]+)(?::(\d{1,5}))?$') {
        $serverHost = $Matches[1]
        $port = 30120
        if ($Matches[2]) { $port = [int]$Matches[2] }
        $ip = Resolve-IXIPv4 -Target $serverHost
        if ($ip -and $port -ge 1 -and $port -le 65535) { return @{ Host = $serverHost; IP = $ip; Port = $port } }
    }
    Write-IXWarn 'That address could not be used; continuing without a server endpoint.'
    return $null
}

function Measure-IXTcpConnect {
    # Time to open a TCP connection to the game port. A server that ignores ping still answers this.
    param([string]$IP,[int]$Port,[int]$Attempts = 10)
    $times = New-Object 'System.Collections.Generic.List[double]'
    $failures = 0
    for ($i = 0; $i -lt $Attempts; $i++) {
        $client = New-Object System.Net.Sockets.TcpClient
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $connect = $client.ConnectAsync($IP,$Port)
            if ($connect.Wait(1000) -and $client.Connected) { $watch.Stop(); [void]$times.Add($watch.Elapsed.TotalMilliseconds) } else { $failures++ }
        } catch { $failures++ }
        finally { try { $client.Close() } catch { } }
        if ($i -lt ($Attempts - 1)) { Start-Sleep -Milliseconds 200 }
    }
    $min = $null; $avg = $null; $max = $null
    if ($times.Count -gt 0) {
        $stats = $times | Measure-Object -Minimum -Average -Maximum
        $min = [math]::Round([double]$stats.Minimum,1); $avg = [math]::Round([double]$stats.Average,1); $max = [math]::Round([double]$stats.Maximum,1)
    }
    return [pscustomobject]@{ Label = ('TCP {0}:{1}' -f $IP,$Port); Attempts = $Attempts; Failures = $failures; MinMs = $min; AvgMs = $avg; MaxMs = $max }
}

function Get-IXLossInterpretation {
    # Pure logic: separates "this host does not answer ping" from loss, as far as the evidence allows.
    param([AllowNull()][object[]]$Ping,[AllowNull()][object]$Tcp)
    $rows = @($Ping)
    $result = New-Object 'System.Collections.Generic.List[object]'
    $gateway = @($rows | Where-Object { $_.Label -eq 'Gateway' } | Select-Object -First 1)
    $gatewayLossy = ($gateway.Count -gt 0 -and [int]$gateway[0].Received -gt 0 -and [int]$gateway[0].Lost -gt 0)
    $anyReply = (@($rows | Where-Object { [int]$_.Received -gt 0 }).Count -gt 0)
    foreach ($row in $rows) {
        $isPublic = @('1.1.1.1','8.8.8.8') -contains [string]$row.Label
        $isGateway = ([string]$row.Label -eq 'Gateway')
        $verdict = 'No loss'; $role = 'Ok'; $text = 'Every probe was answered.'
        if ([string]$row.Resolved -eq 'N/A') {
            $verdict = 'Not resolved'; $role = 'Warn'; $text = 'The name could not be resolved to an IPv4 address, so nothing was measured.'
        } elseif ([int]$row.Received -eq 0) {
            $tcpAnswers = ($null -ne $Tcp -and [int]$Tcp.Failures -lt [int]$Tcp.Attempts)
            if (-not $isPublic -and -not $isGateway -and $tcpAnswers) {
                $verdict = 'Ping filtered'; $role = 'Text'; $text = 'The server answers TCP on its game port but not ping, so it filters ping. This is not packet loss.'
            } elseif ($anyReply) {
                $verdict = 'No ping replies'; $role = 'Warn'; $text = 'Nothing came back while other targets answered. Ping is probably filtered, or the host is down. Not counted as loss.'
            } else {
                $verdict = 'No connectivity'; $role = 'Err'; $text = 'No target answered at all: the connection was down during the test.'
            }
        } elseif ([int]$row.Lost -gt 0) {
            $otherLossy = @($rows | Where-Object { $_.Label -ne $row.Label -and $_.Label -ne 'Gateway' -and [int]$_.Received -gt 0 -and [int]$_.Lost -gt 0 }).Count
            if ($isGateway) { $verdict = 'Loss on local network'; $role = 'Warn'; $text = 'Your own router missed replies: look at the cable or Wi-Fi and the router first.' }
            elseif ($gatewayLossy) { $verdict = 'Loss (local suspected)'; $role = 'Warn'; $text = 'The router also missed replies, so the loss probably starts on your local network.' }
            elseif ($otherLossy -gt 0) { $verdict = 'Packet loss'; $role = 'Warn'; $text = 'Several targets missed replies while the router was clean: real loss beyond your router is likely.' }
            else { $verdict = 'Loss or rate limit'; $role = 'Warn'; $text = 'Only this target missed replies. It may limit ping replies rather than your line losing packets; repeat the test.' }
        }
        [void]$result.Add([pscustomobject]@{ Label = [string]$row.Label; Verdict = $verdict; Role = $role; Text = $text })
    }
    return $result.ToArray()
}

function Get-IXComparisonVerdict {
    # Pure logic. A difference only counts when it is larger than normal run-to-run variation.
    param([AllowNull()][object]$Before,[AllowNull()][object]$After)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $improved = 0; $worsened = 0
    foreach ($now in @($After.Ping)) {
        $oldMatch = @(@($Before.Ping) | Where-Object { $_.Label -eq $now.Label } | Select-Object -First 1)
        $latency = 'Inconclusive'; $jitter = 'Inconclusive'; $loss = 'Inconclusive'
        if ($oldMatch.Count -gt 0) {
            $old = $oldMatch[0]
            $sameProbes = ([int]$old.Sent -eq [int]$now.Sent)
            if ($sameProbes -and $null -ne $old.AvgMs -and $null -ne $now.AvgMs -and [string]$old.AvgMs -ne '' -and [string]$now.AvgMs -ne '') {
                $delta = [double]$now.AvgMs - [double]$old.AvgMs
                $threshold = [math]::Max(2.0,0.10 * [double]$old.AvgMs)
                $latency = if ($delta -le -$threshold) { 'Improved' } elseif ($delta -ge $threshold) { 'Worsened' } else { 'No clear change' }
            }
            if ($sameProbes -and $null -ne $old.JitterMs -and $null -ne $now.JitterMs -and [string]$old.JitterMs -ne '' -and [string]$now.JitterMs -ne '') {
                $delta = [double]$now.JitterMs - [double]$old.JitterMs
                $threshold = [math]::Max(2.0,0.50 * [double]$old.JitterMs)
                $jitter = if ($delta -le -$threshold) { 'Improved' } elseif ($delta -ge $threshold) { 'Worsened' } else { 'No clear change' }
            }
            # A target that never answered in either run says nothing about loss.
            if ($sameProbes -and ([int]$old.Received -gt 0 -or [int]$now.Received -gt 0)) {
                $delta = [int]$now.Lost - [int]$old.Lost
                $loss = if ($delta -le -2) { 'Improved' } elseif ($delta -ge 2) { 'Worsened' } else { 'No clear change' }
            }
        }
        foreach ($value in @($latency,$jitter,$loss)) { if ($value -eq 'Improved') { $improved++ } elseif ($value -eq 'Worsened') { $worsened++ } }
        [void]$rows.Add([pscustomobject]@{ Target = [string]$now.Label; Latency = $latency; Jitter = $jitter; PacketLoss = $loss })
    }
    $overall = 'No clear change (within normal variation)'; $role = 'Text'
    if ($rows.Count -eq 0) { $overall = 'Inconclusive (nothing comparable was measured)'; $role = 'Warn' }
    # One reading out of many can move because of a single stray spike, so it is not a verdict.
    elseif (($improved + $worsened) -eq 1) { $overall = 'No clear change (one isolated difference; repeat the test)'; $role = 'Text' }
    elseif ($improved -gt 0 -and $worsened -eq 0) { $overall = 'Improved'; $role = 'Ok' }
    elseif ($worsened -gt 0 -and $improved -eq 0) { $overall = 'Worsened'; $role = 'Err' }
    elseif ($improved -gt 0 -and $worsened -gt 0) { $overall = 'Mixed (some better, some worse)'; $role = 'Warn' }
    return [pscustomobject]@{ Rows = $rows.ToArray(); Overall = $overall; Role = $role; Improved = $improved; Worsened = $worsened }
}

function Invoke-IXExtremeMeasure {
    param([AllowNull()][hashtable]$Endpoint,[int]$Count = 60)
    $serverHost = ''
    if ($Endpoint) { $serverHost = [string]$Endpoint.Host }
    $run = Invoke-IXBenchmarkRun -ExtraTarget $serverHost -Count $Count
    $tcp = $null
    if ($Endpoint) {
        Write-Host ('Timing TCP connect to {0}:{1}...' -f $Endpoint.IP,$Endpoint.Port) -ForegroundColor Cyan
        $tcp = Measure-IXTcpConnect -IP $Endpoint.IP -Port $Endpoint.Port
    }
    $adapterInfo = $null
    $adapter = Get-IXPrimaryAdapter
    if ($adapter) {
        $rules = Get-IXLowPingRules
        $watched = @($rules.TurnOff.Keys) + @($rules.BufferFloor.Keys) + @($rules.Optional.Keys)
        $settings = @()
        try { $settings = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop | Where-Object { $watched -contains [string]$_.RegistryKeyword } | ForEach-Object { '{0} = {1}' -f $_.DisplayName,$_.DisplayValue }) } catch { }
        $isWifi = ($adapter.Name -match 'Wi-?Fi|Wireless|WLAN') -or ($adapter.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11')
        $adapterInfo = [pscustomobject]@{ Name = [string]$adapter.Name; Description = [string]$adapter.InterfaceDescription; LinkSpeed = [string]$adapter.LinkSpeed; Type = $(if ($isWifi) { 'Wi-Fi' } else { 'Ethernet' }); Mtu = (Get-IXInterfaceMtu -Adapter $adapter); Settings = $settings }
    }
    $run | Add-Member -NotePropertyName ServerPort -NotePropertyValue $(if ($Endpoint) { [int]$Endpoint.Port } else { 0 }) -Force
    $run | Add-Member -NotePropertyName Tcp -NotePropertyValue $tcp -Force
    $run | Add-Member -NotePropertyName Adapter -NotePropertyValue $adapterInfo -Force
    $run | Add-Member -NotePropertyName Interpretation -NotePropertyValue @(Get-IXLossInterpretation -Ping $run.Ping -Tcp $tcp) -Force
    return $run
}

function Show-IXMeasure {
    param([object]$Run,[string]$Heading = 'MEASUREMENT')
    Write-Host ''
    Write-IXSection $Heading
    if ($Run.Adapter) {
        Write-IXStatus -Label 'Adapter' -Value ('{0} ({1})' -f $Run.Adapter.Name,$Run.Adapter.Description)
        Write-IXStatus -Label 'Connection' -Value ('{0}, link {1}, IPv4 MTU {2}' -f $Run.Adapter.Type,$Run.Adapter.LinkSpeed,$(if ($null -ne $Run.Adapter.Mtu) { $Run.Adapter.Mtu } else { 'unknown' })) -Role $(if ($Run.Adapter.Type -eq 'Wi-Fi' -or ($null -ne $Run.Adapter.Mtu -and [int]$Run.Adapter.Mtu -gt 1500)) { 'Warn' } else { 'Text' })
        foreach ($setting in @($Run.Adapter.Settings)) { Write-Host ('      ' + $setting) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-IXSection ('LATENCY / JITTER / LOSS  ({0} probes per target, milliseconds)' -f $Run.Count)
    $Run.Ping | Select-Object Label,Resolved,Sent,Received,LossPct,MinMs,AvgMs,MaxMs,JitterMs | Format-Table -AutoSize | Out-Host
    Write-Host '  Jitter = average absolute difference between consecutive successful replies.' -ForegroundColor DarkGray
    if ($Run.Tcp) {
        Write-IXStatus -Label 'Server TCP' -Value ('{0}: min {1} / avg {2} / max {3} ms, {4} of {5} failed' -f $Run.Tcp.Label,$Run.Tcp.MinMs,$Run.Tcp.AvgMs,$Run.Tcp.MaxMs,$Run.Tcp.Failures,$Run.Tcp.Attempts) -Role $(if ([int]$Run.Tcp.Failures -gt 0) { 'Warn' } else { 'Text' })
    }
    Write-Host ''
    Write-IXSection 'PACKET LOSS: WHAT THE EVIDENCE SAYS'
    foreach ($item in @($Run.Interpretation)) {
        Write-IXStatus -Label $item.Label -Value $item.Verdict -Role $item.Role -LabelWidth 22
        if ($item.Verdict -ne 'No loss') { Write-IXWrapped -Text $item.Text -Indent 6 -Role 'Muted' }
    }
    Write-Host ''
    Write-IXSection 'DNS RESOLUTION'
    $Run.Dns | Format-Table Name,DnsServer,Attempts,Failures,AvgMs,MaxMs -AutoSize | Out-Host
}

function Get-IXMeasureLines {
    param([object]$Run,[string]$Heading)
    $lines = @($Heading,('Time: ' + $Run.Created),('Probes per target: ' + $Run.Count),'Jitter = average absolute difference between consecutive successful replies.')
    if ($Run.Adapter) { $lines += ('Adapter: {0} ({1}); {2}; link {3}; IPv4 MTU {4}' -f $Run.Adapter.Name,$Run.Adapter.Description,$Run.Adapter.Type,$Run.Adapter.LinkSpeed,$Run.Adapter.Mtu); foreach ($setting in @($Run.Adapter.Settings)) { $lines += ('  ' + $setting) } }
    foreach ($row in @($Run.Ping)) { $lines += ('Ping {0} ({1}): sent {2}, received {3}, loss {4}%, min {5}, avg {6}, max {7}, jitter {8}' -f $row.Label,$row.Resolved,$row.Sent,$row.Received,$row.LossPct,$row.MinMs,$row.AvgMs,$row.MaxMs,$row.JitterMs) }
    if ($Run.Tcp) { $lines += ('{0}: min {1}, avg {2}, max {3} ms, {4} of {5} failed' -f $Run.Tcp.Label,$Run.Tcp.MinMs,$Run.Tcp.AvgMs,$Run.Tcp.MaxMs,$Run.Tcp.Failures,$Run.Tcp.Attempts) }
    foreach ($item in @($Run.Interpretation)) { $lines += ('Loss reading {0}: {1}. {2}' -f $item.Label,$item.Verdict,$item.Text) }
    foreach ($row in @($Run.Dns)) { $lines += ('DNS {0} via {1}: {2} of {3} failed, avg {4} ms, max {5} ms' -f $row.Name,$row.DnsServer,$row.Failures,$row.Attempts,$row.AvgMs,$row.MaxMs) }
    return $lines
}

function Invoke-IXExtremeBaseline {
    Show-IXHeader
    Write-IXTitle 'BASELINE DIAGNOSTICS (read-only)'
    Write-Host ' Measures your connection before anything is changed and saves it as the baseline.' -ForegroundColor DarkGray
    Write-Host ' Takes about one minute. Keep your usual apps running so the later comparison is fair.' -ForegroundColor DarkGray
    $endpoint = Read-IXServerEndpoint
    $run = Invoke-IXExtremeMeasure -Endpoint $endpoint
    Show-IXMeasure -Run $run -Heading 'BASELINE'
    $baselinePath = Join-Path $script:IXRoot 'Benchmark-baseline.json'
    try {
        $run | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $baselinePath -Encoding UTF8 -ErrorAction Stop
        Write-IXOk ('Baseline saved: ' + $baselinePath)
    } catch { Write-IXErr ('Baseline could not be saved: ' + $_.Exception.Message) }
    Save-IXReport -Name 'Extreme-Baseline' -Lines (Get-IXMeasureLines -Run $run -Heading 'InternetX EXTREME profile: baseline (BEFORE)') -Rows $run.Ping
}

function Invoke-IXExtremeCompare {
    # Re-runs the baseline's targets with the same probe count and reports a verdict.
    Show-IXHeader
    Write-IXTitle 'AFTER TEST: COMPARE WITH BASELINE (read-only)'
    $baselinePath = Join-Path $script:IXRoot 'Benchmark-baseline.json'
    $before = $null
    if (Test-Path -LiteralPath $baselinePath) { try { $before = Get-Content -LiteralPath $baselinePath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { } }
    if ($null -eq $before) { Write-IXWarn 'No readable baseline exists yet. Run the baseline first.'; return }
    Write-Host (' Baseline from {0}. Re-testing the same targets with {1} probes each...' -f $before.Created,$before.Count) -ForegroundColor DarkGray
    $endpoint = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$before.ExtraTarget)) {
        $ip = Resolve-IXIPv4 -Target ([string]$before.ExtraTarget)
        $port = 30120
        if ($before.PSObject.Properties['ServerPort'] -and [int]$before.ServerPort -gt 0) { $port = [int]$before.ServerPort }
        if ($ip) { $endpoint = @{ Host = [string]$before.ExtraTarget; IP = $ip; Port = $port } }
    }
    $after = Invoke-IXExtremeMeasure -Endpoint $endpoint -Count ([int]$before.Count)
    Show-IXMeasure -Run $after -Heading 'AFTER'
    $verdict = Get-IXComparisonVerdict -Before $before -After $after
    Write-IXSection 'BEFORE -> AFTER'
    $table = foreach ($now in @($after.Ping)) {
        $old = @(@($before.Ping) | Where-Object { $_.Label -eq $now.Label } | Select-Object -First 1)
        $oldRow = if ($old.Count -gt 0) { $old[0] } else { $null }
        $judged = @($verdict.Rows | Where-Object { $_.Target -eq $now.Label } | Select-Object -First 1)
        [pscustomobject]@{
            Target = $now.Label
            Avg = ('{0} -> {1}' -f $(if ($oldRow) { $oldRow.AvgMs } else { '?' }),$now.AvgMs); Latency = $(if ($judged.Count -gt 0) { $judged[0].Latency } else { 'Inconclusive' })
            Jit = ('{0} -> {1}' -f $(if ($oldRow) { $oldRow.JitterMs } else { '?' }),$now.JitterMs); Jitter = $(if ($judged.Count -gt 0) { $judged[0].Jitter } else { 'Inconclusive' })
            Lost = ('{0} -> {1}' -f $(if ($oldRow) { $oldRow.Lost } else { '?' }),$now.Lost); PacketLoss = $(if ($judged.Count -gt 0) { $judged[0].PacketLoss } else { 'Inconclusive' })
        }
    }
    $table | Format-Table -AutoSize | Out-Host
    Write-IXStatus -Label 'Overall' -Value $verdict.Overall -Role $verdict.Role
    Write-Host '  A change only counts when it is larger than normal variation: latency by 2 ms or 10%,' -ForegroundColor DarkGray
    Write-Host '  jitter by 2 ms or 50%, loss by 2 probes, and on more than one reading.' -ForegroundColor DarkGray
    Write-Host '  Ping to public hosts is not the FiveM route; confirm in game as well.' -ForegroundColor DarkGray
    if ($verdict.Overall -like 'Worsened*' -or $verdict.Overall -like 'Mixed*') { Write-IXWarn 'To undo the profile: menu 9 > 7 (Restore InternetX changes).' }
    $lines = @(Get-IXMeasureLines -Run $after -Heading 'InternetX EXTREME profile: AFTER test') + @(('Baseline time: ' + $before.Created),('Overall verdict: ' + $verdict.Overall))
    foreach ($row in $verdict.Rows) { $lines += ('Verdict {0}: latency {1}; jitter {2}; packet loss {3}' -f $row.Target,$row.Latency,$row.Jitter,$row.PacketLoss) }
    Save-IXReport -Name 'Extreme-Compare' -Lines $lines -Rows @($table)
}

function Wait-IXNetwork {
    # After an adapter restart: wait until the router answers again (up to the limit).
    param([int]$Seconds = 45)
    $deadline = (Get-Date).AddSeconds($Seconds)
    $pinger = New-Object System.Net.NetworkInformation.Ping
    try {
        while ((Get-Date) -lt $deadline) {
            $gateway = Get-IXIPv4Gateway
            if ($gateway) {
                try { if ($pinger.Send($gateway,800).Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { Clear-IXLive; return $true } } catch { }
            }
            Write-IXLive -Text (' Waiting for the network to come back... {0}s left' -f [int]($deadline - (Get-Date)).TotalSeconds)
            Start-Sleep -Milliseconds 800
        }
    } finally { $pinger.Dispose() }
    Clear-IXLive
    return $false
}

function Invoke-IXExtremeGuided {
    Show-IXHeader
    Write-IXTitle 'EXTREME PROFILE - GUIDED RUN'
    Write-Host ' Step 1  Baseline test (read-only, about one minute)' -ForegroundColor Gray
    Write-Host ' Step 2  Stability profile: preview, then apply only if you type YES' -ForegroundColor Gray
    Write-Host ' Step 3  Adapter restart so the driver uses the new values' -ForegroundColor Gray
    Write-Host ' Step 4  The same test again, with a verdict: improved, worsened or no clear change' -ForegroundColor Gray
    Write-Host ' Close FiveM first: step 3 drops the connection for a few seconds.' -ForegroundColor Yellow
    Write-Host ' No result is promised. Ping, loss and desync depend mostly on your ISP route and the server.' -ForegroundColor DarkGray
    if (-not (Test-IXAdmin)) { Write-IXErr 'Administrator permission required.'; Wait-IXReturn; return }
    $go = ([string](Read-Host 'Type GO to start, or Enter to go back')).Trim()
    if ($go -cne 'GO') { return }

    Invoke-IXExtremeBaseline
    [void](Read-Host 'Baseline done. Press Enter for the profile preview (nothing is changed yet)')

    $script:IXLastProfileResult = $null
    Invoke-IXLowPingProfile
    $result = $script:IXLastProfileResult
    Show-IXHeader
    Write-IXTitle 'EXTREME PROFILE - GUIDED RUN'
    if ($null -eq $result -or [int]$result.Applied -eq 0) {
        Write-IXInfo 'No setting was changed, so there is nothing to compare. The baseline stays saved.'
        Wait-IXReturn; return
    }
    if (-not $result.Restarted) {
        Write-IXWarn 'The adapter has not been restarted, so the driver is still using the old values.'
        $restart = ([string](Read-Host 'Type RESTART to restart it now, or Enter to test anyway')).Trim()
        if ($restart -ceq 'RESTART') {
            try { Restart-NetAdapter -Name $result.AdapterName -Confirm:$false -ErrorAction Stop; $result.Restarted = $true; Write-IXOk 'Adapter restarted.' }
            catch { Write-IXErr ('Adapter restart failed: ' + $_.Exception.Message) }
        }
    }
    if ($result.Restarted) {
        if (Wait-IXNetwork) { Write-IXOk 'Network is back.'; Start-Sleep -Seconds 5 }
        else { Write-IXErr 'The router did not answer within 45 seconds. Check the connection; menu 9 > 7 restores the old values.'; Wait-IXReturn; return }
    } else {
        Write-IXWarn 'Testing without a restart: the comparison may show no change for that reason alone.'
    }
    Invoke-IXExtremeCompare
    Wait-IXReturn
}

function Get-IXDesyncGuideLines {
    return @(
        'PLAYERS APPEAR TO TELEPORT (warping)',
        '  Measure : menu D > 1 while playing; press W each time.',
        '  Yours   : loss, jitter or spikes on the router or internet targets at the same moments.',
        '  Server  : everyone warps at once, or your measurements stay clean. Needs the server''s hitch warnings.',
        '  Try     : cable instead of Wi-Fi, stop downloads, menu 9 profile; then compare.',
        '',
        'MOVEMENT SLIDES OR STUTTERS (dancing)',
        '  Measure : menu D > 3 in a crowded area; press D each time.',
        '  Yours   : jitter above about 10 ms, or CPU at 90% or more.',
        '  Server  : worse only when many players are near, with a clean network. That is server load.',
        '  Try     : cap FPS, lower Extended Distance Scaling and population settings.',
        '',
        'HITS DO NOT REGISTER',
        '  Measure : menu D > 2 during fights; press H each time.',
        '  Yours   : spikes or loss in the seconds before the marker; unstable FPS.',
        '  Server  : clean network and steady FPS. The server and its scripts decide damage, not your PC.',
        '  Note    : both players'' latency counts. A clean result on your side is still useful to report.',
        '',
        'HIGH LATENCY DURING COMBAT',
        '  Measure : menu 9 > 4 (stability monitor) through a fight.',
        '  Yours   : router latency rises too. Something on your network is using the line (uploads, streams).',
        '  Route   : router steady, public targets rise. That is the ISP path; tuning will not fix it.',
        '  Server  : only the server endpoint rises.',
        '',
        'FPS DROPS THAT LOOK LIKE LAG',
        '  Measure : F8 console "cl_drawperf true"; menu D sessions record CPU load.',
        '  Tell    : ping stays flat while the picture stutters. That is frame time, not network.',
        '  Try     : close overlays and recorders, cap FPS, lower graphics. Network tuning does not help here.',
        '',
        'SERVER PERFORMANCE PROBLEMS',
        '  Signs   : all players affected together; worse at peak player counts; your tests are clean.',
        '  Needs   : server-side data only the owner has: txAdmin performance chart, hitch warnings, resmon.',
        '  Do      : export a report (menu D > 4) and send it to the server staff with the times.',
        '',
        'InternetX measures your side. It cannot read server tick rate or a player''s server-side position,',
        'and it cannot change positions, damage or hit registration.'
    )
}

function Show-IXDesyncGuide {
    Show-IXHeader
    Write-IXTitle 'FIVEM DESYNC TROUBLESHOOTING GUIDE' -Advanced
    foreach ($line in @(Get-IXDesyncGuideLines)) {
        if ($line -cmatch '^[A-Z][A-Z ]{5,}') { Write-IXSection $line }
        elseif ($line -match '^\S') { Write-Host (' ' + $line) -ForegroundColor DarkGray }
        elseif ($line -match '^\s+(Measure|Tell|Signs)') { Write-Host (' ' + $line) -ForegroundColor Gray }
        elseif ($line -match '^\s+(Server|Route|Needs)') { Write-Host (' ' + $line) -ForegroundColor Magenta }
        else { Write-Host (' ' + $line) -ForegroundColor Gray }
    }
    Wait-IXReturn
}

function Invoke-IXExtremeMenu {
    while ($true) {
        Show-IXHeader
        Write-IXTitle 'EXTREME LOW PING / LOW JITTER PROFILE'
        Write-Host ' Measure first, change only what the evidence and the driver support, verify, compare.' -ForegroundColor DarkGray
        Write-IXMenuItem -Key '1' -Text 'Guided run: baseline > profile > verify > compare' -Hint 'changes after YES' -Kind Apply
        Write-IXMenuItem -Key '2' -Text 'Baseline diagnostics only' -Hint 'read-only'
        Write-IXMenuItem -Key '3' -Text 'Stability profile: preview / apply' -Hint 'changes after YES' -Kind Apply
        Write-IXMenuItem -Key '4' -Text 'Real-time stability monitor' -Hint 'read-only'
        Write-IXMenuItem -Key '5' -Text 'After test: compare with baseline' -Hint 'read-only'
        Write-IXMenuItem -Key '6' -Text 'Desync troubleshooting guide' -Hint 'read-only' -Kind Advanced
        Write-IXMenuItem -Key '7' -Text 'Restore InternetX changes' -Hint 'verified rollback'
        Write-IXMenuItem -Key '0' -Text 'Back to main menu' -Kind Exit
        Write-IXRule -Thin
        $choice = Read-IXChoice 'Choose 0-7'
        switch ($choice) {
            '1' { Invoke-IXExtremeGuided }
            '2' { Invoke-IXExtremeBaseline; Wait-IXReturn }
            '3' { Invoke-IXLowPingProfile }
            '4' { Invoke-IXDesyncSession -Mode 'Stability' }
            '5' { Invoke-IXExtremeCompare; Wait-IXReturn }
            '6' { Show-IXDesyncGuide }
            '7' { Invoke-IXRestore }
            '0' { return }
            default { Write-IXErr ('"{0}" is not an option here. Enter 0-7.' -f $choice); Start-Sleep -Milliseconds 1200 }
        }
    }
}

# ---------------------------------------------------------------------------
# Network Adapter Tweaker (GUI window)
# Every value is read live from Windows, so reopening the window shows what is
# really set. Applied values are stored by Windows itself (driver registry /
# persistent store) and are also written to a profile file for re-applying.
# ---------------------------------------------------------------------------
$script:IXT = $null

function Add-IXTLog {
    param([string]$Message)
    Write-IXLog ('Tweaker GUI: ' + $Message)
    try {
        if ($script:IXT -and $script:IXT.LogBox) {
            $script:IXT.LogBox.AppendText(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'),$Message) + [Environment]::NewLine)
        }
    } catch { }
}

function ConvertTo-IXTNumber {
    param([string]$Text)
    $number = 0
    if (-not [int]::TryParse(([string]$Text).Trim(),[ref]$number) -or $number -lt 0) {
        throw ('"{0}" is not a valid whole number (0 or higher)' -f $Text)
    }
    return $number
}

function Get-IXTRegValue {
    param([string]$Path,[string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return [string]$item.$Name
    } catch { return '' }
}

function Set-IXTRegDword {
    # Blank text removes the value so Windows falls back to its built-in default.
    param([string]$Path,[string]$Name,[string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        if (Test-Path -LiteralPath $Path) {
            try { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop } catch [System.Management.Automation.PSArgumentException] { }
        }
        return
    }
    $number = ConvertTo-IXTNumber -Text $Text
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value $number -Force -ErrorAction Stop | Out-Null
}

function Get-IXTClassKey {
    param([object]$Adapter)
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}'
    try {
        foreach ($key in @(Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue)) {
            if ($key.PSChildName -notmatch '^\d{4}$') { continue }
            $guid = Get-IXTRegValue -Path $key.PSPath -Name 'NetCfgInstanceId'
            if ($guid -and $guid -eq [string]$Adapter.InterfaceGuid) { return [string]$key.Name }
        }
    } catch { }
    return $null
}

function Get-IXTInterruptPath {
    param([object]$Adapter)
    $pnp = [string]$Adapter.PnPDeviceID
    if ($pnp -notlike 'PCI\*') { return $null }
    $deviceParameters = 'HKLM:\SYSTEM\CurrentControlSet\Enum\{0}\Device Parameters' -f $pnp
    if (Test-Path -LiteralPath $deviceParameters) { return (Join-Path $deviceParameters 'Interrupt Management') }
    return $null
}

function Get-IXTProfilePath {
    param([object]$Adapter,[ValidateSet('Profile','Original')][string]$Kind)
    $safeName = ([string]$Adapter.InterfaceDescription -replace '[^A-Za-z0-9_-]','_')
    $folder = if ($Kind -eq 'Original') { $script:IXBackupDir } else { $script:IXRoot }
    return (Join-Path $folder ('Tweaker{0}_{1}.json' -f $Kind,$safeName))
}

function New-IXTField {
    param([string]$Section,[string]$Name,[object]$Control,[object]$Map)
    $field = [pscustomobject]@{ Section=$Section; Name=$Name; Control=$Control; Map=$Map; Loaded='' }
    [void]$script:IXT.Fields.Add($field)
    return $field
}

function Get-IXTFieldValue {
    param([object]$Field)
    $text = ([string]$Field.Control.Text).Trim()
    if ($Field.Map) {
        foreach ($key in @($Field.Map.Keys)) {
            if ([string]$Field.Map[[object]$key] -eq $text) { return [string]$key }
        }
    }
    return $text
}

function Set-IXTFieldValue {
    param([object]$Field,[string]$Value)
    $text = $Value
    if ($Field.Map -and $Field.Map.Contains($Value)) { $text = [string]$Field.Map[[object]$Value] }
    if ($Field.Control -is [System.Windows.Forms.ComboBox]) {
        if (-not $Field.Control.Items.Contains($text)) { [void]$Field.Control.Items.Add($text) }
        $Field.Control.SelectedItem = $text
    } else {
        $Field.Control.Text = $text
    }
}

function New-IXTGroup {
    param([object]$Parent,[string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H)
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Text
    $group.Location = New-Object System.Drawing.Point($X,$Y)
    $group.Size = New-Object System.Drawing.Size($W,$H)
    $group.ForeColor = $script:IXT.Fore
    $Parent.Controls.Add($group)
    return $group
}

function New-IXTButton {
    param([object]$Parent,[string]$Text,[int]$X,[int]$Y,[int]$W,[System.Drawing.Color]$Color)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X,$Y)
    $button.Size = New-Object System.Drawing.Size($W,22)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.BackColor = [System.Drawing.Color]::Black
    $button.ForeColor = $Color
    $button.FlatAppearance.BorderColor = $Color
    $Parent.Controls.Add($button)
    return $button
}

function Add-IXTRow {
    param(
        [object]$Parent,[string]$Section,[string]$Name,[string]$Label,[int]$Y,
        [int]$LabelW,[int]$CtrlW,[string[]]$Items,[object]$Map,[switch]$TextBox
    )
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $Label + ':'
    $caption.Location = New-Object System.Drawing.Point(8,($Y + 3))
    $caption.Size = New-Object System.Drawing.Size($LabelW,16)
    $caption.ForeColor = $script:IXT.Fore
    $caption.AutoEllipsis = $true
    $script:IXT.Tip.SetToolTip($caption,$Label)
    $Parent.Controls.Add($caption)

    if ($TextBox) {
        $control = New-Object System.Windows.Forms.TextBox
        $control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    } else {
        $control = New-Object System.Windows.Forms.ComboBox
        $control.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        $control.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $control.DropDownWidth = [Math]::Max($CtrlW,220)
        if ($Map) { foreach ($value in @($Map.Values)) { [void]$control.Items.Add([string]$value) } }
        elseif ($Items) { foreach ($value in $Items) { [void]$control.Items.Add([string]$value) } }
    }
    $control.Location = New-Object System.Drawing.Point(($LabelW + 10),$Y)
    $control.Width = $CtrlW
    $control.BackColor = [System.Drawing.Color]::Black
    $control.ForeColor = [System.Drawing.Color]::White
    $Parent.Controls.Add($control)
    return (New-IXTField -Section $Section -Name $Name -Control $control -Map $Map)
}

function Read-IXTFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        $data = @{}
        foreach ($property in $json.PSObject.Properties) { $data[[string]$property.Name] = [string]$property.Value }
        return $data
    } catch {
        Add-IXTLog ('Could not read {0}: {1}' -f $Path,$_.Exception.Message)
        return $null
    }
}

function Save-IXTFile {
    param([string]$Path)
    $data = [ordered]@{}
    foreach ($field in $script:IXT.Fields) {
        if ($field.Control.Enabled) { $data[[string]($field.Section + '|' + $field.Name)] = [string]$field.Loaded }
    }
    try {
        $data | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        Add-IXTLog ('Could not write {0}: {1}' -f $Path,$_.Exception.Message)
        return $false
    }
}

function Import-IXTFile {
    # Puts stored values into the window only; nothing is written until Apply.
    param([string]$Path,[string]$What)
    $saved = Read-IXTFile -Path $Path
    if ($null -eq $saved) { Add-IXTLog ('No {0} file exists for this adapter yet.' -f $What); return }
    $count = 0
    foreach ($field in $script:IXT.Fields) {
        $key = $field.Section + '|' + $field.Name
        if ($field.Control.Enabled -and $saved.ContainsKey($key) -and ([string]$saved[$key] -ne (Get-IXTFieldValue -Field $field))) {
            Set-IXTFieldValue -Field $field -Value ([string]$saved[$key])
            $count++
        }
    }
    if ($count -eq 0) { Add-IXTLog ('{0}: the window already matches it.' -f $What) }
    else { Add-IXTLog ('{0}: {1} value(s) loaded into the window. Press Apply All to write them.' -f $What,$count) }
}

function Update-IXTAdvancedFields {
    # Adv. Adapter / PowerSaving rows are built from what the installed driver really exposes.
    $adapter = $script:IXT.Adapter
    $powerPattern = '(?i)Power|EEE|Green|Wake|WoL|PME|Energy|ULP|Sleep|Gating|ASPM|Selective.?Suspend'
    foreach ($panel in @($script:IXT.AdvPanel,$script:IXT.PowerPanel)) { $panel.SuspendLayout(); $panel.Controls.Clear() }
    $kept = New-Object 'System.Collections.Generic.List[object]'
    foreach ($field in $script:IXT.Fields) { if (@('Adv','Power') -notcontains $field.Section) { [void]$kept.Add($field) } }
    $script:IXT.Fields = $kept

    $properties = @()
    try {
        $properties = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.RegistryKeyword) } | Sort-Object RegistryKeyword)
    } catch { Add-IXTLog ('Advanced properties could not be read: ' + $_.Exception.Message) }

    $yAdv = 2; $yPower = 2
    foreach ($property in $properties) {
        $keyword = [string]$property.RegistryKeyword
        $isPower = ($keyword -match $powerPattern) -or ([string]$property.DisplayName -match $powerPattern)
        # A MAC override is not a tuning option and is easy to mistype.
        if ($keyword -eq 'NetworkAddress') { continue }
        $registryValues = @($property.ValidRegistryValues | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $displayValues = @($property.ValidDisplayValues | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() })
        $map = $null
        if ($registryValues.Count -gt 0 -and $registryValues.Count -eq $displayValues.Count) {
            $map = [ordered]@{}
            for ($i = 0; $i -lt $registryValues.Count; $i++) {
                if (-not $map.Contains($registryValues[$i])) { $map[[object]$registryValues[$i]] = ('{0} - {1}' -f $registryValues[$i],$displayValues[$i]) }
            }
        }
        $current = ''
        $currentValues = @($property.RegistryValue)
        if ($currentValues.Count -gt 0) { $current = [string]$currentValues[0] }

        if ($isPower) { $panel = $script:IXT.PowerPanel; $section = 'Power'; $y = $yPower; $yPower += 22 }
        else { $panel = $script:IXT.AdvPanel; $section = 'Adv'; $y = $yAdv; $yAdv += 22 }
        $field = Add-IXTRow -Parent $panel -Section $section -Name $keyword -Label ($keyword.TrimStart('*')) -Y $y -LabelW 158 -CtrlW 160 -Map $map -TextBox:($null -eq $map)
        $field.Loaded = $current
        Set-IXTFieldValue -Field $field -Value $current
        $hint = [string]$property.DisplayName
        if ($null -ne $property.NumericParameterMinValue -and $null -ne $property.NumericParameterMaxValue) {
            $script:IXT.Ranges[$keyword] = @($property.NumericParameterMinValue,$property.NumericParameterMaxValue)
            $hint += (' (allowed: {0} - {1})' -f $property.NumericParameterMinValue,$property.NumericParameterMaxValue)
        }
        $script:IXT.Tip.SetToolTip($field.Control,$hint)
    }
    foreach ($panel in @($script:IXT.AdvPanel,$script:IXT.PowerPanel)) { $panel.ResumeLayout() }
}

function Read-IXTValues {
    $adapter = $script:IXT.Adapter
    $values = @{}

    try {
        $rss = Get-NetAdapterRss -Name $adapter.Name -ErrorAction Stop | Select-Object -First 1
        if ($rss) {
            $values['RSS|Status'] = $(if ($rss.Enabled) { 'Enabled' } else { 'Disabled' })
            $values['RSS|NumberOfReceiveQueues'] = [string]$rss.NumberOfReceiveQueues
            $values['RSS|Profile'] = [string]$rss.Profile
            $values['RSS|BaseProcessor'] = [string]$rss.BaseProcessorNumber
            $values['RSS|MaxProcessor'] = [string]$rss.MaxProcessorNumber
            $values['RSS|MaxProcessors'] = [string]$rss.MaxProcessors
        }
    } catch { }

    $values['RSSGlobal|Tcpip'] = Get-IXTRegValue -Path $script:IXT.TcpipPath -Name 'RssBaseCpu'
    $values['RSSGlobal|NDIS'] = Get-IXTRegValue -Path $script:IXT.NdisPath -Name 'RssBaseCpu'

    $interruptPath = $script:IXT.InterruptPath
    if ($interruptPath) {
        $values['Interrupt|MSISupported'] = Get-IXTRegValue -Path (Join-Path $interruptPath 'MessageSignaledInterruptProperties') -Name 'MSISupported'
        $values['Interrupt|DevicePriority'] = Get-IXTRegValue -Path (Join-Path $interruptPath 'Affinity Policy') -Name 'DevicePriority'
        $values['Interrupt|DevicePolicy'] = Get-IXTRegValue -Path (Join-Path $interruptPath 'Affinity Policy') -Name 'DevicePolicy'
    }

    try {
        $global = Get-NetOffloadGlobalSetting -ErrorAction Stop
        foreach ($name in $script:IXT.GlobalNames) {
            $property = $global.PSObject.Properties[$name]
            if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $values['Global|' + $name] = [string]$property.Value }
        }
    } catch { }

    try {
        $family = if ($script:IXT.ChkV4.Checked -or -not $script:IXT.ChkV6.Checked) { 'IPv4' } else { 'IPv6' }
        $ipInterface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily $family -ErrorAction Stop | Select-Object -First 1
        foreach ($name in $script:IXT.InterfaceNames) {
            foreach ($candidate in @($name,($name -replace '(Ms|Bytes)$',''))) {
                $property = $ipInterface.PSObject.Properties[$candidate]
                if ($property -and $null -ne $property.Value) { $values['Interface|' + $name] = [string]$property.Value; break }
            }
        }
    } catch { }

    foreach ($field in $script:IXT.Fields) {
        if ($field.Section -eq 'AFD') { $values['AFD|' + $field.Name] = Get-IXTRegValue -Path $script:IXT.AfdPath -Name $field.Name }
    }

    foreach ($field in $script:IXT.Fields) {
        if (@('Adv','Power') -contains $field.Section) { continue }
        $key = $field.Section + '|' + $field.Name
        if ($values.ContainsKey($key)) {
            $field.Control.Enabled = $true
            $field.Loaded = [string]$values[$key]
            Set-IXTFieldValue -Field $field -Value $field.Loaded
        } else {
            # Not exposed by this adapter / Windows build.
            $field.Loaded = ''
            if ($field.Control -is [System.Windows.Forms.ComboBox]) { $field.Control.SelectedIndex = -1 } else { $field.Control.Text = '' }
            $field.Control.Enabled = $false
        }
    }
}

function Read-IXTAll {
    Update-IXTAdvancedFields
    Read-IXTValues
}

function Set-IXTStablePreset {
    # Fills the window with the same conservative values as the console LOW PING PROFILE.
    # Nothing is written until Apply; rows the driver does not expose are skipped.
    $rules = Get-IXLowPingRules
    $count = 0
    foreach ($field in $script:IXT.Fields) {
        if (-not $field.Control.Enabled) { continue }
        $name = [string]$field.Name
        $current = Get-IXTFieldValue -Field $field
        $target = $null
        if ($field.Section -eq 'RSS' -and $name -eq 'Status') {
            $target = 'Enabled'
        } elseif (@('Adv','Power') -contains $field.Section) {
            if ($rules.TurnOff.Contains($name) -and $field.Map) {
                foreach ($mapKey in @($field.Map.Keys)) {
                    if ([string]$field.Map[[object]$mapKey] -match '(?i) - (Disabled|Disable|Off)$') { $target = [string]$mapKey; break }
                }
            } elseif ($rules.BufferFloor.ContainsKey($name)) {
                $floor = [int]$rules.BufferFloor[$name]
                $number = 0
                if ([int]::TryParse($current,[ref]$number) -and $number -lt $floor) {
                    if ($field.Map) {
                        $pick = @($field.Map.Keys | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object | Where-Object { $_ -ge $floor } | Select-Object -First 1)
                        if ($pick.Count -gt 0) { $target = [string]$pick[0] }
                    } else {
                        $range = $script:IXT.Ranges[$name]
                        if (-not $range -or ($floor -ge [int]$range[0] -and $floor -le [int]$range[1])) { $target = [string]$floor }
                    }
                }
            }
        }
        if ($null -eq $target -or $target -eq $current) { continue }
        Set-IXTFieldValue -Field $field -Value $target
        $count++
        Add-IXTLog ('Preset {0}: {1} -> {2}' -f $name.TrimStart('*'),$(if ($current -eq '') { '(not set)' } else { $current }),$target)
    }
    $mtuField = @($script:IXT.Fields | Where-Object { $_.Section -eq 'Interface' -and $_.Name -eq 'NlMtuBytes' })
    $mtu = 0
    if ($mtuField.Count -gt 0 -and [int]::TryParse([string]$mtuField[0].Loaded,[ref]$mtu) -and $mtu -gt 1500) {
        Add-IXTLog ('Note: interface MTU is {0}. The preset does not type an MTU; it follows Jumbo Packet. Run the MTU test (menu 3) afterwards.' -f $mtu)
    }
    if ($count -eq 0) { Add-IXTLog 'Stable preset: this adapter already has these values.' }
    else { Add-IXTLog ('Stable preset: {0} value(s) filled in. Check them, then press Apply All and Restart Adapter.' -f $count) }
}

function Select-IXTAdapter {
    $index = $script:IXT.AdapterCombo.SelectedIndex
    if ($index -lt 0) { return }
    $adapter = $script:IXT.Adapters[$index]
    $script:IXT.Adapter = $adapter
    $script:IXT.ClassKey = Get-IXTClassKey -Adapter $adapter
    $script:IXT.InterruptPath = Get-IXTInterruptPath -Adapter $adapter
    $script:IXT.RegistryLabel.Text = 'Registry:  ' + $(if ($script:IXT.ClassKey) { $script:IXT.ClassKey } else { 'not found' })
    $script:IXT.NdisLabel.Text = 'NDIS:  {0}     Status: {1}     Link: {2}' -f $adapter.NdisVersion,$adapter.Status,$adapter.LinkSpeed
    Read-IXTAll
    Add-IXTLog ('Adapter loaded: ' + $adapter.InterfaceDescription)

    $originalPath = Get-IXTProfilePath -Adapter $adapter -Kind 'Original'
    if (-not (Test-Path -LiteralPath $originalPath)) {
        if (Save-IXTFile -Path $originalPath) { Add-IXTLog ('Original settings backed up: ' + $originalPath) }
    }
    $saved = Read-IXTFile -Path (Get-IXTProfilePath -Adapter $adapter -Kind 'Profile')
    if ($null -ne $saved) {
        $different = 0
        foreach ($field in $script:IXT.Fields) {
            $key = $field.Section + '|' + $field.Name
            if ($field.Control.Enabled -and $saved.ContainsKey($key) -and ([string]$saved[$key] -ne [string]$field.Loaded)) { $different++ }
        }
        if ($different -eq 0) { Add-IXTLog 'Saved profile found: Windows still has the same values.' }
        else { Add-IXTLog ('{0} value(s) differ from your saved profile (a driver/Windows update may have reset them). Press Load Saved, then Apply All.' -f $different) }
    }
}

function Set-IXTSetting {
    param([object]$Field,[string]$Value)
    $adapter = $script:IXT.Adapter
    $name = [string]$Field.Name
    switch ([string]$Field.Section) {
        'RSS' {
            $parameters = @{}
            if ($name -eq 'Status') { $parameters['Enabled'] = ($Value -eq 'Enabled') }
            elseif ($name -eq 'Profile') { $parameters['Profile'] = $Value }
            elseif ($name -eq 'BaseProcessor') { $parameters['BaseProcessorNumber'] = ConvertTo-IXTNumber -Text $Value }
            elseif ($name -eq 'MaxProcessor') { $parameters['MaxProcessorNumber'] = ConvertTo-IXTNumber -Text $Value }
            else { $parameters[$name] = ConvertTo-IXTNumber -Text $Value }
            Set-NetAdapterRss -Name $adapter.Name @parameters -NoRestart -ErrorAction Stop | Out-Null
        }
        'RSSGlobal' {
            $path = if ($name -eq 'Tcpip') { $script:IXT.TcpipPath } else { $script:IXT.NdisPath }
            Set-IXTRegDword -Path $path -Name 'RssBaseCpu' -Text $Value
        }
        'Interrupt' {
            if (-not $script:IXT.InterruptPath) { throw 'Interrupt settings are not available for this adapter.' }
            $subKey = if ($name -eq 'MSISupported') { 'MessageSignaledInterruptProperties' } else { 'Affinity Policy' }
            Set-IXTRegDword -Path (Join-Path $script:IXT.InterruptPath $subKey) -Name $name -Text $Value
        }
        'Global' {
            $parameters = @{}
            $parameters[$name] = $Value
            Set-NetOffloadGlobalSetting @parameters -ErrorAction Stop | Out-Null
        }
        'Interface' {
            $parameters = @{}
            if ($script:IXT.InterfaceNumeric -contains $name) { $parameters[$name] = [uint32](ConvertTo-IXTNumber -Text $Value) }
            else { $parameters[$name] = $Value }
            $families = @()
            if ($script:IXT.ChkV4.Checked) { $families += 'IPv4' }
            if ($script:IXT.ChkV6.Checked) { $families += 'IPv6' }
            if ($families.Count -eq 0) { throw 'Tick IPv4 and/or IPv6 first.' }
            foreach ($family in $families) {
                Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily $family @parameters -ErrorAction Stop | Out-Null
            }
        }
        { $_ -in @('Adv','Power') } {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $name -RegistryValue $Value -NoRestart -ErrorAction Stop | Out-Null
        }
        'AFD' {
            Set-IXTRegDword -Path $script:IXT.AfdPath -Name $name -Text $Value
        }
    }
}

function Invoke-IXTApply {
    param([string[]]$Sections)
    if (-not $script:IXT.Adapter) { return }
    $changed = @($script:IXT.Fields | Where-Object { ($Sections -contains $_.Section) -and $_.Control.Enabled -and ((Get-IXTFieldValue -Field $_) -ne [string]$_.Loaded) })
    if ($changed.Count -eq 0) { Add-IXTLog 'Nothing to apply: the window matches the current Windows values.'; return }

    $preview = @($changed | Select-Object -First 12 | ForEach-Object {
        '{0}: {1} -> {2}' -f $_.Name,$(if ($_.Loaded -eq '') { '(not set)' } else { $_.Loaded }),$(if ((Get-IXTFieldValue -Field $_) -eq '') { '(not set)' } else { Get-IXTFieldValue -Field $_ })
    })
    if ($changed.Count -gt 12) { $preview += ('... and {0} more' -f ($changed.Count - 12)) }
    $message = ('Apply {0} change(s) to:' -f $changed.Count) + "`n" + $script:IXT.Adapter.InterfaceDescription + "`n`n" + ($preview -join "`n")
    $answer = [System.Windows.Forms.MessageBox]::Show($script:IXT.Form,$message,'InternetX - confirm changes',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { Add-IXTLog 'Cancelled. Nothing changed.'; return }

    $applied = 0; $failed = 0
    foreach ($field in $changed) {
        $value = Get-IXTFieldValue -Field $field
        try {
            Set-IXTSetting -Field $field -Value $value
            $applied++
            Add-IXTLog ('APPLIED {0}: {1} -> {2}' -f $field.Name,$field.Loaded,$value)
        } catch {
            $failed++
            Add-IXTLog ('FAILED {0}: {1}' -f $field.Name,$_.Exception.Message)
        }
    }
    Read-IXTAll
    if (Save-IXTFile -Path (Get-IXTProfilePath -Adapter $script:IXT.Adapter -Kind 'Profile')) {
        Add-IXTLog ('Done. Applied: {0} | Failed: {1}. Profile saved; Windows keeps these values after restart.' -f $applied,$failed)
    }
    Add-IXTLog 'Adapter options need Restart Adapter. RSS Global, Interrupt and Tweaks need a Windows restart.'
}

function New-IXTweakerForm {
    $script:IXT = @{
        Fields = (New-Object 'System.Collections.Generic.List[object]')
        Adapter = $null; Adapters = @(); ClassKey = $null; InterruptPath = $null
        Fore = [System.Drawing.Color]::FromArgb(140,180,255)
        TcpipPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
        NdisPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NDIS\Parameters'
        AfdPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters'
        GlobalNames = @('ReceiveSideScaling','ReceiveSegmentCoalescing','Chimney','TaskOffload','NetworkDirect','NetworkDirectAcrossIPSubnets','PacketCoalescingFilter')
        InterfaceNumeric = @('CurrentHopLimit','BaseReachableTimeMs','RetransmitTimeMs','DadRetransmitTimeMs','DadTransmits','NlMtuBytes')
        InterfaceNames = @()
        Ranges = @{}
    }
    $rowHeight = 22
    $onOff = @('Enabled','Disabled')
    $green = [System.Drawing.Color]::FromArgb(120,220,120)
    $red = [System.Drawing.Color]::FromArgb(235,90,90)
    $yellow = [System.Drawing.Color]::FromArgb(230,200,90)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Network Adapter - Tweaker  |  InternetX'
    $form.BackColor = [System.Drawing.Color]::FromArgb(14,16,22)
    $form.ForeColor = $script:IXT.Fore
    $form.Font = New-Object System.Drawing.Font('Segoe UI',8)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.AutoScroll = $true
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.ClientSize = New-Object System.Drawing.Size([Math]::Min(1262,$workArea.Width - 30),[Math]::Min(846,$workArea.Height - 50))
    $script:IXT.Form = $form
    $script:IXT.Tip = New-Object System.Windows.Forms.ToolTip

    # --- top bar ---
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = 'Adapter:'; $caption.Location = New-Object System.Drawing.Point(8,12); $caption.Size = New-Object System.Drawing.Size(52,16)
    $form.Controls.Add($caption)
    $adapterCombo = New-Object System.Windows.Forms.ComboBox
    $adapterCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $adapterCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $adapterCombo.BackColor = [System.Drawing.Color]::Black; $adapterCombo.ForeColor = [System.Drawing.Color]::White
    $adapterCombo.Location = New-Object System.Drawing.Point(62,8); $adapterCombo.Width = 300
    $form.Controls.Add($adapterCombo)
    $script:IXT.AdapterCombo = $adapterCombo

    $openButton = New-IXTButton -Parent $form -Text 'Open' -X 370 -Y 8 -W 60 -Color $script:IXT.Fore
    $applyAllButton = New-IXTButton -Parent $form -Text 'Apply All' -X 436 -Y 8 -W 76 -Color $green
    $restartButton = New-IXTButton -Parent $form -Text 'Restart Adapter' -X 518 -Y 8 -W 110 -Color $red
    $opacityButton = New-IXTButton -Parent $form -Text 'Opacity On/Off' -X 634 -Y 8 -W 100 -Color $script:IXT.Fore
    $loadSavedButton = New-IXTButton -Parent $form -Text 'Load Saved' -X 740 -Y 8 -W 86 -Color $yellow
    $loadOriginalButton = New-IXTButton -Parent $form -Text 'Load Original' -X 832 -Y 8 -W 96 -Color $yellow
    $refreshButton = New-IXTButton -Parent $form -Text 'Refresh' -X 934 -Y 8 -W 70 -Color $script:IXT.Fore
    $presetButton = New-IXTButton -Parent $form -Text 'Stable Preset' -X 1010 -Y 8 -W 100 -Color $green
    $presetButton.Add_Click({ try { if ($script:IXT.Adapter) { Set-IXTStablePreset } } catch { Add-IXTLog ('Preset error: ' + $_.Exception.Message) } })

    $registryLabel = New-Object System.Windows.Forms.Label
    $registryLabel.Location = New-Object System.Drawing.Point(8,36); $registryLabel.Size = New-Object System.Drawing.Size(1000,16)
    $form.Controls.Add($registryLabel); $script:IXT.RegistryLabel = $registryLabel
    $ndisLabel = New-Object System.Windows.Forms.Label
    $ndisLabel.Location = New-Object System.Drawing.Point(8,54); $ndisLabel.Size = New-Object System.Drawing.Size(1000,16)
    $form.Controls.Add($ndisLabel); $script:IXT.NdisLabel = $ndisLabel

    $applyHandler = { try { Invoke-IXTApply -Sections @($this.Tag) } catch { Add-IXTLog ('Apply error: ' + $_.Exception.Message) } }

    # --- column 1: RSS / RSS Global / Interrupt ---
    $group = New-IXTGroup -Parent $form -Text 'RSS Settings' -X 8 -Y 76 -W 216 -H 184
    $y = 18
    $null = Add-IXTRow -Parent $group -Section 'RSS' -Name 'Status' -Label 'Status' -Y $y -LabelW 124 -CtrlW 74 -Items $onOff; $y += $rowHeight
    $null = Add-IXTRow -Parent $group -Section 'RSS' -Name 'NumberOfReceiveQueues' -Label 'NumberOfReceiveQueues' -Y $y -LabelW 124 -CtrlW 74 -TextBox; $y += $rowHeight
    $null = Add-IXTRow -Parent $group -Section 'RSS' -Name 'Profile' -Label 'Profile' -Y $y -LabelW 124 -CtrlW 74 -Items @('Closest','ClosestStatic','NUMA','NUMAStatic','Conservative'); $y += $rowHeight
    $null = Add-IXTRow -Parent $group -Section 'RSS' -Name 'BaseProcessor' -Label 'BaseProcessor' -Y $y -LabelW 124 -CtrlW 74 -TextBox; $y += $rowHeight
    $null = Add-IXTRow -Parent $group -Section 'RSS' -Name 'MaxProcessor' -Label 'MaxProcessor' -Y $y -LabelW 124 -CtrlW 74 -TextBox; $y += $rowHeight
    $null = Add-IXTRow -Parent $group -Section 'RSS' -Name 'MaxProcessors' -Label 'MaxProcessors' -Y $y -LabelW 124 -CtrlW 74 -TextBox; $y += $rowHeight
    $button = New-IXTButton -Parent $group -Text 'Apply' -X 8 -Y ($y + 4) -W 60 -Color $script:IXT.Fore
    $button.Tag = @('RSS'); $button.Add_Click($applyHandler)

    $group = New-IXTGroup -Parent $form -Text 'RSS Global' -X 8 -Y 266 -W 216 -H 96
    $null = Add-IXTRow -Parent $group -Section 'RSSGlobal' -Name 'Tcpip' -Label 'TCP/IP_RssBaseCpu' -Y 18 -LabelW 124 -CtrlW 74 -TextBox
    $null = Add-IXTRow -Parent $group -Section 'RSSGlobal' -Name 'NDIS' -Label 'NDIS_RssBaseCpu' -Y 40 -LabelW 124 -CtrlW 74 -TextBox
    $button = New-IXTButton -Parent $group -Text 'Apply' -X 8 -Y 66 -W 60 -Color $script:IXT.Fore
    $button.Tag = @('RSSGlobal'); $button.Add_Click($applyHandler)

    $group = New-IXTGroup -Parent $form -Text 'Interrupt Settings' -X 8 -Y 368 -W 216 -H 118
    $msiMap = [ordered]@{ '' = 'Undefined'; '1' = 'Enabled'; '0' = 'Disabled' }
    $priorityMap = [ordered]@{ '' = 'Undefined'; '1' = 'Low'; '2' = 'Normal'; '3' = 'High' }
    $policyMap = [ordered]@{ '' = 'Undefined'; '0' = 'MachineDefault'; '1' = 'AllCloseProcessors'; '2' = 'OneCloseProcessor'; '3' = 'AllProcessorsInMachine'; '5' = 'SpreadMessagesAcrossAllProcessors' }
    $null = Add-IXTRow -Parent $group -Section 'Interrupt' -Name 'MSISupported' -Label 'MSI Mode' -Y 18 -LabelW 96 -CtrlW 102 -Map $msiMap
    $null = Add-IXTRow -Parent $group -Section 'Interrupt' -Name 'DevicePriority' -Label 'Interrupt Priority' -Y 40 -LabelW 96 -CtrlW 102 -Map $priorityMap
    $null = Add-IXTRow -Parent $group -Section 'Interrupt' -Name 'DevicePolicy' -Label 'DevicePolicy' -Y 62 -LabelW 96 -CtrlW 102 -Map $policyMap
    $button = New-IXTButton -Parent $group -Text 'Apply' -X 8 -Y 88 -W 60 -Color $script:IXT.Fore
    $button.Tag = @('Interrupt'); $button.Add_Click($applyHandler)

    # --- column 2: Global / Interface ---
    $group = New-IXTGroup -Parent $form -Text 'Global Settings' -X 232 -Y 76 -W 300 -H 206
    $y = 18
    foreach ($name in $script:IXT.GlobalNames) {
        $items = $onOff
        if ($name -eq 'Chimney') { $items = @('Disabled','Enabled','Automatic') }
        elseif ($name -eq 'NetworkDirectAcrossIPSubnets') { $items = @('Blocked','Allowed') }
        $null = Add-IXTRow -Parent $group -Section 'Global' -Name $name -Label $name -Y $y -LabelW 176 -CtrlW 104 -Items $items
        $y += $rowHeight
    }
    $button = New-IXTButton -Parent $group -Text 'Apply' -X 8 -Y ($y + 4) -W 60 -Color $script:IXT.Fore
    $button.Tag = @('Global'); $button.Add_Click($applyHandler)

    $group = New-IXTGroup -Parent $form -Text 'Interface Settings' -X 232 -Y 288 -W 300 -H 550
    $checkV4 = New-Object System.Windows.Forms.CheckBox
    $checkV4.Text = 'IPv4'; $checkV4.Checked = $true; $checkV4.Location = New-Object System.Drawing.Point(150,0); $checkV4.Size = New-Object System.Drawing.Size(52,16)
    $checkV6 = New-Object System.Windows.Forms.CheckBox
    $checkV6.Text = 'IPv6'; $checkV6.Location = New-Object System.Drawing.Point(206,0); $checkV6.Size = New-Object System.Drawing.Size(52,16)
    $group.Controls.Add($checkV4); $group.Controls.Add($checkV6)
    $script:IXT.ChkV4 = $checkV4; $script:IXT.ChkV6 = $checkV6
    $interfaceRows = @(
        @('AdvertiseDefaultRoute',$onOff), @('Advertising',$onOff), @('AutomaticMetric',$onOff), @('ClampMss',$onOff),
        @('DirectedMacWolPattern',$onOff), @('EcnMarking',@('Disabled','UseEct1','UseEct0','AppDecide')),
        @('ForceArpNdWolPattern',$onOff), @('Forwarding',$onOff), @('IgnoreDefaultRoutes',$onOff),
        @('ManagedAddressConfiguration',$onOff), @('NeighborUnreachabilityDetection',$onOff),
        @('OtherStatefulConfiguration',$onOff), @('RouterDiscovery',@('Disabled','Enabled','ControlledByDHCP')),
        @('WeakHostReceive',$onOff), @('WeakHostSend',$onOff),
        @('CurrentHopLimit',$null), @('BaseReachableTimeMs',$null), @('RetransmitTimeMs',$null),
        @('DadRetransmitTimeMs',$null), @('DadTransmits',$null), @('NlMtuBytes',$null)
    )
    $y = 22
    foreach ($row in $interfaceRows) {
        $name = [string]$row[0]
        $script:IXT.InterfaceNames += $name
        if ($null -eq $row[1]) { $null = Add-IXTRow -Parent $group -Section 'Interface' -Name $name -Label $name -Y $y -LabelW 176 -CtrlW 104 -TextBox }
        else { $null = Add-IXTRow -Parent $group -Section 'Interface' -Name $name -Label $name -Y $y -LabelW 176 -CtrlW 104 -Items $row[1] }
        $y += $rowHeight
    }
    $button = New-IXTButton -Parent $group -Text 'Apply' -X 8 -Y ($y + 6) -W 60 -Color $script:IXT.Fore
    $button.Tag = @('Interface'); $button.Add_Click($applyHandler)

    # --- column 3: Adv. Adapter / PowerSaving (driver-defined rows) ---
    $group = New-IXTGroup -Parent $form -Text 'Adv. Adapter' -X 540 -Y 76 -W 372 -H 500
    $advPanel = New-Object System.Windows.Forms.Panel
    $advPanel.Location = New-Object System.Drawing.Point(4,16); $advPanel.Size = New-Object System.Drawing.Size(364,450); $advPanel.AutoScroll = $true
    $group.Controls.Add($advPanel); $script:IXT.AdvPanel = $advPanel
    $button = New-IXTButton -Parent $group -Text 'Apply' -X 8 -Y 472 -W 60 -Color $script:IXT.Fore
    $button.Tag = @('Adv'); $button.Add_Click($applyHandler)

    $group = New-IXTGroup -Parent $form -Text 'PowerSaving Settings' -X 540 -Y 582 -W 372 -H 256
    $powerPanel = New-Object System.Windows.Forms.Panel
    $powerPanel.Location = New-Object System.Drawing.Point(4,16); $powerPanel.Size = New-Object System.Drawing.Size(364,206); $powerPanel.AutoScroll = $true
    $group.Controls.Add($powerPanel); $script:IXT.PowerPanel = $powerPanel
    $button = New-IXTButton -Parent $group -Text 'Apply' -X 8 -Y 228 -W 60 -Color $script:IXT.Fore
    $button.Tag = @('Power'); $button.Add_Click($applyHandler)

    # --- column 4: AFD tweaks / log ---
    $group = New-IXTGroup -Parent $form -Text 'Tweaks' -X 920 -Y 76 -W 334 -H 562
    $afdNames = @(
        'DefaultReceiveWindow','DefaultSendWindow','BufferMultiplier','BufferAlignment','DoNotHoldNICBuffers',
        'SmallBufferSize','MediumBufferSize','LargeBufferSize','HugeBufferSize','SmallBufferListDepth',
        'MediumBufferListDepth','LargeBufferListDepth','DisableAddressSharing','DisableChainedReceive',
        'DisableDirectAcceptEx','DisableRawSecurity','DynamicSendBufferDisable','FastSendDatagramThreshold',
        'FastCopyReceiveThreshold','IgnorePushBitOnReceives','IgnoreOrderlyRelease','TransmitWorker','PriorityBoost'
    )
    $y = 18
    foreach ($name in $afdNames) {
        $field = Add-IXTRow -Parent $group -Section 'AFD' -Name $name -Label $name -Y $y -LabelW 176 -CtrlW 136 -TextBox
        $script:IXT.Tip.SetToolTip($field.Control,'Empty = not set (Windows default). Takes effect after a Windows restart.')
        $y += $rowHeight
    }
    $button = New-IXTButton -Parent $group -Text 'Apply' -X 8 -Y ($y + 6) -W 60 -Color $script:IXT.Fore
    $button.Tag = @('AFD'); $button.Add_Click($applyHandler)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $logBox.BackColor = [System.Drawing.Color]::Black; $logBox.ForeColor = $green
    $logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $logBox.Location = New-Object System.Drawing.Point(920,644); $logBox.Size = New-Object System.Drawing.Size(334,194)
    $form.Controls.Add($logBox); $script:IXT.LogBox = $logBox

    # --- events ---
    $adapterCombo.Add_SelectedIndexChanged({ try { Select-IXTAdapter } catch { Add-IXTLog ('Adapter load error: ' + $_.Exception.Message) } })
    $applyAllButton.Add_Click({
        try { Invoke-IXTApply -Sections @('RSS','RSSGlobal','Interrupt','Global','Interface','Adv','Power','AFD') }
        catch { Add-IXTLog ('Apply error: ' + $_.Exception.Message) }
    })
    $refreshButton.Add_Click({ try { Read-IXTAll; Add-IXTLog 'Values re-read from Windows.' } catch { Add-IXTLog ('Refresh error: ' + $_.Exception.Message) } })
    $opacityButton.Add_Click({ if ($script:IXT.Form.Opacity -lt 1) { $script:IXT.Form.Opacity = 1 } else { $script:IXT.Form.Opacity = 0.85 } })
    $loadSavedButton.Add_Click({
        try { if ($script:IXT.Adapter) { Import-IXTFile -Path (Get-IXTProfilePath -Adapter $script:IXT.Adapter -Kind 'Profile') -What 'Saved profile' } }
        catch { Add-IXTLog ('Load error: ' + $_.Exception.Message) }
    })
    $loadOriginalButton.Add_Click({
        try { if ($script:IXT.Adapter) { Import-IXTFile -Path (Get-IXTProfilePath -Adapter $script:IXT.Adapter -Kind 'Original') -What 'Original backup' } }
        catch { Add-IXTLog ('Load error: ' + $_.Exception.Message) }
    })
    $openButton.Add_Click({
        try {
            if (-not $script:IXT.ClassKey) { Add-IXTLog 'Registry key for this adapter was not found.'; return }
            $regeditKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit'
            if (-not (Test-Path -LiteralPath $regeditKey)) { New-Item -Path $regeditKey -Force | Out-Null }
            Set-ItemProperty -LiteralPath $regeditKey -Name 'LastKey' -Value ('Computer\' + $script:IXT.ClassKey)
            Start-Process -FilePath (Join-Path $env:SystemRoot 'regedit.exe') -ArgumentList '/m'
        } catch { Add-IXTLog ('Could not open Registry Editor: ' + $_.Exception.Message) }
    })
    $restartButton.Add_Click({
        try {
            if (-not $script:IXT.Adapter) { return }
            $answer = [System.Windows.Forms.MessageBox]::Show($script:IXT.Form,'Restart the adapter now? The connection drops for a few seconds (FiveM will disconnect).','InternetX - restart adapter',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            Restart-NetAdapter -Name $script:IXT.Adapter.Name -Confirm:$false -ErrorAction Stop
            Add-IXTLog 'Adapter restarted.'
            Start-Sleep -Seconds 3
            Read-IXTAll
        } catch { Add-IXTLog ('Restart failed: ' + $_.Exception.Message) }
    })
    $form.Add_Shown({
        try {
            $all = @(Get-NetAdapter -ErrorAction Stop | Sort-Object @{ Expression = { $_.Status -ne 'Up' } },Name)
            $script:IXT.Adapters = $all
            foreach ($adapter in $all) { [void]$script:IXT.AdapterCombo.Items.Add([string]$adapter.InterfaceDescription) }
            if ($all.Count -eq 0) { Add-IXTLog 'No network adapter found.'; return }
            $selected = 0
            $primary = Get-IXPrimaryAdapter
            if ($primary) {
                for ($i = 0; $i -lt $all.Count; $i++) { if ([int]$all[$i].ifIndex -eq [int]$primary.ifIndex) { $selected = $i; break } }
            }
            $script:IXT.AdapterCombo.SelectedIndex = $selected
        } catch { Add-IXTLog ('Could not list adapters: ' + $_.Exception.Message) }
    })
    return $form
}

function Invoke-IXTweakerGui {
    Show-IXHeader
    Write-IXTitle 'NETWORK ADAPTER TWEAKER (WINDOW)' -Advanced
    if (-not (Test-IXAdmin)) {
        Write-Host 'Administrator permission required.' -ForegroundColor Red
        Wait-IXReturn
        return
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        Write-Host ('Windows Forms could not be loaded: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Wait-IXReturn
        return
    }
    Write-Host 'The tweaker window is open. Close it to return to this menu.' -ForegroundColor Cyan
    Write-Host 'Nothing changes until you press Apply and confirm. Original values are backed up on first open.' -ForegroundColor DarkGray
    $form = $null
    try {
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $form = New-IXTweakerForm
        [void]$form.ShowDialog()
    } catch {
        Write-Host ('Tweaker window error: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-IXLog ('Tweaker GUI error: ' + $_.Exception.Message)
        Wait-IXReturn
    } finally {
        if ($form) { try { $form.Dispose() } catch { } }
        $script:IXT = $null
    }
}

Write-IXLog ('InternetX v2.7 started. Admin=' + $script:IXAdmin)
Initialize-IXTheme
while ($true) {
    Show-IXDashboard
    $choice = Read-IXChoice 'Choose an option'
    try {
        switch ($choice) {
            '1' { Invoke-IXQuickScan }
            '2' { Invoke-IXLatencyTest }
            '3' { Invoke-IXMtuTest }
            '4' { Invoke-IXOptimizationMenu }
            '5' { Invoke-IXHitRegMonitor }
            '6' { Invoke-IXReportsMenu }
            '7' { Invoke-IXAdapterTweakerMenu }
            '8' { Invoke-IXTweakerGui }
            '9' { Invoke-IXExtremeMenu }
            'D' { Invoke-IXDesyncMenu }
            'M' { $script:IXMono = -not $script:IXMono }
            '0' { Write-IXLog 'InternetX exited.' }
            default {
                Write-IXErr ('"{0}" is not a menu option. Enter 0-9 or D.' -f $choice)
                Start-Sleep -Milliseconds 1300
            }
        }
    } catch {
        # A failed screen must never close the tool: show the reason and go back to the dashboard.
        Clear-IXLive
        Write-IXErr ('This screen stopped with an error: {0}' -f $_.Exception.Message)
        Write-IXLog ('Screen error (choice ' + $choice + '): ' + $_.Exception.Message)
        Wait-IXReturn
    }
    if ($choice -eq '0') { break }
}
