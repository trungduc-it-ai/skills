<#
.SYNOPSIS
  Server HTTP giả lập các dịch vụ mà service gọi ra ngoài (cổng ký, Report...), để chạy thử log mà
  không cần hệ thống thật.

.DESCRIPTION
  RoutesFile là JSON, mỗi key là path:
    {
      "/sign":   { "body": { "code": "00", "data": { "dataSigned": "__BASE64_3000__" } },
                   "failWhen": "FAILCASE", "failBody": { "code": "ERR-401" }, "delayMs": 150 },
      "/export": { "body": { "ResultCode": "00", "Data": { "Bytes": "__BASE64_3000__" } } }
    }
  - __BASE64_<n>__ trong body được thay bằng chuỗi base64 của n byte (giả lập file PDF).
  - Request body chứa chuỗi failWhen thì trả failBody (giả lập dịch vụ báo lỗi).
  - status: mã HTTP trả về (mặc định 200). Path không khai báo -> 404.
  - Gọi GET /stop để dừng server.
  Chạy nền: powershell -File Start-FakeUpstream.ps1 -Port 18110 -RoutesFile routes.json
#>
param(
    [int]$Port = 18110,
    [Parameter(Mandatory = $true)][string]$RoutesFile
)

$routes = Get-Content $RoutesFile -Raw -Encoding UTF8 | ConvertFrom-Json

function Expand-Body($obj) {
    $json = $obj | ConvertTo-Json -Depth 20 -Compress
    return [regex]::Replace($json, '__BASE64_(\d+)__', {
        param($m)
        $n = [int]$m.Groups[1].Value
        [Convert]::ToBase64String([byte[]](0..($n - 1) | ForEach-Object { $_ % 256 }))
    })
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "Fake upstream đang chạy ở http://127.0.0.1:$Port/ (GET /stop để dừng)"

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath
    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream)
    $requestBody = $reader.ReadToEnd()
    $status = 200
    $json = '{}'
    $stop = $false

    $route = $routes.PSObject.Properties[$path]
    if ($path -eq '/stop') {
        $stop = $true
    } elseif ($route) {
        $r = $route.Value
        if ($r.delayMs) { Start-Sleep -Milliseconds $r.delayMs }
        if ($r.status) { $status = [int]$r.status }
        $useFail = $r.failWhen -and $requestBody.Contains([string]$r.failWhen)
        $json = Expand-Body $(if ($useFail) { $r.failBody } else { $r.body })
    } else {
        $status = 404
    }

    $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.Close()
    if ($stop) { $listener.Stop() }
}
