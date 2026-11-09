<#
.SYNOPSIS
  Tạo log giả "kiểu cũ" trong thư mục Logs để kiểm tra: lọc lại mật khẩu/base64 khi đọc, và tự xoá/xoá
  theo khoảng ngày.

.DESCRIPTION
  Tạo trong <LogsDir>:
  - Logs/{hôm qua}/Legacy_Input.txt: 2 dòng còn mật khẩu + base64 nguyên văn (1 dòng Key=value, 1 dòng JSON).
  - Logs/{hôm nay-90}, {hôm nay-45}, {hôm nay-10}/Api_Input.txt: để thử RetentionDays (vd. 30 thì xoá
    -90 và -45, giữ -10).
  - Logs/{yyyyMMdd của hôm nay-90}.txt: file ILogger cũ ở gốc Logs.
  In ra danh sách chuỗi bí mật đã gài, dùng làm -Secrets cho Test-LogLeaks.ps1.
#>
param([Parameter(Mandatory = $true)][string]$LogsDir)

$utf8 = New-Object System.Text.UTF8Encoding($false)
function DayDir([DateTime]$d) {
    $p = Join-Path $LogsDir ("{0}\{1}\{2}" -f $d.Year, $d.Month, $d.Day)
    New-Item -ItemType Directory -Force $p | Out-Null
    return $p
}
function Stamp([DateTime]$d) { $d.ToString('dd/MM/yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }

$secrets = @('SeedP@ssw0rd!', 'seed-key-auth-123', 'seedPwd456')
$b64 = [Convert]::ToBase64String([byte[]](0..599 | ForEach-Object { $_ % 256 }))

$y = (Get-Date).Date.AddDays(-1).AddHours(9)
$legacy = "DateTime: $(Stamp $y), Data: Input={""password"":""$($secrets[0])"",""FileData"":""$b64""}, Url=http://x/api?pwd=$($secrets[2])&a=1`r`n" +
          "DateTime: $(Stamp $y.AddSeconds(1)), Data: {""Url"":""/api/legacy"",""Method"":""POST"",""Request"":{""keyAuth"":""$($secrets[1])"",""data"":""$b64""},""Error"":null,""Calls"":[]}`r`n"
[IO.File]::WriteAllText((Join-Path (DayDir $y) 'Legacy_Input.txt'), $legacy, $utf8)

foreach ($offset in -90, -45, -10) {
    $d = (Get-Date).Date.AddDays($offset).AddHours(8)
    [IO.File]::WriteAllText((Join-Path (DayDir $d) 'Api_Input.txt'),
        "DateTime: $(Stamp $d), Data: {""Url"":""/old$offset"",""Method"":""GET""}`r`n", $utf8)
}
$old = (Get-Date).Date.AddDays(-90)
[IO.File]::WriteAllText((Join-Path $LogsDir ($old.ToString('yyyyMMdd') + '.txt')), "ilogger old`r`n", $utf8)

Write-Host 'Đã gài các chuỗi bí mật (dùng cho Test-LogLeaks.ps1 -Secrets):'
$secrets
