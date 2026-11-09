<#
.SYNOPSIS
    Kiểm tra bộ cài do New-ApiDeploy.ps1 tạo ra, không cần quyền Administrator, không đụng IIS.

.DESCRIPTION
    - File đủ, mã hoá file: .ps1 UTF-8 có BOM; .bat ASCII, CRLF.
    - Cú pháp mọi .ps1, lệnh gọi tới hàm không tồn tại.
    - deploy-manifest.json: cú pháp, project tồn tại, port không trùng, kiểu mã hoá / tham số hợp lệ.
    - Mật khẩu (khi có -Password): hash PBKDF2-SHA256 và SHA1 khớp, mật khẩu sai bị từ chối,
      không có mật khẩu dạng chữ trong bộ cài.
    - Mã hoá: giải mã được chuỗi kết nối đang có trong appsettings.json của mã nguồn, mã hoá / giải mã vòng tròn.
    - Môi trường máy đang chạy (chỉ thông tin).
    - Không có chữ tiếng Việt lỗi mã hoá; Deploy.ps1 / Build-Package.ps1 có đổi font console (Consolas).
    - -Build: chạy Build-Package -All -Zip, kiểm tra gói có dll, đã xoá trắng giá trị bí mật, và file zip
      trong dist\ có đủ công cụ + gói, không chứa _backup, không chứa mật khẩu dạng chữ.

.EXAMPLE
    .\Test-ApiDeploy.ps1 -DeployPath "H:\01. Project\07. HIS\API_BaoSon\Deploy" -Password (Read-Host -AsSecureString)
#>
param(
    [Parameter(Mandatory = $true)][string]$DeployPath,
    [SecureString]$Password,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$DeployPath = [System.IO.Path]::GetFullPath($DeployPath).TrimEnd('\')

. (Join-Path $DeployPath 'lib\JsonC.ps1')
. (Join-Path $DeployPath 'lib\Common.ps1')
. (Join-Path $DeployPath 'lib\Iis.ps1')
. (Join-Path $DeployPath 'lib\Prereq.ps1')
. (Join-Path $DeployPath 'lib\Auth.ps1')

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$group, [string]$check, [bool]$ok, [string]$detail = '') {
    $results.Add([pscustomobject]@{ Nhom = $group; KiemTra = $check; KetQua = $(if ($ok) { 'ĐẠT' } else { 'LỖI' }); ChiTiet = $detail })
    if ($ok) { Write-Ok "$check $detail" } else { Write-Err "$check $detail" }
}

Write-Title "KIỂM TRA BỘ CÀI: $DeployPath"

#region File + mã hoá file
Write-Step 'File và mã hoá file'
$required = 'Deploy.bat', 'Deploy.ps1', 'Build-Package.bat', 'Build-Package.ps1', 'deploy-manifest.json', 'HUONG_DAN.md',
'lib\Auth.ps1', 'lib\Common.ps1', 'lib\Iis.ps1', 'lib\JsonC.ps1', 'lib\Prereq.ps1', 'prereq\README.txt'
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $DeployPath $_)) })
Add-Result 'File' 'Đủ file' ($missing.Count -eq 0) ($missing -join ', ')
foreach ($f in (Get-ChildItem $DeployPath -Recurse -Include *.ps1, *.bat -File | Where-Object { $_.FullName -notmatch '\\(packages|_backup|dist)\\' })) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
    $rel = $f.FullName.Substring($DeployPath.Length + 1)
    if ($f.Extension -eq '.ps1') { Add-Result 'File' "$rel UTF-8 BOM" $bom }
    else {
        $ascii = -not $bom -and -not @($b | Where-Object { $_ -gt 127 }).Count
        $text = [System.Text.Encoding]::ASCII.GetString($b)
        $crlf = ($text -replace "`r`n", '') -notmatch "`n"
        Add-Result 'File' "$rel ASCII + CRLF" ($ascii -and $crlf)
    }
}
# Chữ tiếng Việt bị đọc / ghi sai bảng mã (vd "Mật" thành "MÃ¡ÂºÂ­t")
# Dựng bằng [char] để mã nguồn chỉ có ASCII (dấu nháy cong U+2018 viết thẳng sẽ bị PowerShell hiểu là dấu nháy)
$mojiRx = '{0}[{1}-{2}]|{3}{4}|{3}{5}|{6}{7}|{8}{9}|{10}' -f [char]0xC3, [char]0x80, [char]0xBF, [char]0xE1, [char]0xBB, [char]0xBA, [char]0xC6, [char]0xB0, [char]0xC4, [char]0x2018, [char]0xFFFD
$moji = @(Get-ChildItem $DeployPath -Recurse -File -Include *.ps1, *.json, *.md, *.txt |
        Where-Object { $_.FullName -notmatch '\\(packages|_backup|dist)\\' -and [regex]::IsMatch([System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8), $mojiRx) } |
        ForEach-Object { $_.FullName.Substring($DeployPath.Length + 1) })
Add-Result 'File' 'Không có chữ tiếng Việt lỗi mã hoá' ($moji.Count -eq 0) ($moji -join ', ')
#endregion

#region Cú pháp + hàm không tồn tại
Write-Step 'Cú pháp PowerShell'
$scripts = @(Get-ChildItem $DeployPath -Recurse -Filter *.ps1 -File | Where-Object { $_.FullName -notmatch '\\(packages|_backup|dist)\\' })
$asts = @{}
foreach ($s in $scripts) {
    $tokens = $null; $errs = $null
    $asts[$s.FullName] = [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$tokens, [ref]$errs)
    Add-Result 'Cú pháp' $s.Name ($errs.Count -eq 0) (($errs | ForEach-Object { "dòng $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')
}
$defined = @{}
foreach ($a in $asts.Values) {
    foreach ($fn in $a.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined[$fn.Name] = 1 }
}
# Lệnh chỉ có trên Windows Server / được gọi có điều kiện
$allowed = @('Install-WindowsFeature')
$unknown = New-Object System.Collections.Generic.List[string]
foreach ($k in $asts.Keys) {
    foreach ($c in $asts[$k].FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $n = $c.GetCommandName()
        if (-not $n -or $defined.ContainsKey($n) -or $allowed -contains $n) { continue }
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { $unknown.Add("$(Split-Path $k -Leaf): $n (dòng $($c.Extent.StartLineNumber))") }
    }
}
Add-Result 'Cú pháp' 'Không gọi hàm / lệnh không tồn tại' ($unknown.Count -eq 0) (($unknown | Select-Object -Unique) -join '; ')
foreach ($n in 'Deploy.ps1', 'Build-Package.ps1') {
    $a = $asts[(Join-Path $DeployPath $n)]
    $calls = @()
    if ($a) { $calls = @($a.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Set-ConsoleUnicodeFont' }, $true)) }
    Add-Result 'Cú pháp' "$n đổi font console sang Consolas (hiện đúng tiếng Việt)" ($calls.Count -gt 0)
}
#endregion

#region Manifest
Write-Step 'deploy-manifest.json'
$manifest = $null
try { $manifest = Get-Content (Join-Path $DeployPath 'deploy-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json; Add-Result 'Manifest' 'Cú pháp JSON' $true }
catch { Add-Result 'Manifest' 'Cú pháp JSON' $false $_.Exception.Message }
if ($manifest) {
    $d = $manifest.defaults
    foreach ($k in 'toolTitle', 'installRoot', 'sitePrefix', 'aspNetCoreRuntime', 'dataDir', 'firewallPrefix', 'firewallGroup') {
        Add-Result 'Manifest' "defaults.$k" (-not [string]::IsNullOrEmpty([string]$d.$k)) ([string]$d.$k)
    }
    $repo = Split-Path $DeployPath -Parent
    if ($d.repoRoot) { $repo = [string]$d.repoRoot; if (-not [System.IO.Path]::IsPathRooted($repo)) { $repo = [System.IO.Path]::GetFullPath((Join-Path $DeployPath $repo)) } }
    Add-Result 'Manifest' 'Thư mục mã nguồn' (Test-Path $repo) $repo
    $names = @{}; $ports = @{}
    $types = 'string', 'url', 'path', 'int', 'bool', 'secret', 'encrypted', 'token'
    foreach ($s in $manifest.services) {
        $errs = New-Object System.Collections.Generic.List[string]
        if ($names.ContainsKey($s.name)) { $errs.Add('trùng tên') }; $names[$s.name] = 1
        if ($ports.ContainsKey([int]$s.defaultPort)) { $errs.Add("trùng port $($s.defaultPort) với $($ports[[int]$s.defaultPort])") }; $ports[[int]$s.defaultPort] = $s.name
        if ([int]$s.defaultPort -lt 1 -or [int]$s.defaultPort -gt 65535) { $errs.Add('port sai') }
        if (-not (Test-Path (Join-Path $repo $s.project))) { $errs.Add("không có project $($s.project)") }
        if ($s.dll -notmatch '\.dll$') { $errs.Add('dll sai') }
        $scheme = if ($s.cryptoScheme) { [string]$s.cryptoScheme } else { 'aes256-zeroiv' }
        if ($scheme -notin 'aes256-zeroiv', 'aes128-md5-randiv', 'none') { $errs.Add("cryptoScheme '$scheme' không hỗ trợ") }
        if ($scheme -eq 'aes256-zeroiv' -and [System.Text.Encoding]::UTF8.GetByteCount([string]$s.cryptoKey) -ne 32) { $errs.Add('cryptoKey aes256-zeroiv phải đúng 32 byte') }
        if ($scheme -eq 'aes128-md5-randiv' -and -not $s.cryptoKey) { $errs.Add('thiếu cryptoKey') }
        foreach ($c in @($s.connections)) { if ($c -and $c.type -notin 'sqlserver', 'oracle') { $errs.Add("kết nối $($c.name): type '$($c.type)'") } }
        foreach ($st in @($s.settings) + @($s.controllers | ForEach-Object { $_.settings })) {
            if ($st -and $st.type -and $st.type -notin $types) { $errs.Add("tham số $($st.key): type '$($st.type)'") }
            if ($st -and -not $st.key) { $errs.Add('tham số thiếu key') }
        }
        Add-Result 'Manifest' $s.name ($errs.Count -eq 0) ($errs -join '; ')
    }
}
#endregion

#region Mật khẩu
Write-Step 'Mật khẩu công cụ'
Add-Result 'Mật khẩu' 'Hash PBKDF2 có trong lib\Auth.ps1' ([bool]($script:ToolPasswordSalt -and $script:ToolPasswordHashSha256 -and $script:ToolPasswordHashSha1)) "($($script:ToolPasswordIterations) vòng)"
if ($Password) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    Add-Result 'Mật khẩu' 'Mật khẩu đúng được chấp nhận' (Test-ToolPassword $pw)
    Add-Result 'Mật khẩu' 'Mật khẩu sai bị từ chối' (-not (Test-ToolPassword ($pw + 'x')) -and -not (Test-ToolPassword ''))
    $salt = [Convert]::FromBase64String($script:ToolPasswordSalt)
    $sha1 = [Convert]::ToBase64String((Get-PasswordHashBytes $pw $salt $script:ToolPasswordIterations 'SHA1'))
    Add-Result 'Mật khẩu' 'Hash dự phòng SHA1 (.NET cũ) khớp' ($sha1 -ceq $script:ToolPasswordHashSha1)
    $leak = @(Get-ChildItem $DeployPath -Recurse -File -Include *.ps1, *.bat, *.json, *.md, *.txt |
            Where-Object { $_.FullName -notmatch '\\(packages|_backup|dist)\\' -and ([System.IO.File]::ReadAllText($_.FullName)).Contains($pw) } |
            ForEach-Object { $_.FullName.Substring($DeployPath.Length + 1) })
    Add-Result 'Mật khẩu' 'Không có mật khẩu dạng chữ trong bộ cài' ($leak.Count -eq 0) ($leak -join ', ')
    $pw = $null
}
else { Write-Info 'Không truyền -Password: bỏ qua kiểm tra mật khẩu đúng/sai.' }
#endregion

#region Mã hoá chuỗi kết nối
Write-Step 'Mã hoá chuỗi kết nối (so với appsettings.json của mã nguồn)'
if ($manifest) {
    foreach ($s in $manifest.services) {
        $scheme = if ($s.cryptoScheme) { [string]$s.cryptoScheme } else { 'aes256-zeroiv' }
        $file = Join-Path (Split-Path (Join-Path $repo $s.project) -Parent) 'appsettings.json'
        $sample = 'Data Source=10.0.0.1;Initial Catalog=Test;User ID=sa;Password=Th$ử-Mật_khẩu;'
        $round = Unprotect-HisString (Protect-HisString $sample ([string]$s.cryptoKey) $scheme) ([string]$s.cryptoKey) $scheme
        Add-Result 'Mã hoá' "$($s.name): mã hoá rồi giải mã ra đúng chuỗi ($scheme)" ($round -ceq $sample)
        if (-not (Test-Path $file)) { continue }
        $doc = Read-JsonCFile $file
        foreach ($c in @($s.connections)) {
            if (-not $c) { continue }
            $cipher = Get-JsonCValue $doc "ConnectionStrings:$($c.name)"
            if ([string]::IsNullOrEmpty($cipher)) { Write-Info "$($s.name): ConnectionStrings:$($c.name) đang trống - không có mẫu để so"; continue }
            $plain = Unprotect-HisString $cipher ([string]$s.cryptoKey) $scheme
            $ok = [bool]($plain -and $plain -match '=')
            $detail = ''
            if ($ok -and $scheme -eq 'aes256-zeroiv') { $ok = ((Protect-HisString $plain ([string]$s.cryptoKey) $scheme) -ceq $cipher); $detail = '(mã hoá lại ra đúng chuỗi cũ)' }
            Add-Result 'Mã hoá' "$($s.name): giải mã ConnectionStrings:$($c.name) của mã nguồn" $ok $detail
        }
    }
}
#endregion

#region Môi trường (thông tin)
Write-Step 'Môi trường máy này (chỉ thông tin, không tính lỗi)'
if ($manifest) {
    $ch = ConvertTo-RuntimeChannels (@([string]$manifest.defaults.aspNetCoreRuntime) + @($manifest.services | ForEach-Object { [string]$_.runtime }))
    $st = Get-EnvironmentStatus $ch
    Write-Info "IIS: $($st.Iis) | WAS/W3SVC chạy: $($st.IisRunning) | ANCM: $($st.Ancm) | AppInit: $($st.AppInit) | Runtime $($ch -join ','): $($st.Runtime)"
    Write-Info "Runtime đang có: $((Get-AspNetCoreRuntimes) -join ', ') | Chờ khởi động lại: $(Test-PendingReboot)"
    if ($st.Missing.Count) { Write-Warn "Máy này còn thiếu: $($st.Missing -join ', ') (Deploy.bat sẽ đề nghị cài)" }
}
#endregion

#region Build
if ($Build) {
    Write-Step 'Build-Package -All -Zip'
    $buildStart = Get-Date
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DeployPath 'Build-Package.ps1') -All -Zip | Out-Host
    foreach ($s in $manifest.services) {
        $pkg = Join-Path $DeployPath "packages\$($s.name)"
        $hasDll = Test-Path (Join-Path $pkg $s.dll)
        Add-Result 'Build' "$($s.name): gói có $($s.dll)" $hasDll
        if (-not $hasDll) { continue }
        Add-Result 'Build' "$($s.name): có web.config (AspNetCoreModuleV2)" ([bool](Select-String -Path (Join-Path $pkg 'web.config') -Pattern 'AspNetCoreModuleV2' -Quiet))
        $af = Join-Path $pkg 'appsettings.json'
        if (Test-Path $af) {
            $doc = Read-JsonCFile $af
            $keys = @($s.connections | Where-Object { $_ } | ForEach-Object { "ConnectionStrings:$($_.name)" }) +
            @(@($s.settings) + @($s.controllers | ForEach-Object { $_.settings }) | Where-Object { $_ -and $_.type -in 'secret', 'encrypted', 'token' } | ForEach-Object { $_.key })
            $left = @($keys | Where-Object { -not [string]::IsNullOrEmpty((Get-JsonCValue $doc $_)) })
            Add-Result 'Build' "$($s.name): appsettings.json của gói không còn giá trị bí mật" ($left.Count -eq 0) ($left -join ', ')
        }
    }

    # File zip giao cho máy chủ
    $zip = Get-ChildItem (Join-Path $DeployPath 'dist') -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $buildStart } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Add-Result 'Zip' 'Tạo file zip mới trong dist\' ([bool]$zip) $(if ($zip) { "$($zip.FullName) ($([Math]::Round($zip.Length / 1MB, 1)) MB)" } else { '' })
    if ($zip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
        try {
            $names = @($za.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
            $need = @('Deploy.bat', 'Deploy.ps1', 'Build-Package.bat', 'Build-Package.ps1', 'deploy-manifest.json', 'HUONG_DAN.md',
                'lib/Auth.ps1', 'lib/Common.ps1', 'lib/Iis.ps1', 'lib/JsonC.ps1', 'lib/Prereq.ps1', 'prereq/README.txt')
            foreach ($s in $manifest.services) { $need += "packages/$($s.name)/$($s.dll)"; $need += "packages/$($s.name)/web.config" }
            $miss = @($need | Where-Object { $names -notcontains $_ })
            Add-Result 'Zip' 'Zip có đủ công cụ + gói của mọi service' ($miss.Count -eq 0) ($miss -join ', ')
            $extra = @($names | Where-Object { $_ -match '^(_backup|dist|logs)/' })
            Add-Result 'Zip' 'Zip không chứa _backup / dist / logs' ($extra.Count -eq 0) (($extra | Select-Object -First 5) -join ', ')
            if ($Password) {
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
                try { $pwz = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                $leakZ = New-Object System.Collections.Generic.List[string]
                foreach ($en in $za.Entries) {
                    if ($en.FullName -notmatch '\.(ps1|bat|json|md|txt|config)$') { continue }
                    $sr = New-Object System.IO.StreamReader($en.Open(), [System.Text.Encoding]::UTF8)
                    try { if ($sr.ReadToEnd().Contains($pwz)) { $leakZ.Add($en.FullName) } } finally { $sr.Dispose() }
                }
                $pwz = $null
                Add-Result 'Zip' 'Zip không chứa mật khẩu dạng chữ' ($leakZ.Count -eq 0) ($leakZ -join ', ')
            }
        }
        finally { $za.Dispose() }
    }
}
#endregion

Write-Step 'Kết quả'
$results | Format-Table -AutoSize -Wrap | Out-Host
$fail = @($results | Where-Object { $_.KetQua -ne 'ĐẠT' }).Count
if ($fail) { Write-Err "$fail mục LỖI / $($results.Count)"; exit 1 }
Write-Ok "Tất cả $($results.Count) mục ĐẠT"
