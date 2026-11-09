<#
.SYNOPSIS
  Chép bộ template log có cấu trúc + màn hình /logs.html vào 1 service ASP.NET Core, thay token theo service.

.DESCRIPTION
  - Thay %%NAMESPACE%%, %%LOG_ROUTE%%, %%SERVICE_TITLE%%, %%DEFAULT_TAG%% trong templates\ rồi ghi vào service.
  - File đã tồn tại và khác nội dung: chép bản cũ sang thư mục backup trước khi ghi đè.
  - Giữ kiểu xuống dòng (CRLF/LF) theo Startup.cs của service.
  - Không sửa Startup.cs / appsettings.json / controller nghiệp vụ - chỉ in ra những việc còn phải làm tay.

.EXAMPLE
  .\Install-LogViewer.ps1 -ServiceDir "H:\01. Project\07. HIS\API_Signer\APIService\FPT.Service" `
      -Namespace FPT.Service -LogRoute "API/FPT/Logs" -DefaultTag "Signer_PDF_Queue"
#>
param(
    [Parameter(Mandatory = $true)][string]$ServiceDir,
    # Namespace gốc lấy từ Startup.cs (KHÔNG suy ra từ tên thư mục - vd. Vnpt.Service dùng "Visnam.Service").
    [Parameter(Mandatory = $true)][string]$Namespace,
    # Route của LogViewerController, cùng tiền tố với API nghiệp vụ, không có "/" đầu. Vd: api/2ID/Logs
    [Parameter(Mandatory = $true)][string]$LogRoute,
    [string]$ServiceTitle,
    # Loại log được chọn sẵn khi mở trang (tag hay cần tra nhất của service).
    [string]$DefaultTag = 'Api_Input',
    [string]$BackupDir,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$templates = (Resolve-Path (Join-Path $PSScriptRoot '..\templates')).Path
$ServiceDir = (Resolve-Path $ServiceDir).Path

if (-not (Get-ChildItem $ServiceDir -Filter *.csproj)) { throw "Không thấy file .csproj trong $ServiceDir" }
$LogRoute = $LogRoute.Trim('/')
if ($LogRoute -notmatch '^[A-Za-z0-9_\-/]+$') { throw "LogRoute không hợp lệ: $LogRoute" }
if ($Namespace -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$') { throw "Namespace không hợp lệ: $Namespace" }
if ($DefaultTag -notmatch '^[\w\-]+$') { throw "DefaultTag không hợp lệ: $DefaultTag" }
if (-not $ServiceTitle) { $ServiceTitle = Split-Path $ServiceDir -Leaf }

if (-not $BackupDir) {
    # Quy ước API_Signer: <repo>\_backup\<thời điểm>_<việc>. Không có <repo>\_backup thì để cạnh thư mục service.
    $repoBackup = Join-Path (Split-Path (Split-Path $ServiceDir)) '_backup'
    $root = if (Test-Path $repoBackup) { $repoBackup } else { Join-Path (Split-Path $ServiceDir) '_backup' }
    $BackupDir = Join-Path $root ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_logviewer_' + (Split-Path $ServiceDir -Leaf))
}

$startup = Join-Path $ServiceDir 'Startup.cs'
$useCrlf = (Test-Path $startup) -and ([IO.File]::ReadAllText($startup).Contains("`r`n"))

$tokens = [ordered]@{
    '%%NAMESPACE%%'     = $Namespace
    '%%LOG_ROUTE%%'     = $LogRoute
    '%%SERVICE_TITLE%%' = $ServiceTitle
    '%%DEFAULT_TAG%%'   = $DefaultTag
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
$backedUp = $false

$results = foreach ($file in Get-ChildItem $templates -Recurse -File) {
    $rel = $file.FullName.Substring($templates.Length + 1)
    $text = [IO.File]::ReadAllText($file.FullName, $utf8).Replace("`r`n", "`n")
    foreach ($k in $tokens.Keys) { $text = $text.Replace($k, $tokens[$k]) }
    if ($text -match '%%[A-Z_]+%%') { throw "Còn token chưa thay trong ${rel}: $($Matches[0])" }
    if ($useCrlf) { $text = $text.Replace("`n", "`r`n") }

    $target = Join-Path $ServiceDir $rel
    $action = 'Tạo mới'
    if (Test-Path $target) {
        $current = [IO.File]::ReadAllText($target)
        if ($current.Replace("`r`n", "`n") -eq $text.Replace("`r`n", "`n")) {
            $action = 'Không đổi'
        } else {
            $action = if ($DryRun) { 'Sẽ ghi đè (có backup)' } else { 'Ghi đè (đã backup)' }
            if (-not $DryRun) {
                $bak = Join-Path $BackupDir $rel
                New-Item -ItemType Directory -Force (Split-Path $bak) | Out-Null
                Copy-Item $target $bak -Force
                $backedUp = $true
            }
        }
    }
    if (-not $DryRun -and $action -ne 'Không đổi') {
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        [IO.File]::WriteAllText($target, $text, $utf8)
    }
    [pscustomobject]@{ File = $rel; Action = $action }
}

if ($DryRun) { Write-Host '(DryRun - chưa ghi file nào)' -ForegroundColor Yellow }
$results | Format-Table -AutoSize | Out-String | Write-Host
if ($backedUp) { Write-Host "Bản cũ đã chép sang: $BackupDir" }

# ---------------------------------------------------------------- việc còn phải làm tay
$sources = Get-ChildItem $ServiceDir -Recurse -Filter *.cs |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.Name -ne 'LogHelper.cs' }
$todo = @()

$regLogs = $sources | Select-String -Pattern 'static\s+void\s+RegLog\s*\('
foreach ($r in $regLogs) {
    $todo += "RegLog riêng ở $($r.Path.Substring($ServiceDir.Length + 1)):$($r.LineNumber) -> đổi thân hàm thành LogHelper.RegLog(IMEI, Mess);"
}

$oldCalls = $sources | Select-String -Pattern 'Calls\s*=\s*ApiCallRecorder\.EndAndGet\(\)'
foreach ($r in $oldCalls) {
    $todo += "Cách dùng cũ 'Calls = ApiCallRecorder.EndAndGet()' ở $($r.Path.Substring($ServiceDir.Length + 1)):$($r.LineNumber) -> chuyển sang ApiLogger.Log(tag, entry, ApiCallRecorder.EndAndGet())"
}

if (Test-Path $startup) {
    $s = [IO.File]::ReadAllText($startup)
    if ($s -notmatch 'ILogMaintenance') { $todo += 'Startup.ConfigureServices: services.AddSingleton<ILogMaintenance, LogMaintenance>();' }
    if ($s -notmatch 'LogCleanupBackgroundService') { $todo += 'Startup.ConfigureServices: services.AddHostedService<LogCleanupBackgroundService>();' }
    if ($s -notmatch 'UseStaticFiles') { $todo += 'Startup.Configure: app.UseStaticFiles(); (trước UseRouting)' }
    if ($s -notmatch 'ApiRequestLoggingMiddleware') { $todo += 'Startup.Configure: app.UseMiddleware<ApiRequestLoggingMiddleware>(); (sau UseStaticFiles, trước UseRouting)' }
    if ($s -notmatch [regex]::Escape("using $Namespace.Common;")) { $todo += "Startup.cs: thêm using $Namespace.Common;" }
} else {
    $todo += 'Không thấy Startup.cs - tự nối DI/middleware theo kiểu host của service (Program.cs minimal hosting...)'
}

$appsettings = Join-Path $ServiceDir 'appsettings.json'
if ((Test-Path $appsettings) -and ([IO.File]::ReadAllText($appsettings) -notmatch '"LogSettings"')) {
    $todo += 'appsettings.json: thêm mục LogSettings { RetentionDays, CleanupIntervalHours, AdminKey }'
}

if ($todo.Count) {
    Write-Host 'Việc còn phải làm tay:' -ForegroundColor Cyan
    $todo | ForEach-Object { Write-Host "  - $_" }
} else {
    Write-Host 'Không phát hiện việc nối tay nào còn thiếu.' -ForegroundColor Green
}
