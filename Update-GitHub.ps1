<#
.SYNOPSIS
    Đẩy thay đổi của thư mục skills lên GitHub: lấy bản mới, quét thông tin nội bộ, commit, push.

.DESCRIPTION
    Mẫu thông tin nội bộ cần chặn (IP, login, tên CSDL...) nằm ở .git\info\noi-bo.txt:
    mỗi dòng 1 regex, dòng bắt đầu bằng # là ghi chú. File nằm trong .git nên KHÔNG bao giờ lên GitHub.
    Gặp mẫu nào trong file sắp đẩy thì script dừng, không commit, không push.

.EXAMPLE
    .\Update-GitHub.ps1 -Message "Thêm skill X"

.EXAMPLE
    .\Update-GitHub.ps1 -DryRun
    (chỉ quét và xem sẽ đẩy gì, không thay đổi gì)
#>
param(
    [string]$Message,
    [switch]$DryRun
)

Set-Location -LiteralPath $PSScriptRoot

function Dung([string]$loi) { Write-Host $loi -ForegroundColor Red; exit 1 }

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE -ne 0) { Dung "Lệnh 'git $($args -join ' ')' lỗi (mã $LASTEXITCODE)." }
}

$fileMau = '.git/info/noi-bo.txt'
if (-not (Test-Path -LiteralPath $fileMau)) {
    Dung "Thiếu $fileMau. Tạo file này, mỗi dòng 1 regex cần chặn (vd 10\.10\.[0-9]+\.[0-9]+)."
}
$mau = @(Get-Content -LiteralPath $fileMau -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
if ($mau.Count -eq 0) { Dung "$fileMau chưa có mẫu nào." }

Write-Host '== 1. Lấy bản mới từ GitHub ==' -ForegroundColor Cyan
if ($DryRun) { Invoke-Git fetch -q origin }
else { Invoke-Git pull -q --rebase --autostash }
git status -sb | Select-Object -First 1

Write-Host "== 2. Quét thông tin nội bộ ($($mau.Count) mẫu) ==" -ForegroundColor Cyan
$thamSo = @('grep', '--untracked', '-n', '-I', '-E') + @($mau | ForEach-Object { '-e'; $_ })
$trung = & git @thamSo
$maGrep = $LASTEXITCODE
if ($maGrep -eq 0) {
    $trung | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
    Dung 'Còn thông tin nội bộ ở các dòng trên. Sửa rồi chạy lại. Chưa commit, chưa push gì.'
}
if ($maGrep -gt 1) { Dung "git grep lỗi (mã $maGrep)." }
Write-Host '   Sạch.'

Write-Host '== 3. Thay đổi ==' -ForegroundColor Cyan
$thayDoi = git status --porcelain
$chuaDay = [int](git rev-list --count '@{u}..HEAD')
if (-not $thayDoi -and $chuaDay -eq 0) { Write-Host '   Không có gì mới để đẩy.'; exit 0 }
if ($thayDoi) { git status --short }
if ($chuaDay -gt 0) { Write-Host "   $chuaDay commit chưa đẩy." }

if ($DryRun) { Write-Host 'DryRun: dừng ở đây, chưa commit, chưa push.' -ForegroundColor Yellow; exit 0 }

if ($thayDoi) {
    if (-not $Message) { $Message = Read-Host 'Mô tả thay đổi (Enter = mặc định)' }
    if (-not $Message) { $Message = "Cập nhật skills $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
    Invoke-Git add -A
    Invoke-Git commit -q -m $Message
}

Write-Host '== 4. Đẩy lên GitHub ==' -ForegroundColor Cyan
Invoke-Git push -q
git log --oneline -1
Write-Host 'Đã cập nhật GitHub.' -ForegroundColor Green
