# =====================================================================
#  Iis.ps1 - IIS (qua appcmd.exe, có sẵn khi cài IIS), Windows Firewall,
#  copy file chương trình, phân quyền thư mục.
# =====================================================================

$script:AppCmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
# Mặc định của bộ HIS cũ; Deploy.ps1 đổi theo defaults.firewallPrefix / firewallGroup trong manifest
$script:FirewallPrefix = 'HISAPI_'
$script:FirewallGroup = 'HIS API'

#region ---------- appcmd ----------

function Invoke-AppCmd {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AppArgs)
    $out = & $script:AppCmd @AppArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Log ('appcmd {0} => {1}' -f ($AppArgs -join ' '), $code)
    return @{ Code = $code; Output = $out.Trim() }
}

function Test-IisInstalled {
    return ((Test-Path $script:AppCmd) -and $null -ne (Get-Service W3SVC -ErrorAction SilentlyContinue))
}

# ASP.NET Core Module V2 đã cài và đăng ký với IIS?
# Hosting Bundle cài module vào %ProgramFiles%\IIS\Asp.Net Core Module\V2 (không phải System32\inetsrv)
# và đăng ký AspNetCoreModuleV2 trong applicationHost.config. Cài Hosting Bundle trước IIS thì có file
# nhưng chưa đăng ký -> coi như chưa cài để công cụ chạy repair.
function Test-AncmInstalled {
    $dll = Join-Path $env:ProgramFiles 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
    if (-not (Test-Path $dll)) { return $false }
    $cfg = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
    try { $text = [System.IO.File]::ReadAllText($cfg) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return $false }   # chưa cài IIS
    catch { return $true }   # không đủ quyền đọc -> dựa vào file module
    return ($text -match '<add\s+name="AspNetCoreModuleV2"')
}

# Application Initialization (IIS) đã cài? Cần để app tự khởi động sau khi IIS / app pool khởi động lại
# (job chạy nền, BackgroundService) mà không phải chờ request đầu tiên.
function Test-AppInitInstalled {
    return (Test-Path (Join-Path $env:windir 'System32\inetsrv\warmup.dll'))
}

# ASP.NET 4.x đã đăng ký với IIS (feature Web-Asp-Net45 / IIS-ASPNET45)? Cần cho service .NET Framework.
# Feature này đăng ký module ManagedEngineV4.0 trong applicationHost.config.
function Test-AspNet45Installed {
    if (-not (Test-IisInstalled)) { return $false }
    $cfg = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
    try { $text = [System.IO.File]::ReadAllText($cfg) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return $false }
    catch { return (Test-Path (Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\webengine4.dll')) }   # không đủ quyền đọc
    return ($text -match '<add\s+name="ManagedEngineV4\.0_(64|32)bit"')
}

function Get-AncmVersion {
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\IIS AspNetCore Module V2' -ErrorAction SilentlyContinue
    if ($k -and $k.Version) { return [string]$k.Version }
    return ''
}

function Get-AppCmdXml([string[]]$listArgs) {
    $all = @($listArgs) + '/xml'
    $r = Invoke-AppCmd @all
    if ($r.Code -ne 0 -or -not $r.Output) { return $null }
    try { return [xml]$r.Output } catch { return $null }
}

# Danh sách site: Name, Id, State, Bindings (chuỗi gốc), Ports (int[])
function Get-IisSites {
    $x = Get-AppCmdXml @('list', 'site')
    $list = New-Object System.Collections.Generic.List[object]
    if ($x -and $x.appcmd.SITE) {
        foreach ($s in @($x.appcmd.SITE)) {
            $ports = @()
            foreach ($b in ($s.bindings -split ',')) {
                if ($b -match '^(https?)/[^:]*:(\d+):') { $ports += [int]$Matches[2] }
            }
            $list.Add([pscustomobject]@{ Name = $s.'SITE.NAME'; Id = $s.'SITE.ID'; State = $s.state; Bindings = $s.bindings; Ports = $ports })
        }
    }
    return , $list
}

function Get-IisSite([string]$name) {
    foreach ($s in (Get-IisSites)) { if ($s.Name -ieq $name) { return $s } }
    return $null
}

# Map tên site -> @{ Path; Pool } của app gốc, lấy bằng 2 lệnh appcmd cho tất cả site
function Get-IisSiteMap {
    $map = @{}
    $apps = Get-AppCmdXml @('list', 'app')
    if ($apps -and $apps.appcmd.APP) {
        foreach ($a in @($apps.appcmd.APP)) {
            if ($a.'APP.NAME' -eq ($a.'SITE.NAME' + '/')) { $map[$a.'SITE.NAME'] = @{ Path = $null; Pool = $a.'APPPOOL.NAME' } }
        }
    }
    $vdirs = Get-AppCmdXml @('list', 'vdir')
    if ($vdirs -and $vdirs.appcmd.VDIR) {
        foreach ($v in @($vdirs.appcmd.VDIR)) {
            $vn = $v.'VDIR.NAME'
            if ($vn -eq $v.'APP.NAME' -and $vn.EndsWith('/') -and $vn.IndexOf('/') -eq $vn.Length - 1) {
                $site = $vn.Substring(0, $vn.Length - 1)
                if (-not $map.ContainsKey($site)) { $map[$site] = @{ Path = $null; Pool = $null } }
                $map[$site].Path = [Environment]::ExpandEnvironmentVariables($v.physicalPath)
            }
        }
    }
    return $map
}

function Get-IisSitePath([string]$name) {
    $x = Get-AppCmdXml @('list', 'vdir', "$name/")
    if ($x -and $x.appcmd.VDIR) { return [Environment]::ExpandEnvironmentVariables(@($x.appcmd.VDIR)[0].physicalPath) }
    return $null
}

function Get-IisSitePool([string]$name) {
    $x = Get-AppCmdXml @('list', 'app', "$name/")
    if ($x -and $x.appcmd.APP) { return @($x.appcmd.APP)[0].'APPPOOL.NAME' }
    return $null
}

function Get-IisPoolState([string]$pool) {
    $x = Get-AppCmdXml @('list', 'apppool', $pool)
    if ($x -and $x.appcmd.APPPOOL) { return @($x.appcmd.APPPOOL)[0].state }
    return $null
}

# Tạo / cập nhật app pool. $managedRuntime: '' = No Managed Code (ASP.NET Core), 'v4.0' = ASP.NET .NET Framework 4.x
function Set-IisAppPool([string]$pool, [string]$managedRuntime = '') {
    if (-not (Get-IisPoolState $pool)) {
        $r = Invoke-AppCmd add apppool "/name:$pool"
        if ($r.Code -ne 0) { throw "Không tạo được app pool $pool : $($r.Output)" }
        Write-Ok "Tạo app pool $pool"
    }
    $rtArg = if ($managedRuntime) { "/managedRuntimeVersion:$managedRuntime" } else { '/managedRuntimeVersion:""' }
    $r = Invoke-AppCmd set apppool "/apppool.name:$pool" $rtArg '/managedPipelineMode:Integrated' '/startMode:AlwaysRunning' '/processModel.idleTimeout:00:00:00' '/processModel.loadUserProfile:true'
    if ($r.Code -ne 0) { throw "Không cấu hình được app pool $pool : $($r.Output)" }
}

# Tạo / cập nhật site: đường dẫn, binding http *:port, app pool.
# Chỉ thay binding http do công cụ quản lý ($oldPort), giữ nguyên binding khác (https, host name...)
function Set-IisSite([string]$site, [string]$path, [int]$port, [string]$pool, [int]$oldPort = 0) {
    $existing = Get-IisSite $site
    if (-not $existing) {
        $r = Invoke-AppCmd add site "/name:$site" "/bindings:http/*:${port}:" "/physicalPath:$path"
        if ($r.Code -ne 0) { throw "Không tạo được site $site : $($r.Output)" }
        Write-Ok "Tạo site IIS $site (http://*:$port)"
    }
    else {
        $r = Invoke-AppCmd set vdir "/vdir.name:$site/" "/physicalPath:$path"
        if ($r.Code -ne 0) { throw "Không cập nhật được đường dẫn site $site : $($r.Output)" }
        if ($existing.Bindings -notmatch "(^|,)http/\*:${port}:(,|$)") {
            if ($oldPort -gt 0 -and $oldPort -ne $port -and $existing.Bindings -match "(^|,)http/\*:${oldPort}:(,|$)") {
                $r = Invoke-AppCmd set site "/site.name:$site" "/-bindings.[protocol='http',bindingInformation='*:${oldPort}:']"
                if ($r.Code -ne 0) { throw "Không xoá được binding cũ port $oldPort : $($r.Output)" }
                Write-Ok "Xoá binding cũ http://*:$oldPort"
            }
            $r = Invoke-AppCmd set site "/site.name:$site" "/+bindings.[protocol='http',bindingInformation='*:${port}:']"
            if ($r.Code -ne 0) { throw "Không thêm được binding port $port : $($r.Output)" }
            Write-Ok "Thêm binding http://*:$port"
        }
    }
    $r = Invoke-AppCmd set app "/app.name:$site/" "/applicationPool:$pool"
    if ($r.Code -ne 0) { throw "Không gán app pool cho site $site : $($r.Output)" }
    if (Test-AppInitInstalled) {
        # Pool AlwaysRunning + preload: app khởi động ngay khi IIS chạy, job nền không phải chờ request
        $r = Invoke-AppCmd set app "/app.name:$site/" '/preloadEnabled:true'
        if ($r.Code -ne 0) { Write-Warn "Không bật được preload cho site $site : $($r.Output)" }
    }
    $s = Get-IisSite $site
    if ($s -and $s.State -ne 'Started') {
        $r = Invoke-AppCmd start site "/site.name:$site"
        if ($r.Code -ne 0) { Write-Warn "Không start được site $site : $($r.Output)" }
    }
}

function Restart-IisPool([string]$pool) {
    $poolState = Get-IisPoolState $pool
    if (-not $poolState) { return $false }
    if ($poolState -eq 'Started') { $r = Invoke-AppCmd recycle apppool "/apppool.name:$pool" }
    else { $r = Invoke-AppCmd start apppool "/apppool.name:$pool" }
    return ($r.Code -eq 0)
}

function Stop-IisPool([string]$pool) {
    if ((Get-IisPoolState $pool) -eq 'Started') { [void](Invoke-AppCmd stop apppool "/apppool.name:$pool") }
}

function Remove-IisSiteAndPool([string]$site, [string]$pool) {
    if (Get-IisSite $site) {
        [void](Invoke-AppCmd stop site "/site.name:$site")
        $r = Invoke-AppCmd delete site $site
        if ($r.Code -eq 0) { Write-Ok "Xoá site $site" } else { Write-Err "Xoá site $site lỗi: $($r.Output)" }
    }
    if ($pool -and (Get-IisPoolState $pool)) {
        # Chỉ xoá pool nếu không còn app nào dùng
        $x = Get-AppCmdXml @('list', 'app', "/apppool.name:$pool")
        if (-not ($x -and $x.appcmd.APP)) {
            [void](Invoke-AppCmd stop apppool "/apppool.name:$pool")
            $r = Invoke-AppCmd delete apppool $pool
            if ($r.Code -eq 0) { Write-Ok "Xoá app pool $pool" } else { Write-Err "Xoá app pool $pool lỗi: $($r.Output)" }
        }
        else { Write-Warn "App pool $pool còn app khác dùng, giữ lại" }
    }
}

#endregion

#region ---------- Port ----------

# Kiểm tra port có bị chương trình / site khác dùng không. Trả về chuỗi mô tả xung đột, '' nếu trống
function Get-PortConflict([int]$port, [string]$ownSite) {
    foreach ($s in (Get-IisSites)) {
        if ($s.Name -ine $ownSite -and $s.Ports -contains $port) { return "site IIS '$($s.Name)' đang dùng port $port" }
    }
    $listen = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    foreach ($l in $listen) {
        if ($l.OwningProcess -eq 4) { continue }   # System (http.sys) - IIS, đã xét ở trên
        $p = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
        $pn = if ($p) { $p.ProcessName } else { "PID $($l.OwningProcess)" }
        return "chương trình '$pn' đang lắng nghe port $port"
    }
    return ''
}

#endregion

#region ---------- Firewall ----------

function Get-FirewallRuleName([string]$service) { return "$($script:FirewallPrefix)$service" }

function Get-HisFirewallRule([string]$service) {
    $rule = Get-NetFirewallRule -Name (Get-FirewallRuleName $service) -ErrorAction SilentlyContinue
    if (-not $rule) { return $null }
    $pf = $rule | Get-NetFirewallPortFilter
    $af = $rule | Get-NetFirewallAddressFilter
    return [pscustomobject]@{
        Enabled = ($rule.Enabled -eq 'True')
        Port    = [string]$pf.LocalPort
        Remote  = (@($af.RemoteAddress) -join ',')
    }
}

function Set-HisFirewallRule([string]$service, [int]$port, [string]$remote) {
    $name = Get-FirewallRuleName $service
    Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $p = @{
        Name        = $name
        DisplayName = "$($script:FirewallGroup) - $service (TCP $port)"
        Group       = $script:FirewallGroup
        Direction   = 'Inbound'
        Protocol    = 'TCP'
        LocalPort   = $port
        Action      = 'Allow'
        Profile     = 'Any'
    }
    if ($remote -and $remote -ne 'Any') { $p.RemoteAddress = @($remote -split '\s*,\s*' | Where-Object { $_ }) }
    New-NetFirewallRule @p | Out-Null
    $scope = if ($p.RemoteAddress) { $remote } else { 'mọi IP' }
    Write-Ok "Firewall: mở TCP $port cho $scope (rule $name)"
}

function Remove-HisFirewallRule([string]$service) {
    $name = Get-FirewallRuleName $service
    if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -Name $name
        Write-Ok "Xoá rule firewall $name"
    }
}

#endregion

#region ---------- File chương trình ----------

# Copy gói mới vào thư mục cài đặt. Không ghi đè appsettings*.json (xử lý merge riêng).
# Dùng app_offline.htm để ASP.NET Core Module / ASP.NET tự dừng app, nhả khoá file dll.
# $AfterCopy chạy ngay sau khi copy, trước khi gỡ app_offline.htm (vd ghép lại giá trị Web.config đang dùng
# để app không khởi động với cấu hình trống của gói).
function Copy-AppPackage([string]$source, [string]$target, [string]$pool, [scriptblock]$AfterCopy = $null) {
    New-Item -ItemType Directory -Force $target | Out-Null
    $offline = Join-Path $target 'app_offline.htm'
    $hasApp = Test-Path (Join-Path $target 'web.config')
    if ($hasApp) {
        Set-Content -Path $offline -Value '<html><body><h3>Đang cập nhật phiên bản mới, vui lòng thử lại sau ít phút.</h3></body></html>' -Encoding UTF8
        Start-Sleep -Seconds 3
    }
    try {
        $rcArgs = @($source, $target, '/E', '/R:5', '/W:3', '/NP', '/NFL', '/NDL', '/NJH', '/NJS',
            '/XF', 'appsettings.json', 'appsettings.*.json', 'app_offline.htm',
            '/XD', 'Logs', 'logs')
        $out = & robocopy @rcArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
        if ($code -ge 8 -and $pool) {
            # Vẫn bị khoá file -> dừng hẳn app pool rồi copy lại
            Write-Warn 'File đang bị khoá, dừng app pool rồi copy lại...'
            Stop-IisPool $pool
            Start-Sleep -Seconds 3
            $out = & robocopy @rcArgs 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        Write-Log "robocopy $source -> $target => $code"
        if ($code -ge 8) { throw "Copy file lỗi (robocopy $code): $out" }
        if ($AfterCopy) { & $AfterCopy }
    }
    finally {
        Remove-Item $offline -Force -ErrorAction SilentlyContinue
    }
}

# Sao lưu toàn bộ thư mục chương trình (trừ log) trước khi cập nhật
function Backup-AppFolder([string]$service, [string]$path) {
    if (-not (Test-Path (Join-Path $path 'web.config'))) { return $null }
    $dir = Get-BackupDir $service
    $dst = Join-Path $dir ('app_{0:yyyyMMdd_HHmmss}' -f (Get-Date))
    $out = & robocopy $path $dst /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS /XD Logs logs 2>&1 | Out-String
    if ($LASTEXITCODE -ge 8) { Write-Warn "Sao lưu thư mục chương trình lỗi: $out"; return $null }
    Remove-OldBackups $dir 'app_*' 5
    return $dst
}

# Cấp quyền Modify cho tài khoản app pool trên thư mục chương trình (để ghi Logs, file tạm...)
function Grant-PoolAccess([string]$path, [string]$pool) {
    $out = & icacls $path /grant "IIS AppPool\${pool}:(OI)(CI)M" /Q 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Warn "Không cấp quyền được cho IIS AppPool\$pool : $out" }
    else { Write-Ok "Cấp quyền ghi thư mục cho IIS AppPool\$pool" }
}

# Bật/tắt log khởi động (stdout) của ASP.NET Core Module trong web.config để chẩn đoán lỗi 500.30
function Set-StdoutLog([string]$path, [bool]$enabled) {
    $wc = Join-Path $path 'web.config'
    if (-not (Test-Path $wc)) { return $false }
    [xml]$x = Get-Content $wc -Raw -Encoding UTF8
    $node = $x.SelectSingleNode('//aspNetCore')
    if (-not $node) { return $false }
    $node.SetAttribute('stdoutLogEnabled', $enabled.ToString().ToLowerInvariant())
    if (-not $node.GetAttribute('stdoutLogFile')) { $node.SetAttribute('stdoutLogFile', '.\logs\stdout') }
    New-Item -ItemType Directory -Force (Join-Path $path 'logs') | Out-Null
    $x.Save($wc)
    return $true
}

#endregion
