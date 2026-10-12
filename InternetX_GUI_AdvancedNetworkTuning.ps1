#requires -Version 5.1
<#
InternetX GUI - Advanced Network Tuning
Windows 10/11, PowerShell 5.1+, WinForms.
Provides read-only network diagnostics and opt-in, driver-supported adapter settings.
Does not generate artificial packet loss/desynchronization or alter hit registration.
#>
$ErrorActionPreference = 'Continue'

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Host "Windows Forms could not be loaded: $($_.Exception.Message)" -ForegroundColor Red
    return
}

$script:IXIsAdmin = $false
try {
    $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $script:IXIsAdmin = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

$script:IXRoot = Join-Path $env:ProgramData 'InternetX-GUI'
if (-not $script:IXIsAdmin) { $script:IXRoot = Join-Path $env:LOCALAPPDATA 'InternetX-GUI' }
$script:IXReports = Join-Path ([Environment]::GetFolderPath('Desktop')) 'InternetX-Reports'
$script:IXLogs = Join-Path $script:IXRoot 'Logs'
$script:IXBackups = Join-Path $script:IXRoot 'Backups'
foreach ($p in @($script:IXRoot,$script:IXReports,$script:IXLogs,$script:IXBackups)) {
    try { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null } catch {}
}
$script:IXStatePath = Join-Path $script:IXRoot 'state.json'
$script:IXLogPath = Join-Path $script:IXLogs ('InternetX_GUI_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
$script:IXState = [pscustomobject]@{ Version = 1; Entries = @() }
try {
    if (Test-Path -LiteralPath $script:IXStatePath) {
        $loaded = Get-Content -LiteralPath $script:IXStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($loaded -and $null -ne $loaded.Entries) { $script:IXState = $loaded }
    }
} catch {}

function Write-IXLogGUI([string]$Message) {
    try { Add-Content -LiteralPath $script:IXLogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message) -Encoding UTF8 } catch {}
}
function Save-IXStateGUI {
    try { $script:IXState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:IXStatePath -Encoding UTF8 } catch { Write-IXLogGUI ('STATE SAVE ERROR: ' + $_.Exception.Message) }
}
function Add-IXStateGUI($Entry) {
    $existing = @($script:IXState.Entries | Where-Object { $_.Key -eq $Entry.Key -and $_.Status -eq 'Applied' } | Select-Object -First 1)
    if ($existing.Count -gt 0) { return $existing[0] }
    $script:IXState.Entries = @($script:IXState.Entries) + @($Entry)
    Save-IXStateGUI
    return $Entry
}
function Get-IXAdaptersGUI {
    try { return @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) } catch { return @() }
}
function Get-IXGatewayGUI {
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        if ($cfg) { return [string]$cfg.IPv4DefaultGateway.NextHop }
    } catch {}
    return $null
}
function Show-IXMessage([string]$Message,[string]$Title='InternetX',[System.Windows.Forms.MessageBoxIcon]$Icon=[System.Windows.Forms.MessageBoxIcon]::Information) {
    [void][System.Windows.Forms.MessageBox]::Show($Message,$Title,[System.Windows.Forms.MessageBoxButtons]::OK,$Icon)
}
function New-IXLabel([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H,[int]$Size=10,[bool]$Bold=$false,[System.Drawing.Color]$Color=([System.Drawing.Color]::FromArgb(225,232,242))) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X,$Y); $l.Size = New-Object System.Drawing.Size($W,$H)
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    $l.Font = New-Object System.Drawing.Font('Segoe UI',$Size,$style)
    $l.ForeColor = $Color; $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}
function New-IXButton([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H,[bool]$Primary=$false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X,$Y); $b.Size = New-Object System.Drawing.Size($W,$H)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(55,77,105)
    $b.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
    if ($Primary) { $b.BackColor = [System.Drawing.Color]::FromArgb(0,135,210); $b.ForeColor = [System.Drawing.Color]::White }
    else { $b.BackColor = [System.Drawing.Color]::FromArgb(31,44,63); $b.ForeColor = [System.Drawing.Color]::FromArgb(230,238,248) }
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}
function Set-IXPage([string]$PageName) {
    foreach ($pair in $script:IXPages.GetEnumerator()) { $pair.Value.Visible = ($pair.Key -eq $PageName) }
    foreach ($b in $script:IXNavButtons) {
        if ([string]$b.Tag -eq $PageName) { $b.BackColor = [System.Drawing.Color]::FromArgb(0,111,175) }
        else { $b.BackColor = [System.Drawing.Color]::FromArgb(23,34,51) }
    }
    $script:IXStatus.Text = 'Ready  |  ' + $PageName
}
function Refresh-IXOverview {
    $adapters = @(Get-IXAdaptersGUI)
    if ($adapters.Count -gt 0) {
        $primary = $adapters[0]
        try {
            $cfgs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway })
            foreach ($cfg in $cfgs) {
                $candidate = $adapters | Where-Object { $_.ifIndex -eq $cfg.InterfaceIndex } | Select-Object -First 1
                if ($candidate) { $primary = $candidate; break }
            }
        } catch {}
        $script:IXAdapterSummary.Text = "$($primary.Name)  |  $($primary.InterfaceDescription)`r`nLink: $($primary.LinkSpeed)    Status: $($primary.Status)"
    } else { $script:IXAdapterSummary.Text = 'No active physical adapter detected.' }
    $script:IXAdminSummary.Text = if ($script:IXIsAdmin) { 'Administrator: YES' } else { 'Administrator: NO — read-only functions only; reopen as admin to change settings.' }
}
function Refresh-IXAdapterCombo {
    $script:IXAdapterCombo.Items.Clear()
    foreach ($a in (Get-IXAdaptersGUI)) { [void]$script:IXAdapterCombo.Items.Add([string]$a.Name) }
    if ($script:IXAdapterCombo.Items.Count -gt 0) { $script:IXAdapterCombo.SelectedIndex = 0 }
}
function Clear-IXAdvancedRows {
    $script:IXAdvancedFlow.Controls.Clear()
}
function Render-IXAdvancedProperties {
    Clear-IXAdvancedRows
    $name = [string]$script:IXAdapterCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($name)) {
        $script:IXAdvancedFlow.Controls.Add((New-IXLabel 'No active adapter selected.' 14 12 600 26 10 $false ([System.Drawing.Color]::FromArgb(238,190,100))))
        return
    }
    try { $props = @(Get-NetAdapterAdvancedProperty -Name $name -AllProperties -ErrorAction Stop) }
    catch {
        $script:IXAdvancedFlow.Controls.Add((New-IXLabel ('Could not read driver properties: ' + $_.Exception.Message) 14 12 720 44 10 $false ([System.Drawing.Color]::FromArgb(255,130,130))))
        return
    }
    $patterns = 'Interrupt Moderation|Energy Efficient Ethernet|Green Ethernet|Advanced EEE|Receive Buffers|Rx.*Buffers|Transmit Buffers|Tx.*Buffers|Roaming Aggressiveness|MIMO Power Save'
    $matches = @($props | Where-Object { $_.DisplayName -match $patterns })
    if ($matches.Count -eq 0) {
        $script:IXAdvancedFlow.Controls.Add((New-IXLabel 'This driver does not expose the common tweakable properties. Nothing was changed.' 14 12 710 46 10 $false ([System.Drawing.Color]::FromArgb(238,190,100))))
    } else {
        foreach ($prop in $matches) {
            $row = New-Object System.Windows.Forms.Panel
            $row.Height = 70; $row.Width = 775; $row.Margin = New-Object System.Windows.Forms.Padding(4,3,4,3)
            $row.BackColor = [System.Drawing.Color]::FromArgb(24,36,53)
            $row.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $nameLabel = New-IXLabel ([string]$prop.DisplayName) 12 7 300 23 9 $true
            $valueLabel = New-IXLabel ("Current: {0}" -f $prop.DisplayValue) 12 32 300 22 8 $false ([System.Drawing.Color]::FromArgb(158,177,202))
            $combo = New-Object System.Windows.Forms.ComboBox
            $combo.Location = New-Object System.Drawing.Point(325,18); $combo.Size = New-Object System.Drawing.Size(280,25)
            $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
            $combo.BackColor = [System.Drawing.Color]::FromArgb(17,25,38); $combo.ForeColor = [System.Drawing.Color]::White
            foreach ($v in @($prop.ValidDisplayValues | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { [void]$combo.Items.Add($v) }
            if ($combo.Items.Count -gt 0) {
                $idx = $combo.Items.IndexOf([string]$prop.DisplayValue)
                if ($idx -ge 0) { $combo.SelectedIndex = $idx } else { $combo.SelectedIndex = 0 }
            } else { $combo.Enabled = $false }
            $apply = New-IXButton 'Apply' 620 17 90 31 $true
            $meta = [pscustomobject]@{ AdapterName=$name; Property=$prop; Combo=$combo; Current=[string]$prop.DisplayValue }
            $apply.Tag = $meta
            $apply.Add_Click({
                $btn = $this
                $info = $btn.Tag
                if (-not $script:IXIsAdmin) { Show-IXMessage 'Administrator rights are required to change adapter settings.' 'InternetX' ([System.Windows.Forms.MessageBoxIcon]::Warning); return }
                if ($null -eq $info.Combo.SelectedItem) { Show-IXMessage 'This driver exposes no selectable values.'; return }
                $desired = [string]$info.Combo.SelectedItem
                if ($desired -eq $info.Current) { Show-IXMessage 'This value is already selected.'; return }
                $answer = [System.Windows.Forms.MessageBox]::Show("Adapter: $($info.AdapterName)`r`nProperty: $($info.Property.DisplayName)`r`nCurrent: $($info.Current)`r`nNew: $desired`r`n`r`nChanging this setting may affect latency or connectivity. Continue?",'Confirm adapter change',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                $keyword = [string]$info.Property.RegistryKeyword
                if ([string]::IsNullOrWhiteSpace($keyword)) { $keyword = [string]$info.Property.DisplayName }
                $entry = [pscustomobject]@{ Key=('PROP|' + $info.AdapterName + '|' + $keyword); Type='AdapterProperty'; AdapterName=$info.AdapterName; DisplayName=[string]$info.Property.DisplayName; RegistryKeyword=[string]$info.Property.RegistryKeyword; OriginalDisplayValue=$info.Current; Status='Pending'; Created=(Get-Date).ToString('s'); LastUpdated=(Get-Date).ToString('s') }
                try {
                    $entry = Add-IXStateGUI $entry
                    Set-NetAdapterAdvancedProperty -Name $info.AdapterName -DisplayName $info.Property.DisplayName -DisplayValue $desired -NoRestart -ErrorAction Stop
                    $entry.Status = 'Applied'; $entry.LastUpdated=(Get-Date).ToString('s'); Save-IXStateGUI
                    Write-IXLogGUI ("Adapter changed: {0} / {1}: {2} -> {3}" -f $info.AdapterName,$info.Property.DisplayName,$info.Current,$desired)
                    Show-IXMessage 'Setting applied. Some drivers require an adapter restart or Windows restart.' 'InternetX'
                    Render-IXAdvancedProperties
                } catch { Show-IXMessage ('Change failed: ' + $_.Exception.Message) 'InternetX' ([System.Windows.Forms.MessageBoxIcon]::Error) }
            })
            $row.Controls.AddRange(@($nameLabel,$valueLabel,$combo,$apply))
            [void]$script:IXAdvancedFlow.Controls.Add($row)
        }
    }
    # RSS toggle card; only add if the adapter cmdlet supports it.
    try {
        $rss = Get-NetAdapterRss -Name $name -ErrorAction Stop | Select-Object -First 1
        $row = New-Object System.Windows.Forms.Panel; $row.Height=70; $row.Width=775; $row.Margin=New-Object System.Windows.Forms.Padding(4,3,4,3); $row.BackColor=[System.Drawing.Color]::FromArgb(24,36,53)
        $stateText = if ($rss.Enabled) { 'Enabled' } else { 'Disabled' }
        $lab = New-IXLabel ("Receive Side Scaling (RSS)  |  Current: $stateText") 12 19 470 25 9 $true
        $rssButton = New-IXButton $(if ($rss.Enabled) { 'Already Enabled' } else { 'Enable RSS' }) 620 17 110 31 $true
        $rssButton.Enabled = -not [bool]$rss.Enabled
        $rssButton.Tag = [pscustomobject]@{AdapterName=$name; Original=[bool]$rss.Enabled}
        $rssButton.Add_Click({
            $btn=$this; $m=$btn.Tag
            if (-not $script:IXIsAdmin) { Show-IXMessage 'Administrator rights are required.'; return }
            $answer=[System.Windows.Forms.MessageBox]::Show("Enable RSS for adapter $($m.AdapterName)? Driver support and performance vary.",'Confirm RSS',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $entry=[pscustomobject]@{Key=('RSS|' + $m.AdapterName);Type='RSS';AdapterName=$m.AdapterName;OriginalEnabled=[bool]$m.Original;Status='Pending';Created=(Get-Date).ToString('s');LastUpdated=(Get-Date).ToString('s')}
            try { $entry=Add-IXStateGUI $entry; Set-NetAdapterRss -Name $m.AdapterName -Enabled $true -NoRestart -ErrorAction Stop | Out-Null; $entry.Status='Applied';$entry.LastUpdated=(Get-Date).ToString('s');Save-IXStateGUI;Write-IXLogGUI ('RSS enabled: '+$m.AdapterName);Render-IXAdvancedProperties }
            catch { Show-IXMessage ('RSS change failed: '+$_.Exception.Message) 'InternetX' ([System.Windows.Forms.MessageBoxIcon]::Error) }
        })
        $row.Controls.AddRange(@($lab,$rssButton)); [void]$script:IXAdvancedFlow.Controls.Add($row)
    } catch {}
}

# UI palette
$C = @{
    Background = [System.Drawing.Color]::FromArgb(12,18,29)
    Sidebar = [System.Drawing.Color]::FromArgb(16,25,39)
    Panel = [System.Drawing.Color]::FromArgb(20,31,47)
    Panel2 = [System.Drawing.Color]::FromArgb(24,36,53)
    Accent = [System.Drawing.Color]::FromArgb(0,155,230)
    Text = [System.Drawing.Color]::FromArgb(230,237,247)
    Muted = [System.Drawing.Color]::FromArgb(145,163,188)
    Border = [System.Drawing.Color]::FromArgb(41,59,82)
}
$form = New-Object System.Windows.Forms.Form
$form.Text = 'InternetX | FiveM Network Utility'
$form.Size = New-Object System.Drawing.Size(1120,760)
$form.MinimumSize = New-Object System.Drawing.Size(1020,690)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Background
$form.ForeColor = $C.Text
$form.Font = New-Object System.Drawing.Font('Segoe UI',9)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable

# Sidebar
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = [System.Windows.Forms.DockStyle]::Left; $sidebar.Width = 218; $sidebar.BackColor = $C.Sidebar
$brand = New-IXLabel 'InternetX' 22 22 170 34 21 $true ([System.Drawing.Color]::FromArgb(69,194,255)); $sidebar.Controls.Add($brand)
$brandSub = New-IXLabel 'FIVEM NETWORK UTILITY' 24 57 178 22 8 $true $C.Muted; $sidebar.Controls.Add($brandSub)
$navSep = New-Object System.Windows.Forms.Panel; $navSep.Location=New-Object System.Drawing.Point(18,91);$navSep.Size=New-Object System.Drawing.Size(180,1);$navSep.BackColor=$C.Border;$sidebar.Controls.Add($navSep)
$script:IXPages = @{}
$script:IXNavButtons = New-Object 'System.Collections.Generic.List[object]'
$content = New-Object System.Windows.Forms.Panel; $content.Dock=[System.Windows.Forms.DockStyle]::Fill; $content.BackColor=$C.Background; $form.Controls.Add($content)
$header = New-Object System.Windows.Forms.Panel; $header.Dock=[System.Windows.Forms.DockStyle]::Top; $header.Height=78; $header.BackColor=$C.Background
$script:IXPageTitle = New-IXLabel 'Overview' 28 19 600 32 19 $true; $header.Controls.Add($script:IXPageTitle)
$script:IXStatus = New-IXLabel 'Ready' 660 26 390 23 9 $false $C.Muted; $script:IXStatus.TextAlign=[System.Drawing.ContentAlignment]::MiddleRight; $header.Controls.Add($script:IXStatus)
$body = New-Object System.Windows.Forms.Panel; $body.Dock=[System.Windows.Forms.DockStyle]::Fill; $body.BackColor=$C.Background; $body.Padding=New-Object System.Windows.Forms.Padding(22,4,22,18); $content.Controls.Add($body); $content.Controls.Add($header); $header.BringToFront(); $form.Controls.Add($sidebar); $sidebar.BringToFront()

# Create pages
foreach ($name in @('Overview','Network Diagnostics','Advanced Network Tuning','Restore & Reports')) {
    $p = New-Object System.Windows.Forms.Panel; $p.Dock=[System.Windows.Forms.DockStyle]::Fill; $p.BackColor=$C.Background; $p.Visible=$false; $p.AutoScroll=$true
    $body.Controls.Add($p); $script:IXPages[$name]=$p
}
function Add-IXNav([string]$Text,[string]$Page,[int]$Y) {
    $b = New-IXButton $Text 14 $Y 190 42 $false; $b.TextAlign=[System.Drawing.ContentAlignment]::MiddleLeft; $b.Padding=New-Object System.Windows.Forms.Padding(12,0,0,0); $b.Tag=$Page
    $b.Add_Click({ Set-IXPage ([string]$this.Tag); $script:IXPageTitle.Text=[string]$this.Tag })
    $sidebar.Controls.Add($b); [void]$script:IXNavButtons.Add($b)
}
Add-IXNav '  Overview' 'Overview' 112
Add-IXNav '  Network Diagnostics' 'Network Diagnostics' 160
Add-IXNav '  Advanced Network Tuning' 'Advanced Network Tuning' 208
Add-IXNav '  Restore & Reports' 'Restore & Reports' 256
$navFoot = New-IXLabel 'Driver-supported settings only`r`nNo intentional desync' 20 625 180 42 8 $false $C.Muted; $sidebar.Controls.Add($navFoot)

# Overview page
$ov = $script:IXPages['Overview']
$card1 = New-Object System.Windows.Forms.Panel; $card1.Location=New-Object System.Drawing.Point(0,10);$card1.Size=New-Object System.Drawing.Size(800,134);$card1.BackColor=$C.Panel;$ov.Controls.Add($card1)
$card1.Controls.Add((New-IXLabel 'ACTIVE NETWORK ADAPTER' 18 14 300 22 9 $true $C.Muted))
$script:IXAdapterSummary = New-IXLabel 'Detecting adapter...' 18 43 740 42 13 $true $C.Text; $card1.Controls.Add($script:IXAdapterSummary)
$script:IXAdminSummary = New-IXLabel '' 18 94 740 22 9 $false $C.Muted; $card1.Controls.Add($script:IXAdminSummary)
$scanBtn = New-IXButton 'Refresh status' 18 166 140 36 $true; $ov.Controls.Add($scanBtn)
$diagBtn = New-IXButton 'Run Ping test' 172 166 140 36 $false; $ov.Controls.Add($diagBtn)
$tuneBtn = New-IXButton 'Advanced Network Tuning' 326 166 220 36 $false; $ov.Controls.Add($tuneBtn)
$notePanel = New-Object System.Windows.Forms.Panel; $notePanel.Location=New-Object System.Drawing.Point(0,222);$notePanel.Size=New-Object System.Drawing.Size(800,166);$notePanel.BackColor=$C.Panel2;$ov.Controls.Add($notePanel)
$notePanel.Controls.Add((New-IXLabel 'IMPORTANT' 18 15 180 24 10 $true ([System.Drawing.Color]::FromArgb(77,197,255))))
$noteText = "InternetX measures connectivity and offers optional adapter settings exposed by the installed driver.`r`nIt does not create lag, desynchronization, or change damage / hit registration.`r`nTest one adapter setting at a time and compare results before and after.`r`nReports are saved under Desktop\InternetX-Reports."
$notePanel.Controls.Add((New-IXLabel $noteText 18 47 760 100 10 $false $C.Text))
$scanBtn.Add_Click({ Refresh-IXOverview; Show-IXMessage 'Adapter status refreshed.' })
$diagBtn.Add_Click({ Set-IXPage 'Network Diagnostics'; $script:IXPageTitle.Text='Network Diagnostics' })
$tuneBtn.Add_Click({ Set-IXPage 'Advanced Network Tuning'; $script:IXPageTitle.Text='Advanced Network Tuning'; Refresh-IXAdapterCombo; Render-IXAdvancedProperties })

# Diagnostics page
$dg = $script:IXPages['Network Diagnostics']
$dg.Controls.Add((New-IXLabel 'Run an ICMP test to compare your gateway with public endpoints.' 0 10 770 25 10 $false $C.Muted))
$dg.Controls.Add((New-IXLabel 'Extra IPv4 host / IP (optional)' 0 50 300 22 9 $true))
$targetBox = New-Object System.Windows.Forms.TextBox; $targetBox.Location=New-Object System.Drawing.Point(0,77);$targetBox.Size=New-Object System.Drawing.Size(310,28);$targetBox.Text='';$targetBox.BackColor=$C.Panel2;$targetBox.ForeColor=$C.Text;$targetBox.BorderStyle='FixedSingle';$dg.Controls.Add($targetBox)
$runPingBtn = New-IXButton 'Run 15-probe test' 328 75 170 32 $true; $dg.Controls.Add($runPingBtn)
$runMtuBtn = New-IXButton 'Path MTU test' 510 75 135 32 $false; $dg.Controls.Add($runMtuBtn)
$script:IXDiagStatus = New-IXLabel 'Ready to test.' 0 120 780 24 9 $false $C.Muted; $dg.Controls.Add($script:IXDiagStatus)
$diagOutput = New-Object System.Windows.Forms.TextBox; $diagOutput.Location=New-Object System.Drawing.Point(0,153);$diagOutput.Size=New-Object System.Drawing.Size(800,355);$diagOutput.Multiline=$true;$diagOutput.ReadOnly=$true;$diagOutput.ScrollBars='Vertical';$diagOutput.BackColor=$C.Panel;$diagOutput.ForeColor=$C.Text;$diagOutput.Font=New-Object System.Drawing.Font('Consolas',9);$diagOutput.BorderStyle='FixedSingle';$dg.Controls.Add($diagOutput)
$script:IXWorker = $null
$runPingBtn.Add_Click({
    if ($script:IXWorker -and $script:IXWorker.IsBusy) { return }
    $custom = $targetBox.Text.Trim()
    if ($custom -match '[\s;&|<>`"]') { Show-IXMessage 'Enter a valid hostname or IP without spaces or shell characters.' 'Invalid target' ([System.Windows.Forms.MessageBoxIcon]::Warning); return }
    $targets = New-Object 'System.Collections.Generic.List[object]'
    $gw = Get-IXGatewayGUI
    if ($gw) { [void]$targets.Add([pscustomobject]@{Name='Gateway';IP=$gw}) }
    foreach ($ip in @('1.1.1.1','8.8.8.8')) { if (@($targets | Where-Object {$_.IP -eq $ip}).Count -eq 0) { [void]$targets.Add([pscustomobject]@{Name=$ip;IP=$ip}) } }
    if ($custom) {
        $resolved = $null
        try { $resolved = [System.Net.Dns]::GetHostAddresses($custom) | Where-Object {$_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork} | Select-Object -First 1 } catch {}
        if (-not $resolved) { Show-IXMessage 'Could not resolve that host to IPv4.' 'Invalid target' ([System.Windows.Forms.MessageBoxIcon]::Warning); return }
        $customIP = $resolved.IPAddressToString
        if (@($targets | Where-Object {$_.IP -eq $customIP}).Count -eq 0) { [void]$targets.Add([pscustomobject]@{Name=$custom;IP=$customIP}) }
    }
    $runPingBtn.Enabled=$false; $script:IXDiagStatus.Text='Testing…'; $diagOutput.Clear()
    $worker = New-Object System.ComponentModel.BackgroundWorker; $worker.WorkerReportsProgress=$true
    $worker.add_DoWork({
        param($sender,$e)
        $inputTargets = @($e.Argument)
        $results = New-Object 'System.Collections.Generic.List[object]'
        foreach ($t in $inputTargets) {
            $sender.ReportProgress(0,('Testing ' + $t.Name + ' (' + $t.IP + ')...'))
            $rtts = New-Object 'System.Collections.Generic.List[double]'
            $statuses = New-Object 'System.Collections.Generic.List[string]'
            $previous = $null; $diffs = New-Object 'System.Collections.Generic.List[double]'
            for ($i=1; $i -le 15; $i++) {
                $p = $null
                try {
                    $p = New-Object System.Net.NetworkInformation.Ping
                    $reply = $p.Send([string]$t.IP,900)
                    $status = [string]$reply.Status; [void]$statuses.Add($status)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $rtt = [double]$reply.RoundtripTime; [void]$rtts.Add($rtt)
                        if ($null -ne $previous) { [void]$diffs.Add([math]::Abs($rtt-$previous)) }
                        $previous = $rtt
                    } else { $previous = $null }
                } catch { [void]$statuses.Add('Error'); $previous = $null }
                finally { if ($p) { $p.Dispose() } }
                $sender.ReportProgress(0,('Testing {0}: {1}/15' -f $t.Name,$i))
            }
            $sent = $statuses.Count; $received = $rtts.Count; $lost = $sent-$received; $lossPct = if ($sent) {[math]::Round(100*$lost/$sent,1)} else {0}
            $min=$null;$avg=$null;$max=$null;$jitter=$null;$p95=$null
            if ($received -gt 0) {
                $stats=$rtts | Measure-Object -Minimum -Average -Maximum
                $min=[math]::Round([double]$stats.Minimum,1);$avg=[math]::Round([double]$stats.Average,1);$max=[math]::Round([double]$stats.Maximum,1)
                if ($diffs.Count -gt 0) {$jitter=[math]::Round((($diffs | Measure-Object -Average).Average),1)}
                $sorted=@($rtts | Sort-Object);$p95Index=[int][math]::Ceiling(.95*$sorted.Count)-1;$p95Index=[math]::Max(0,[math]::Min($p95Index,$sorted.Count-1));$p95=[math]::Round([double]$sorted[$p95Index],1)
            }
            [void]$results.Add([pscustomobject]@{Target=$t.Name;IP=$t.IP;Sent=$sent;Received=$received;LossPct=$lossPct;MinMs=$min;AvgMs=$avg;MaxMs=$max;JitterMs=$jitter;P95Ms=$p95;Statuses=($statuses -join ',')})
        }
        $e.Result = @($results.ToArray())
    })
    $worker.add_ProgressChanged({ param($sender,$e) $script:IXDiagStatus.Text=[string]$e.UserState })
    $worker.add_RunWorkerCompleted({
        param($sender,$e)
        $runPingBtn.Enabled=$true
        if ($e.Error) { $script:IXDiagStatus.Text='Test failed.'; $diagOutput.Text=$e.Error.Exception.Message; return }
        $rows=@($e.Result)
        $builder=New-Object System.Text.StringBuilder
        [void]$builder.AppendLine('INTERNETX NETWORK DIAGNOSTICS')
        [void]$builder.AppendLine(('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
        [void]$builder.AppendLine('ICMP results are not the same as actual FiveM server latency.')
        [void]$builder.AppendLine('')
        foreach ($r in $rows) {
            [void]$builder.AppendLine(('Target: {0} ({1})' -f $r.Target,$r.IP))
            [void]$builder.AppendLine(('  Replies {0}/{1} | Loss {2}% | Min {3} ms | Avg {4} ms | Max {5} ms | Jitter {6} ms | P95 {7} ms' -f $r.Received,$r.Sent,$r.LossPct,$r.MinMs,$r.AvgMs,$r.MaxMs,$r.JitterMs,$r.P95Ms))
            [void]$builder.AppendLine('')
        }
        $diagOutput.Text=$builder.ToString(); $script:IXDiagStatus.Text='Completed. Report saved.'
        $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
        try { $rows | Export-Csv -LiteralPath (Join-Path $script:IXReports "NetworkTest_$stamp.csv") -NoTypeInformation -Encoding UTF8 } catch {}
        try { $diagOutput.Text | Set-Content -LiteralPath (Join-Path $script:IXReports "NetworkTest_$stamp.txt") -Encoding UTF8 } catch {}
        Write-IXLogGUI ('Network test completed. Destinations: ' + (($rows | ForEach-Object {$_.IP}) -join ', '))
    })
    $script:IXWorker=$worker
    $worker.RunWorkerAsync($targets.ToArray())
})

$runMtuBtn.Add_Click({
    if ($script:IXWorker -and $script:IXWorker.IsBusy) { return }
    $custom = $targetBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($custom)) { $custom = '1.1.1.1' }
    if ($custom -match '[\s;&|<>`"]') { Show-IXMessage 'Enter a valid hostname or IPv4 address.' 'Invalid target' ([System.Windows.Forms.MessageBoxIcon]::Warning); return }
    $resolved = $null
    try { $resolved = [System.Net.Dns]::GetHostAddresses($custom) | Where-Object {$_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork} | Select-Object -First 1 } catch {}
    if (-not $resolved) { Show-IXMessage 'Could not resolve the target to IPv4.' 'Invalid target' ([System.Windows.Forms.MessageBoxIcon]::Warning); return }
    $dest = $resolved.IPAddressToString
    $runPingBtn.Enabled = $false; $runMtuBtn.Enabled = $false; $script:IXDiagStatus.Text = 'Testing path MTU…'; $diagOutput.Clear()
    $worker = New-Object System.ComponentModel.BackgroundWorker; $worker.WorkerReportsProgress = $true
    $worker.add_DoWork({
        param($sender,$e)
        $targetIP = [string]$e.Argument
        $samples = @(548,900,1100,1200,1280,1360,1400,1420,1440,1452,1464,1472)
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $pingExe = Join-Path $env:SystemRoot 'System32\ping.exe'
        foreach ($size in $samples) {
            $pass=0; $tooBig=0; $fail=0
            for ($i=0; $i -lt 3; $i++) {
                $output = @(& $pingExe -4 -n 1 -w 1000 -f -l $size $targetIP 2>&1)
                $exit = $LASTEXITCODE
                $msg = ($output | ForEach-Object {[string]$_}) -join ' '
                if ($msg -match '(?i)(needs to be fragmented|packet needs to be fragmented|fragmentation needed|packet too big|must be fragmented|fragment|分片|分段)') { $tooBig++ }
                elseif ($exit -eq 0) { $pass++ }
                else { $fail++ }
            }
            $state = if ($pass -eq 3) {'PASS'} elseif ($tooBig -eq 3) {'TOO_BIG'} else {'INCONCLUSIVE'}
            [void]$rows.Add([pscustomobject]@{Payload=$size; IPv4PacketBytes=$size+28; Replies=$pass; TooBig=$tooBig; OtherFailures=$fail; Result=$state})
            $sender.ReportProgress(0,('MTU payload {0} bytes: {1}' -f $size,$state))
        }
        $largest = @($rows | Where-Object {$_.Result -eq 'PASS'} | Sort-Object Payload -Descending | Select-Object -First 1)
        $boundary = @($rows | Where-Object {$_.Result -eq 'TOO_BIG'} | Sort-Object Payload | Select-Object -First 1)
        $summary = if ($largest.Count -and $boundary.Count -and $boundary[0].Payload -gt $largest[0].Payload) {
            'Candidate MTU lower bound: ' + $largest[0].IPv4PacketBytes + ' bytes. First confirmed too-big payload: ' + $boundary[0].Payload + ' bytes. Confirm boundary with a narrow search before changing anything.'
        } elseif ($largest.Count -and $largest[0].Payload -eq 1472) {
            'At least 1500-byte IPv4 packets passed to this test target; exact maximum is not established.'
        } else {
            'INCONCLUSIVE: no reliable MTU boundary was established. No settings were changed.'
        }
        $e.Result = [pscustomobject]@{Target=$targetIP;Rows=$rows.ToArray();Summary=$summary}
    })
    $worker.add_ProgressChanged({ param($sender,$e) $script:IXDiagStatus.Text = [string]$e.UserState })
    $worker.add_RunWorkerCompleted({
        param($sender,$e)
        $runPingBtn.Enabled = $true; $runMtuBtn.Enabled = $true
        if ($e.Error) { $script:IXDiagStatus.Text='MTU test failed.'; $diagOutput.Text=$e.Error.Exception.Message; return }
        $result=$e.Result
        $sb=New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('INTERNETX PATH MTU DIAGNOSTIC')
        [void]$sb.AppendLine(('Target: ' + $result.Target))
        [void]$sb.AppendLine('No MTU settings were changed.')
        [void]$sb.AppendLine('')
        foreach ($row in $result.Rows) { [void]$sb.AppendLine(('Payload {0,4} B | packet {1,4} B | reply {2}/3 | too-big {3}/3 | {4}' -f $row.Payload,$row.IPv4PacketBytes,$row.Replies,$row.TooBig,$row.Result)) }
        [void]$sb.AppendLine(''); [void]$sb.AppendLine($result.Summary)
        [void]$sb.AppendLine('ICMP path results may differ from the actual FiveM server route.')
        $diagOutput.Text=$sb.ToString(); $script:IXDiagStatus.Text='MTU test completed. Review the candidate; do not apply it automatically.'
        $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
        try { $result.Rows | Export-Csv -LiteralPath (Join-Path $script:IXReports "PathMTU_$stamp.csv") -NoTypeInformation -Encoding UTF8 } catch {}
        try { $diagOutput.Text | Set-Content -LiteralPath (Join-Path $script:IXReports "PathMTU_$stamp.txt") -Encoding UTF8 } catch {}
        Write-IXLogGUI ('Path MTU test completed for ' + $result.Target)
    })
    $script:IXWorker=$worker
    $worker.RunWorkerAsync($dest)
})

# Advanced tuning page
$adv=$script:IXPages['Advanced Network Tuning']
$adv.Controls.Add((New-IXLabel 'Select an active adapter. Only settings reported by its driver are shown.' 0 7 790 27 10 $false $C.Muted))
$adv.Controls.Add((New-IXLabel 'Network adapter' 0 44 150 22 9 $true))
$script:IXAdapterCombo=New-Object System.Windows.Forms.ComboBox;$script:IXAdapterCombo.Location=New-Object System.Drawing.Point(0,70);$script:IXAdapterCombo.Size=New-Object System.Drawing.Size(330,28);$script:IXAdapterCombo.DropDownStyle='DropDownList';$script:IXAdapterCombo.BackColor=$C.Panel2;$script:IXAdapterCombo.ForeColor=$C.Text;$adv.Controls.Add($script:IXAdapterCombo)
$refreshNIC=New-IXButton 'Refresh adapters' 345 68 145 32 $false;$adv.Controls.Add($refreshNIC)
$script:IXAdapterCombo.Add_SelectedIndexChanged({ Render-IXAdvancedProperties })
$refreshNIC.Add_Click({ Refresh-IXAdapterCombo; Render-IXAdvancedProperties })
$hint=New-IXLabel 'Options are driver-specific. Choose one change at a time; compare the network test before and after.' 0 111 795 38 9 $false ([System.Drawing.Color]::FromArgb(238,190,100));$adv.Controls.Add($hint)
$script:IXAdvancedFlow=New-Object System.Windows.Forms.FlowLayoutPanel;$script:IXAdvancedFlow.Location=New-Object System.Drawing.Point(0,156);$script:IXAdvancedFlow.Size=New-Object System.Drawing.Size(815,440);$script:IXAdvancedFlow.FlowDirection=[System.Windows.Forms.FlowDirection]::TopDown;$script:IXAdvancedFlow.WrapContents=$false;$script:IXAdvancedFlow.AutoScroll=$true;$script:IXAdvancedFlow.BackColor=$C.Background;$adv.Controls.Add($script:IXAdvancedFlow)

# Restore and reports page
$rr=$script:IXPages['Restore & Reports']
$rr.Controls.Add((New-IXLabel 'Restore settings changed by InternetX and open your diagnostic reports.' 0 10 780 25 10 $false $C.Muted))
$restoreBtn=New-IXButton 'Restore InternetX changes' 0 54 220 38 $true;$rr.Controls.Add($restoreBtn)
$openReportsBtn=New-IXButton 'Open report folder' 236 54 170 38 $false;$rr.Controls.Add($openReportsBtn)
$openLogsBtn=New-IXButton 'Open log folder' 420 54 150 38 $false;$rr.Controls.Add($openLogsBtn)
$tcpBtn=New-IXButton 'View TCP status' 0 110 160 36 $false;$rr.Controls.Add($tcpBtn)
$restoreInfo=New-IXLabel 'Restore affects only changes recorded by InternetX. Driver behavior may require a restart.' 0 166 780 52 10 $false ([System.Drawing.Color]::FromArgb(238,190,100));$rr.Controls.Add($restoreInfo)
$restoreBtn.Add_Click({
    if (-not $script:IXIsAdmin) { Show-IXMessage 'Run InternetX as Administrator to restore system settings.'; return }
    $entries=@($script:IXState.Entries | Where-Object { $_.Status -eq 'Applied' })
    if ($entries.Count -eq 0) { Show-IXMessage 'No active InternetX changes are recorded.'; return }
    $answer=[System.Windows.Forms.MessageBox]::Show(("Restore {0} recorded change(s) to original values?" -f $entries.Count),'Confirm restore',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    foreach ($entry in $entries) {
        try {
            if ($entry.Type -eq 'RSS') {
                Set-NetAdapterRss -Name $entry.AdapterName -Enabled ([bool]$entry.OriginalEnabled) -NoRestart -ErrorAction Stop | Out-Null
            } elseif ($entry.Type -eq 'AdapterProperty') {
                Set-NetAdapterAdvancedProperty -Name $entry.AdapterName -DisplayName $entry.DisplayName -DisplayValue ([string]$entry.OriginalDisplayValue) -NoRestart -ErrorAction Stop
            } else { continue }
            $entry.Status='Restored';$entry.LastUpdated=(Get-Date).ToString('s');Write-IXLogGUI ('Restored: '+$entry.Key)
        } catch { Write-IXLogGUI ('Restore failed: '+$entry.Key+' | '+$_.Exception.Message) }
    }
    Save-IXStateGUI
    Show-IXMessage 'Restore attempt finished. Review the log for failures; some drivers require restart.'
})
$openReportsBtn.Add_Click({ try { Invoke-Item -LiteralPath $script:IXReports } catch { Show-IXMessage $_.Exception.Message } })
$openLogsBtn.Add_Click({ try { Invoke-Item -LiteralPath $script:IXLogs } catch { Show-IXMessage $_.Exception.Message } })
$tcpBtn.Add_Click({
    try {
        $tcp=@(& netsh.exe interface tcp show global 2>&1 | ForEach-Object {[string]$_}) -join "`r`n"
        [void][System.Windows.Forms.MessageBox]::Show($tcp,'TCP Global Settings',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
    } catch { Show-IXMessage $_.Exception.Message }
})

# First run and nav
Refresh-IXOverview
Refresh-IXAdapterCombo
Set-IXPage 'Overview'
Write-IXLogGUI ('GUI started. Admin=' + $script:IXIsAdmin)
[void]$form.ShowDialog()
try { if ($script:IXWorker) { $script:IXWorker.Dispose() } } catch {}
try { $form.Dispose() } catch {}
