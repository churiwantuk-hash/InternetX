#requires -Version 5.1
<#
InternetX v2.6 - Advanced Network Tuning ALL
Windows 10/11. Diagnostics measure connectivity; they do not create lag or desynchronization.
Changes are limited to supported RSS/EEE adapter options and have a rollback manifest.
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

function Show-IXHeader {
    Clear-Host
    $osText = 'Windows 10/11'
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $osText = '{0} (build {1})' -f $os.Caption,$os.BuildNumber } catch { }
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' InternetX v2.5  |  FiveM Network Utility' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (' {0} | Admin: {1}' -f $osText, $(if ($script:IXAdmin) { 'YES' } else { 'NO' })) -ForegroundColor DarkGray
    $primary = Get-IXPrimaryAdapter
    if ($primary) {
        $adapterLabel = [string]$primary.Name
        if ($adapterLabel.Length -gt 38) { $adapterLabel = $adapterLabel.Substring(0,35) + '...' }
        Write-Host (' Adapter: {0} | Link: {1}' -f $adapterLabel,$primary.LinkSpeed) -ForegroundColor Gray
    } else {
        Write-Host ' Adapter: no active default-route adapter detected' -ForegroundColor Yellow
    }
    Write-Host ' Diagnostics do not create lag or player desynchronization.' -ForegroundColor DarkGray
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
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
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[object]]$Destination
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
    Write-Host 'REPORT WRITER SELF-TEST' -ForegroundColor Yellow
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
    Write-Host 'QUICK PC / NETWORK SCAN' -ForegroundColor Yellow
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
    Write-Host 'LIVE PING / JITTER / PACKET-LOSS MONITOR' -ForegroundColor Yellow
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
            if ($status -eq 'Success') {
                Write-Host ('[{0}] {1,5} ms  reply' -f $stamp.ToString('HH:mm:ss'),$rtt) -ForegroundColor $(if ($rtt -ge 100) { 'Yellow' } else { 'Gray' })
            } else {
                Write-Host ('[{0}] no reply ({1})' -f $stamp.ToString('HH:mm:ss'),$status) -ForegroundColor Yellow
            }
            Start-Sleep -Milliseconds 100
        }
    } finally {
        $pinger.Dispose()
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
    Write-Host 'MULTI-PATH LIVE MONITOR' -ForegroundColor Yellow
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
    Write-Host 'PING / JITTER / PACKET LOSS' -ForegroundColor Yellow
    Write-Host '[1] Quick summary (gateway + public targets)' -ForegroundColor Cyan
    Write-Host '[2] Single-target live monitor' -ForegroundColor Cyan
    Write-Host '[3] Multi-path live monitor (gateway + two external targets)' -ForegroundColor Cyan
    $mode = (Read-Host 'Choose 1-3 (Enter = 1)').Trim()
    if ($mode -eq '2') { Invoke-IXLiveMonitor; return }
    if ($mode -eq '3') { Invoke-IXMultiPathMonitor; return }
    if ($mode -ne '' -and $mode -ne '1') {
        Write-Host 'Invalid choice. Enter 1, 2, or 3.' -ForegroundColor Yellow
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
    Write-Host 'PATH MTU TEST (diagnostic only; no settings changed)' -ForegroundColor Yellow
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
    Write-Host 'OPTIMIZATION PREVIEW (read-only)' -ForegroundColor Yellow
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
                Set-NetAdapterAdvancedProperty -Name $entry.AdapterName -DisplayName $entry.DisplayName -DisplayValue ([string]$entry.OriginalDisplayValue) -NoRestart -ErrorAction Stop
            } else { continue }
            Set-IXEntryStatus -Entry $entry -Status 'Restored'
            Write-Host ("Restored: {0} / {1}" -f $entry.AdapterName,$entry.Type) -ForegroundColor Green
            Write-IXLog ('Restored: ' + $entry.AdapterName + ' / ' + $entry.Type)
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
    Write-Host 'HITREG / RUBBERBAND SYMPTOM MONITOR' -ForegroundColor Yellow
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
        Write-Host 'REPORTS & SELF-TEST' -ForegroundColor Yellow
        Write-Host '[1] Open InternetX report folder' -ForegroundColor Cyan
        Write-Host '[2] Test report writer (array/list/null)' -ForegroundColor Cyan
        Write-Host '[3] Show recent log entries' -ForegroundColor Gray
        Write-Host '[0] Back' -ForegroundColor Gray
        $choice = (Read-Host 'Select 0-3').Trim()
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
            default { Write-Host 'Invalid choice. Enter 0, 1, 2 or 3.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 900 }
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
    Write-Host 'NETWORK ADAPTER TWEAKER - SCAN ONLY' -ForegroundColor Yellow
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
    Write-Host 'NETWORK ADAPTER TWEAKER - CHANGE PREVIEW' -ForegroundColor Yellow
    $plan | Select-Object AdapterName,DisplayName,OriginalDisplayValue,TargetDisplayValue | Format-Table -AutoSize -Wrap
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

    Write-Host 'ALL - PREVIEW OF SUPPORTED ADAPTER TWEAKS' -ForegroundColor Magenta
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

    $plan | Select-Object AdapterName,Feature,DisplayName,OriginalDisplayValue,TargetDisplayValue | Format-Table -AutoSize -Wrap
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
        Write-Host 'NETWORK ADAPTER TWEAKER (OPTIONAL)' -ForegroundColor Yellow
        Write-Host 'Nothing is changed automatically. Preview first, then opt in per tweak.' -ForegroundColor DarkGray
        Write-Host '[1] Scan supported NIC properties (read-only)' -ForegroundColor Cyan
        Write-Host '[2] Disable Interrupt Moderation (optional)' -ForegroundColor Yellow
        Write-Host '[3] Disable wired EEE / Green Ethernet (optional)' -ForegroundColor Yellow
        Write-Host '[4] Maximize Receive Buffers (if numeric options are exposed)' -ForegroundColor Cyan
        Write-Host '[5] Maximize Transmit Buffers (if numeric options are exposed)' -ForegroundColor Cyan
        Write-Host '[6] Wi-Fi Roaming Aggressiveness = Lowest (Wi-Fi only)' -ForegroundColor Cyan
        Write-Host '[7] Wi-Fi MIMO Power Save = No SMPS (Wi-Fi only)' -ForegroundColor Cyan
        Write-Host '[8] Restore InternetX changes' -ForegroundColor Yellow
        Write-Host '[9] ALL - Apply all supported tweaks (preview + one confirmation)' -ForegroundColor Magenta
        Write-Host '[0] Back to main menu' -ForegroundColor Gray
        $choice = (Read-Host 'Select 0-9').Trim()
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
            default { Write-Host 'Invalid choice. Enter 0-8.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 900 }
        }
    }
}

function Invoke-IXOptimizationMenu {
    while ($true) {
        Show-IXHeader
        Write-Host 'OPTIMIZATION & RESTORE' -ForegroundColor Yellow
        Write-Host '[1] Preview supported settings' -ForegroundColor Cyan
        Write-Host '[2] Enable RSS where supported' -ForegroundColor Green
        Write-Host '[3] Optional wired EEE disable' -ForegroundColor Yellow
        Write-Host '[4] Restore InternetX changes' -ForegroundColor Yellow
        Write-Host '[5] View TCP global settings (read-only)' -ForegroundColor Gray
        Write-Host '[0] Back to main menu' -ForegroundColor Gray
        $choice = (Read-Host 'Select 0-5').Trim()
        switch ($choice) {
            '1' { Invoke-IXPreview }
            '2' { Invoke-IXApplyRSS }
            '3' { Invoke-IXDisableEEE }
            '4' { Invoke-IXRestore }
            '5' { Show-IXHeader; netsh.exe interface tcp show global; Wait-IXReturn }
            '0' { return }
            default { Write-Host 'Invalid choice. Enter 0, 1, 2, 3, 4 or 5.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}

Write-IXLog ('InternetX v2.6 started. Admin=' + $script:IXAdmin)
while ($true) {
    Show-IXHeader
    Write-Host '[1] Quick network / adapter scan' -ForegroundColor Cyan
    Write-Host '[2] Ping, jitter, packet loss + live monitor' -ForegroundColor Cyan
    Write-Host '[3] Path MTU diagnostic' -ForegroundColor Cyan
    Write-Host '[4] Optimization preview / apply / restore' -ForegroundColor Yellow
    Write-Host '[5] HitReg / rubberband symptom monitor (H = mark)' -ForegroundColor Magenta
    Write-Host '[6] Reports, logs & report-writer self-test' -ForegroundColor Gray
    Write-Host '[7] Advanced Network Tuning' -ForegroundColor Magenta
    Write-Host '[0] Exit' -ForegroundColor Gray
    $choice = (Read-Host 'Select 0-7').Trim()
    switch ($choice) {
        '1' { Invoke-IXQuickScan }
        '2' { Invoke-IXLatencyTest }
        '3' { Invoke-IXMtuTest }
        '4' { Invoke-IXOptimizationMenu }
        '5' { Invoke-IXHitRegMonitor }
        '6' { Invoke-IXReportsMenu }
        '7' { Invoke-IXAdapterTweakerMenu }
        '0' { Write-IXLog 'InternetX exited.'; break }
        default { Write-Host 'Invalid choice. Enter 0-7.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 900 }
    }
    if ($choice -eq '0') { break }
}
