# =====================================================================
#  Common.ps1 - Hàm dùng chung: hiển thị, nhập liệu, mã hoá, chuỗi kết nối,
#  kiểm tra kết nối, log, sao lưu.
# =====================================================================

$script:LogFile = $null
# Mặc định của bộ HIS cũ; Deploy.ps1 đổi theo defaults.dataDir trong deploy-manifest.json
$script:DataDir = Join-Path $env:ProgramData 'HIS.API.Deploy'

#region ---------- Log / hiển thị ----------

# Cửa sổ powershell.exe mặc định dùng font Lucida Console / Raster: không có chữ tiếng Việt dựng sẵn
# (ạ, ế, ở, ữ...) nên hiện ô vuông / dấu ?. Đổi font cửa sổ đang chạy sang Consolas.
# Windows Terminal, output chuyển hướng, không có console: bỏ qua. Không bao giờ làm dừng công cụ.
function Set-ConsoleUnicodeFont {
    try {
        if ([Console]::IsOutputRedirected) { return }
        if (-not ('HisConsoleFont' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HisConsoleFont {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFOEX {
        public uint cbSize; public uint nFont; public short FontWidth; public short FontHeight;
        public int FontFamily; public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
    }
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool GetCurrentConsoleFontEx(IntPtr h, bool max, ref CONSOLE_FONT_INFOEX f);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref CONSOLE_FONT_INFOEX f);
    public static string Get() {
        var f = new CONSOLE_FONT_INFOEX(); f.cbSize = (uint)Marshal.SizeOf(f);
        return GetCurrentConsoleFontEx(GetStdHandle(-11), false, ref f) ? f.FaceName : null;
    }
    public static bool Set(string face) {
        IntPtr h = GetStdHandle(-11);
        var f = new CONSOLE_FONT_INFOEX(); f.cbSize = (uint)Marshal.SizeOf(f);
        if (!GetCurrentConsoleFontEx(h, false, ref f)) return false;
        short height = f.FontHeight < 14 ? (short)16 : f.FontHeight;
        f.FaceName = face; f.FontFamily = 54; f.FontWeight = 400; f.FontWidth = 0; f.FontHeight = height;
        return SetCurrentConsoleFontEx(h, false, ref f);
    }
}
'@
        }
        $face = [HisConsoleFont]::Get()
        if ($null -eq $face -or $face -in 'Consolas', 'Cascadia Mono', 'Cascadia Code', 'Courier New') { return }
        [void][HisConsoleFont]::Set('Consolas')
    }
    catch { }
}

function Initialize-DeployLog([string]$dir) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $script:LogFile = Join-Path $dir ('deploy_{0:yyyyMMdd}.log' -f (Get-Date))
}

function Write-Log([string]$message) {
    if (-not $script:LogFile) { return }
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $env:USERNAME, $message
        [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Write-Title([string]$text) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Write-Step([string]$text) {
    Write-Host ''
    Write-Host "--- $text " -ForegroundColor Yellow -NoNewline
    Write-Host ('-' * [Math]::Max(3, 73 - $text.Length)) -ForegroundColor DarkYellow
}

function Write-Ok([string]$text) { Write-Host "   [OK] $text" -ForegroundColor Green; Write-Log "OK   $text" }
function Write-Warn([string]$text) { Write-Host "   [!]  $text" -ForegroundColor DarkYellow; Write-Log "WARN $text" }
function Write-Err([string]$text) { Write-Host "   [X]  $text" -ForegroundColor Red; Write-Log "ERR  $text" }
function Write-Info([string]$text) { Write-Host "        $text" -ForegroundColor Gray }

function Wait-Continue {
    Write-Host ''
    [void](Read-Host '   Nhấn Enter để tiếp tục')
}

#endregion

#region ---------- Nhập liệu ----------

# Nhập 1 giá trị. Enter = giữ $Default. '-' = xoá trắng (khi -AllowClear)
function Read-Value {
    param(
        [string]$Prompt,
        [string]$Default = '',
        [switch]$Required,
        [switch]$AllowClear,
        [scriptblock]$Validate
    )
    while ($true) {
        $label = if ($Default -ne '') { "$Prompt [$Default]" } else { $Prompt }
        $v = Read-Host "   $label"
        if ($null -eq $v) { $v = '' }
        $v = $v.Trim()
        if ($v -eq '') { $v = $Default }
        elseif ($AllowClear -and $v -eq '-') { $v = '' }
        if ($Required -and $v -eq '') { Write-Warn 'Giá trị bắt buộc, vui lòng nhập.'; continue }
        if ($Validate -and $v -ne '') {
            $msg = & $Validate $v
            if ($msg) { Write-Warn $msg; continue }
        }
        return $v
    }
}

# Nhập ẩn (mật khẩu). Trả về chuỗi rỗng nếu chỉ nhấn Enter
function Read-Secret([string]$Prompt) {
    $ss = Read-Host "   $Prompt" -AsSecureString
    if ($null -eq $ss -or $ss.Length -eq 0) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-YesNo([string]$Prompt, [bool]$Default = $true) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $v = Read-Host "   $Prompt ($hint)"
        if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
        switch -Regex ($v.Trim()) {
            '^(?i)(y|yes|c|co|có|1|true)$' { return $true }
            '^(?i)(n|no|k|khong|không|0|false)$' { return $false }
        }
        Write-Warn 'Nhập Y (có) hoặc N (không).'
    }
}

# "1,3,5-7" -> danh sách số trong khoảng 1..$max. Sai cú pháp -> $null
function ConvertFrom-NumberList([string]$text, [int]$max) {
    $result = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($text -split '[,; ]+' | Where-Object { $_ -ne '' })) {
        if ($part -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            for ($i = $a; $i -le $b; $i++) { if ($i -ge 1 -and $i -le $max -and -not $result.Contains($i)) { $result.Add($i) } }
        }
        elseif ($part -match '^\d+$') {
            $i = [int]$part
            if ($i -lt 1 -or $i -gt $max) { return $null }
            if (-not $result.Contains($i)) { $result.Add($i) }
        }
        else { return $null }
    }
    return , $result
}

function Format-Secret([string]$value) {
    if ([string]::IsNullOrEmpty($value)) { return '(trống)' }
    return ('*' * [Math]::Min(8, $value.Length)) + " ($($value.Length) ký tự)"
}

#endregion

#region ---------- Mã hoá (tương thích Cryptography.cs của các service) ----------
# cryptoScheme trong deploy-manifest.json:
#   aes256-zeroiv     : AES-256-CBC, IV = 16 byte 0, PKCS7, key = UTF8 của chuỗi 32 ký tự, kết quả Base64
#   aes128-md5-randiv : AES-128-CBC, PKCS7, key = MD5(UTF8(passphrase)), IV ngẫu nhiên,
#                       kết quả Base64(IV 16 byte || bản mã). Mỗi lần mã hoá ra chuỗi khác nhau
#   none              : không mã hoá, lưu nguyên văn

function Get-HisAesKey([string]$key, [string]$scheme) {
    if ($scheme -eq 'aes128-md5-randiv') {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try { return $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key)) } finally { $md5.Dispose() }
    }
    return [System.Text.Encoding]::UTF8.GetBytes($key)
}

function Protect-HisString([string]$plainText, [string]$key, [string]$scheme = 'aes256-zeroiv') {
    if ($scheme -eq 'none') { return $plainText }
    if ($scheme -eq 'aes128-md5-randiv' -and [string]::IsNullOrEmpty($plainText)) { return $plainText }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = Get-HisAesKey $key $scheme
        if ($scheme -eq 'aes128-md5-randiv') { $aes.GenerateIV() } else { $aes.IV = New-Object byte[] 16 }
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($plainText)
        $enc = $aes.CreateEncryptor()
        $cipher = $enc.TransformFinalBlock($bytes, 0, $bytes.Length)
        if ($scheme -eq 'aes128-md5-randiv') { $cipher = [byte[]]($aes.IV + $cipher) }
        return [Convert]::ToBase64String($cipher)
    }
    finally { $aes.Dispose() }
}

# Giải mã; lỗi (sai key / không phải chuỗi mã hoá) -> $null
function Unprotect-HisString([string]$cipherText, [string]$key, [string]$scheme = 'aes256-zeroiv') {
    if ([string]::IsNullOrEmpty($cipherText)) { return $null }
    if ($scheme -eq 'none') { return $cipherText }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = Get-HisAesKey $key $scheme
        $bytes = [Convert]::FromBase64String($cipherText)
        $offset = 0
        if ($scheme -eq 'aes128-md5-randiv') {
            if ($bytes.Length -le 16) { return $null }
            $iv = New-Object byte[] 16
            [Array]::Copy($bytes, $iv, 16)
            $aes.IV = $iv
            $offset = 16
        }
        else { $aes.IV = New-Object byte[] 16 }
        $dec = $aes.CreateDecryptor()
        return [System.Text.Encoding]::UTF8.GetString($dec.TransformFinalBlock($bytes, $offset, $bytes.Length - $offset))
    }
    catch { return $null }
    finally { $aes.Dispose() }
}

function New-RandomToken([string]$format = 'hex32') {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        switch ($format) {
            'base64-32' { $b = New-Object byte[] 24; $rng.GetBytes($b); return [Convert]::ToBase64String($b) }
            'base64-48' { $b = New-Object byte[] 36; $rng.GetBytes($b); return [Convert]::ToBase64String($b) }
            default { $b = New-Object byte[] 16; $rng.GetBytes($b); return (-join ($b | ForEach-Object { $_.ToString('x2') })) }
        }
    }
    finally { $rng.Dispose() }
}

#endregion

#region ---------- Chuỗi kết nối ----------

function ConvertFrom-SqlConnectionString([string]$cs) {
    $info = @{ Server = ''; Database = ''; User = ''; Password = ''; Timeout = 30; Extra = $cs }
    if ([string]::IsNullOrWhiteSpace($cs)) { return $info }
    try {
        # Builder là IDictionary -> PowerShell hiểu .DataSource là key, phải dùng keyword chuẩn
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($cs)
        $info.Server = $b['Data Source']; $info.Database = $b['Initial Catalog']
        $info.User = $b['User ID']; $info.Password = $b['Password']; $info.Timeout = $b['Connect Timeout']
    }
    catch {
        # Có keyword .NET Framework không hiểu -> đọc thô
        foreach ($pair in ($cs -split ';')) {
            $kv = $pair -split '=', 2
            if ($kv.Length -ne 2) { continue }
            $k = $kv[0].Trim().ToLowerInvariant(); $v = $kv[1].Trim()
            if ($k -in 'server', 'data source', 'address', 'addr') { $info.Server = $v }
            elseif ($k -in 'database', 'initial catalog') { $info.Database = $v }
            elseif ($k -in 'user id', 'uid', 'user') { $info.User = $v }
            elseif ($k -in 'password', 'pwd') { $info.Password = $v }
            elseif ($k -eq 'connect timeout' -and $v -match '^\d+$') { $info.Timeout = [int]$v }
        }
        $info.Extra = ''
    }
    return $info
}

function New-SqlConnectionString($info) {
    # Giữ lại các tham số khác của chuỗi cũ (TrustServerCertificate, ...) nếu đọc được
    $b = $null
    if ($info.Extra) { try { $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($info.Extra) } catch { $b = $null } }
    if (-not $b) { $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder }
    $b['Data Source'] = $info.Server
    $b['Initial Catalog'] = $info.Database
    $b['Integrated Security'] = $false
    $b['User ID'] = $info.User
    $b['Password'] = $info.Password
    $b['Connect Timeout'] = [int]$info.Timeout
    return $b.ConnectionString
}

function Test-SqlConnection([string]$cs, [int]$timeoutSec = 8) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($cs)
    $b['Connect Timeout'] = $timeoutSec
    $conn = New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) + ' / DB=' + DB_NAME()"
        $v = $cmd.ExecuteScalar()
        return @{ Ok = $true; Message = "SQL Server $v" }
    }
    catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return @{ Ok = $false; Message = $e.Message }
    }
    finally { $conn.Dispose() }
}

function ConvertFrom-OracleConnectionString([string]$cs) {
    $info = @{ Host = ''; Port = '1521'; ServiceType = 'SERVICE_NAME'; ServiceName = ''; User = ''; Password = '' }
    if ([string]::IsNullOrWhiteSpace($cs)) { return $info }
    if ($cs -match '(?i)\(HOST\s*=\s*([^)]+)\)') { $info.Host = $Matches[1].Trim() }
    if ($cs -match '(?i)\(PORT\s*=\s*(\d+)\)') { $info.Port = $Matches[1] }
    if ($cs -match '(?i)\((SID|SERVICE_NAME)\s*=\s*([^)]+)\)') { $info.ServiceType = $Matches[1].ToUpperInvariant(); $info.ServiceName = $Matches[2].Trim() }
    elseif ($cs -match '(?i)Data\s*Source\s*=\s*([^;:/]+)(?::(\d+))?/([^;]+)') {
        # EZConnect host:port/service
        $info.Host = $Matches[1].Trim(); if ($Matches[2]) { $info.Port = $Matches[2] }
        $info.ServiceType = 'SERVICE_NAME'; $info.ServiceName = $Matches[3].Trim()
    }
    if ($cs -match '(?i)User\s*Id\s*=\s*("[^"]*"|[^;]*)') { $info.User = $Matches[1].Trim().Trim('"') }
    if ($cs -match '(?i)Password\s*=\s*("[^"]*"|[^;]*)') { $info.Password = $Matches[1].Trim().Trim('"') }
    return $info
}

function New-OracleConnectionString($info) {
    $pass = $info.Password
    if ($pass -match '[;=''\s]') { $pass = '"' + $pass + '"' }
    $user = $info.User
    if ($user -match '[;=\s]') { $user = '"' + $user + '"' }
    return ('Data Source=(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST={0})(PORT={1}))(CONNECT_DATA=({2}={3})));User Id={4};Password={5};' -f `
            $info.Host, $info.Port, $info.ServiceType, $info.ServiceName, $user, $pass)
}

function Test-TcpPort([string]$hostName, [int]$port, [int]$timeoutMs = 3000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($hostName, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $false }
        $client.EndConnect($ar)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

#endregion

#region ---------- HTTP / runtime ----------

# Gọi thử URL; trả về mã HTTP (0 = không kết nối được)
function Test-HttpUrl([string]$url, [int]$timeoutSec = 30) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
        return @{ Status = [int]$r.StatusCode; Message = '' }
    }
    catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($resp) { return @{ Status = [int]$resp.StatusCode; Message = $resp.StatusDescription } }
        return @{ Status = 0; Message = $_.Exception.Message }
    }
    catch {
        return @{ Status = 0; Message = $_.Exception.Message }
    }
}

function Get-AspNetCoreRuntimes {
    $dirs = @()
    foreach ($root in @("$env:ProgramFiles\dotnet", "${env:ProgramFiles(x86)}\dotnet")) {
        $p = Join-Path $root 'shared\Microsoft.AspNetCore.App'
        if (Test-Path $p) { $dirs += Get-ChildItem $p -Directory | ForEach-Object { $_.Name } }
    }
    return , @($dirs | Sort-Object -Unique)
}

#endregion

#region ---------- Trạng thái (lưu tại %ProgramData%\HIS.API.Deploy\state.json) ----------

function Get-StateDoc {
    New-Item -ItemType Directory -Force $script:DataDir | Out-Null
    $f = Join-Path $script:DataDir 'state.json'
    if (Test-Path $f) { return (Read-JsonCFile $f) }
    $doc = New-JsonCDoc "{`r`n  `"services`": {`r`n  }`r`n}`r`n" $f
    return $doc
}

function Save-StateDoc($doc) {
    Save-JsonCFile $doc (Join-Path $script:DataDir 'state.json')
}

function Get-ServiceState($stateDoc, [string]$service, [string]$key) {
    return (Get-JsonCValue $stateDoc "services:$service`:$key")
}

function Set-ServiceState($stateDoc, [string]$service, [string]$key, $value) {
    [void](Set-JsonCValue $stateDoc "services:$service`:$key" $value)
}

#endregion

#region ---------- Sao lưu ----------

function Get-BackupDir([string]$service) {
    $d = Join-Path $script:DataDir "backup\$service"
    New-Item -ItemType Directory -Force $d | Out-Null
    return $d
}

# Giữ lại $keep bản mới nhất theo mẫu tên
function Remove-OldBackups([string]$dir, [string]$filter, [int]$keep) {
    Get-ChildItem $dir -Filter $filter -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -Skip $keep |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

function Backup-AppSettings([string]$service, [string]$file) {
    if (-not (Test-Path $file)) { return $null }
    $dir = Get-BackupDir $service
    $dst = Join-Path $dir ('appsettings_{0:yyyyMMdd_HHmmss}.json' -f (Get-Date))
    Copy-Item $file $dst -Force
    Remove-OldBackups $dir 'appsettings_*.json' 20
    return $dst
}

#endregion
