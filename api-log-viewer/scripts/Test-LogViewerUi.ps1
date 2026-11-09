<#
.SYNOPSIS
  Kiểm thử nhanh trang /logs.html bằng Edge/Chrome headless (DevTools Protocol), không cần node.

.DESCRIPTION
  Mở trang, chọn loại log, tìm kiếm, mở chi tiết dòng lỗi/cảnh báo (nếu có), chuyển "JSON gốc", lọc
  "Chỉ lỗi", tìm "Tất cả loại log", mở tab quản lý, rồi thử khổ điện thoại 390px. Chụp ảnh PNG vào
  OutDir và in: số dòng, trạng thái từng dòng, số bước trong chi tiết, có tràn ngang không, số lỗi JS.
  Chỉ dừng đúng tiến trình trình duyệt dùng profile test, không đụng trình duyệt của người dùng.

.EXAMPLE
  .\Test-LogViewerUi.ps1 -BaseUrl http://127.0.0.1:18202 -Tag KySo_2ID -OutDir C:\temp\ui
#>
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$BrowserPath,
    [int]$DebugPort = 9333
)

$ErrorActionPreference = 'Stop'
if (-not $BrowserPath) {
    $BrowserPath = @(
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Google\Chrome\Application\chrome.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $BrowserPath) { throw 'Không tìm thấy Edge/Chrome - truyền -BrowserPath' }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$profileDir = Join-Path $OutDir 'browser-profile'
if (Test-Path $profileDir) { Remove-Item -Recurse -Force $profileDir -Confirm:$false }
$proc = Start-Process $BrowserPath -PassThru -ArgumentList @(
    '--headless=new', "--remote-debugging-port=$DebugPort", "--user-data-dir=$profileDir",
    '--window-size=1280,1600', '--no-first-run', 'about:blank')

try {
    $target = $null
    for ($i = 0; $i -lt 40 -and -not $target; $i++) {
        try { $target = (Invoke-RestMethod "http://127.0.0.1:$DebugPort/json") | Where-Object { $_.type -eq 'page' } | Select-Object -First 1 }
        catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $target) { throw 'Trình duyệt headless không mở được cổng DevTools' }

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
    $script:id = 0
    $script:events = New-Object System.Collections.ArrayList

    function Receive-Msg {
        $buf = New-Object byte[] 1048576
        $ms = New-Object System.IO.MemoryStream
        do {
            $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
            $r = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None).Result
            $ms.Write($buf, 0, $r.Count)
        } while (-not $r.EndOfMessage)
        return [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
    }

    function Send-Cdp($method, $params) {
        $script:id++
        $msg = @{ id = $script:id; method = $method; params = $(if ($params) { $params } else { @{} }) } | ConvertTo-Json -Depth 10 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        $ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)), 'Text', $true, [Threading.CancellationToken]::None).Wait()
        while ($true) {
            $m = Receive-Msg
            if ($m.id -eq $script:id) { return $m }
            [void]$script:events.Add($m)
        }
    }

    # Mỗi biểu thức bọc trong IIFE: Runtime.evaluate chạy ở global scope, khai báo const/let lặp lại giữa
    # các lần gọi sẽ ném SyntaxError.
    function Eval($js) {
        $r = Send-Cdp 'Runtime.evaluate' @{ expression = "(async () => { $js })()"; awaitPromise = $true; returnByValue = $true }
        if ($r.result.exceptionDetails) { return 'EXCEPTION: ' + ($r.result.exceptionDetails.exception.description) }
        return $r.result.result.value
    }

    function Shot($name) {
        $r = Send-Cdp 'Page.captureScreenshot' @{ format = 'png' }
        [IO.File]::WriteAllBytes((Join-Path $OutDir $name), [Convert]::FromBase64String($r.result.data))
    }

    function Search($tagValue) {
        Eval "document.getElementById('tag').value = '$tagValue'; document.getElementById('searchBtn').click(); return 1;" | Out-Null
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 250
            if ((Eval "return document.getElementById('searchBtn').disabled;") -eq $false) { break }
        }
    }

    Send-Cdp 'Runtime.enable' | Out-Null
    Send-Cdp 'Page.enable' | Out-Null
    Send-Cdp 'Page.navigate' @{ url = $BaseUrl.TrimEnd('/') + '/logs.html' } | Out-Null
    Start-Sleep -Seconds 2

    'Số loại log trong dropdown: ' + (Eval "return document.getElementById('tag').options.length;")
    'Có tag cần thử: ' + (Eval "return [...document.getElementById('tag').options].some(o => o.value === '$Tag');")
    Search $Tag
    'Kết quả: ' + (Eval "return document.getElementById('results-meta').textContent || document.getElementById('status').textContent;")
    'Số dòng trang 1: ' + (Eval "return document.querySelectorAll('#results .entry').length;")
    'Trạng thái các dòng: ' + (Eval "return [...document.querySelectorAll('#results .entry')].map(e => e.className.replace('entry ', '')).join(', ');")
    Shot '1-list.png'

    $opened = Eval @"
const rows = [...document.querySelectorAll('#results .entry')];
const row = rows.find(e => e.classList.contains('st-error')) || rows.find(e => e.classList.contains('st-warn')) || rows[0];
if (!row) return 'không có dòng nào';
row.querySelector('button').click();
return row.className;
"@
    'Mở chi tiết dòng: ' + $opened
    Start-Sleep -Milliseconds 500
    'Số bước trong chi tiết: ' + (Eval "return document.querySelectorAll('#modal-content .step').length;")
    'Số lệnh gọi ra ngoài: ' + (Eval "return document.querySelectorAll('#modal-content .call-card').length;")
    'Placeholder đã che (<đã ẩn>/<chuỗi base64>): ' + (Eval "return document.querySelectorAll('#modal-content .j-mask').length;")
    Shot '2-detail.png'
    Eval "document.getElementById('toggleRawBtn').click(); return 1;" | Out-Null
    'Chế độ JSON gốc có khối code: ' + (Eval "return document.querySelectorAll('#modal-content pre.code').length;")
    Eval "document.getElementById('modal-close').click(); return 1;" | Out-Null

    Eval "const f = document.getElementById('statusFilter'); f.value = 'error'; f.dispatchEvent(new Event('change')); return 1;" | Out-Null
    'Số dòng khi lọc Chỉ lỗi: ' + (Eval "return document.querySelectorAll('#results .entry').length;")
    Eval "const f = document.getElementById('statusFilter'); f.value = 'all'; f.dispatchEvent(new Event('change')); return 1;" | Out-Null
    Search '*'
    'Tất cả loại log: ' + (Eval "return document.getElementById('results-meta').textContent;")

    Eval "document.querySelector('.tab[data-tab=manage]').click(); return 1;" | Out-Null
    Start-Sleep -Seconds 2
    'Thống kê: ' + (Eval "return [...document.querySelectorAll('#statCards .card')].map(c => c.innerText.replace(/\n/g, ': ')).join(' | ');")
    'Cấu hình tự xoá: ' + (Eval "return document.getElementById('settingsInfo').textContent;")
    'Yêu cầu mã quản trị: ' + (Eval "return !document.getElementById('adminKeyPanel').hidden;")
    Shot '3-manage.png'

    Send-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 390; height = 900; deviceScaleFactor = 1; mobile = $true } | Out-Null
    Start-Sleep -Milliseconds 500
    'Tràn ngang ở 390px (tab quản lý): ' + (Eval "return document.documentElement.scrollWidth > window.innerWidth;")
    Eval "document.querySelector('.tab[data-tab=search]').click(); return 1;" | Out-Null
    Search $Tag
    'Tràn ngang ở 390px (tab tra cứu): ' + (Eval "return document.documentElement.scrollWidth > window.innerWidth;")
    Shot '4-mobile.png'

    $exceptions = @($script:events | Where-Object { $_.method -eq 'Runtime.exceptionThrown' })
    'Lỗi JS: ' + $exceptions.Count
    foreach ($e in $exceptions) { '  ' + $e.params.exceptionDetails.exception.description }
    'console.error: ' + @($script:events | Where-Object { $_.method -eq 'Runtime.consoleAPICalled' -and $_.params.type -eq 'error' }).Count
    "Ảnh chụp: $OutDir"
}
finally {
    if ($ws) { $ws.Dispose() }
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$profileDir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
