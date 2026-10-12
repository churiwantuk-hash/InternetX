#requires -Version 5.1
<#
InternetX v2.0 Compact - FiveM Network Diagnostics & Safe Optimization
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
    Write-Host ' InternetX v2.0  |  FiveM Network Utility' -ForegroundColor Cyan
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

function Save-IXReport {
    param([string]$Name,[string[]]$Lines,[object[]]$Rows)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = ($Name -replace '[^A-Za-z0-9_-]','_')
    $txt = Join-Path $script:IXReportDir ('{0}_{1}.txt' -f $safeName,$stamp)
    try { $Lines | Set-Content -LiteralPath $txt -Encoding UTF8; Write-Host ('Report: {0}' -f $txt) -ForegroundColor Green; Write-IXLog ('Report saved: ' + $txt) } catch { Write-Host 'Report could not be saved.' -ForegroundColor Yellow }
    if ($Rows -and $Rows.Count -gt 0) {
        $csv = Join-Path $script:IXReportDir ('{0}_{1}.csv' -f $safeName,$stamp)
        try { $Rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8; Write-Host ('CSV: {0}' -f $csv) -ForegroundColor Green } catch { }
    }
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
    $pinger = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($i=0; $i -lt $Count; $i++) {
            try {
                $reply = $pinger.Send($ip,$TimeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    [void]$rtts.Add([double]$reply.RoundtripTime)
                    [void]$sentStatuses.Add('Success')
                } else { [void]$sentStatuses.Add([string]$reply.Status) }
            } catch { [void]$sentStatuses.Add('Error') }
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
    if ($received -ge 2) {
        $diffs = @()
        for ($j=1; $j -lt $rtts.Count; $j++) { $diffs += [math]::Abs($rtts[$j] - $rtts[$j-1]) }
        if ($diffs.Count -gt 0) { $jitter = [math]::Round((($diffs | Measure-Object -Average).Average),1) }
    }
    $result = 'Sample complete; compare destinations and repeat during gameplay'
    if ($received -eq 0) { $result = 'No ICMP replies; ICMP may be blocked or target unreachable' }
    elseif ($lossPct -ge 5) { $result = 'Packet loss observed in this sample' }
    elseif ($null -ne $jitter -and $jitter -ge 15) { $result = 'High RTT variation in this sample (heuristic)' }
    elseif ($lossPct -eq 0) { $result = 'No packet loss observed in this sample' }
    return [pscustomobject]@{ Target=$Target; Resolved=$ip; Sent=$Count; Received=$received; Lost=$lost; LossPct=$lossPct; MinMs=$min; AvgMs=$avg; MaxMs=$max; JitterMs=$jitter; Result=$result }
}

function Invoke-IXLatencyTest {
    Show-IXHeader
    Write-Host 'PING / JITTER / PACKET LOSS' -ForegroundColor Yellow
    Write-Host 'Each target: 15 probes. Jitter is mean absolute difference between consecutive successful RTTs.' -ForegroundColor DarkGray
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
    Save-IXReport -Name 'Ping-Jitter-Loss' -Lines $lines -Rows @($tests)
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
    Save-IXReport -Name 'Path-MTU' -Lines $lines -Rows @($rows)
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

Write-IXLog ('InternetX started. Admin=' + $script:IXAdmin)
while ($true) {
    Show-IXHeader
    Write-Host '[1] Quick network scan' -ForegroundColor Cyan
    Write-Host '[2] Ping / jitter / packet loss test' -ForegroundColor Cyan
    Write-Host '[3] Path MTU test + final summary' -ForegroundColor Cyan
    Write-Host '[4] Optimization & restore' -ForegroundColor Yellow
    Write-Host '[0] Exit' -ForegroundColor Gray
    $choice = (Read-Host 'Select 0-4').Trim()
    switch ($choice) {
        '1' { Invoke-IXQuickScan }
        '2' { Invoke-IXLatencyTest }
        '3' { Invoke-IXMtuTest }
        '4' { Invoke-IXOptimizationMenu }
        '0' { Write-IXLog 'InternetX exited.'; break }
        default { Write-Host 'Invalid choice. Enter 0, 1, 2, 3 or 4.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
    if ($choice -eq '0') { break }
}
