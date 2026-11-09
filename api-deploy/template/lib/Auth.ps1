# =====================================================================
#  Auth.ps1 - Mật khẩu vào công cụ và cấu hình chung trên máy chủ.
#    Mật khẩu: cố định cho mọi máy chủ, không đổi được trong công cụ. Chỉ nhúng hash
#              PBKDF2 (không có mật khẩu rõ trong gói triển khai).
#    Thư mục lưu các API (installRoot): %ProgramData%\<defaults.dataDir>\config.json
# =====================================================================

# Hash PBKDF2 của mật khẩu công cụ. Đổi mật khẩu: tạo salt + hash mới (xem HUONG_DAN.md)
# rồi thay 4 giá trị dưới đây. Có cả bản SHA1 vì PBKDF2-SHA256 cần .NET Framework 4.7.2+
$script:ToolPasswordSalt = '3xe9DzpI7iDznapSfKZmyQ=='
$script:ToolPasswordIterations = 200000
$script:ToolPasswordHashSha256 = 'ljawZiwLnb9DX15iAmWl819o64nSLBhfoNzgTV4MzM8='
$script:ToolPasswordHashSha1 = 'b7+ZdUFPuBp3qBEjj14W8lPWeEYksU8clfIuGk0iqgg='

function Get-ToolConfig {
    New-Item -ItemType Directory -Force $script:DataDir | Out-Null
    $f = Join-Path $script:DataDir 'config.json'
    if (Test-Path $f) { return (Read-JsonCFile $f) }
    return (New-JsonCDoc "{`r`n}`r`n" $f)
}

function Save-ToolConfig($doc) {
    Save-JsonCFile $doc (Join-Path $script:DataDir 'config.json')
}

# Thư mục dữ liệu chứa bản sao lưu appsettings (có mật khẩu CSDL đã mã hoá, token...)
# -> chỉ Administrators và SYSTEM được đọc
function Protect-DataDir {
    $marker = Join-Path $script:DataDir '.acl'
    if (Test-Path $marker) { return }
    $out = & icacls $script:DataDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { Set-Content $marker 'Administrators + SYSTEM' -Encoding ASCII }
    else { Write-Log "Không giới hạn quyền được $($script:DataDir): $out" }
}

#region ---------- Mật khẩu ----------

function Get-PasswordHashBytes([string]$password, [byte[]]$salt, [int]$iterations, [string]$algorithm) {
    if ($algorithm -eq 'SHA256') {
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($password, $salt, $iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    }
    else {
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($password, $salt, $iterations)
    }
    try { return $kdf.GetBytes(32) } finally { $kdf.Dispose() }
}

function Test-ToolPassword([string]$password) {
    if ([string]::IsNullOrEmpty($password)) { return $false }
    $salt = [Convert]::FromBase64String($script:ToolPasswordSalt)
    try {
        $actual = Get-PasswordHashBytes $password $salt $script:ToolPasswordIterations 'SHA256'
        $expected = [Convert]::FromBase64String($script:ToolPasswordHashSha256)
    }
    catch {
        # .NET Framework cũ (Windows Server 2016 chưa cập nhật) không có PBKDF2-SHA256
        $actual = Get-PasswordHashBytes $password $salt $script:ToolPasswordIterations 'SHA1'
        $expected = [Convert]::FromBase64String($script:ToolPasswordHashSha1)
    }
    # So sánh thời gian cố định
    $diff = $expected.Length -bxor $actual.Length
    for ($i = 0; $i -lt [Math]::Min($expected.Length, $actual.Length); $i++) { $diff = $diff -bor ($expected[$i] -bxor $actual[$i]) }
    return ($diff -eq 0)
}

# Đăng nhập: 3 lần, sai thì chờ tăng dần
function Invoke-ToolLogin {
    for ($i = 1; $i -le 3; $i++) {
        $pw = Read-Secret 'Mật khẩu công cụ triển khai'
        if (Test-ToolPassword $pw) {
            Write-Log 'Đăng nhập thành công'
            return $true
        }
        Write-Err "Sai mật khẩu ($i/3)"
        Write-Log "Đăng nhập sai lần $i"
        Start-Sleep -Seconds ($i * 2)
    }
    Write-Log 'Đăng nhập thất bại 3 lần - thoát'
    return $false
}

#endregion

#region ---------- Thư mục lưu API ----------

# Kiểm tra đường dẫn thư mục lưu API. Trả về chuỗi lỗi, '' nếu hợp lệ
function Test-InstallRootPath([string]$path) {
    if ($path -notmatch '^[A-Za-z]:\\') { return 'Phải là đường dẫn đầy đủ trên ổ đĩa của máy chủ, vd D:\HIS_API' }
    if ($path -match '[<>"|?*]') { return 'Đường dẫn có ký tự không hợp lệ' }
    $drive = $path.Substring(0, 3)
    if (-not (Test-Path $drive)) { return "Không có ổ $drive trên máy chủ" }
    $di = New-Object System.IO.DriveInfo($drive)
    if ($di.DriveType -ne 'Fixed') { return "Ổ $drive không phải ổ cứng cố định ($($di.DriveType))" }
    $full = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
    if ($full.Length -le 3) { return 'Không dùng thư mục gốc của ổ đĩa, hãy đặt 1 thư mục con (vd D:\HIS_API)' }
    foreach ($sys in @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Split-Path $env:PUBLIC -Parent), $env:ProgramData)) {
        if ($sys -and ($full -ieq $sys -or $full.StartsWith($sys.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { return "Không đặt trong thư mục hệ thống $sys" }
    }
    return ''
}

function Read-InstallRoot([string]$current) {
    while ($true) {
        $p = Read-Value 'Thư mục lưu các API' $current -Required
        $p = $p.Trim().TrimEnd('\')
        $err = Test-InstallRootPath $p
        if ($err) { Write-Warn $err; continue }
        try { New-Item -ItemType Directory -Force $p | Out-Null }
        catch { Write-Warn "Không tạo được thư mục: $($_.Exception.Message)"; continue }
        $free = (New-Object System.IO.DriveInfo($p.Substring(0, 3))).AvailableFreeSpace / 1GB
        Write-Ok ("Thư mục API: {0} (ổ còn trống {1:N1} GB)" -f $p, $free)
        if ($free -lt 2) { Write-Warn 'Ổ đĩa còn ít dung lượng (dưới 2 GB) - log và bản sao lưu có thể làm đầy ổ.' }
        return $p
    }
}

#endregion
