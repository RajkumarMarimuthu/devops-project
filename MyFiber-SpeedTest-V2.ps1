#requires -version 5.1
<#
MyFiber Speed Test - Version 2
Windows 11 | Single-file PowerShell automation

DEFAULT:
  - Runs every day at 10:00 AM
  - Uses Chrome in headless mode (does not disturb the user)
  - Opens https://myfiber.co.in/
  - Starts the speed test
  - Waits for download/upload results
  - Adds date/time to the captured page
  - Saves a full-page PNG to \\192.168.21.19\newfolder

INSTALL:
  Right-click -> Run with PowerShell
  Or:
    powershell.exe -ExecutionPolicy Bypass -File .\MyFiber-SpeedTest-V2.ps1

CHANGE TIME:
  Edit $RunAt below, e.g. "14:30"

UNINSTALL:
  powershell.exe -ExecutionPolicy Bypass -File .\MyFiber-SpeedTest-V2.ps1 -Uninstall
#>

param(
    [switch]$Uninstall,
    [switch]$RunTask
)

# ---------------- CONFIGURATION ----------------
$RunAt       = "10:00"
$TaskName    = "MyFiber Daily Speed Test"
$Url         = "https://myfiber.co.in/"
$NetworkPath = "\\192.168.21.19\newfolder"

# Set to $true if you want the script to run the test immediately after installation.
$RunNowAfterInstall = $true

# How long to wait for the test to finish.
$MaxTestSeconds = 180
# ------------------------------------------------

$ErrorActionPreference = "Stop"

function Write-Info($Message) {
    Write-Host "[MyFiber] $Message" -ForegroundColor Cyan
}

function Find-Chrome {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $paths) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    throw "Google Chrome was not found. Install Chrome first."
}

function Test-NetworkFolder {
    param([string]$Path)
    try {
        if (-not (Test-Path $Path)) {
            throw "Network folder is not accessible: $Path"
        }
    } catch {
        throw "Cannot access $Path. Check network connectivity and share permissions. $($_.Exception.Message)"
    }
}

function Send-CdpCommand {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $obj = @{
        id = $Id
        method = $Method
        params = $Params
    }
    $json = $obj | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList (, $bytes)
    $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $buffer = New-Object byte[] 1048576
    $ms = New-Object IO.MemoryStream
    do {
        $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $buffer)
        $result = $Socket.ReceiveAsync($seg, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            throw "Chrome DevTools connection closed."
        }
        $ms.Write($buffer, 0, $result.Count)
    } while (-not $result.EndOfMessage)

    return [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}

function Get-CdpValue {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Expression
    )
    $r = Send-CdpCommand -Socket $Socket -Id $Id -Method "Runtime.evaluate" -Params @{
        expression = $Expression
        returnByValue = $true
        awaitPromise = $true
    }
    if ($r.result.result.value -ne $null) {
        return $r.result.result.value
    }
    return $null
}

function Get-CdpTarget {
    param([int]$Port)
    for ($i=0; $i -lt 30; $i++) {
        try {
            $targets = Invoke-RestMethod "http://127.0.0.1:$Port/json/list"
            $target = $targets | Where-Object { $_.type -eq "page" -and $_.url -notlike "devtools://*" } | Select-Object -First 1
            if ($target) { return $target }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw "Could not connect to Chrome DevTools."
}

function Wait-ForChrome {
    param([int]$Port)
    for ($i=0; $i -lt 30; $i++) {
        try {
            Invoke-RestMethod "http://127.0.0.1:$Port/json/version" | Out-Null
            return
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Chrome remote debugging did not start."
}

function Run-SpeedTest {
    $chrome = Find-Chrome
    Test-NetworkFolder $NetworkPath

    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $safeHost = $env:COMPUTERNAME
    $fileName = "MyFiber_${safeHost}_${stamp}.png"
    $output = Join-Path $NetworkPath $fileName

    $tempProfile = Join-Path $env:TEMP ("MyFiberChrome_" + [guid]::NewGuid().ToString("N"))
    $port = Get-Random -Minimum 9222 -Maximum 9299

    New-Item -ItemType Directory -Path $tempProfile -Force | Out-Null

    Write-Info "Starting Chrome headless..."
    $args = @(
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-background-networking",
        "--disable-sync",
        "--window-size=1440,1400",
        "--hide-scrollbars",
        "--remote-debugging-port=$port",
        "--user-data-dir=$tempProfile",
        "--disable-dev-shm-usage",
        "--disable-popup-blocking",
        "--disable-notifications",
        $Url
    )

    $proc = Start-Process -FilePath $chrome -ArgumentList $args -PassThru

    try {
        Wait-ForChrome $port
        $target = Get-CdpTarget $port

        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

        $id = 1
        Send-CdpCommand $ws $id "Page.enable" | Out-Null; $id++
        Send-CdpCommand $ws $id "Runtime.enable" | Out-Null; $id++
        Send-CdpCommand $ws $id "Emulation.setDeviceMetricsOverride" @{
            width = 1440
            height = 1400
            deviceScaleFactor = 1
            mobile = $false
        } | Out-Null; $id++

        Write-Info "Loading $Url..."
        Send-CdpCommand $ws $id "Page.navigate" @{url=$Url} | Out-Null; $id++
        Start-Sleep -Seconds 5

        # Click the site's "Start Test" control. The page has used image/button
        # controls with Start Test text, so the JS checks common clickable elements.
        $clickScript = @'
(() => {
  const els = [...document.querySelectorAll('button, input, a, img, [role="button"], div')];
  const hit = els.find(e => {
    const t = ((e.innerText || e.value || e.alt || e.title || '') + '').trim().toLowerCase();
    return t.includes('start test') || t.includes('start fiber test');
  });
  if (hit) { hit.click(); return true; }
  return false;
})()
'@
        $clicked = Get-CdpValue $ws $id $clickScript; $id++
        Write-Info "Start Test clicked: $clicked"

        # Poll the page until real non-zero Download and Upload values appear.
        $deadline = (Get-Date).AddSeconds($MaxTestSeconds)
        $complete = $false

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3

            $statusScript = @'
(() => {
  const txt = (document.body && document.body.innerText) ? document.body.innerText : '';
  const m = txt.match(/DOWNLOAD[\s\S]{0,120}?([0-9]+(?:\.[0-9]+)?)\s*MBPS[\s\S]{0,250}?UPLOAD[\s\S]{0,120}?([0-9]+(?:\.[0-9]+)?)\s*MBPS/i);
  const zeros = (txt.match(/00\.00/g) || []).length;
  return {text: txt.slice(0,10000), match: m ? [m[1],m[2]] : null, zeros: zeros};
})()
'@
            $status = Get-CdpValue $ws $id $statusScript; $id++

            if ($status -and $status.match -and
                ([double]$status.match[0] -gt 0 -or [double]$status.match[1] -gt 0)) {
                $complete = $true
                Write-Info "Speed test result detected: Download=$($status.match[0]) Mbps, Upload=$($status.match[1]) Mbps"
                break
            }
        }

        if (-not $complete) {
            throw "Speed test did not finish within $MaxTestSeconds seconds."
        }

        # Give the page a moment to finish rendering all result graphics/text.
        Start-Sleep -Seconds 3

        # Add timestamp + computer name visibly to the page before capture.
        $nowText = Get-Date -Format "dd-MM-yyyy HH:mm:ss"
        $overlayScript = @"
(() => {
  const old = document.getElementById('__myfiber_capture_stamp');
  if (old) old.remove();
  const d = document.createElement('div');
  d.id='__myfiber_capture_stamp';
  d.innerHTML = 'Test Date & Time: <b>$nowText</b> &nbsp; | &nbsp; Computer: <b>$safeHost</b>';
  Object.assign(d.style, {
    position:'fixed', top:'10px', left:'10px', zIndex:'2147483647',
    background:'rgba(255,255,255,0.96)', color:'#000', padding:'8px 12px',
    border:'2px solid #000', borderRadius:'6px', font:'bold 16px Arial',
    boxShadow:'0 2px 8px rgba(0,0,0,.3)'
  });
  document.body.appendChild(d);
  return true;
})()
"@
        Get-CdpValue $ws $id $overlayScript | Out-Null; $id++
        Start-Sleep -Seconds 1

        # Determine complete page dimensions.
        $metrics = Send-CdpCommand $ws $id "Page.getLayoutMetrics" @{}; $id++
        $contentSize = $metrics.result.contentSize
        $width = [math]::Max(1440, [math]::Ceiling([double]$contentSize.width))
        $height = [math]::Ceiling([double]$contentSize.height)

        # Capture full page as PNG.
        $shot = Send-CdpCommand $ws $id "Page.captureScreenshot" @{
            format = "png"
            captureBeyondViewport = $true
            fromSurface = $true
        }; $id++

        [IO.File]::WriteAllBytes($output, [Convert]::FromBase64String($shot.result.data))

        Write-Info "Saved: $output"

        $ws.CloseAsync(
            [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
            "done",
            [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()
        $ws.Dispose()
    }
    finally {
        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill() } catch {}
        }
        if (Test-Path $tempProfile) {
            Remove-Item $tempProfile -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $output
}

# ---------------- SCHEDULED TASK EXECUTION ----------------
if ($RunTask) {
    try {
        Run-SpeedTest | Out-Null
        exit 0
    } catch {
        Write-EventLog -LogName Application -Source "Windows PowerShell" -EventId 1001 -EntryType Error `
            -Message "MyFiber Speed Test failed: $($_.Exception.Message)" -ErrorAction SilentlyContinue
        exit 1
    }
}

# ---------------- UNINSTALL ----------------
if ($Uninstall) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "Removed scheduled task: $TaskName" -ForegroundColor Green
    } catch {
        Write-Host "Scheduled task not found: $TaskName" -ForegroundColor Yellow
    }
    exit
}

# ---------------- INSTALL / RUN ----------------
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " MyFiber Daily Speed Test - Version 2" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host "Schedule : Daily at $RunAt"
Write-Host "URL      : $Url"
Write-Host "Storage  : $NetworkPath"
Write-Host "Computer : $env:COMPUTERNAME"
Write-Host ""

try {
    Test-NetworkFolder $NetworkPath
    $chrome = Find-Chrome
    Write-Info "Chrome: $chrome"

    # Register task for the currently logged-in user.
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -RunTask"

    $trigger = New-ScheduledTaskTrigger -Daily -At $RunAt

    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Runs MyFiber internet speed test daily and stores full-page screenshot on the network share." `
        -Force | Out-Null

    Write-Host "Scheduled task installed successfully." -ForegroundColor Green

    if ($RunNowAfterInstall) {
        Write-Host ""
        Write-Info "Running the first test now..."
        $result = Run-SpeedTest
        Write-Host ""
        Write-Host "SUCCESS: $result" -ForegroundColor Green
    } else {
        Write-Host "The first automatic test will run at $RunAt." -ForegroundColor Yellow
    }

} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Check that:" -ForegroundColor Yellow
    Write-Host "1. Chrome is installed."
    Write-Host "2. The PC can access $NetworkPath"
    Write-Host "3. The Windows account has write permission to the network share."
    Write-Host "4. The PC is connected to the required Wi-Fi/WAN network."
    exit 1
}

Write-Host ""
Write-Host "Installation complete." -ForegroundColor Green
Write-Host "To remove the automatic schedule later:" -ForegroundColor Yellow
Write-Host "powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Uninstall"
