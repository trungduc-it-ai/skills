<#
.SYNOPSIS
    Tạo mới hoặc cập nhật bộ cài đặt (thư mục Deploy) cho các API ASP.NET Core của 1 dự án.

.DESCRIPTION
    1. Quét solution (.sln) trong RepoRoot: project web ASP.NET Core, target framework, appsettings.json,
       ConnectionStrings, Cryptography.cs (kiểu mã hoá + khoá), controller/action, ApiSwitchFilter, Swagger.
    2. Sinh mới deploy-manifest.json, hoặc cập nhật manifest đang có: giữ phần đã sửa tay, chỉ bổ sung
       service / kết nối / tham số / controller / action mới, báo những mục không còn thấy trong mã nguồn.
    3. Chép engine của skill (Deploy.ps1, Build-Package.ps1, lib\, .bat). File cũ khác nội dung được sao lưu
       vào <DeployPath>\_backup\<thời điểm>\ trước khi ghi đè.
    4. Nhúng hash PBKDF2 của mật khẩu công cụ vào lib\Auth.ps1 (không lưu mật khẩu dạng chữ).
    5. Sinh HUONG_DAN.md cho người triển khai.

.PARAMETER ProjectName
    Tên dự án: tiêu đề công cụ, tiền tố site/app pool, thư mục dữ liệu trên máy chủ, rule firewall, tên file zip.
.PARAMETER DeployPath
    Thư mục lưu bộ cài (vd <repo>\Deploy). Đã có deploy-manifest.json thì chạy chế độ cập nhật.
.PARAMETER RepoRoot
    Thư mục gốc mã nguồn (chứa .sln). Mặc định: thư mục cha của DeployPath nếu có .sln, không thì thư mục hiện tại.
.PARAMETER Password
    SecureString - đặt mật khẩu công cụ mới. Bỏ trống: giữ hash đang có trong DeployPath\lib\Auth.ps1,
    chưa có thì dùng hash mặc định nhúng trong template của skill.
.PARAMETER StartPort
    Port gợi ý cho service mới đầu tiên, các service sau tăng dần.
.PARAMETER Services
    Chỉ lấy các service có tên trong danh sách (mặc định: mọi project web trong solution).
.PARAMETER ScanOnly
    Chỉ quét và in báo cáo, không ghi file.
.PARAMETER Force
    Sinh lại deploy-manifest.json từ đầu thay vì cập nhật (bản cũ được sao lưu).
.PARAMETER Zip
    Ghi bộ cài xong thì chạy Build-Package -All -Zip: build mọi service và nén file zip vào <DeployPath>\dist\.

.EXAMPLE
    .\New-ApiDeploy.ps1 -ProjectName API_BaoSon -DeployPath "H:\01. Project\07. HIS\API_BaoSon\Deploy"
.EXAMPLE
    .\New-ApiDeploy.ps1 -ProjectName API_BaoSon -DeployPath D:\Deploy_BaoSon -RepoRoot "H:\01. Project\07. HIS\API_BaoSon" -ScanOnly
.EXAMPLE
    .\New-ApiDeploy.ps1 -ProjectName X -DeployPath .\Deploy -Password (Read-Host 'Mật khẩu công cụ' -AsSecureString)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectName,
    [Parameter(Mandatory = $true)][string]$DeployPath,
    [string]$RepoRoot,
    [SecureString]$Password,
    [int]$StartPort = 8301,
    [string]$SitePrefix,
    [string]$InstallRoot,
    [string[]]$Services,
    [switch]$ScanOnly,
    [switch]$Force,
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$SkillRoot = Split-Path $PSScriptRoot -Parent
$Template = Join-Path $SkillRoot 'template'
. (Join-Path $Template 'lib\JsonC.ps1')
. (Join-Path $Template 'lib\Common.ps1')

$ExcludeDirRx = '\\(bin|obj|OLD|packages|node_modules|_backup|\.vs|\.git|Deploy|dist)\\'
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$Warnings = New-Object System.Collections.Generic.List[string]
$Notes = New-Object System.Collections.Generic.List[string]

function Add-Warning([string]$text) { $Warnings.Add($text); Write-Warn $text }

#region ---------- Đường dẫn ----------

function ConvertTo-SafeName([string]$s) { return ($s.Trim() -replace '[^A-Za-z0-9_.\-]', '_') }

$DeployPath = [System.IO.Path]::GetFullPath($DeployPath).TrimEnd('\')
if (-not $RepoRoot) {
    $parent = Split-Path $DeployPath -Parent
    if ($parent -and (Test-Path $parent) -and @(Get-ChildItem $parent -Filter *.sln -File).Count) { $RepoRoot = $parent }
    elseif (@(Get-ChildItem (Get-Location).Path -Filter *.sln -File).Count) { $RepoRoot = (Get-Location).Path }
    else { throw 'Không thấy file .sln ở thư mục cha của DeployPath hoặc thư mục hiện tại. Truyền -RepoRoot.' }
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
if (-not (Test-Path $RepoRoot)) { throw "Không có thư mục mã nguồn $RepoRoot" }

# Đường dẫn tương đối từ $from tới $to, dùng '/'
function Get-RelativePath([string]$from, [string]$to) {
    $f = New-Object System.Uri(($from.TrimEnd('\') + '\'))
    $t = New-Object System.Uri($to)
    $rel = [System.Uri]::UnescapeDataString($f.MakeRelativeUri($t).ToString())
    if ($rel -match '^file:') { return $to }
    return $rel
}

# Loại thư mục build / bản cũ. So trên phần đường dẫn sau RepoRoot để tên thư mục cha không ảnh hưởng
function Test-ExcludedPath([string]$full) {
    $rel = $full
    if ($full.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) { $rel = $full.Substring($RepoRoot.Length) }
    return ($rel -match $ExcludeDirRx)
}

#endregion

#region ---------- Quét mã nguồn ----------

function Get-ProjectFiles {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($sln in @(Get-ChildItem $RepoRoot -Filter *.sln -File)) {
        $text = [System.IO.File]::ReadAllText($sln.FullName)
        foreach ($m in [regex]::Matches($text, '(?m)^Project\("\{[^}]+\}"\)\s*=\s*"[^"]*"\s*,\s*"([^"]+\.csproj)"')) {
            $p = [System.IO.Path]::GetFullPath((Join-Path $sln.DirectoryName $m.Groups[1].Value))
            if ((Test-Path $p) -and -not $list.Contains($p)) { $list.Add($p) }
        }
    }
    if ($list.Count -eq 0) {
        foreach ($f in (Get-ChildItem $RepoRoot -Recurse -Filter *.csproj -File)) {
            if (-not (Test-ExcludedPath $f.FullName)) { $list.Add($f.FullName) }
        }
    }
    return , $list
}

function Read-CsProj([string]$path) {
    [xml]$x = [System.IO.File]::ReadAllText($path)
    $props = @{}
    foreach ($pg in @($x.Project.PropertyGroup)) {
        if (-not $pg) { continue }
        foreach ($n in $pg.ChildNodes) {
            if ($n.NodeType -eq 'Element' -and -not $props.ContainsKey($n.LocalName)) { $props[$n.LocalName] = $n.InnerText.Trim() }
        }
    }
    $dir = Split-Path $path -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
    if ($props['AssemblyName'] -and $props['AssemblyName'] -notmatch '\$\(') { $name = $props['AssemblyName'] }
    $tfm = [string]$props['TargetFramework']
    if (-not $tfm) { $tfm = ([string]$props['TargetFrameworks'] -split ';')[0] }
    return @{
        Path     = $path
        Dir      = $dir
        Sdk      = [string]$x.Project.Sdk
        Name     = $name
        Tfm      = $tfm
        Packages = @($x.SelectNodes('//PackageReference') | ForEach-Object { $_.GetAttribute('Include') })
        ProjRefs = @($x.SelectNodes('//ProjectReference') | ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path $dir $_.GetAttribute('Include'))) })
    }
}

# netcoreapp3.1 -> 3.1, net8.0 -> 8.0; .NET Framework -> $null (không chạy bằng ASP.NET Core Module)
function Get-RuntimeChannel([string]$tfm) {
    if ($tfm -match '^netcoreapp(\d+\.\d+)$') { return $Matches[1] }
    if ($tfm -match '^net(\d+\.\d+)(-windows.*)?$' -and [version]$Matches[1] -ge [version]'5.0') { return $Matches[1] }
    return $null
}

# File .cs của project + các project được tham chiếu (đệ quy), kèm danh sách package
function Get-SourceSet($proj) {
    $seen = @{}
    $files = New-Object System.Collections.Generic.List[string]
    $packages = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($proj.Path)
    while ($queue.Count) {
        $p = [string]$queue.Dequeue()
        if ($seen.ContainsKey($p) -or -not (Test-Path $p)) { continue }
        $seen[$p] = 1
        $info = Read-CsProj $p
        foreach ($pk in $info.Packages) { if ($pk) { $packages.Add($pk) } }
        foreach ($f in (Get-ChildItem $info.Dir -Recurse -Filter *.cs -File)) {
            if ($f.FullName -notmatch '\\(bin|obj)\\' -and -not (Test-ExcludedPath $f.FullName)) { $files.Add($f.FullName) }
        }
        foreach ($r in $info.ProjRefs) { $queue.Enqueue($r) }
    }
    return @{ Files = $files; Packages = $packages }
}

# Bỏ comment /* */, dòng //, và // cuối dòng (không đụng tới http:// trong chuỗi)
function Remove-CsComments([string]$code) {
    $code = [regex]::Replace($code, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $code = [regex]::Replace($code, '(?m)^\s*//.*$', '')
    return [regex]::Replace($code, '(?m)(?<![:"])//.*$', '')
}

# Kiểu mã hoá chuỗi kết nối theo Cryptography.cs. Không gọi DecryptString ở đâu -> 'none'
function Find-Crypto($files, $texts) {
    $usesDecrypt = $false
    $found = $null
    foreach ($f in $files) {
        $code = Remove-CsComments $texts[$f]
        $isCrypto = $code -match 'class\s+Cryptography\b'
        if (-not $isCrypto -and $code -match '\bDecryptString\s*\(') { $usesDecrypt = $true }
        if ($isCrypto -and -not $found) {
            $keyMatch = [regex]::Match($code, '(?:const|static\s+readonly|static)\s+string\s+\w+\s*=\s*"([^"]+)"')
            $encKey = [regex]::Match($code, '(?i)encryptionKey\s*=\s*"([^"]+)"')
            if ($code -match '\bMD5\b' -and $code -match 'GenerateIV\s*\(' -and $keyMatch.Success) {
                $found = @{ Scheme = 'aes128-md5-randiv'; Key = $keyMatch.Groups[1].Value; File = $f }
            }
            elseif ($encKey.Success) { $found = @{ Scheme = 'aes256-zeroiv'; Key = $encKey.Groups[1].Value; File = $f } }
            else { $found = @{ Scheme = 'unknown'; Key = ''; File = $f } }
        }
    }
    if (-not $usesDecrypt) {
        $file = ''
        if ($found) { $file = $found.File }
        return @{ Scheme = 'none'; Key = ''; File = $file }
    }
    if (-not $found) { return @{ Scheme = 'unknown'; Key = ''; File = '' } }
    return $found
}

# Controller + action: method public có [HttpGet/Post/Put/Delete/Patch]
function Get-Controllers($files, $texts) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in ($files | Where-Object { $_ -match '\\Controllers\\' } | Sort-Object)) {
        $ctrl = $null; $pendingHttp = $false
        $acts = New-Object System.Collections.Generic.List[string]
        foreach ($l in ($texts[$f] -split "\r?\n")) {
            $t = $l.Trim()
            if ($t.StartsWith('//')) { continue }
            if (-not $ctrl) {
                $m = [regex]::Match($t, 'public\s+(?:sealed\s+|partial\s+)*class\s+(\w+)Controller\b')
                if ($m.Success) { $ctrl = $m.Groups[1].Value }
                continue
            }
            if ($t -match '^\[Http(Get|Post|Put|Delete|Patch)\b') { $pendingHttp = $true; continue }
            if ($t -match '^\[') { continue }
            $m = [regex]::Match($t, '^public\s+(?:async\s+)?(?:virtual\s+)?[\w<>\[\],\.\s\?]+?\s+(\w+)\s*\(')
            if ($m.Success -and $pendingHttp -and -not $acts.Contains($m.Groups[1].Value)) { $acts.Add($m.Groups[1].Value) }
            if ($t -ne '') { $pendingHttp = $false }
        }
        # Controller không có action (lớp cơ sở) thì bỏ
        if ($ctrl -and $acts.Count) { $list.Add([ordered]@{ name = $ctrl; title = $ctrl; actions = $acts.ToArray(); settings = @() }) }
    }
    return , $list
}

$LabelMap = @{
    username = 'Tên đăng nhập'; tendangnhap = 'Tên đăng nhập'; user = 'Tài khoản'; password = 'Mật khẩu'; matkhau = 'Mật khẩu'
    baseurl = 'URL gốc'; endpoint = 'URL endpoint'; url = 'URL'; enabled = 'Bật / tắt (true/false)'
    certthumbprint = 'Thumbprint chứng thư số'; certstorename = 'Kho chứng thư (StoreName)'
    certstorelocation = 'Vị trí kho chứng thư (CurrentUser / LocalMachine)'
    pfxpath = 'Đường dẫn file chứng thư .pfx'; pfxpassword = 'Mật khẩu file .pfx'
    privatekey = 'Khoá bí mật (private key)'; publickey = 'Khoá công khai (public key)'
    retentiondays = 'Giữ log bao nhiêu ngày (0 = không tự xoá)'; cleanupintervalhours = 'Chu kỳ tự dọn log (giờ)'
    adminkey = 'Mã quản trị màn hình log (trống = không yêu cầu)'; key = 'Khoá'; issuer = 'Issuer'; audience = 'Audience'
    pollingintervalseconds = 'Chu kỳ quét (giây)'; tokenrefreshskewseconds = 'Làm mới token trước khi hết hạn (giây)'
}

function Get-SettingType([string]$key, [string]$kind, [string]$value) {
    $leaf = ($key -split ':')[-1]
    if ($kind -eq 'true' -or $kind -eq 'false') { return 'bool' }
    if ($kind -eq 'number') { if ($value -match '^-?\d+$') { return 'int' } else { return 'string' } }
    if ($leaf -match '(?i)(password|passwd|pwd|matkhau|mat_khau|secret|privatekey|passcode)$') { return 'secret' }
    if ($key -match '(?i)(^|:)jwt:(key|secret)$' -or $leaf -match '(?i)(apikey|api_key|adminkey|token|signingkey)$') { return 'token' }
    if ($value -match '^(?i)https?://') { return 'url' }
    if ($leaf -match '(?i)(url|endpoint)') { return 'url' }
    if ($leaf -match '(?i)(path|folder|directory|thumuc)$' -or $leaf -match '(?i)^thumuc') { return 'path' }
    return 'string'
}

# Các leaf key trong appsettings: @{ Key; Kind; Value }
function Get-LeafSettings($node, [string]$prefix, $list) {
    if ($node.Kind -eq 'object') {
        foreach ($m in $node.Members) {
            $path = if ($prefix) { "$prefix`:$($m.Key)" } else { $m.Key }
            Get-LeafSettings $m.Value $path $list
        }
    }
    elseif ($node.Kind -eq 'array') {
        for ($i = 0; $i -lt $node.Items.Count; $i++) { Get-LeafSettings $node.Items[$i] "$prefix`:$i" $list }
    }
    else { $list.Add(@{ Key = $prefix; Kind = $node.Kind; Value = [string]$node.Value }) }
}

function New-SettingEntry($leaf) {
    $type = Get-SettingType $leaf.Key $leaf.Kind $leaf.Value
    $last = ($leaf.Key -split ':')[-1]
    $title = $LabelMap[$last.ToLowerInvariant()]
    if (-not $title) { $title = $last }
    $e = [ordered]@{ key = $leaf.Key; type = $type; title = $title }
    if ($type -eq 'token') {
        if ($leaf.Key -match '(?i)jwt') { $e.generate = 'base64-48'; $e.required = $true } else { $e.generate = 'hex32' }
    }
    if ($last -match '(?i)(Interval|Seconds|Minute|Timeout|Hours|Skew|Retry|Version|StoreName|StoreLocation|DataFormat|LanguageId)') { $e.advanced = $true }
    return $e
}

function Get-ServiceScan($proj) {
    $src = Get-SourceSet $proj
    $texts = @{}
    foreach ($f in $src.Files) { $texts[$f] = [System.IO.File]::ReadAllText($f) }
    $own = @($src.Files | Where-Object { $_.StartsWith($proj.Dir + '\', [StringComparison]::OrdinalIgnoreCase) })
    $allCode = ($src.Files | ForEach-Object { $texts[$_] }) -join "`n"
    $ownCode = ($own | ForEach-Object { $texts[$_] }) -join "`n"

    $s = @{
        Name        = $proj.Name
        Project     = Get-RelativePath $RepoRoot $proj.Path
        Dir         = $proj.Dir
        Runtime     = Get-RuntimeChannel $proj.Tfm
        Crypto      = Find-Crypto $src.Files $texts
        ApiSwitch   = ($ownCode -match 'class\s+ApiSwitchFilter\b')
        HealthPath  = ''
        Connections = (New-Object System.Collections.Generic.List[object])
        Settings    = (New-Object System.Collections.Generic.List[object])
        Controllers = (Get-Controllers $own $texts)
        Secrets     = (New-Object System.Collections.Generic.List[string])
        Skipped     = (New-Object System.Collections.Generic.List[string])
        Note        = ''
    }
    if ($ownCode -match 'UseSwaggerUI|UseSwaggerForOcelotUI') { $s.HealthPath = 'swagger/index.html' }
    if (@(Get-ChildItem $proj.Dir -Filter 'ocelot*.json' -File -ErrorAction SilentlyContinue).Count) {
        $s.Note = 'Có Ocelot.json: sửa DownstreamHostAndPorts theo port các service đã cài (công cụ không sửa file này)'
    }

    $settingsFile = Join-Path $proj.Dir 'appsettings.json'
    if (-not (Test-Path $settingsFile)) { Add-Warning "$($s.Name): không có appsettings.json"; return $s }
    $doc = Read-JsonCFile $settingsFile
    $isOracleProject = (@($src.Packages | Where-Object { $_ -match '^Oracle\.' }).Count -gt 0) -and
        (@($src.Packages | Where-Object { $_ -match 'SqlClient|EntityFrameworkCore\.SqlServer' }).Count -eq 0)

    foreach ($k in (Get-JsonCKeys $doc 'ConnectionStrings')) {
        $v = Get-JsonCValue $doc "ConnectionStrings:$k"
        $plain = $null
        if ($v) {
            if ($s.Crypto.Scheme -eq 'unknown') { $plain = $null }
            else { $plain = Unprotect-HisString $v $s.Crypto.Key $s.Crypto.Scheme }
            if ($plain -and $plain -match '=') {
                if ($s.Crypto.Scheme -eq 'none') { $s.Secrets.Add("ConnectionStrings:$k (không mã hoá)") }
            }
            elseif ($s.Crypto.Scheme -ne 'unknown') {
                Add-Warning "$($s.Name): không giải mã được ConnectionStrings:$k bằng khoá trong $(Split-Path $s.Crypto.File -Leaf) ($($s.Crypto.Scheme)) - kiểm tra lại Cryptography.cs"
            }
        }
        $type = 'sqlserver'
        if (($plain -and $plain -match '(?i)\(\s*DESCRIPTION\s*=') -or ((-not $plain) -and $isOracleProject)) { $type = 'oracle' }
        $s.Connections.Add([ordered]@{ name = $k; type = $type; title = "CSDL $k" })
    }

    $skipSections = @('Logging', 'AllowedHosts', 'ConnectionStrings', 'ApiSwitch')
    foreach ($m in $doc.Root.Members) {
        if ($skipSections -contains $m.Key) { continue }
        # Chỉ lấy section có tên xuất hiện trong mã nguồn (bỏ section sao lưu / không còn dùng)
        if ($allCode.IndexOf('"' + $m.Key + '"', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $allCode.IndexOf('"' + $m.Key + ':', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $s.Skipped.Add($m.Key); continue
        }
        $leaves = New-Object System.Collections.Generic.List[object]
        Get-LeafSettings $m.Value $m.Key $leaves
        foreach ($leaf in $leaves) {
            $e = New-SettingEntry $leaf
            $s.Settings.Add($e)
            if ($e.type -in 'secret', 'token' -and $leaf.Value) { $s.Secrets.Add($leaf.Key) }
        }
    }
    return $s
}

#endregion

#region ---------- JSON / manifest ----------

# PSCustomObject (ConvertFrom-Json) -> ordered dictionary, giữ thứ tự key
function ConvertTo-PlainData($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [string] -or $o -is [bool] -or $o -is [int] -or $o -is [long] -or $o -is [double] -or $o -is [decimal]) { return $o }
    if ($o -is [System.Collections.IDictionary]) {
        $r = [ordered]@{}
        foreach ($k in @($o.Keys)) { $r[$k] = ConvertTo-PlainData $o[$k] }
        return $r
    }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $r = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { $r[$p.Name] = ConvertTo-PlainData $p.Value }
        return $r
    }
    if ($o -is [System.Collections.IEnumerable]) { return , @($o | ForEach-Object { ConvertTo-PlainData $_ }) }
    return [string]$o
}

function Format-Json($v, [string]$indent = '', [bool]$inArray = $false) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [int] -or $v -is [long]) { return [string]$v }
    if ($v -is [double] -or $v -is [decimal]) { return ([string]$v).Replace(',', '.') }
    if ($v -is [string]) { return (JcQuote $v) }
    $inner = $indent + '  '
    if ($v -is [System.Collections.IDictionary]) {
        if ($v.Count -eq 0) { return '{}' }
        $nested = @($v.Values | Where-Object { $_ -is [System.Collections.IDictionary] -or $_ -is [array] }).Count
        if ($inArray -and $nested -eq 0) {
            $one = '{ ' + ((@($v.Keys) | ForEach-Object { (JcQuote $_) + ': ' + (Format-Json $v[$_] $inner) }) -join ', ') + ' }'
            if ($one.Length -le 220) { return $one }
        }
        $lines = @($v.Keys) | ForEach-Object { $inner + (JcQuote $_) + ': ' + (Format-Json $v[$_] $inner) }
        return "{`r`n" + ($lines -join ",`r`n") + "`r`n$indent}"
    }
    if ($v -is [array]) {
        if ($v.Count -eq 0) { return '[]' }
        $nested = @($v | Where-Object { $_ -is [System.Collections.IDictionary] -or $_ -is [array] }).Count
        if ($nested -eq 0) {
            $one = '[ ' + ((@($v) | ForEach-Object { Format-Json $_ $inner }) -join ', ') + ' ]'
            if ($one.Length -le 200) { return $one }
        }
        $lines = @($v) | ForEach-Object { $inner + (Format-Json $_ $inner $true) }
        return "[`r`n" + ($lines -join ",`r`n") + "`r`n$indent]"
    }
    return (JcQuote ([string]$v))
}

# Lưu ý PowerShell 5.1: @($x) với $x là List[object] chứa OrderedDictionary báo "Argument types do not match"
# -> duyệt thẳng List / dùng .ToArray(), không bọc @()
function Find-ByName($list, [string]$name) {
    if ($null -eq $list) { return $null }
    if ($list -is [System.Collections.IDictionary]) { $list = , $list }
    foreach ($i in $list) { if ($i -and [string]$i['name'] -ieq $name) { return $i } }
    return $null
}

$ManifestComment = @(
    'Mô tả các API service cho công cụ Deploy.ps1 / Build-Package.ps1 (sinh bởi skill api-deploy, sửa tay được).',
    'Chạy lại skill để cập nhật: phần đã sửa tay được giữ, chỉ bổ sung service / kết nối / tham số / controller / action mới.',
    'type: string | url | path | int | bool | secret (ẩn khi nhập) | encrypted (mã hoá bằng cryptoKey) | token (G = sinh ngẫu nhiên)',
    'advanced: true = chỉ hỏi khi chọn cấu hình nâng cao. generate: hex32 | base64-32 | base64-48 (cho type token). required: true = không cho để trống',
    'cryptoScheme: aes256-zeroiv | aes128-md5-randiv | none - phải khớp Cryptography.cs của service, cryptoKey là khoá / passphrase trong file đó',
    'apiSwitch: false = service không có ApiSwitchFilter, bỏ bước chọn API. healthPath: đường dẫn gọi thử sau khi khởi động ("" = trang gốc)',
    'defaults.installRoot chỉ là gợi ý lần đầu; thư mục thật chọn trên máy chủ, lưu ở %ProgramData%\<dataDir>\config.json',
    'defaults.aspNetCoreRuntime: các kênh runtime cần có trên máy chủ (vd "3.1" hoặc "3.1,8.0"), công cụ tự tải Hosting Bundle của từng kênh'
)

#endregion

#region ---------- Mật khẩu ----------

function New-ToolPasswordHash([SecureString]$secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($pw.Length -lt 8) { throw 'Mật khẩu công cụ phải có ít nhất 8 ký tự.' }
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $iter = 200000
    $a = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, $iter, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $b = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, $iter)
    try {
        return @{ Salt = [Convert]::ToBase64String($salt); Iterations = $iter
            Sha256 = [Convert]::ToBase64String($a.GetBytes(32)); Sha1 = [Convert]::ToBase64String($b.GetBytes(32)) }
    }
    finally { $a.Dispose(); $b.Dispose() }
}

function Get-AuthHash([string]$text) {
    $get = { param($n) $m = [regex]::Match($text, "(?m)^\`$script:$n\s*=\s*'?([^'\r\n]*)'?"); if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null } }
    $h = @{ Salt = (& $get 'ToolPasswordSalt'); Iterations = (& $get 'ToolPasswordIterations'); Sha256 = (& $get 'ToolPasswordHashSha256'); Sha1 = (& $get 'ToolPasswordHashSha1') }
    if ($h.Salt -and $h.Sha256 -and $h.Sha1 -and $h.Iterations -match '^\d+$') { return $h }
    return $null
}

function Set-AuthHash([string]$text, $h) {
    foreach ($pair in @(@('ToolPasswordSalt', "'$($h.Salt)'"), @('ToolPasswordIterations', [string]$h.Iterations),
            @('ToolPasswordHashSha256', "'$($h.Sha256)'"), @('ToolPasswordHashSha1', "'$($h.Sha1)'"))) {
        $rx = New-Object System.Text.RegularExpressions.Regex("(?m)^(\`$script:$($pair[0])\s*=\s*)[^\r\n]+")
        if (-not $rx.IsMatch($text)) { throw "Không thấy `$script:$($pair[0]) trong lib\Auth.ps1" }
        $val = $pair[1]
        $text = $rx.Replace($text, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Groups[1].Value + $val }, 1)
    }
    return $text
}

#endregion

#region ---------- Quét ----------

Write-Title "API-DEPLOY: $ProjectName"
Write-Info "Mã nguồn : $RepoRoot"
Write-Info "Bộ cài   : $DeployPath"

$scans = New-Object System.Collections.Generic.List[object]
foreach ($p in (Get-ProjectFiles)) {
    $proj = Read-CsProj $p
    if ($proj.Sdk -notmatch '(?i)Microsoft\.NET\.Sdk\.Web') { continue }
    if ($Services -and -not (@($Services | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() }) -contains $proj.Name)) { continue }
    if (-not (Get-RuntimeChannel $proj.Tfm)) { Add-Warning "$($proj.Name): target framework '$($proj.Tfm)' không chạy bằng ASP.NET Core Module - bỏ qua"; continue }
    Write-Step "Quét $($proj.Name) ($($proj.Tfm))"
    $sc = Get-ServiceScan $proj
    $scans.Add($sc)
    Write-Info ("Mã hoá   : {0}{1}" -f $sc.Crypto.Scheme, $(if ($sc.Crypto.File) { " ($(Get-RelativePath $RepoRoot $sc.Crypto.File))" } else { '' }))
    Write-Info ("CSDL     : " + $(if ($sc.Connections.Count) { ($sc.Connections | ForEach-Object { "$($_.name) [$($_.type)]" }) -join ', ' } else { '(không có)' }))
    Write-Info ("Controller: " + $(if ($sc.Controllers.Count) { ($sc.Controllers | ForEach-Object { "$($_.name)($(@($_.actions).Count))" }) -join ', ' } else { '(không có)' }))
    Write-Info "Tham số  : $($sc.Settings.Count)$(if ($sc.Skipped.Count) { "  (bỏ section không thấy trong code: $($sc.Skipped -join ', '))" })"
    Write-Info "ApiSwitch: $(if ($sc.ApiSwitch) { 'có' } else { 'không' })   Health: /$($sc.HealthPath)"
    if ($sc.Crypto.Scheme -eq 'unknown') { Add-Warning "$($sc.Name): không nhận ra cách mã hoá trong Cryptography.cs - đọc code và sửa cryptoScheme/cryptoKey trong manifest" }
    if ($sc.Secrets.Count) { Add-Warning "$($sc.Name): appsettings.json trong mã nguồn đang có giá trị bí mật: $($sc.Secrets -join ', '). Build-Package sẽ xoá trắng trong gói (trừ khi -KeepSecrets)" }
    if ($sc.Note) { Add-Warning "$($sc.Name): $($sc.Note)" }
}
if ($scans.Count -eq 0) { throw 'Không tìm thấy project ASP.NET Core (Microsoft.NET.Sdk.Web) nào.' }
foreach ($sc in $scans) {
    if ($DeployPath.StartsWith($sc.Dir + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "DeployPath nằm trong project $($sc.Name) - bộ cài sẽ bị publish cùng service. Chọn thư mục khác." }
}

#endregion

#region ---------- Manifest ----------

$manifestFile = Join-Path $DeployPath 'deploy-manifest.json'
$existing = $null
if ((Test-Path $manifestFile) -and -not $Force) {
    $existing = ConvertTo-PlainData (Get-Content $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    Write-Step 'Chế độ CẬP NHẬT: đã có deploy-manifest.json'
}
else { Write-Step 'Chế độ TẠO MỚI' }

$safe = ConvertTo-SafeName $ProjectName
$computedPrefix = (ConvertTo-SafeName ($ProjectName -replace '^(?i)API[_\.\-]?', ''))
if (-not $computedPrefix) { $computedPrefix = $safe }
$computedPrefix = $computedPrefix.TrimEnd('_') + '_'
$channels = @($scans | ForEach-Object { $_.Runtime } | Select-Object -Unique)

$defaults = [ordered]@{}
if ($existing -and $existing['defaults']) { $defaults = $existing['defaults'] }
function Set-DefaultValue([string]$key, $value, [bool]$override = $false) {
    if ($override -or -not $defaults.Contains($key) -or [string]::IsNullOrEmpty([string]$defaults[$key])) { $defaults[$key] = $value }
}
# Manifest cũ (bộ HIS) không có dataDir/firewallPrefix/firewallGroup: giữ giá trị engine cũ đã dùng
# để không làm mất trạng thái / rule firewall của các máy chủ đã cài
$legacy = ($null -ne $existing)
Set-DefaultValue 'toolTitle' $ProjectName
Set-DefaultValue 'installRoot' $(if ($InstallRoot) { $InstallRoot } else { "C:\$safe" }) ([bool]$InstallRoot)
Set-DefaultValue 'sitePrefix' $(if ($SitePrefix) { $SitePrefix } else { $computedPrefix }) ([bool]$SitePrefix)
$rt = @(@(([string]$defaults['aspNetCoreRuntime']) -split '\s*,\s*') + $channels | Where-Object { $_ } | Select-Object -Unique)
$defaults['aspNetCoreRuntime'] = ($rt -join ',')
Set-DefaultValue 'dataDir' $(if ($legacy) { 'HIS.API.Deploy' } else { "$safe.Deploy" })
Set-DefaultValue 'firewallPrefix' $(if ($legacy) { 'HISAPI_' } else { [string]$defaults['sitePrefix'] })
Set-DefaultValue 'firewallGroup' $(if ($legacy) { 'HIS API' } else { $ProjectName })
Set-DefaultValue 'packageName' "$($safe)_Deploy"
if ((Split-Path $DeployPath -Parent) -ieq $RepoRoot) { if ($defaults.Contains('repoRoot')) { $defaults.Remove('repoRoot') } }
elseif ($DeployPath.StartsWith($RepoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { $defaults['repoRoot'] = (Get-RelativePath $DeployPath ($RepoRoot + '\')).TrimEnd('/') }
else { $defaults['repoRoot'] = $RepoRoot }

$svcList = New-Object System.Collections.Generic.List[object]
if ($existing -and $existing['services']) { foreach ($e in @($existing['services'])) { $svcList.Add($e) } }
$usedPorts = @($svcList | ForEach-Object { [int]$_['defaultPort'] })
$nextPort = [int][Math]::Max($StartPort, $(if ($usedPorts.Count) { [int]($usedPorts | Measure-Object -Maximum).Maximum + 1 } else { $StartPort }))
$changes = New-Object System.Collections.Generic.List[string]

foreach ($sc in $scans) {
    $e = Find-ByName $svcList $sc.Name
    if (-not $e) {
        while ($usedPorts -contains $nextPort) { $nextPort++ }
        $e = [ordered]@{
            name         = $sc.Name
            title        = $sc.Name
            project      = $sc.Project
            dll          = "$($sc.Name).dll"
            runtime      = $sc.Runtime
            defaultPort  = $nextPort
            apiSwitch    = [bool]$sc.ApiSwitch
            healthPath   = $sc.HealthPath
            cryptoScheme = $sc.Crypto.Scheme
            cryptoKey    = $sc.Crypto.Key
            connections  = $sc.Connections.ToArray()
            settings     = $sc.Settings.ToArray()
            controllers  = $sc.Controllers.ToArray()
        }
        if ($sc.Note) { $e.Insert(2, 'note', $sc.Note) }
        $usedPorts += $nextPort; $nextPort++
        $svcList.Add($e)
        $changes.Add("+ service $($sc.Name) (port $($e.defaultPort))")
        continue
    }

    # Service đã có: cập nhật thông tin lấy từ mã nguồn, bổ sung mục mới, giữ phần sửa tay
    foreach ($pair in @(@('project', $sc.Project), @('dll', "$($sc.Name).dll"), @('runtime', $sc.Runtime))) {
        if ([string]$e[$pair[0]] -ne [string]$pair[1]) { $changes.Add("~ $($sc.Name).$($pair[0]): '$($e[$pair[0]])' -> '$($pair[1])'"); $e[$pair[0]] = $pair[1] }
    }
    if ($sc.Crypto.Scheme -ne 'unknown') {
        $oldScheme = if ($e.Contains('cryptoScheme')) { [string]$e['cryptoScheme'] } else { 'aes256-zeroiv' }
        if ($oldScheme -ne $sc.Crypto.Scheme -or [string]$e['cryptoKey'] -cne $sc.Crypto.Key) {
            $changes.Add("~ $($sc.Name): mã hoá $oldScheme -> $($sc.Crypto.Scheme) (theo Cryptography.cs)")
        }
        $e['cryptoScheme'] = $sc.Crypto.Scheme; $e['cryptoKey'] = $sc.Crypto.Key
    }
    if (-not $e.Contains('apiSwitch') -or [bool]$e['apiSwitch'] -ne [bool]$sc.ApiSwitch) {
        if ($e.Contains('apiSwitch')) { $changes.Add("~ $($sc.Name).apiSwitch -> $([bool]$sc.ApiSwitch)") }
        $e['apiSwitch'] = [bool]$sc.ApiSwitch
    }
    if (-not $e.Contains('healthPath')) { $e['healthPath'] = $sc.HealthPath }
    if ($sc.Note -and -not $e.Contains('note')) { $e['note'] = $sc.Note }

    $conns = @($e['connections'] | Where-Object { $_ })
    foreach ($c in $sc.Connections) {
        if (-not (Find-ByName $conns $c.name)) { $conns += $c; $changes.Add("+ $($sc.Name): kết nối $($c.name)") }
    }
    foreach ($c in $conns) { if (-not (Find-ByName $sc.Connections $c['name'])) { Add-Warning "$($sc.Name): kết nối $($c['name']) trong manifest không còn trong appsettings.json (công cụ không tự xoá)" } }
    $e['connections'] = $conns

    $ctrls = @($e['controllers'] | Where-Object { $_ })
    $knownKeys = @{}
    foreach ($st in @($e['settings']) + @($ctrls | ForEach-Object { $_['settings'] })) { if ($st) { $knownKeys[([string]$st['key']).ToLowerInvariant()] = 1 } }
    $svcSettings = @($e['settings'] | Where-Object { $_ })
    foreach ($st in $sc.Settings) {
        if (-not $knownKeys.ContainsKey($st.key.ToLowerInvariant())) { $svcSettings += $st; $changes.Add("+ $($sc.Name): tham số $($st.key)") }
    }
    $scannedKeys = @($sc.Settings | ForEach-Object { $_.key.ToLowerInvariant() })
    foreach ($k in $knownKeys.Keys) { if ($scannedKeys -notcontains $k) { Add-Warning "$($sc.Name): tham số $k trong manifest không có trong appsettings.json của mã nguồn (công cụ không tự xoá)" } }
    $e['settings'] = $svcSettings

    foreach ($c in $sc.Controllers) {
        $ec = Find-ByName $ctrls $c.name
        if (-not $ec) { $ctrls += $c; $changes.Add("+ $($sc.Name): controller $($c.name)"); continue }
        $acts = @($ec['actions'] | Where-Object { $_ })
        foreach ($a in $c.actions) { if ($acts -notcontains $a) { $acts += $a; $changes.Add("+ $($sc.Name): action $($c.name).$a") } }
        foreach ($a in $acts) { if (@($c.actions) -notcontains $a) { Add-Warning "$($sc.Name): action $($c.name).$a không còn thấy trong mã nguồn" } }
        $ec['actions'] = $acts
    }
    foreach ($ec in $ctrls) { if (-not (Find-ByName $sc.Controllers $ec['name'])) { Add-Warning "$($sc.Name): controller $($ec['name']) không còn thấy trong mã nguồn" } }
    $e['controllers'] = $ctrls
}
foreach ($e in $svcList) {
    if (-not (Find-ByName $scans $e['name'])) { Add-Warning "Service $($e['name']) trong manifest không có trong solution (giữ nguyên, kiểm tra lại)" }
}

$manifest = [ordered]@{ _comment = $ManifestComment; defaults = $defaults; services = $svcList.ToArray() }
$manifestText = (Format-Json $manifest) + "`r`n"
[void]($manifestText | ConvertFrom-Json)   # kiểm tra cú pháp trước khi ghi

Write-Step 'Thay đổi manifest'
if ($changes.Count) { foreach ($c in $changes) { Write-Info $c } } else { Write-Info '(không có thay đổi từ mã nguồn)' }

#endregion

if ($ScanOnly) {
    Write-Step 'ScanOnly: không ghi file'
    Write-Host $manifestText
    return
}

#region ---------- Ghi bộ cài ----------

$stamp = '{0:yyyyMMdd_HHmmss}' -f (Get-Date)
$backupDir = Join-Path $DeployPath "_backup\$stamp"
$written = New-Object System.Collections.Generic.List[string]

function Write-DeployFile([string]$rel, [byte[]]$bytes) {
    $dst = Join-Path $DeployPath $rel
    if (Test-Path $dst) {
        $old = [System.IO.File]::ReadAllBytes($dst)
        if ([Convert]::ToBase64String($old) -ceq [Convert]::ToBase64String($bytes)) { $written.Add("= $rel"); return }
        $bk = Join-Path $backupDir $rel
        New-Item -ItemType Directory -Force (Split-Path $bk -Parent) | Out-Null
        Copy-Item $dst $bk -Force
        [System.IO.File]::WriteAllBytes($dst, $bytes)
        $written.Add("~ $rel (bản cũ: _backup\$stamp)")
        return
    }
    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
    [System.IO.File]::WriteAllBytes($dst, $bytes)
    $written.Add("+ $rel")
}

function Get-Utf8BomBytes([string]$text) { return [byte[]]($Utf8Bom.GetPreamble() + $Utf8Bom.GetBytes($text)) }

New-Item -ItemType Directory -Force $DeployPath | Out-Null
foreach ($rel in 'Deploy.bat', 'Build-Package.bat', 'Deploy.ps1', 'Build-Package.ps1', 'lib\JsonC.ps1', 'lib\Common.ps1', 'lib\Iis.ps1', 'lib\Prereq.ps1', 'prereq\README.txt') {
    Write-DeployFile $rel ([System.IO.File]::ReadAllBytes((Join-Path $Template $rel)))
}

# lib\Auth.ps1: engine mới + hash mật khẩu (mới / đang dùng / mặc định của template)
$authText = [System.IO.File]::ReadAllText((Join-Path $Template 'lib\Auth.ps1'))
$targetAuth = Join-Path $DeployPath 'lib\Auth.ps1'
if ($Password) { $authText = Set-AuthHash $authText (New-ToolPasswordHash $Password); Write-Ok 'Mật khẩu công cụ: đặt mới (chỉ lưu hash PBKDF2)' }
elseif (Test-Path $targetAuth) {
    $h = Get-AuthHash ([System.IO.File]::ReadAllText($targetAuth))
    if ($h) { $authText = Set-AuthHash $authText $h; Write-Ok 'Mật khẩu công cụ: giữ hash đang dùng trong bộ cài' }
    else { Add-Warning 'Không đọc được hash trong lib\Auth.ps1 đang có - dùng hash mặc định của template' }
}
else { Write-Ok 'Mật khẩu công cụ: hash mặc định của template' }
Write-DeployFile 'lib\Auth.ps1' (Get-Utf8BomBytes $authText)

Write-DeployFile 'deploy-manifest.json' (Get-Utf8BomBytes $manifestText)

# HUONG_DAN.md
$prefix = [string]$defaults['sitePrefix']
$rows = New-Object System.Collections.Generic.List[string]
$rows.Add('| Service | Mô tả | Port gợi ý | Site / App pool mặc định | CSDL | Mã hoá chuỗi kết nối | Chọn API |')
$rows.Add('|---|---|---|---|---|---|---|')
foreach ($e in $svcList) {
    $cs = (@($e['connections'] | Where-Object { $_ } | ForEach-Object { "$($_['name']) ($($_['type']))" }) -join ', ')
    if (-not $cs) { $cs = '-' }
    $rows.Add(('| `{0}` | {1} | {2} | `{3}{0}` | {4} | {5} | {6} |' -f $e['name'], $e['title'], $e['defaultPort'], $prefix, $cs, $e['cryptoScheme'], $(if ($false -eq $e['apiSwitch']) { 'không (chạy tất cả)' } else { 'ApiSwitch' })))
    if ($e['note']) { $Notes.Add("- ``$($e['name'])``: $($e['note'])") }
}
$guide = [System.IO.File]::ReadAllText((Join-Path $Template 'HUONG_DAN.template.md'))
$tokens = [ordered]@{
    '%%PROJECT%%'         = [string]$defaults['toolTitle']
    '%%DATA_DIR%%'        = [string]$defaults['dataDir']
    '%%RUNTIME%%'         = [string]$defaults['aspNetCoreRuntime']
    '%%SERVICE_TABLE%%'   = ($rows -join "`r`n")
    '%%FIREWALL_PREFIX%%' = [string]$defaults['firewallPrefix']
    '%%FIREWALL_GROUP%%'  = [string]$defaults['firewallGroup']
    '%%PACKAGE_NAME%%'    = [string]$defaults['packageName']
    '%%NOTES%%'           = $(if ($Notes.Count) { "Lưu ý theo service:`r`n`r`n" + ($Notes -join "`r`n") } else { '' })
}
foreach ($t in $tokens.Keys) { $guide = $guide.Replace($t, $tokens[$t]) }
Write-DeployFile 'HUONG_DAN.md' (Get-Utf8BomBytes ($guide -replace "\r?\n", "`r`n"))

Write-Step 'File bộ cài'
foreach ($w in $written) { Write-Info $w }

#endregion

Write-Step 'Tóm tắt'
foreach ($e in $svcList) {
    Write-Host ('   {0,-22} port {1,-6} site/pool {2,-32} mã hoá {3}' -f $e['name'], $e['defaultPort'], ($prefix + $e['name']), $e['cryptoScheme'])
}
if ($Warnings.Count) {
    Write-Step "Cần xem lại ($($Warnings.Count))"
    foreach ($w in $Warnings) { Write-Host "   - $w" -ForegroundColor DarkYellow }
}
if ($Zip) {
    Write-Step 'Build gói + nén zip'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DeployPath 'Build-Package.ps1') -All -Zip | Out-Host
    $buildCode = $LASTEXITCODE
    $zipFile = Get-ChildItem (Join-Path $DeployPath 'dist') -Filter '*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($buildCode -ne 0 -or -not $zipFile) { Write-Err 'Build / nén zip lỗi - xem log ở trên.'; exit 1 }
    Write-Ok ("File zip: {0} ({1:N1} MB)" -f $zipFile.FullName, ($zipFile.Length / 1MB))
}

Write-Step 'Bước tiếp theo'
Write-Info "1. Sửa title / note / required trong $manifestFile cho dễ hiểu với người triển khai."
Write-Info "2. Kiểm tra + build + nén zip: powershell -File `"$PSScriptRoot\Test-ApiDeploy.ps1`" -DeployPath `"$DeployPath`" -Build"
Write-Info "   (hoặc `"$DeployPath\Build-Package.bat`" -All -Zip). File zip nằm ở $DeployPath\dist\"
Write-Info "3. Máy chủ: giải nén zip, chạy Deploy.bat (mật khẩu công cụ, tự kiểm tra / cài môi trường)."
