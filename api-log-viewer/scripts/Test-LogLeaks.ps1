<#
.SYNOPSIS
  Quét file log xem còn lọt base64 dài / mật khẩu nguyên văn không.

.DESCRIPTION
  - Base64: báo mọi đoạn [A-Za-z0-9+/] liên tục dài >= MinRun (mặc định 100 = đúng ngưỡng JsonHelper
    thay bằng placeholder, nên còn đoạn nào dài vậy tức là bị lọt).
  - Secrets: các chuỗi cần chắc chắn không xuất hiện (mật khẩu trong appsettings, chuỗi do
    New-SeedLogs.ps1 gài...). Lưu ý: file log kiểu cũ ghi TRƯỚC khi cài bộ lọc vẫn còn nguyên văn
    trên đĩa (chỉ được che khi hiển thị) - dùng -Exclude để bỏ qua các file đó.
  Trả exit code 1 nếu có rò rỉ.

.EXAMPLE
  .\Test-LogLeaks.ps1 -LogsDir .\Logs -Secrets 'ehos@p4ssw0rd','FTPU@9981' -Exclude Legacy_Input.txt
#>
param(
    [Parameter(Mandatory = $true)][string]$LogsDir,
    [string[]]$Secrets = @(),
    [string[]]$Exclude = @(),
    [int]$MinRun = 100
)

$files = Get-ChildItem $LogsDir -Recurse -Filter *.txt | Where-Object { $Exclude -notcontains $_.Name }
$leaks = 0
foreach ($f in $files) {
    $content = [IO.File]::ReadAllText($f.FullName)
    $rel = $f.FullName.Substring((Resolve-Path $LogsDir).Path.Length + 1)
    foreach ($m in [regex]::Matches($content, "[A-Za-z0-9+/]{$MinRun,}")) {
        $leaks++
        Write-Host ("BASE64  {0}: đoạn dài {1} ký tự: {2}..." -f $rel, $m.Length, $m.Value.Substring(0, 40)) -ForegroundColor Red
    }
    foreach ($s in $Secrets) {
        if ($s -and $content.Contains($s)) {
            $leaks++
            Write-Host ("SECRET  {0}: còn chuỗi '{1}'" -f $rel, $s) -ForegroundColor Red
        }
    }
}
Write-Host ("Đã quét {0} file, phát hiện {1} chỗ rò rỉ." -f @($files).Count, $leaks)
if ($leaks) { exit 1 }
