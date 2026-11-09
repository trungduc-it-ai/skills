<#
.SYNOPSIS
    Công cụ triển khai API ASP.NET Core lên IIS: cài đặt / cập nhật file, cấu hình kết nối CSDL
    (mã hoá), port + IIS + firewall, chọn API chạy, tham số appsettings theo API đã chọn.
    Chạy lại bất cứ lúc nào để cập nhật cấu hình - giá trị hiện tại được giữ làm mặc định.

.PARAMETER Service
    Vào thẳng menu của 1 service (vd: -Service CanLamSang.Service)

.NOTES
    Chạy bằng Deploy.bat (tự xin quyền Administrator).
    Hỏi mật khẩu công cụ (cố định, xem lib\Auth.ps1) trước mọi bước.
    Lần đầu chạy trên máy chủ: chọn thư mục lưu API, kiểm tra / cài môi trường.
    Cấu hình, trạng thái, sao lưu, log: %ProgramData%\<defaults.dataDir trong deploy-manifest.json>
#>
param([string]$Service)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = $PSScriptRoot
. (Join-Path $Root 'lib\JsonC.ps1')
. (Join-Path $Root 'lib\Common.ps1')
. (Join-Path $Root 'lib\Iis.ps1')
. (Join-Path $Root 'lib\Prereq.ps1')
. (Join-Path $Root 'lib\Auth.ps1')
# Cửa sổ mở lại với quyền Administrator dùng font Lucida Console -> lỗi font tiếng Việt
Set-ConsoleUnicodeFont

#region ---------- Khởi động ----------

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Cần quyền Administrator - đang mở lại cửa sổ với quyền Administrator...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Service) { $argList += @('-Service', $Service) }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

$Manifest = Get-Content (Join-Path $Root 'deploy-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Defaults = $Manifest.defaults
# Kênh runtime cần có: defaults.aspNetCoreRuntime ("3.1" hoặc "3.1,8.0") + runtime riêng của từng service
$RuntimeChannels = ConvertTo-RuntimeChannels (@([string]$Defaults.aspNetCoreRuntime) + @($Manifest.services | ForEach-Object { [string]$_.runtime }))
$script:ToolTitle = if ($Defaults.toolTitle) { [string]$Defaults.toolTitle } else { 'HIS API' }
if ($Defaults.dataDir) { $script:DataDir = Join-Path $env:ProgramData ([string]$Defaults.dataDir) }
if ($Defaults.firewallPrefix) { $script:FirewallPrefix = [string]$Defaults.firewallPrefix }
if ($Defaults.firewallGroup) { $script:FirewallGroup = [string]$Defaults.firewallGroup }
Initialize-DeployLog (Join-Path $script:DataDir 'logs')
Protect-DataDir
Enable-Tls12
$State = Get-StateDoc
$Config = Get-ToolConfig
$script:InstallRoot = $Defaults.installRoot
$script:IisReady = Test-IisInstalled
$script:SiteCache = $null
Write-Log "===== Mở công cụ deploy trên $env:COMPUTERNAME"

# Thư mục chứa bộ cài môi trường: cạnh công cụ, không ghi được thì dùng %ProgramData%
function Get-PrereqDir {
    $d = Join-Path $script:Root 'prereq'
    try {
        New-Item -ItemType Directory -Force $d | Out-Null
        $probe = Join-Path $d '.write-test'
        Set-Content $probe '' -ErrorAction Stop; Remove-Item $probe -Force
        return $d
    }
    catch { return (Join-Path $script:DataDir 'prereq') }
}

# Luôn hỏi mật khẩu trước. Lần đầu trên máy chủ: chọn thư mục lưu API + kiểm tra môi trường
function Start-ToolSession {
    Clear-Host
    Write-Title "$($script:ToolTitle) - CÔNG CỤ TRIỂN KHAI   (máy chủ: $env:COMPUTERNAME)"
    if (-not (Invoke-ToolLogin)) { return $false }

    $apiRoot = Get-JsonCValue $Config 'installRoot'
    if (-not $apiRoot) {
        Write-Title "THIẾT LẬP BAN ĐẦU - máy chủ $env:COMPUTERNAME"
        Write-Info 'Công cụ chưa được thiết lập trên máy chủ này.'

        Write-Step '1/2 Thư mục lưu các API'
        Write-Info 'Mỗi service được cài vào 1 thư mục con, vd <thư mục>\CanLamSang.Service'
        $apiRoot = Read-InstallRoot ([string]$Defaults.installRoot)
        [void](Set-JsonCValue $Config 'installRoot' $apiRoot)
        Save-ToolConfig $Config
        $script:InstallRoot = $apiRoot
        Write-Log "Thư mục lưu API: $apiRoot"

        Write-Step '2/2 Môi trường máy chủ'
        [void](Show-Environment)
        Wait-Continue
    }
    $script:InstallRoot = $apiRoot
    return $true
}

#endregion

#region ---------- Ngữ cảnh service ----------

function Get-Sites {
    if ($null -eq $script:SiteCache) {
        $script:SiteCache = if ($script:IisReady) { Get-IisSites } else { New-Object System.Collections.Generic.List[object] }
        $script:SiteMap = if ($script:IisReady) { Get-IisSiteMap } else { @{} }
    }
    return , $script:SiteCache
}

function Reset-SiteCache { $script:SiteCache = $null; $script:SiteMap = $null }

function Get-SvcContext($def) {
    $name = $def.name
    $site = Get-ServiceState $State $name 'siteName'
    if (-not $site) { $site = $Defaults.sitePrefix + $name }
    $pool = Get-ServiceState $State $name 'appPool'
    if (-not $pool) { $pool = $site }
    $path = Get-ServiceState $State $name 'installPath'
    $port = Get-ServiceState $State $name 'port'

    $iisSite = $null
    foreach ($s in (Get-Sites)) { if ($s.Name -ieq $site) { $iisSite = $s } }
    if ($iisSite) {
        $info = $script:SiteMap[$iisSite.Name]
        if ($info -and $info.Path) { $path = $info.Path }
        if ($info -and $info.Pool) { $pool = $info.Pool }
        if ($iisSite.Ports.Count -gt 0 -and -not ($port -and $iisSite.Ports -contains [int]$port)) { $port = $iisSite.Ports[0] }
    }
    if (-not $path) { $path = Join-Path $script:InstallRoot $name }
    if (-not $port) { $port = $def.defaultPort }
    $path = $path.TrimEnd('\')

    return @{
        Def          = $def
        Name         = $name
        Site         = $site
        Pool         = $pool
        Path         = $path
        Port         = [int]$port
        IisSite      = $iisSite
        SettingsFile = (Join-Path $path 'appsettings.json')
        Package      = (Join-Path $script:Root "packages\$name")
        Doc          = $null
        Dirty        = $false
        Changes      = (New-Object System.Collections.Generic.List[string])
    }
}

function Test-Installed($ctx) { return (Test-Path $ctx.SettingsFile) }

# Mã hoá / giải mã đúng cách Cryptography.cs của service (cryptoScheme + cryptoKey trong manifest)
function Get-CryptoScheme($def) { if ($def.cryptoScheme) { return [string]$def.cryptoScheme } return 'aes256-zeroiv' }
function Protect-SvcString($def, [string]$plainText) { return (Protect-HisString $plainText ([string]$def.cryptoKey) (Get-CryptoScheme $def)) }
function Unprotect-SvcString($def, [string]$cipherText) { return (Unprotect-HisString $cipherText ([string]$def.cryptoKey) (Get-CryptoScheme $def)) }

# Service có ApiSwitchFilter (bật/tắt từng controller / API)? Manifest ghi "apiSwitch": false nếu không có
function Test-ApiSwitch($def) { return -not ($false -eq $def.apiSwitch) }

function Open-SettingsDoc($ctx) {
    if ($null -eq $ctx.Doc) {
        if (-not (Test-Installed $ctx)) { throw "Chưa có $($ctx.SettingsFile). Chọn 1 (Triển khai đầy đủ) hoặc 2 (Cập nhật file) trước." }
        $ctx.Doc = Read-JsonCFile $ctx.SettingsFile
    }
    return $ctx.Doc
}

# Ghi 1 giá trị vào appsettings (trong bộ nhớ) + ghi nhận để hiển thị trước khi lưu
function Set-CtxValue($ctx, [string]$key, $value, [string]$display = $null, [switch]$Secret) {
    $doc = Open-SettingsDoc $ctx
    $v = $value
    if (Test-JsonCPath $doc $key) {
        # Đã có key -> truyền chuỗi để giữ đúng kiểu JSON đang dùng trong file
        if ($value -is [bool]) { $v = $value.ToString().ToLowerInvariant() } else { $v = [string]$value }
    }
    if (Set-JsonCValue $doc $key $v) {
        $ctx.Dirty = $true
        # [string] tham số nhận $null thành '' -> kiểm tra rỗng
        if ([string]::IsNullOrEmpty($display)) { $display = if ($Secret) { Format-Secret ([string]$value) } else { [string]$value } }
        if ($display -eq '') { $display = '(trống)' }
        $ctx.Changes.Add("$key = $display")
    }
}

function Remove-CtxValue($ctx, [string]$key) {
    $doc = Open-SettingsDoc $ctx
    if (Remove-JsonCValue $doc $key) {
        $ctx.Dirty = $true
        $ctx.Changes.Add("$key (xoá)")
    }
}

function Get-PackageInfo([string]$dir) {
    $f = Join-Path $dir '.package-info.json'
    if (-not (Test-Path $f)) { return $null }
    try { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Format-PackageInfo($info) {
    if (-not $info) { return 'không rõ phiên bản' }
    return "v$($info.version), build $($info.builtAt)"
}

# Trạng thái bật/tắt API đọc từ appsettings
function Get-ApiSwitchState($ctx) {
    $doc = Open-SettingsDoc $ctx
    $dv = Get-JsonCValue $doc 'ApiSwitch:Default'
    $default = ($null -eq $dv -or $dv -eq 'true')
    $ctrl = @{}; $ovr = @{}
    foreach ($c in $ctx.Def.controllers) {
        $v = Get-JsonCValue $doc "ApiSwitch:Controllers:$($c.name)"
        $ctrl[$c.name] = if ($null -eq $v) { $default } else { $v -eq 'true' }
        foreach ($a in $c.actions) {
            $v = Get-JsonCValue $doc "ApiSwitch:Actions:$($c.name).$a"
            if ($null -ne $v) { $ovr["$($c.name).$a"] = ($v -eq 'true') }
        }
    }
    return @{ Default = $default; Controllers = $ctrl; Overrides = $ovr }
}

function Get-EnabledActionCount($c, $sw) {
    $n = 0
    foreach ($a in $c.actions) {
        $k = "$($c.name).$a"
        $on = if ($sw.Overrides.ContainsKey($k)) { $sw.Overrides[$k] } else { $sw.Controllers[$c.name] }
        if ($on) { $n++ }
    }
    return $n
}

# Controller có ít nhất 1 API đang chạy
function Get-EnabledControllers($ctx) {
    if (-not (Test-ApiSwitch $ctx.Def)) { return , @($ctx.Def.controllers) }
    $sw = Get-ApiSwitchState $ctx
    return , @($ctx.Def.controllers | Where-Object { (Get-EnabledActionCount $_ $sw) -gt 0 -or ($sw.Controllers[$_.name] -and @($_.actions).Count -eq 0) })
}

#endregion

#region ---------- Bước: file chương trình ----------

function Invoke-UpdateFiles($ctx) {
    Write-Step "File chương trình"
    $installed = Test-Installed $ctx
    if (-not (Test-Path (Join-Path $ctx.Package $ctx.Def.dll))) {
        if ($installed) { Write-Info "Không có gói packages\$($ctx.Name) - giữ nguyên file đang chạy."; return $true }
        Write-Err "Không tìm thấy gói packages\$($ctx.Name)\$($ctx.Def.dll)."
        Write-Info 'Chạy Build-Package.bat trên máy build, copy cả thư mục Deploy sang máy chủ rồi chạy lại.'
        return $false
    }

    $pkg = Get-PackageInfo $ctx.Package
    Write-Info "Gói cài đặt : $(Format-PackageInfo $pkg)"
    if ($installed) {
        Write-Info "Đang chạy   : $(Format-PackageInfo (Get-PackageInfo $ctx.Path))"
        if (-not (Read-YesNo 'Cập nhật file chương trình từ gói?' $true)) { return $true }
        $bk = Backup-AppFolder $ctx.Name $ctx.Path
        if ($bk) { Write-Ok "Sao lưu bản đang chạy: $bk" }
    }

    $pool = if ($script:IisReady -and (Get-IisPoolState $ctx.Pool)) { $ctx.Pool } else { $null }
    Copy-AppPackage $ctx.Package $ctx.Path $pool
    Write-Ok "Copy file vào $($ctx.Path)"

    $pkgSettings = Join-Path $ctx.Package 'appsettings.json'
    if (-not (Test-Path $ctx.SettingsFile)) {
        Copy-Item $pkgSettings $ctx.SettingsFile
        Write-Ok 'Tạo appsettings.json từ gói (sẽ cấu hình ở các bước sau)'
    }
    elseif (Test-Path $pkgSettings) {
        # Bản mới có thêm tham số -> bổ sung, không ghi đè giá trị đang dùng
        $doc = Read-JsonCFile $ctx.SettingsFile
        $added = Merge-JsonCMissing $doc (Read-JsonCFile $pkgSettings)
        if ($added.Count -gt 0) {
            [void](Backup-AppSettings $ctx.Name $ctx.SettingsFile)
            Save-JsonCFile $doc
            Write-Ok "Bổ sung $($added.Count) tham số mới từ gói: $($added -join ', ')"
            Write-Warn 'Kiểm tra lại giá trị các tham số mới ở bước "Tham số appsettings".'
        }
        else { Write-Info 'appsettings.json đang dùng được giữ nguyên.' }
    }
    $ctx.Doc = $null

    Set-ServiceState $State $ctx.Name 'installPath' $ctx.Path
    if ($pkg) { Set-ServiceState $State $ctx.Name 'version' ([string]$pkg.version) }
    Set-ServiceState $State $ctx.Name 'filesUpdatedAt' ('{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))
    Save-StateDoc $State
    Write-Log "$($ctx.Name): cập nhật file $(Format-PackageInfo $pkg)"
    return $true
}

#endregion

#region ---------- Bước: kết nối CSDL ----------

function Edit-Connections($ctx) {
    $doc = Open-SettingsDoc $ctx
    foreach ($conn in $ctx.Def.connections) {
        $type = if ($conn.type -eq 'oracle') { 'Oracle' } else { 'SQL Server' }
        Write-Step "Kết nối CSDL: $($conn.name) - $($conn.title) [$type]"
        $path = "ConnectionStrings:$($conn.name)"
        $cipher = Get-JsonCValue $doc $path
        $plain = Unprotect-SvcString $ctx.Def $cipher
        if ($cipher -and -not $plain) { Write-Warn 'Không giải mã được chuỗi kết nối hiện tại (sai khoá hoặc chưa mã hoá) - cần nhập lại.' }

        if ($conn.type -eq 'oracle') { $cs = Read-OracleConnection $plain }
        else { $cs = Read-SqlConnection $plain }

        if ($cs) { Set-CtxValue $ctx $path (Protect-SvcString $ctx.Def $cs) (Format-ConnectionDisplay $conn.type $cs (Get-CryptoScheme $ctx.Def)) }
    }
}

function Format-ConnectionDisplay([string]$type, [string]$cs, [string]$scheme = '') {
    $tag = if ($scheme -eq 'none') { '(không mã hoá)' } else { '(mã hoá)' }
    if ($type -eq 'oracle') {
        $i = ConvertFrom-OracleConnectionString $cs
        return "$tag $($i.Host):$($i.Port)/$($i.ServiceType)=$($i.ServiceName) | User=$($i.User)"
    }
    $i = ConvertFrom-SqlConnectionString $cs
    return "$tag Server=$($i.Server) | Database=$($i.Database) | User=$($i.User)"
}

# Trả về chuỗi kết nối mới (chưa mã hoá), $null = không đổi
function Read-SqlConnection([string]$current) {
    $info = ConvertFrom-SqlConnectionString $current
    if ($current) {
        Write-Info "Hiện tại: Server=$($info.Server) | Database=$($info.Database) | User=$($info.User) | Password=$(Format-Secret $info.Password)"
        if (-not (Read-YesNo 'Thay đổi kết nối này?' $false)) { return $null }
    }
    while ($true) {
        $info.Server = Read-Value 'Server (IP | IP\Instance | IP,Port)' $info.Server -Required
        $info.Database = Read-Value 'Database' $info.Database -Required
        $info.User = Read-Value 'User SQL' $info.User -Required
        $prompt = if ($info.Password) { 'Mật khẩu (Enter = giữ mật khẩu cũ)' } else { 'Mật khẩu' }
        $pw = Read-Secret $prompt
        if ($pw) { $info.Password = $pw }
        elseif (-not $info.Password) { Write-Warn 'Chưa nhập mật khẩu.'; continue }

        $cs = New-SqlConnectionString $info
        Write-Info 'Đang kiểm tra kết nối...'
        $t = Test-SqlConnection $cs
        if ($t.Ok) { Write-Ok "Kết nối thành công: $($t.Message)"; return $cs }
        Write-Err "Kết nối thất bại: $($t.Message)"
        $c = Read-Value '(L) Nhập lại  (S) Vẫn lưu  (B) Bỏ qua, không đổi' 'L'
        if ($c -match '^(?i)s') { return $cs }
        if ($c -match '^(?i)b') { return $null }
    }
}

function Read-OracleConnection([string]$current) {
    $info = ConvertFrom-OracleConnectionString $current
    if ($current) {
        Write-Info "Hiện tại: $($info.Host):$($info.Port) $($info.ServiceType)=$($info.ServiceName) | User=$($info.User) | Password=$(Format-Secret $info.Password)"
        if (-not (Read-YesNo 'Thay đổi kết nối này?' $false)) { return $null }
    }
    while ($true) {
        $info.Host = Read-Value 'Host / IP máy chủ Oracle' $info.Host -Required
        $info.Port = Read-Value 'Port' $info.Port -Required -Validate { if ($args[0] -notmatch '^\d{1,5}$') { 'Port phải là số' } }
        $t = if ($info.ServiceType -eq 'SID') { '2' } else { '1' }
        $t = Read-Value 'Kiểu: (1) SERVICE_NAME  (2) SID' $t -Validate { if ($args[0] -notmatch '^[12]$') { 'Chọn 1 hoặc 2' } }
        $info.ServiceType = if ($t -eq '2') { 'SID' } else { 'SERVICE_NAME' }
        $info.ServiceName = Read-Value $info.ServiceType $info.ServiceName -Required
        $info.User = Read-Value 'User Oracle' $info.User -Required
        $prompt = if ($info.Password) { 'Mật khẩu (Enter = giữ mật khẩu cũ)' } else { 'Mật khẩu' }
        $pw = Read-Secret $prompt
        if ($pw) {
            # Không đăng nhập thử được Oracle (máy chủ thường không có Oracle client) -> nhập lại để chắc chắn
            if ((Read-Secret 'Nhập lại mật khẩu') -cne $pw) { Write-Warn 'Hai lần nhập mật khẩu không khớp.'; continue }
            if ($pw.Contains('"')) { Write-Warn 'Mật khẩu Oracle không được chứa dấu ".'; continue }
            $info.Password = $pw
        }
        elseif (-not $info.Password) { Write-Warn 'Chưa nhập mật khẩu.'; continue }

        $cs = New-OracleConnectionString $info
        Write-Info "Đang kiểm tra cổng TCP $($info.Host):$($info.Port) (không kiểm tra đăng nhập)..."
        if (Test-TcpPort $info.Host ([int]$info.Port)) { Write-Ok 'Kết nối được tới cổng Oracle'; return $cs }
        Write-Err "Không kết nối được tới $($info.Host):$($info.Port)"
        $c = Read-Value '(L) Nhập lại  (S) Vẫn lưu  (B) Bỏ qua, không đổi' 'L'
        if ($c -match '^(?i)s') { return $cs }
        if ($c -match '^(?i)b') { return $null }
    }
}

#endregion

#region ---------- Bước: chọn API ----------

function Edit-ApiSwitch($ctx) {
    $sw = Get-ApiSwitchState $ctx
    $ctrls = @($ctx.Def.controllers)
    $default = $sw.Default
    $ctrlState = $sw.Controllers
    $ovr = $sw.Overrides

    while ($true) {
        Write-Step "Chọn API chạy - $($ctx.Name)"
        Write-Host ('   {0,-4}{1,-6}{2,-18}{3,-9}{4}' -f '#', 'Bật', 'Controller', 'API bật', 'Mô tả') -ForegroundColor DarkGray
        for ($i = 0; $i -lt $ctrls.Count; $i++) {
            $c = $ctrls[$i]
            $on = $ctrlState[$c.name]
            $cnt = Get-EnabledActionCount $c (@{ Controllers = $ctrlState; Overrides = $ovr })
            $total = @($c.actions).Count
            $mark = if ($on) { '[x]' } else { '[ ]' }
            $color = if ($cnt -gt 0) { 'White' } else { 'DarkGray' }
            $extra = if (($on -and $cnt -lt $total) -or (-not $on -and $cnt -gt 0)) { ' *riêng' } else { '' }
            Write-Host ('   {0,-4}{1,-6}{2,-18}{3,-9}{4}{5}' -f ($i + 1), $mark, $c.name, "$cnt/$total", $c.title, $extra) -ForegroundColor $color
            if ($c.note) { Write-Host "                                     ! $($c.note)" -ForegroundColor DarkYellow }
        }
        Write-Host "   Controller không có trong danh sách: Default = $($default.ToString().ToLower())" -ForegroundColor DarkGray
        Write-Host '   Nhập số để bật/tắt (vd 1,3,5-7) | A = bật hết | N = tắt hết | C<số> = chọn từng API (vd C2)' -ForegroundColor Gray
        Write-Host '   D = đổi Default | Enter = xong' -ForegroundColor Gray
        $in = (Read-Host '   Chọn').Trim()
        if ($in -eq '') { break }

        if ($in -match '^(?i)a$' -or $in -match '^(?i)n$') {
            $v = ($in -match '^(?i)a$')
            foreach ($c in $ctrls) { $ctrlState[$c.name] = $v; Clear-ActionOverrides $c $ovr }
            continue
        }
        if ($in -match '^(?i)d$') { $default = -not $default; continue }
        if ($in -match '^(?i)c\s*(\d+)$') {
            $idx = [int]$Matches[1]
            if ($idx -ge 1 -and $idx -le $ctrls.Count) { Edit-Actions $ctrls[$idx - 1] $ctrlState $ovr }
            else { Write-Warn 'Số không hợp lệ.' }
            continue
        }
        $nums = ConvertFrom-NumberList $in $ctrls.Count
        if ($null -eq $nums -or $nums.Count -eq 0) { Write-Warn 'Lựa chọn không hợp lệ.'; continue }
        foreach ($n in $nums) {
            $c = $ctrls[$n - 1]
            $ctrlState[$c.name] = -not $ctrlState[$c.name]
            # Đổi cả controller thì các API theo controller, bỏ cấu hình riêng
            Clear-ActionOverrides $c $ovr
        }
    }

    Set-CtxValue $ctx 'ApiSwitch:Default' $default
    foreach ($c in $ctrls) {
        Set-CtxValue $ctx "ApiSwitch:Controllers:$($c.name)" ([bool]$ctrlState[$c.name])
        foreach ($a in $c.actions) {
            $k = "$($c.name).$a"
            if ($ovr.ContainsKey($k)) { Set-CtxValue $ctx "ApiSwitch:Actions:$k" ([bool]$ovr[$k]) }
            elseif (Test-JsonCPath $ctx.Doc "ApiSwitch:Actions:$k") { Remove-CtxValue $ctx "ApiSwitch:Actions:$k" }
        }
    }
    $on = @($ctrls | Where-Object { $ctrlState[$_.name] } | ForEach-Object { $_.name })
    Write-Ok ("Controller bật: " + $(if ($on.Count) { $on -join ', ' } else { '(không có)' }))
}

function Clear-ActionOverrides($c, $ovr) {
    foreach ($a in $c.actions) { [void]$ovr.Remove("$($c.name).$a") }
}

function Edit-Actions($c, $ctrlState, $ovr) {
    $acts = @($c.actions)
    while ($true) {
        $ctrlOn = [bool]$ctrlState[$c.name]
        Write-Host ''
        Write-Host "   API của $($c.name) - controller đang $(if ($ctrlOn) { 'BẬT' } else { 'TẮT' })" -ForegroundColor Cyan
        for ($j = 0; $j -lt $acts.Count; $j++) {
            $k = "$($c.name).$($acts[$j])"
            $isOvr = $ovr.ContainsKey($k)
            $on = if ($isOvr) { $ovr[$k] } else { $ctrlOn }
            $mark = if ($on) { '[x]' } else { '[ ]' }
            $tag = if ($isOvr) { '  (riêng)' } else { '' }
            Write-Host ('     {0,-4}{1,-5}{2}{3}' -f ($j + 1), $mark, $acts[$j], $tag) -ForegroundColor $(if ($on) { 'White' } else { 'DarkGray' })
        }
        Write-Host '     Số = bật/tắt | A = bật hết | N = tắt hết | R = bỏ cấu hình riêng | Enter = quay lại' -ForegroundColor Gray
        $in = (Read-Host '     Chọn').Trim()
        if ($in -eq '') { return }
        if ($in -match '^(?i)r$') { Clear-ActionOverrides $c $ovr; continue }
        if ($in -match '^(?i)[an]$') {
            $v = ($in -match '^(?i)a$')
            foreach ($a in $acts) {
                $k = "$($c.name).$a"
                if ($v -eq $ctrlOn) { [void]$ovr.Remove($k) } else { $ovr[$k] = $v }
            }
            continue
        }
        $nums = ConvertFrom-NumberList $in $acts.Count
        if ($null -eq $nums -or $nums.Count -eq 0) { Write-Warn 'Lựa chọn không hợp lệ.'; continue }
        foreach ($n in $nums) {
            $k = "$($c.name).$($acts[$n - 1])"
            $cur = if ($ovr.ContainsKey($k)) { $ovr[$k] } else { $ctrlOn }
            $new = -not $cur
            if ($new -eq $ctrlOn) { [void]$ovr.Remove($k) } else { $ovr[$k] = $new }
        }
    }
}

#endregion

#region ---------- Bước: tham số appsettings ----------

function Get-RequiredSettings($ctx) {
    $list = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($s in @($ctx.Def.settings)) {
        if (-not $list.Contains($s.key)) { $list[$s.key] = @{ Setting = $s; UsedBy = (New-Object System.Collections.Generic.List[string]) } }
        $list[$s.key].UsedBy.Add('chung')
    }
    foreach ($c in (Get-EnabledControllers $ctx)) {
        foreach ($s in @($c.settings)) {
            if (-not $list.Contains($s.key)) { $list[$s.key] = @{ Setting = $s; UsedBy = (New-Object System.Collections.Generic.List[string]) } }
            $list[$s.key].UsedBy.Add($c.name)
        }
    }
    return $list
}

function Edit-Settings($ctx) {
    $doc = Open-SettingsDoc $ctx
    $list = Get-RequiredSettings $ctx
    Write-Step "Tham số appsettings theo API đang bật - $($ctx.Name)"
    if ($list.Count -eq 0) { Write-Info 'Các API đang bật không cần tham số nào.'; return }

    $items = @($list.Values)
    $advCount = @($items | Where-Object { $_.Setting.advanced }).Count
    $showAdv = $false
    if ($advCount -gt 0) { $showAdv = Read-YesNo "Cấu hình cả $advCount tham số nâng cao?" $false }
    if (-not $showAdv) { $items = @($items | Where-Object { -not $_.Setting.advanced }) }

    $missing = @($items | Where-Object { [string]::IsNullOrEmpty((Get-JsonCValue $doc $_.Setting.key)) }).Count
    Write-Info "Có $($items.Count) tham số, $missing tham số chưa có giá trị. Enter = giữ nguyên, '-' = xoá trắng."
    $onlyMissing = $false
    if ($missing -gt 0 -and $missing -lt $items.Count) {
        $onlyMissing = (Read-Value 'Duyệt (1) tất cả  (2) chỉ tham số còn trống' '1' -Validate { if ($args[0] -notmatch '^[12]$') { 'Chọn 1 hoặc 2' } }) -eq '2'
    }
    elseif ($missing -eq 0 -and $items.Count -gt 0) {
        if (-not (Read-YesNo 'Tất cả tham số đã có giá trị. Duyệt lại để sửa?' $true)) { return }
    }

    $lastSection = ''
    foreach ($it in $items) {
        $s = $it.Setting
        if ($onlyMissing -and -not [string]::IsNullOrEmpty((Get-JsonCValue $doc $s.key))) { continue }
        $section = ($s.key -split ':')[0]
        if ($section -ne $lastSection) {
            Write-Host ''
            Write-Host "   [$section]  dùng bởi: $(($it.UsedBy | Select-Object -Unique) -join ', ')" -ForegroundColor Cyan
            $lastSection = $section
        }
        Edit-OneSetting $ctx $s
    }
}

function Edit-OneSetting($ctx, $s) {
    $doc = $ctx.Doc
    $key = $s.key
    $type = if ($s.type) { $s.type } else { 'string' }
    $exists = Test-JsonCPath $doc $key
    $cur = Get-JsonCValue $doc $key
    if ($null -eq $cur) { $cur = '' }
    $proposed = if ($exists) { $cur } elseif ($s.default) { [string]$s.default } else { '' }
    $req = [bool]$s.required

    Write-Host "   $key" -ForegroundColor White -NoNewline
    Write-Host "  - $($s.title)$(if ($req) { ' (bắt buộc)' })" -ForegroundColor Gray
    if ($s.note) { Write-Info $s.note }

    switch ($type) {
        'bool' {
            $v = Read-Value '  true/false' $(if ($proposed) { $proposed } else { 'false' }) -Validate { if ($args[0] -notmatch '^(?i)(true|false|y|n|1|0)$') { 'Nhập true hoặc false' } }
            $b = ($v -match '^(?i)(true|y|1)$')
            if (-not $exists -or $cur -ne $b.ToString().ToLower()) { Set-CtxValue $ctx $key $b }
        }
        'int' {
            $v = Read-Value '  Giá trị (số)' $proposed -Required:$req -Validate { if ($args[0] -notmatch '^-?\d+$') { 'Phải là số nguyên' } }
            if ($v -ne '' -and (-not $exists -or $v -ne $cur)) { Set-CtxValue $ctx $key ([int]$v) }
        }
        { $_ -in 'secret', 'encrypted' } {
            $plainCur = $cur
            if ($type -eq 'encrypted' -and $cur) {
                $plainCur = Unprotect-SvcString $ctx.Def $cur
                if ($null -eq $plainCur) { Write-Warn 'Giá trị hiện tại chưa mã hoá hoặc sai khoá - nên nhập lại.'; $plainCur = '' }
            }
            Write-Info "Hiện tại: $(Format-Secret $plainCur)"
            while ($true) {
                $v = Read-Secret '  Giá trị mới (Enter = giữ nguyên)'
                if (-not $v) {
                    if ($req -and -not $plainCur) { Write-Warn 'Giá trị bắt buộc.'; continue }
                    break
                }
                if ((Read-Secret '  Nhập lại để xác nhận') -cne $v) { Write-Warn 'Hai lần nhập không khớp.'; continue }
                if ($type -eq 'encrypted') { Set-CtxValue $ctx $key (Protect-SvcString $ctx.Def $v) '(đã mã hoá)' }
                else { Set-CtxValue $ctx $key $v -Secret }
                break
            }
        }
        'token' {
            $gen = if ($s.generate) { [string]$s.generate } else { 'hex32' }
            $v = Read-Value '  Giá trị (G = sinh ngẫu nhiên)' $proposed -Required:$req
            if ($v -match '^(?i)g$') {
                $v = New-RandomToken $gen
                Write-Ok "Giá trị mới: $v"
                Write-Info 'Gửi giá trị này cho bên gọi API (đối tác) nếu cần.'
            }
            if ($v -ne '' -and (-not $exists -or $v -cne $cur)) { Set-CtxValue $ctx $key $v }
        }
        default {
            $validate = $null
            if ($type -eq 'url') { $validate = { if ($args[0] -notmatch '^(?i)https?://\S+$') { 'URL phải bắt đầu bằng http:// hoặc https://' } } }
            $v = Read-Value '  Giá trị' $proposed -Required:$req -AllowClear -Validate $validate
            if ($type -eq 'path' -and $v -and -not (Test-Path $v)) { Write-Warn "Đường dẫn '$v' chưa tồn tại trên máy này." }
            if ((-not $exists -and $v -ne '') -or ($exists -and $v -cne $cur)) { Set-CtxValue $ctx $key $v }
        }
    }
}

#endregion

#region ---------- Lưu / khởi động lại ----------

function Save-Settings($ctx) {
    if (-not $ctx.Dirty) { Write-Info 'Không có thay đổi appsettings.'; return $false }
    Write-Step 'Các thay đổi sẽ lưu vào appsettings.json'
    foreach ($c in $ctx.Changes) { Write-Info "- $c" }
    if (-not (Read-YesNo 'Lưu các thay đổi trên?' $true)) {
        $ctx.Doc = $null; $ctx.Dirty = $false; $ctx.Changes.Clear()
        Write-Warn 'Đã huỷ, không lưu thay đổi.'
        return $false
    }
    $bk = Backup-AppSettings $ctx.Name $ctx.SettingsFile
    Save-JsonCFile $ctx.Doc
    Write-Ok "Đã lưu $($ctx.SettingsFile)"
    if ($bk) { Write-Info "Bản sao lưu: $bk" }
    foreach ($c in $ctx.Changes) { Write-Log "$($ctx.Name): $c" }
    $ctx.Dirty = $false; $ctx.Changes.Clear()
    Set-ServiceState $State $ctx.Name 'configUpdatedAt' ('{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))
    Save-StateDoc $State
    return $true
}

function Get-HealthPath($ctx) {
    # healthPath khai báo trong manifest được ưu tiên ("" = gọi trang gốc)
    if ($ctx.Def.PSObject.Properties['healthPath']) { return [string]$ctx.Def.healthPath }
    if (-not (Test-Installed $ctx)) { return '' }
    $doc = Open-SettingsDoc $ctx
    if ((Get-JsonCValue $doc 'Swagger:Enabled') -eq 'false') { return '' }
    return 'swagger/index.html'
}

function Restart-AndCheck($ctx, [switch]$NoRestart) {
    if (-not $script:IisReady -or -not (Get-IisPoolState $ctx.Pool)) { Write-Warn 'Service chưa có site IIS - chọn bước "Port, IIS, Firewall".'; return }
    if (-not $NoRestart) {
        if (Restart-IisPool $ctx.Pool) { Write-Ok "Khởi động lại app pool $($ctx.Pool)" }
        else { Write-Err "Không khởi động lại được app pool $($ctx.Pool)" }
    }
    $url = "http://localhost:$($ctx.Port)/$(Get-HealthPath $ctx)"
    Write-Info "Kiểm tra $url ..."
    $r = Test-HttpUrl $url 60
    if ($r.Status -ge 200 -and $r.Status -lt 500) {
        Write-Ok "API đang chạy (HTTP $($r.Status))"
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | ForEach-Object { $_.IPAddress })
        foreach ($ip in $ips) { Write-Info "Địa chỉ: http://${ip}:$($ctx.Port)/$(Get-HealthPath $ctx)" }
        Write-Log "$($ctx.Name): health OK HTTP $($r.Status)"
        return
    }
    if ($r.Status -eq 0) { Write-Err "Không kết nối được: $($r.Message)" }
    else {
        Write-Err "Ứng dụng lỗi (HTTP $($r.Status) $($r.Message))"
        Write-Info 'HTTP 500.30/500.31: thiếu .NET runtime hoặc lỗi khi khởi động (sai chuỗi kết nối, sai appsettings...).'
        Write-Info 'HTTP 503: app pool đang dừng / lỗi liên tục. Xem thêm Event Viewer > Windows Logs > Application.'
    }
    if (Read-YesNo 'Bật log khởi động (stdout) để xem lỗi chi tiết?' $true) { Show-StartupLog $ctx }
}

function Show-StartupLog($ctx) {
    if (-not (Set-StdoutLog $ctx.Path $true)) { Write-Err 'Không sửa được web.config'; return }
    $logDir = Join-Path $ctx.Path 'logs'
    $since = Get-Date
    [void](Restart-IisPool $ctx.Pool)
    [void](Test-HttpUrl "http://localhost:$($ctx.Port)/" 60)
    Start-Sleep -Seconds 2
    $f = Get-ChildItem $logDir -Filter 'stdout*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since.AddSeconds(-5) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) {
        Write-Step "Log khởi động: $($f.FullName)"
        Get-Content $f.FullName -Tail 40 -Encoding UTF8 | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
    }
    else { Write-Warn "Không thấy file log mới trong $logDir (có thể app không khởi chạy được tiến trình - kiểm tra .NET runtime)." }
    [void](Set-StdoutLog $ctx.Path $false)
    Write-Info 'Đã tắt lại log stdout.'
}

#endregion

#region ---------- Bước: port, IIS, firewall ----------

function Set-Hosting($ctx) {
    if (-not (Confirm-Prerequisites)) { Write-Err 'Máy chưa cài IIS - không tạo được site. Về menu chính chọn K để cài.'; return $false }
    if (-not (Test-AncmInstalled)) { Write-Warn 'Chưa có ASP.NET Core Module (Hosting Bundle) - site sẽ không chạy được. Xem menu K.' }

    Write-Step "Port và IIS - $($ctx.Name)"
    $oldPort = if ($ctx.IisSite) { $ctx.Port } else { 0 }
    while ($true) {
        $p = Read-Value 'Port API' ([string]$ctx.Port) -Required -Validate { if ($args[0] -notmatch '^\d{1,5}$' -or [int]$args[0] -lt 1 -or [int]$args[0] -gt 65535) { 'Port từ 1 đến 65535' } }
        $conflict = Get-PortConflict ([int]$p) $ctx.Site
        if (-not $conflict) { break }
        Write-Err "Port $p đang bị dùng: $conflict"
        if (-not (Read-YesNo 'Chọn port khác?' $true)) { break }
    }
    $ctx.Port = [int]$p
    if (-not $ctx.IisSite) {
        $ctx.Site = Read-Value 'Tên site IIS' $ctx.Site -Required
        $ctx.Pool = Read-Value 'Tên app pool' $ctx.Site -Required
    }

    Set-IisAppPool $ctx.Pool
    Set-IisSite $ctx.Site $ctx.Path $ctx.Port $ctx.Pool $oldPort
    Grant-PoolAccess $ctx.Path $ctx.Pool
    Reset-SiteCache
    $ctx.IisSite = Get-IisSite $ctx.Site

    Write-Step 'Windows Firewall'
    $fw = Get-HisFirewallRule $ctx.Name
    if ($fw) { Write-Info "Rule hiện tại: port $($fw.Port), cho phép: $(if ($fw.Remote -eq 'Any') { 'mọi IP' } else { $fw.Remote })" }
    if (Read-YesNo "Mở port $($ctx.Port) trên Windows Firewall?" $true) {
        $curRemote = if ($fw -and $fw.Remote -ne 'Any') { $fw.Remote } else { '' }
        $remote = Read-Value 'Chỉ cho phép IP / dải IP (vd 192.168.1.0/24,10.0.0.5 | Enter = mọi IP | - = mọi IP)' $curRemote -AllowClear
        Set-HisFirewallRule $ctx.Name $ctx.Port $remote
        Set-ServiceState $State $ctx.Name 'firewallRemote' $remote
    }
    elseif ($fw -and (Read-YesNo 'Xoá rule firewall đang có?' $false)) { Remove-HisFirewallRule $ctx.Name }

    Set-ServiceState $State $ctx.Name 'installPath' $ctx.Path
    Set-ServiceState $State $ctx.Name 'siteName' $ctx.Site
    Set-ServiceState $State $ctx.Name 'appPool' $ctx.Pool
    Set-ServiceState $State $ctx.Name 'port' $ctx.Port
    Set-ServiceState $State $ctx.Name 'hostingUpdatedAt' ('{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))
    Save-StateDoc $State
    Write-Log "$($ctx.Name): site=$($ctx.Site) pool=$($ctx.Pool) port=$($ctx.Port) path=$($ctx.Path)"

    Restart-AndCheck $ctx
    return $true
}

#endregion

#region ---------- Luồng chính của 1 service ----------

function Invoke-FullDeploy($ctx) {
    [void](Confirm-Prerequisites)
    Write-Step "1/6 Thư mục cài đặt"
    if (-not $ctx.IisSite) {
        $p = Read-Value 'Thư mục cài đặt' $ctx.Path -Required
        $ctx.Path = $p.TrimEnd('\')
        $ctx.SettingsFile = Join-Path $ctx.Path 'appsettings.json'
    }
    else { Write-Info "$($ctx.Path) (theo site IIS $($ctx.Site))" }

    if (-not (Invoke-UpdateFiles $ctx)) { return }
    Write-Host '   (2/6 xong)' -ForegroundColor DarkGray

    Write-Host '' ; Write-Host '   === 3/6 Kết nối CSDL ===' -ForegroundColor Yellow
    Edit-Connections $ctx
    Write-Host '' ; Write-Host '   === 4/6 Chọn API chạy ===' -ForegroundColor Yellow
    if (Test-ApiSwitch $ctx.Def) { Edit-ApiSwitch $ctx }
    else { Write-Info 'Service không có ApiSwitchFilter - mọi API đều chạy, bỏ qua bước này.' }
    Write-Host '' ; Write-Host '   === 5/6 Tham số appsettings ===' -ForegroundColor Yellow
    Edit-Settings $ctx
    [void](Save-Settings $ctx)

    Write-Host '' ; Write-Host '   === 6/6 Port, IIS, Firewall ===' -ForegroundColor Yellow
    [void](Set-Hosting $ctx)
    Write-Log "$($ctx.Name): triển khai đầy đủ xong"
}

function Show-Config($ctx) {
    Write-Step "Cấu hình hiện tại - $($ctx.Name)"
    Write-Info "Thư mục    : $($ctx.Path)"
    Write-Info "Phiên bản  : $(Format-PackageInfo (Get-PackageInfo $ctx.Path))"
    if ($ctx.IisSite) {
        Write-Info "Site IIS   : $($ctx.Site) ($($ctx.IisSite.State)) - binding $($ctx.IisSite.Bindings)"
        Write-Info "App pool   : $($ctx.Pool) ($(Get-IisPoolState $ctx.Pool))"
    }
    else { Write-Info 'Site IIS   : (chưa tạo)' }
    $fw = if ($script:IisReady) { Get-HisFirewallRule $ctx.Name } else { $null }
    Write-Info ("Firewall   : " + $(if ($fw) { "TCP $($fw.Port), cho phép $(if ($fw.Remote -eq 'Any') { 'mọi IP' } else { $fw.Remote })" } else { '(chưa mở)' }))
    if (-not (Test-Installed $ctx)) { return }

    $doc = Open-SettingsDoc $ctx
    foreach ($conn in $ctx.Def.connections) {
        $plain = Unprotect-SvcString $ctx.Def (Get-JsonCValue $doc "ConnectionStrings:$($conn.name)")
        $d = if ($plain) { Format-ConnectionDisplay $conn.type $plain (Get-CryptoScheme $ctx.Def) } else { '(chưa có / không giải mã được)' }
        Write-Info "CSDL       : $($conn.name) -> $d"
    }
    $hasSwitch = Test-ApiSwitch $ctx.Def
    $sw = if ($hasSwitch) { Get-ApiSwitchState $ctx } else { $null }
    Write-Host ''
    Write-Host "   API:$(if (-not $hasSwitch) { ' (không có ApiSwitch - tất cả đang chạy)' })" -ForegroundColor Cyan
    foreach ($c in $ctx.Def.controllers) {
        $cnt = if ($hasSwitch) { Get-EnabledActionCount $c $sw } else { @($c.actions).Count }
        $mark = if ($cnt -gt 0) { '[x]' } else { '[ ]' }
        Write-Host ('     {0} {1,-18} {2,-7} {3}' -f $mark, $c.name, "$cnt/$(@($c.actions).Count)", $c.title) -ForegroundColor $(if ($cnt -gt 0) { 'White' } else { 'DarkGray' })
    }
    $list = Get-RequiredSettings $ctx
    if ($list.Count -gt 0) {
        Write-Host ''
        Write-Host '   Tham số theo API đang bật:' -ForegroundColor Cyan
        foreach ($it in $list.Values) {
            $s = $it.Setting
            $v = Get-JsonCValue $doc $s.key
            if ($s.type -in 'secret', 'encrypted') { $v = if ($v) { '********' } else { '(trống)' } }
            elseif ([string]::IsNullOrEmpty($v)) { $v = '(trống)' }
            Write-Host ('     {0,-45} {1}' -f $s.key, $v) -ForegroundColor Gray
        }
    }
}

function Restore-Backup($ctx) {
    $dir = Get-BackupDir $ctx.Name
    $items = @(Get-ChildItem $dir -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'app_*' -or $_.Name -like 'appsettings_*.json' } | Sort-Object Name -Descending)
    if ($items.Count -eq 0) { Write-Info "Chưa có bản sao lưu nào trong $dir"; return }
    Write-Step "Bản sao lưu - $($ctx.Name)"
    for ($i = 0; $i -lt $items.Count; $i++) {
        $kind = if ($items[$i].PSIsContainer) { 'Toàn bộ chương trình' } else { 'Chỉ appsettings.json' }
        Write-Host ('   {0,-4}{1,-34}{2}' -f ($i + 1), $items[$i].Name, $kind)
    }
    $in = Read-Value 'Chọn bản cần khôi phục (Enter = huỷ)' ''
    if (-not $in) { return }
    $nums = ConvertFrom-NumberList $in $items.Count
    if ($null -eq $nums -or $nums.Count -ne 1) { Write-Warn 'Lựa chọn không hợp lệ.'; return }
    $b = $items[$nums[0] - 1]
    if (-not (Read-YesNo "Khôi phục $($b.Name) vào $($ctx.Path)?" $false)) { return }

    [void](Backup-AppSettings $ctx.Name $ctx.SettingsFile)
    if ($b.PSIsContainer) {
        $bk = Backup-AppFolder $ctx.Name $ctx.Path
        if ($bk) { Write-Ok "Sao lưu bản hiện tại: $bk" }
        $offline = Join-Path $ctx.Path 'app_offline.htm'
        Set-Content $offline '<html><body>Đang khôi phục phiên bản...</body></html>' -Encoding UTF8
        Start-Sleep -Seconds 3
        $out = & robocopy $b.FullName $ctx.Path /MIR /R:5 /W:3 /NP /NFL /NDL /NJH /NJS /XD Logs logs /XF app_offline.htm 2>&1 | Out-String
        $code = $LASTEXITCODE
        Remove-Item $offline -Force -ErrorAction SilentlyContinue
        if ($code -ge 8) { Write-Err "Khôi phục lỗi (robocopy $code): $out"; return }
    }
    else { Copy-Item $b.FullName $ctx.SettingsFile -Force }
    $ctx.Doc = $null
    Write-Ok "Đã khôi phục $($b.Name)"
    Write-Log "$($ctx.Name): khôi phục $($b.Name)"
    Restart-AndCheck $ctx
}

function Uninstall-Service($ctx) {
    Write-Step "Gỡ cài đặt $($ctx.Name)"
    Write-Warn "Sẽ xoá site IIS '$($ctx.Site)', app pool '$($ctx.Pool)', rule firewall của service."
    $confirm = Read-Host "   Gõ đúng tên service ($($ctx.Name)) để xác nhận"
    if ($confirm -cne $ctx.Name) { Write-Info 'Đã huỷ.'; return }
    if ($script:IisReady) { Remove-IisSiteAndPool $ctx.Site $ctx.Pool }
    Remove-HisFirewallRule $ctx.Name
    if ((Test-Path $ctx.Path) -and (Read-YesNo "Xoá luôn thư mục $($ctx.Path)? (có sao lưu trước)" $false)) {
        $bk = Backup-AppFolder $ctx.Name $ctx.Path
        if ($bk) { Write-Ok "Sao lưu: $bk" }
        Remove-Item $ctx.Path -Recurse -Force
        Write-Ok "Xoá thư mục $($ctx.Path)"
    }
    [void](Remove-JsonCValue $State "services:$($ctx.Name)")
    Save-StateDoc $State
    Reset-SiteCache
    Write-Log "$($ctx.Name): gỡ cài đặt"
}

function Show-ServiceMenu($def) {
    while ($true) {
        Reset-SiteCache
        $ctx = Get-SvcContext $def
        $installed = Test-Installed $ctx
        $pkg = Get-PackageInfo $ctx.Package
        Write-Title "$($def.name) - $($def.title)"
        Write-Info "Thư mục  : $($ctx.Path)$(if (-not $installed) { '  (chưa cài)' })"
        Write-Info ("Site IIS : " + $(if ($ctx.IisSite) { "$($ctx.Site) - $($ctx.IisSite.State) - port $($ctx.Port)" } else { '(chưa tạo)' }))
        Write-Info ("Gói mới  : " + $(if (Test-Path (Join-Path $ctx.Package $def.dll)) { Format-PackageInfo $pkg } else { '(không có)' }))
        if ($def.note) { Write-Host "   ! $($def.note)" -ForegroundColor DarkYellow }
        Write-Host ''
        Write-Host '   1. Triển khai đầy đủ (file -> CSDL -> API -> tham số -> port/IIS/firewall)' -ForegroundColor White
        Write-Host '   2. Cập nhật file chương trình từ gói'
        Write-Host '   3. Kết nối CSDL (nhập user/mật khẩu, tự mã hoá)'
        Write-Host '   4. Port, IIS, Firewall'
        if (Test-ApiSwitch $def) { Write-Host '   5. Chọn API chạy (bật/tắt controller, từng API)' }
        else { Write-Host '   5. Chọn API chạy (service không có ApiSwitch - mọi API đều chạy)' -ForegroundColor DarkGray }
        Write-Host '   6. Tham số appsettings theo API đã bật'
        Write-Host '   7. Khởi động lại & kiểm tra'
        Write-Host '   8. Xem cấu hình hiện tại'
        Write-Host '   9. Khôi phục bản sao lưu'
        Write-Host '   X. Gỡ cài đặt'
        Write-Host '   0. Quay lại'
        $c = (Read-Host '   Chọn').Trim()
        if ($c -eq '0' -or $c -eq '') { return }
        try {
            switch -Regex ($c) {
                '^1$' { Invoke-FullDeploy $ctx }
                '^2$' { if (Invoke-UpdateFiles $ctx) { if (Read-YesNo 'Khởi động lại & kiểm tra?' $true) { Restart-AndCheck $ctx -NoRestart } } }
                '^3$' { Edit-Connections $ctx; if (Save-Settings $ctx) { Restart-AndCheck $ctx } }
                '^4$' { if (-not $installed) { throw 'Chưa cài file chương trình - chọn 1 hoặc 2 trước.' }; [void](Set-Hosting $ctx) }
                '^5$' { if (-not (Test-ApiSwitch $def)) { throw 'Service không có ApiSwitchFilter nên không bật/tắt được từng API.' }; Edit-ApiSwitch $ctx; if (Save-Settings $ctx) { if (Read-YesNo 'Kiểm tra tham số cho các API vừa bật?' $true) { Edit-Settings $ctx; [void](Save-Settings $ctx) }; Restart-AndCheck $ctx } }
                '^6$' { Edit-Settings $ctx; if (Save-Settings $ctx) { Restart-AndCheck $ctx } }
                '^7$' { Restart-AndCheck $ctx }
                '^8$' { Show-Config $ctx }
                '^9$' { Restore-Backup $ctx }
                '^(?i)x$' { Uninstall-Service $ctx; Wait-Continue; return }
                default { Write-Warn 'Lựa chọn không hợp lệ.' }
            }
        }
        catch {
            Write-Err $_.Exception.Message
            Write-Log "$($def.name): LỖI $($_.Exception.Message) $($_.ScriptStackTrace)"
        }
        Wait-Continue
    }
}

#endregion

#region ---------- Môi trường / trạng thái ----------

function Show-Environment {
    Write-Step 'Kiểm tra môi trường máy chủ'
    $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $osVer = [Environment]::OSVersion.Version
    Write-Info "Hệ điều hành : $os (build $($osVer.Build))"
    if ($osVer.Major -lt 10 -or $osVer.Build -lt 14393) { Write-Err 'Cần Windows Server 2016 / Windows 10 trở lên để chạy ASP.NET Core Module V2.' }
    Write-Info "PowerShell   : $($PSVersionTable.PSVersion)"
    $netfx = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    if ($netfx -ge 461808) { Write-Info ".NET Framework: 4.7.2 trở lên (release $netfx)" }
    else { Write-Warn ".NET Framework cũ hơn 4.7.2 (release $netfx) - công cụ vẫn chạy, nên cập nhật Windows." }
    $drive = New-Object System.IO.DriveInfo($script:InstallRoot.Substring(0, 3))
    $freeGb = $drive.AvailableFreeSpace / 1GB
    Write-Info ("Thư mục API  : {0} (ổ còn trống {1:N1} GB)" -f $script:InstallRoot, $freeGb)
    if ($freeGb -lt 2) { Write-Warn 'Ổ đĩa còn dưới 2 GB - log và bản sao lưu có thể làm đầy ổ.' }
    foreach ($p in (Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
        Write-Info ("Firewall {0,-8}: {1}" -f $p.Name, $(if ($p.Enabled) { 'bật' } else { 'TẮT' }))
    }
    if (Test-PendingReboot) { Write-Warn 'Windows đang chờ khởi động lại (sau khi cài update / feature) - nên khởi động lại trước khi cài.' }

    $st = Get-EnvironmentStatus $RuntimeChannels
    $rts = Get-AspNetCoreRuntimes
    if (-not $st.Iis) { Write-Err 'IIS chưa cài' }
    elseif ($st.IisRunning) { Write-Ok 'IIS (WAS/W3SVC đang chạy)' }
    else { Write-Err 'IIS đã cài nhưng dịch vụ WAS/W3SVC đang dừng' }
    if ($st.Ancm) { Write-Ok "ASP.NET Core Module V2 (Hosting Bundle) $(Get-AncmVersion)" }
    elseif (Test-Path (Join-Path $env:ProgramFiles 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll')) { Write-Err 'ASP.NET Core Module V2 có file nhưng chưa đăng ký với IIS (cần repair Hosting Bundle)' }
    else { Write-Err 'ASP.NET Core Module V2 (Hosting Bundle) chưa cài' }
    foreach ($c in $RuntimeChannels) {
        $have = @($rts | Where-Object { $_ -like "$c.*" })
        if ($have.Count) { Write-Ok "ASP.NET Core Runtime $c ($($have -join ', '))" }
        else { Write-Err "ASP.NET Core Runtime $c chưa cài (đang có: $(if ($rts.Count) { $rts -join ', ' } else { 'không' }))" }
    }
    if ($st.Iis) {
        if ($st.AppInit) { Write-Ok 'IIS Application Initialization (preload cho job chạy nền)' }
        else { Write-Warn 'Chưa có IIS Application Initialization - API có job chạy nền chỉ chạy sau request đầu tiên.' }
        # Port mặc định của các service chưa cài có bị chương trình khác chiếm không
        $script:IisReady = $true
        Reset-SiteCache
        foreach ($def in $Manifest.services) {
            $ctx = Get-SvcContext $def
            if ($ctx.IisSite) { continue }
            $conflict = Get-PortConflict $ctx.Port $ctx.Site
            if ($conflict) { Write-Warn "Port gợi ý $($ctx.Port) của $($def.name): $conflict - chọn port khác khi cài." }
        }
    }

    if ($st.Missing.Count -eq 0) {
        if ($st.Iis -and -not $st.AppInit -and (Read-YesNo 'Cài thêm IIS Application Initialization (khuyến nghị)?' $true)) { [void](Install-IisAppInit) }
        return $true
    }
    Write-Host ''
    if (-not (Read-YesNo "Tự động tải và cài: $($st.Missing -join ', ')?" $true)) { return $false }
    $ok = Install-Prerequisites $RuntimeChannels (Get-PrereqDir)
    $script:IisReady = Test-IisInstalled
    Reset-SiteCache
    return $ok
}

# Trước khi tạo site: thiếu IIS / Hosting Bundle thì đề nghị cài tự động
function Confirm-Prerequisites {
    $st = Get-EnvironmentStatus $RuntimeChannels
    if ($st.Missing.Count -eq 0) { return $true }
    Write-Warn "Máy chủ còn thiếu: $($st.Missing -join ', ')"
    if (Read-YesNo 'Tự động tải và cài ngay?' $true) {
        [void](Install-Prerequisites $RuntimeChannels (Get-PrereqDir))
        $script:IisReady = Test-IisInstalled
        Reset-SiteCache
    }
    return $script:IisReady
}

function Show-GeneralSettings {
    while ($true) {
        Write-Step 'Cài đặt chung'
        Write-Host "   1. Đổi thư mục lưu các API (hiện tại: $($script:InstallRoot))"
        Write-Host '   0. Quay lại'
        $c = (Read-Host '   Chọn').Trim()
        if ($c -eq '0' -or $c -eq '') { return }
        if ($c -eq '1') {
            $old = $script:InstallRoot
            $apiRoot = Read-InstallRoot $old
            if ($apiRoot -ieq $old) { continue }
            [void](Set-JsonCValue $Config 'installRoot' $apiRoot)
            Save-ToolConfig $Config
            $script:InstallRoot = $apiRoot
            Write-Log "Đổi thư mục lưu API: $old -> $apiRoot"
            Write-Info 'Service cài mới sẽ vào thư mục này. Service đã cài giữ nguyên thư mục hiện tại.'
        }
    }
}

function Show-AllStatus {
    Write-Step 'Trạng thái các service'
    foreach ($def in $Manifest.services) {
        $ctx = Get-SvcContext $def
        if (-not (Test-Installed $ctx)) { continue }
        $health = '-'
        if ($ctx.IisSite) {
            $r = Test-HttpUrl "http://localhost:$($ctx.Port)/$(Get-HealthPath $ctx)" 20
            $health = if ($r.Status -ge 200 -and $r.Status -lt 500) { "OK ($($r.Status))" } elseif ($r.Status -eq 0) { 'không kết nối' } else { "LỖI ($($r.Status))" }
        }
        $fw = Get-HisFirewallRule $def.name
        $fwText = if ($fw) { "mở $($fw.Port)" } else { 'chưa mở' }
        $color = if ($health -like 'OK*') { 'Green' } else { 'Red' }
        Write-Host ('   {0,-20} port {1,-6} pool {2,-8} firewall {3,-10} API: {4}' -f $def.name, $ctx.Port, (Get-IisPoolState $ctx.Pool), $fwText, $health) -ForegroundColor $color
    }
}

function Show-MainMenu {
    while ($true) {
        Reset-SiteCache
        Clear-Host
        Write-Title "$($script:ToolTitle) - CÔNG CỤ TRIỂN KHAI   (máy chủ: $env:COMPUTERNAME)"
        Write-Info "Thư mục API: $($script:InstallRoot)"
        $envSt = Get-EnvironmentStatus $RuntimeChannels
        if ($envSt.Missing.Count) { Write-Warn "Môi trường còn thiếu: $($envSt.Missing -join ', ') - chọn K để tự động cài." }
        Write-Host ''
        Write-Host ('   {0,-4}{1,-22}{2,-14}{3,-7}{4,-8}{5}' -f '#', 'Service', 'Trạng thái', 'Port', 'API', 'Mô tả') -ForegroundColor DarkGray
        $defs = @($Manifest.services)
        for ($i = 0; $i -lt $defs.Count; $i++) {
            $def = $defs[$i]
            $ctx = Get-SvcContext $def
            $status = 'Chưa cài'; $port = '-'; $api = '-'; $color = 'DarkGray'
            if (Test-Installed $ctx) {
                $status = if ($ctx.IisSite) { if ($ctx.IisSite.State -eq 'Started') { 'Đang chạy' } else { 'Đã dừng' } } else { 'Chưa có site' }
                $color = if ($status -eq 'Đang chạy') { 'Green' } else { 'Yellow' }
                if ($ctx.IisSite) { $port = $ctx.Port }
                try { $api = "$((Get-EnabledControllers $ctx).Count)/$(@($def.controllers).Count)" } catch { $api = 'lỗi' }
            }
            $newPkg = if (Test-Path (Join-Path $ctx.Package $def.dll)) { ' (có gói)' } else { '' }
            Write-Host ('   {0,-4}{1,-22}{2,-14}{3,-7}{4,-8}{5}{6}' -f ($i + 1), $def.name, $status, $port, $api, $def.title, $newPkg) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '   [số]  Chọn service để cài đặt / cấu hình'
        Write-Host '   K     Kiểm tra môi trường máy chủ, thiếu thì tự động tải & cài (IIS, .NET Hosting Bundle)'
        Write-Host '   T     Trạng thái & kiểm tra API đang chạy'
        Write-Host '   C     Cài đặt chung (thư mục lưu API)'
        Write-Host '   Q     Thoát'
        $c = (Read-Host '   Chọn').Trim()
        try {
            if ($c -match '^(?i)q$') { return }
            elseif ($c -match '^(?i)k$') { [void](Show-Environment); Wait-Continue }
            elseif ($c -match '^(?i)c$') { Show-GeneralSettings }
            elseif ($c -match '^(?i)t$') { Show-AllStatus; Wait-Continue }
            elseif ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $defs.Count) { Show-ServiceMenu $defs[[int]$c - 1] }
        }
        catch {
            Write-Err $_.Exception.Message
            Write-Log "LỖI $($_.Exception.Message) $($_.ScriptStackTrace)"
            Wait-Continue
        }
    }
}

#endregion

try {
    if (-not (Start-ToolSession)) { Start-Sleep -Seconds 2; return }
    if ($Service) {
        $def = $Manifest.services | Where-Object { $_.name -ieq $Service } | Select-Object -First 1
        if (-not $def) { throw "Không có service '$Service' trong deploy-manifest.json" }
        Show-ServiceMenu $def
    }
    else { Show-MainMenu }
}
catch {
    Write-Err $_.Exception.Message
    Write-Log "LỖI $($_.Exception.Message) $($_.ScriptStackTrace)"
    Wait-Continue
}
Write-Log '===== Đóng công cụ deploy'
