# MyFiber Speed Test + Full Page Screenshot
# Windows 11 / Google Chrome / PowerShell 5.1+
# Save as: MyFiber-SpeedTest.ps1

$ErrorActionPreference = "Stop"

$Url = "https://myfiber.co.in/"
$NetworkFolder = "\\192.168.21.19\newfolder"
$Port = 9222
$Chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
if (!(Test-Path $Chrome)) {
    $Chrome = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
}
if (!(Test-Path $Chrome)) {
    throw "Google Chrome was not found."
}

# Make sure the destination is reachable.
if (!(Test-Path $NetworkFolder)) {
    throw "Network folder is not reachable: $NetworkFolder"
}

# Use a temporary Chrome profile so an existing Chrome session is not affected.
$Profile = Join-Path $env:TEMP "MyFiberSpeedTestChrome"
if (Test-Path $Profile) {
    Remove-Item $Profile -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $Profile -Force | Out-Null

# Start Chrome with DevTools enabled.
$chromeProc = Start-Process -FilePath $Chrome -ArgumentList @(
    "--remote-debugging-port=$Port",
    "--user-data-dir=$Profile",
    "--new-window",
    "--start-maximized",
    "--disable-notifications",
    "--no-first-run",
    "--no-default-browser-check",
    $Url
) -PassThru

try {
    # Wait for Chrome DevTools endpoint.
    $debugInfo = $null
    for ($i=0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $debugInfo = Invoke-RestMethod "http://127.0.0.1:$Port/json"
            if ($debugInfo) { break }
        } catch {}
    }

    if (!$debugInfo) { throw "Chrome DevTools could not be started." }

    $page = $debugInfo | Where-Object { $_.type -eq "page" -and $_.url -like "*myfiber.co.in*" } | Select-Object -First 1
    if (!$page) { $page = $debugInfo | Where-Object { $_.type -eq "page" } | Select-Object -First 1 }
    if (!$page.webSocketDebuggerUrl) { throw "Could not find Chrome debugging WebSocket." }

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $script:CommandId = 0

    function Send-CDP {
        param(
            [string]$Method,
            [hashtable]$Params = @{}
        )

        $script:CommandId++
        $id = $script:CommandId
        $obj = @{ id = $id; method = $Method; params = $Params }
        $json = $obj | ConvertTo-Json -Compress -Depth 20
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)

        $segment = New-Object System.ArraySegment[byte] (,$bytes)
        $ws.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

        $buffer = New-Object byte[] 65536
        $ms = New-Object IO.MemoryStream
        do {
            $seg = New-Object System.ArraySegment[byte] (,$buffer)
            $result = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
            if ($result.Count -gt 0) { $ms.Write($buffer, 0, $result.Count) }
        } while (!$result.EndOfMessage)

        $responseText = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        $response = $responseText | ConvertFrom-Json
        return $response
    }

    # Enable required CDP domains.
    Send-CDP "Page.enable" | Out-Null
    Send-CDP "Runtime.enable" | Out-Null

    Start-Sleep -Seconds 3

    # Click the MyFiber Start Test control. This deliberately searches several
    # common attributes so minor page markup changes are less likely to break it.
    $clickJS = @'
(() => {
  const els = [...document.querySelectorAll('button,input,img,a,[role="button"],div,span')];
  const score = e => {
    const s = ((e.innerText||'')+' '+(e.alt||'')+' '+(e.title||'')+' '+(e.value||'')+' '+(e.getAttribute('aria-label')||'')).toLowerCase();
    if (!s.includes('start')) return -1;
    if (!s.includes('test') && !s.includes('fiber')) return -1;
    let n = 0;
    if (s.includes('start test')) n += 10;
    if (s.includes('start fiber')) n += 10;
    if (e.tagName==='BUTTON' || e.tagName==='INPUT' || e.tagName==='A') n += 3;
    return n;
  };
  els.sort((a,b)=>score(b)-score(a));
  const e = els[0];
  if (!e || score(e)<0) return 'NOT_FOUND';
  e.scrollIntoView({block:'center'});
  e.click();
  return 'CLICKED:'+e.tagName+':'+((e.innerText||e.alt||e.value||'').trim()).slice(0,80);
})()
'@

    $r = Send-CDP "Runtime.evaluate" @{ expression=$clickJS; returnByValue=$true }
    $clickResult = $r.result.result.value
    if ($clickResult -eq "NOT_FOUND") {
        throw "Could not find the MyFiber Start Test button."
    }

    # Wait for the test to finish. We look for non-zero Download/Upload values
    # and for the Start Test control to become available again.
    $testDone = $false
    $lastText = ""
    for ($i=0; $i -lt 180; $i++) {
        Start-Sleep -Seconds 1
        $pollJS = @'
(() => {
  const t = document.body ? document.body.innerText : '';
  const nums = [...t.matchAll(/(\d+(?:\.\d+)?)\s*Mbps/gi)].map(m=>parseFloat(m[1]));
  const nz = nums.filter(n=>n>0);
  return JSON.stringify({text:t.slice(0,12000), nonzero:nz.slice(0,10)});
})()
'@
        $p = Send-CDP "Runtime.evaluate" @{ expression=$pollJS; returnByValue=$true }
        $data = $p.result.result.value | ConvertFrom-Json
        $lastText = $data.text

        # Require at least two non-zero Mbps values; this normally corresponds
        # to download and upload after the test completes.
        if ($data.nonzero.Count -ge 2) {
            $testDone = $true
            break
        }
    }

    if (!$testDone) {
        throw "Speed test did not reach a completed result within 180 seconds."
    }

    # Add a visible timestamp to the screenshot itself.
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $overlayJS = @"
(() => {
  const old=document.getElementById('__myfiber_timestamp');
  if(old) old.remove();
  const d=document.createElement('div');
  d.id='__myfiber_timestamp';
  d.textContent='Speed Test: $stamp';
  Object.assign(d.style,{
    position:'fixed',top:'12px',right:'12px',zIndex:'2147483647',
    background:'rgba(0,0,0,.78)',color:'#fff',padding:'8px 12px',
    font:'bold 16px Arial',borderRadius:'5px',boxShadow:'0 2px 8px rgba(0,0,0,.35)'
  });
  document.body.appendChild(d);
  return 'OK';
})()
"@
    Send-CDP "Runtime.evaluate" @{ expression=$overlayJS; returnByValue=$true } | Out-Null
    Start-Sleep -Milliseconds 500

    # Get full page dimensions.
    $layout = Send-CDP "Page.getLayoutMetrics"
    $width = [math]::Ceiling([double]$layout.result.cssContentSize.width)
    $height = [math]::Ceiling([double]$layout.result.cssContentSize.height)

    # Capture the entire page, not just the visible viewport.
    $shot = Send-CDP "Page.captureScreenshot" @{
        format = "png"
        captureBeyondViewport = $true
        fromSurface = $true
        clip = @{
            x=0; y=0; width=$width; height=$height; scale=1
        }
    }

    $stampFile = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $file = Join-Path $NetworkFolder "MyFiber_SpeedTest_$stampFile.png"
    [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($shot.result.data))

    Write-Host ""
    Write-Host "Speed test completed." -ForegroundColor Green
    Write-Host "Screenshot saved to:"
    Write-Host $file -ForegroundColor Cyan
}
finally {
    if ($ws) {
        try { $ws.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"Done",[Threading.CancellationToken]::None).GetAwaiter().GetResult() } catch {}
        $ws.Dispose()
    }

    if ($chromeProc -and !$chromeProc.HasExited) {
        Stop-Process -Id $chromeProc.Id -Force -ErrorAction SilentlyContinue
    }

    Remove-Item $Profile -Recurse -Force -ErrorAction SilentlyContinue
}
