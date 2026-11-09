# =====================================================================
#  Prereq.ps1 - Kiểm tra và tự động cài môi trường chạy API:
#    IIS (Windows feature), ASP.NET Core Hosting Bundle (runtime + ANCM) cho service ASP.NET Core,
#    ASP.NET 4.x cho IIS + kiểm tra phiên bản .NET Framework cho service .NET Framework (runtime "netfx").
#  Bộ cài Hosting Bundle lấy từ release metadata chính thức của Microsoft,
#  kiểm tra SHA512 + chữ ký số trước khi chạy. Máy không có internet thì
#  dùng file bỏ sẵn trong thư mục prereq.
# =====================================================================

$script:DotnetMetadataUrls = @(
    'https://builds.dotnet.microsoft.com/dotnet/release-metadata/{0}/releases.json',
    'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/{0}/releases.json'
)

function Enable-Tls12 {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
}

#region ---------- Trạng thái ----------

function Test-RuntimeInstalled([string]$channel) {
    return (@(Get-AspNetCoreRuntimes | Where-Object { $_ -like "$channel.*" }).Count -gt 0)
}

# "3.1" | "3.1,8.0" | mảng -> mảng kênh runtime ASP.NET Core không trùng (bỏ "netfx" của service .NET Framework)
function ConvertTo-RuntimeChannels($channels) {
    return , @(@($channels) | ForEach-Object { [string]$_ -split '\s*,\s*' } | Where-Object { $_ -match '^\d+(\.\d+)*$' } | Select-Object -Unique)
}

# Release (registry) tối thiểu của từng phiên bản .NET Framework 4.x
$script:NetFxReleases = [ordered]@{
    '4.5' = 378389; '4.5.1' = 378675; '4.5.2' = 379893; '4.6' = 393295; '4.6.1' = 394254; '4.6.2' = 394802
    '4.7' = 460798; '4.7.1' = 461308; '4.7.2' = 461808; '4.8' = 528040; '4.8.1' = 533320
}

function Get-NetFxRelease {
    $r = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    if ($r) { return [int]$r }
    return 0
}

# Máy có .NET Framework >= $version (vd "4.6.1")?
function Test-NetFxVersion([string]$version) {
    if (-not $version) { return $true }
    $need = $script:NetFxReleases[$version]
    if (-not $need) {
        # Phiên bản không có trong bảng: lấy mức gần nhất không cao hơn
        foreach ($k in $script:NetFxReleases.Keys) { if ([version]$k -le [version]$version) { $need = $script:NetFxReleases[$k] } }
    }
    if (-not $need) { $need = $script:NetFxReleases['4.5'] }
    return ((Get-NetFxRelease) -ge $need)
}

# Dịch vụ IIS (WAS + W3SVC) đang chạy?
function Test-IisServiceRunning {
    foreach ($n in 'WAS', 'W3SVC') {
        $svc = Get-Service $n -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') { return $false }
    }
    return $true
}

# Windows đang chờ khởi động lại (sau khi cài update / Windows feature)?
function Test-PendingReboot {
    foreach ($k in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path $k) { return $true }
    }
    return $false
}

# Trạng thái môi trường, không cần mạng. $channels: kênh runtime các service ASP.NET Core cần (vd "3.1" hoặc
# "3.1,8.0"). $netFramework: phiên bản .NET Framework các service ASP.NET (.NET Framework) cần ('' = không có).
# Không có service ASP.NET Core thì không cần ASP.NET Core Module.
function Get-EnvironmentStatus($channels, [string]$netFramework = '') {
    $channels = ConvertTo-RuntimeChannels $channels
    $s = @{
        Iis             = (Test-IisInstalled)
        IisRunning      = $false
        Ancm            = $true
        AppInit         = (Test-AppInitInstalled)
        Runtime         = $true
        AspNet45        = $true
        NetFx           = $true
        MissingRuntimes = (New-Object System.Collections.Generic.List[string])
        Missing         = (New-Object System.Collections.Generic.List[string])
    }
    if ($channels.Count) { $s.Ancm = (Test-AncmInstalled) }
    $s.IisRunning = ($s.Iis -and (Test-IisServiceRunning))
    foreach ($c in $channels) { if (-not (Test-RuntimeInstalled $c)) { $s.MissingRuntimes.Add($c) } }
    $s.Runtime = ($s.MissingRuntimes.Count -eq 0)
    if ($netFramework) {
        $s.NetFx = (Test-NetFxVersion $netFramework)
        $s.AspNet45 = (Test-AspNet45Installed)
    }
    if (-not $s.Iis) { $s.Missing.Add('IIS') }
    elseif (-not $s.IisRunning) { $s.Missing.Add('Dịch vụ IIS (WAS/W3SVC) đang dừng') }
    if (-not $s.Ancm) { $s.Missing.Add('ASP.NET Core Module (Hosting Bundle)') }
    foreach ($c in $s.MissingRuntimes) { $s.Missing.Add("ASP.NET Core Runtime $c") }
    if ($netFramework -and -not $s.NetFx) { $s.Missing.Add(".NET Framework $netFramework") }
    if ($netFramework -and $s.Iis -and -not $s.AspNet45) { $s.Missing.Add('ASP.NET 4.x cho IIS') }
    return $s
}

#endregion

#region ---------- Tải file ----------

function New-WebRequestObject([string]$url, [int]$timeoutMs) {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Timeout = $timeoutMs
    $req.ReadWriteTimeout = 120000
    $req.UserAgent = 'HIS-API-Deploy'
    $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
    $proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    $req.Proxy = $proxy
    return $req
}

function Get-WebText([string]$url, [int]$timeoutMs = 10000) {
    Enable-Tls12
    $resp = (New-WebRequestObject $url $timeoutMs).GetResponse()
    try {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        return $sr.ReadToEnd()
    }
    finally { $resp.Close() }
}

# Tải file có hiện tiến độ; ghi ra .part rồi mới đổi tên để không để lại file dở
function Save-WebFile([string]$url, [string]$destination) {
    Enable-Tls12
    $tmp = "$destination.part"
    $resp = (New-WebRequestObject $url 30000).GetResponse()
    try {
        $total = $resp.ContentLength
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($tmp)
        try {
            $buf = New-Object byte[] 262144
            $done = 0L; $lastPct = -1
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $done += $n
                if ($total -gt 0) {
                    $pct = [int][Math]::Floor($done * 100 / $total)
                    if ($pct -ne $lastPct -and ($pct % 5 -eq 0)) {
                        Write-Host ("`r        Đang tải: {0,3}% ({1:N1} / {2:N1} MB)" -f $pct, ($done / 1MB), ($total / 1MB)) -NoNewline
                        $lastPct = $pct
                    }
                }
            }
            Write-Host ''
        }
        finally { $out.Close() }
    }
    finally { $resp.Close() }
    if ($total -gt 0 -and (Get-Item $tmp).Length -ne $total) { Remove-Item $tmp -Force; throw 'Tải file không đủ dung lượng, thử lại.' }
    Move-Item $tmp $destination -Force
}

#endregion

#region ---------- Hosting Bundle ----------

# Thông tin bản Hosting Bundle mới nhất của kênh (vd 3.1): @{ Version; Url; Hash; FileName }. Không có mạng -> $null
function Get-HostingBundleRelease([string]$channel) {
    foreach ($fmt in $script:DotnetMetadataUrls) {
        $url = $fmt -f $channel
        try {
            $json = Get-WebText $url | ConvertFrom-Json
            $ver = $json.'latest-release'
            $rel = @($json.releases | Where-Object { $_.'release-version' -eq $ver })[0]
            $file = @($rel.'aspnetcore-runtime'.files | Where-Object { $_.name -eq 'dotnet-hosting-win.exe' })[0]
            if ($file -and $file.url) {
                $name = Split-Path ([Uri]$file.url).AbsolutePath -Leaf
                return @{ Version = $rel.'aspnetcore-runtime'.version; Url = $file.url; Hash = ([string]$file.hash).ToUpperInvariant(); FileName = $name }
            }
        }
        catch { Write-Log "Không đọc được $url : $($_.Exception.Message)" }
    }
    return $null
}

# Chữ ký số Microsoft hợp lệ?
function Test-MicrosoftSignature([string]$file) {
    $sig = Get-AuthenticodeSignature $file
    $isMs = $sig.SignerCertificate -and $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation'
    return @{ Valid = ($sig.Status -eq 'Valid' -and $isMs); IsMicrosoft = [bool]$isMs; Status = [string]$sig.Status }
}

# Lấy đường dẫn bộ cài Hosting Bundle: có mạng thì tải bản mới nhất (dùng lại nếu đã tải),
# không có mạng thì tìm trong thư mục prereq. Trả về $null nếu không có.
function Get-HostingBundleInstaller([string]$channel, [string]$prereqDir) {
    New-Item -ItemType Directory -Force $prereqDir | Out-Null
    Write-Info "Tìm bản ASP.NET Core Hosting Bundle $channel mới nhất từ Microsoft..."
    $rel = Get-HostingBundleRelease $channel

    if ($rel) {
        $dest = Join-Path $prereqDir $rel.FileName
        if ((Test-Path $dest) -and (Get-FileHash $dest -Algorithm SHA512).Hash -eq $rel.Hash) {
            Write-Ok "Đã có sẵn $($rel.FileName)"
        }
        else {
            Write-Info "Tải $($rel.FileName) (phiên bản $($rel.Version))"
            Write-Info $rel.Url
            Save-WebFile $rel.Url $dest
            $hash = (Get-FileHash $dest -Algorithm SHA512).Hash
            if ($hash -ne $rel.Hash) { Remove-Item $dest -Force; throw 'File tải về sai mã SHA512 - đã xoá, không cài.' }
            Write-Ok 'Tải xong, đúng mã SHA512 của Microsoft công bố'
        }
        $sig = Test-MicrosoftSignature $dest
        if (-not $sig.IsMicrosoft) { throw "File $dest không có chữ ký số của Microsoft - không cài." }
        return $dest
    }

    Write-Warn 'Không kết nối được tới máy chủ Microsoft (máy không có internet hoặc bị chặn proxy).'
    $local = @(Get-ChildItem $prereqDir -Filter "dotnet-hosting-$channel.*-win.exe" -ErrorAction SilentlyContinue |
            Sort-Object { [version]($_.Name -replace '^dotnet-hosting-([\d\.]+)-win\.exe$', '$1') } -Descending)
    if ($local.Count -eq 0) {
        Write-Err "Không có bộ cài trong $prereqDir"
        Write-Info "Trên máy có internet, tải 'ASP.NET Core Runtime $channel - Hosting Bundle' tại"
        Write-Info "https://dotnet.microsoft.com/download/dotnet/$channel rồi bỏ vào thư mục trên, chạy lại."
        return $null
    }
    $file = $local[0].FullName
    $sig = Test-MicrosoftSignature $file
    if ($sig.Valid) { Write-Ok "Dùng bộ cài có sẵn: $($local[0].Name) (chữ ký Microsoft hợp lệ)" }
    elseif ($sig.IsMicrosoft) {
        # Máy không có mạng thường không kiểm tra được thu hồi chứng chỉ -> trạng thái khác Valid
        Write-Warn "Chữ ký Microsoft trên $($local[0].Name) chưa xác minh đầy đủ (trạng thái: $($sig.Status))."
        if (-not (Read-YesNo 'Vẫn cài file này?' $true)) { return $null }
    }
    else { throw "File $file không có chữ ký số của Microsoft - không cài." }
    return $file
}

function Invoke-HostingBundleSetup([string]$file, [bool]$repair) {
    $mode = if ($repair) { '/repair' } else { '/install' }
    Write-Info "Đang cài $(Split-Path $file -Leaf) ($mode, có thể mất vài phút)..."
    $p = Start-Process -FilePath $file -ArgumentList $mode, '/quiet', '/norestart' -Wait -PassThru
    $code = $p.ExitCode
    Write-Log "Hosting Bundle $mode => $code"
    switch ($code) {
        0 { Write-Ok 'Cài Hosting Bundle xong'; return @{ Ok = $true; Reboot = $false } }
        3010 { Write-Ok 'Cài Hosting Bundle xong (cần khởi động lại máy để hoàn tất)'; return @{ Ok = $true; Reboot = $true } }
        1641 { Write-Ok 'Cài Hosting Bundle xong, máy đang khởi động lại'; return @{ Ok = $true; Reboot = $true } }
        default { Write-Err "Cài Hosting Bundle lỗi, mã $code (log trong %TEMP%\dd_*.log)"; return @{ Ok = $false; Reboot = $false } }
    }
}

#endregion

#region ---------- IIS ----------

# -AspNet45: cài kèm ASP.NET 4.x (cho service .NET Framework)
function Install-IisFeature([switch]$AspNet45) {
    Write-Info 'Đang cài IIS (có thể mất vài phút)...'
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        # Windows Server
        $names = @('Web-Server', 'Web-AppInit')
        if ($AspNet45) { $names += 'Web-Asp-Net45' }
        $r = Install-WindowsFeature -Name $names -IncludeManagementTools
        Write-Log "Install-WindowsFeature $($names -join ',') => $($r.Success) restart=$($r.RestartNeeded)"
        return @{ Ok = [bool]$r.Success; Reboot = ([string]$r.RestartNeeded -eq 'Yes') }
    }
    # Windows 10/11
    $features = @('IIS-WebServerRole', 'IIS-WebServer', 'IIS-ManagementConsole', 'IIS-ApplicationInit')
    if ($AspNet45) { $features += 'IIS-ASPNET45' }
    $r = Enable-WindowsOptionalFeature -Online -All -NoRestart -FeatureName $features
    Write-Log "Enable-WindowsOptionalFeature $($features -join ',') => restart=$($r.RestartNeeded)"
    return @{ Ok = $true; Reboot = [bool]$r.RestartNeeded }
}

# Cài thêm ASP.NET 4.x khi IIS đã có sẵn nhưng thiếu thành phần này (service .NET Framework)
function Install-IisAspNet45 {
    Write-Info 'Đang cài ASP.NET 4.x cho IIS...'
    try {
        if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
            $r = Install-WindowsFeature -Name Web-Asp-Net45
            Write-Log "Install-WindowsFeature Web-Asp-Net45 => $($r.Success) restart=$($r.RestartNeeded)"
        }
        else {
            $r = Enable-WindowsOptionalFeature -Online -All -NoRestart -FeatureName IIS-ASPNET45
            Write-Log "Enable-WindowsOptionalFeature IIS-ASPNET45 => restart=$($r.RestartNeeded)"
        }
    }
    catch { Write-Err "Không cài được ASP.NET 4.x: $($_.Exception.Message)"; return $false }
    if (Test-AspNet45Installed) { Write-Ok 'Đã cài ASP.NET 4.x cho IIS'; return $true }
    Write-Err 'Cài ASP.NET 4.x cho IIS chưa thành công.'
    return $false
}

# Cài thêm Application Initialization khi IIS đã có sẵn nhưng thiếu thành phần này
function Install-IisAppInit {
    Write-Info 'Đang cài IIS Application Initialization...'
    try {
        if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
            $r = Install-WindowsFeature -Name Web-AppInit
            Write-Log "Install-WindowsFeature Web-AppInit => $($r.Success)"
        }
        else {
            $r = Enable-WindowsOptionalFeature -Online -All -NoRestart -FeatureName IIS-ApplicationInit
            Write-Log "Enable-WindowsOptionalFeature IIS-ApplicationInit => restart=$($r.RestartNeeded)"
        }
    }
    catch { Write-Warn "Không cài được Application Initialization: $($_.Exception.Message)"; return $false }
    if (Test-AppInitInstalled) { Write-Ok 'Đã cài Application Initialization'; return $true }
    Write-Warn 'Cài Application Initialization chưa thành công.'
    return $false
}

# Bật WAS + W3SVC, đặt khởi động tự động
function Start-IisServices {
    foreach ($n in 'WAS', 'W3SVC') {
        $svc = Get-Service $n -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ([string]$svc.StartType -ne 'Automatic') { Set-Service $n -StartupType Automatic }
        if ($svc.Status -ne 'Running') { Start-Service $n }
    }
    if (Test-IisServiceRunning) { Write-Ok 'Dịch vụ IIS đang chạy'; return $true }
    Write-Err 'Không khởi động được dịch vụ IIS (WAS/W3SVC).'
    return $false
}

function Restart-IisService {
    Write-Info 'Khởi động lại IIS để nạp ASP.NET Core Module...'
    & net stop was /y | Out-Null
    & net start w3svc | Out-Null
    Write-Ok 'Đã khởi động lại IIS'
}

#endregion

#region ---------- Cài tự động ----------

# Cài các thành phần còn thiếu. Thứ tự bắt buộc: IIS trước, Hosting Bundle sau
# (Hosting Bundle cài trước IIS thì không đăng ký được module cho IIS -> phải repair).
# $netFramework <> '': có service .NET Framework -> cài thêm ASP.NET 4.x cho IIS, kiểm tra phiên bản .NET Framework.
function Install-Prerequisites($channels, [string]$prereqDir, [string]$netFramework = '') {
    $channels = ConvertTo-RuntimeChannels $channels
    if ($channels.Count -eq 0 -and -not $netFramework) { Write-Err 'deploy-manifest.json thiếu defaults.aspNetCoreRuntime.'; return $false }
    $reboot = $false
    $st = Get-EnvironmentStatus $channels $netFramework

    if (-not $st.Iis) {
        $r = Install-IisFeature -AspNet45:([bool]$netFramework)
        if (-not $r.Ok -or -not (Test-IisInstalled)) { Write-Err 'Cài IIS không thành công.'; return $false }
        Write-Ok 'Đã cài IIS'
        $reboot = $reboot -or $r.Reboot
        $st = Get-EnvironmentStatus $channels $netFramework
    }
    if (-not $st.IisRunning) {
        if (-not (Start-IisServices)) { return $false }
    }
    if ($netFramework) {
        if (-not (Test-AspNet45Installed)) { if (-not (Install-IisAspNet45)) { return $false } }
        if (-not (Test-NetFxVersion $netFramework)) {
            # Không tự cài được (bộ cài lớn, cần khởi động lại) - Windows Server 2016 trở lên có sẵn 4.6.2
            Write-Err ".NET Framework trên máy (release $(Get-NetFxRelease)) cũ hơn $netFramework mà service cần."
            Write-Info 'Cài .NET Framework 4.8 từ https://dotnet.microsoft.com/download/dotnet-framework rồi khởi động lại máy.'
        }
    }

    $installed = $false
    # Mỗi kênh runtime còn thiếu: cài Hosting Bundle của kênh đó (gồm runtime + module IIS)
    foreach ($c in $st.MissingRuntimes) {
        $file = Get-HostingBundleInstaller $c $prereqDir
        if (-not $file) { return $false }
        $r = Invoke-HostingBundleSetup $file $false
        if (-not $r.Ok) { return $false }
        $reboot = $reboot -or $r.Reboot
        $installed = $true
    }

    if ($channels.Count -and -not (Test-AncmInstalled)) {
        # Đã có runtime mà thiếu module IIS -> repair Hosting Bundle kênh mới nhất để đăng ký lại module.
        # Bản tải về khác bản đang cài thì repair có thể lỗi -> cài đè (/install)
        $c = @($channels | Sort-Object { [version]$_ } -Descending)[0]
        $file = Get-HostingBundleInstaller $c $prereqDir
        if (-not $file) { return $false }
        $r = Invoke-HostingBundleSetup $file (Test-RuntimeInstalled $c)
        if (-not $r.Ok -and (Test-RuntimeInstalled $c)) { $r = Invoke-HostingBundleSetup $file $false }
        if (-not $r.Ok) { return $false }
        $reboot = $reboot -or $r.Reboot
        $installed = $true
    }
    if ($installed -and (Test-IisInstalled)) { Restart-IisService }

    $st = Get-EnvironmentStatus $channels $netFramework
    if ($st.Missing.Count -eq 0) { Write-Ok 'Môi trường đã đủ để chạy API' }
    else { Write-Err "Vẫn còn thiếu: $($st.Missing -join ', ')" }
    if (-not $st.AppInit -and $st.Iis) {
        Write-Warn 'Chưa có IIS Application Initialization: API có job chạy nền chỉ chạy sau request đầu tiên.'
        if (Read-YesNo 'Cài thêm Application Initialization?' $true) { [void](Install-IisAppInit) }
    }
    if ($reboot -or (Test-PendingReboot)) { Write-Warn 'Nên khởi động lại máy chủ để hoàn tất cài đặt.' }
    return ($st.Missing.Count -eq 0)
}

#endregion
