<#
.SYNOPSIS
    Build các API service thành gói cài đặt Deploy\packages\<Service>: dotnet publish (ASP.NET Core) hoặc
    MSBuild publish (ASP.NET .NET Framework, runtime "netfx" - cần Visual Studio / Build Tools có MSBuild),
    tuỳ chọn nén cả thư mục Deploy thành 1 file zip để copy sang máy chủ.

.EXAMPLE
    .\Build-Package.ps1                                   # chọn service bằng menu
    .\Build-Package.ps1 -All -Zip
    .\Build-Package.ps1 -Services CanLamSang.Service,Bank.Service -Zip
    .\Build-Package.ps1 -All -SelfContained               # máy chủ không cần cài .NET runtime
    .\Build-Package.ps1 -All -Zip -IncludePrereq          # kèm bộ cài Hosting Bundle cho máy chủ không có internet

    Đường dẫn "project" trong deploy-manifest.json tính từ defaults.repoRoot (tuyệt đối, hoặc tương đối
    với thư mục chứa script này). Không khai báo repoRoot thì dùng thư mục cha của thư mục Deploy.
#>
param(
    [string[]]$Services,
    [switch]$All,
    [string]$Configuration = 'Release',
    [switch]$SelfContained,
    [switch]$Zip,
    [switch]$IncludePrereq,
    [switch]$KeepSecrets      # giữ nguyên mật khẩu / token / chuỗi kết nối của máy dev trong appsettings.json / Web.config của gói
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = $PSScriptRoot
. (Join-Path $Root 'lib\JsonC.ps1')
. (Join-Path $Root 'lib\Common.ps1')
. (Join-Path $Root 'lib\Prereq.ps1')
. (Join-Path $Root 'lib\WebConfig.ps1')
Set-ConsoleUnicodeFont

# Xoá trắng giá trị bí mật (ConnectionStrings + tham số type secret/encrypted/token) trong appsettings.json /
# Web.config của gói: máy chủ cài mới phải nhập giá trị thật, gói zip không mang mật khẩu của máy dev.
# Cập nhật bản mới không bị ảnh hưởng vì công cụ giữ giá trị đang dùng, không lấy giá trị trong gói.
function Clear-PackageSecrets($def, [string]$file) {
    if (-not (Test-Path $file)) { return 0 }
    $doc = Read-CfgFile $file
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($def.connections)) { if ($c) { $keys.Add("ConnectionStrings:$($c.name)") } }
    $all = @($def.settings) + @($def.controllers | ForEach-Object { $_.settings })
    foreach ($s in $all) { if ($s -and $s.type -in 'secret', 'encrypted', 'token') { $keys.Add([string]$s.key) } }
    $n = 0
    foreach ($k in ($keys | Select-Object -Unique)) {
        if (Test-WebConfigDoc $doc) {
            if (-not [string]::IsNullOrEmpty((Get-WebConfigValue $doc $k))) { [void](Set-WebConfigValue $doc $k ''); $n++ }
            continue
        }
        $node = Get-JsonCNode $doc $k
        if ($node -and $node.Kind -eq 'string' -and $node.Value -ne '') { [void](Set-JsonCValue $doc $k ''); $n++ }
    }
    if (Test-WebConfigDoc $doc) {
        # Web.config thường còn các khối <add .../> cũ bị comment lại, kèm mật khẩu / chuỗi kết nối thật
        $nc = Remove-WebConfigCommentedEntries $doc
        if ($nc) { Write-Ok "Bỏ $nc đoạn cấu hình cũ bị comment trong Web.config của gói (có thể chứa mật khẩu cũ)" }
        if ($n -or $nc) { Save-CfgFile $doc }
        return $n
    }
    if ($n) { Save-CfgFile $doc }
    return $n
}

# MSBuild.exe mới nhất (Visual Studio / Build Tools) qua vswhere - cần cho service .NET Framework
function Find-MsBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $p = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        if ($p -and (Test-Path $p)) { return $p }
    }
    $cmd = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# File .sln trong repoRoot có chứa project (để restore packages.config vào <thư mục sln>\packages)
function Find-SolutionFor([string]$proj) {
    $full = [System.IO.Path]::GetFullPath($proj)
    foreach ($sln in @(Get-ChildItem $RepoRoot -Filter *.sln -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
        $text = [System.IO.File]::ReadAllText($sln.FullName)
        foreach ($m in [regex]::Matches($text, '"([^"]+\.csproj)"')) {
            if ([System.IO.Path]::GetFullPath((Join-Path $sln.DirectoryName $m.Groups[1].Value)) -ieq $full) { return $sln.FullName }
        }
    }
    return $null
}

# ASP.NET (.NET Framework): restore NuGet theo solution, MSBuild publish (FileSystem) vào $out, áp dụng Web.<Configuration>.config.
# DeployTarget=WebPublish: thiếu thì DeployOnBuild không có publish profile chỉ đóng gói Web Deploy, không ra thư mục.
# Output của MSBuild đưa thẳng ra màn hình (Out-Host) để không lẫn vào giá trị trả về của hàm.
function Invoke-NetFxPublish([string]$proj, [string]$out) {
    $msb = Find-MsBuild
    if (-not $msb) { Write-Err 'Không tìm thấy MSBuild (cài Visual Studio hoặc Build Tools for Visual Studio có workload ASP.NET).'; return $false }
    Write-Info "MSBuild: $msb"
    $sln = Find-SolutionFor $proj
    if ($sln) {
        & $msb $sln '/t:Restore' '/p:RestorePackagesConfig=true' "/p:Configuration=$Configuration" '/v:minimal' '/nologo' | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Warn 'Restore NuGet lỗi - thử build với các package đang có.' }
    }
    & $msb $proj "/p:Configuration=$Configuration" '/p:DeployOnBuild=true' '/p:DeployTarget=WebPublish' '/p:WebPublishMethod=FileSystem' "/p:PublishUrl=$out" '/p:DeleteExistingFiles=true' '/v:minimal' '/nologo' | Out-Host
    return ($LASTEXITCODE -eq 0)
}

$manifest = Get-Content (Join-Path $Root 'deploy-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$defs = @($manifest.services)
$RepoRoot = Split-Path $Root -Parent
if ($manifest.defaults.repoRoot) {
    $rr = [string]$manifest.defaults.repoRoot
    if (-not [System.IO.Path]::IsPathRooted($rr)) { $rr = Join-Path $Root $rr }
    $RepoRoot = [System.IO.Path]::GetFullPath($rr)
}
if (-not (Test-Path $RepoRoot)) { throw "Không thấy thư mục mã nguồn $RepoRoot (defaults.repoRoot trong deploy-manifest.json)." }
$toolTitle = if ($manifest.defaults.toolTitle) { [string]$manifest.defaults.toolTitle } else { 'HIS API' }
$zipPrefix = if ($manifest.defaults.packageName) { [string]$manifest.defaults.packageName } else { 'HIS_API_Deploy' }

Write-Title "$toolTitle - BUILD GÓI CÀI ĐẶT"
Write-Info "Mã nguồn: $RepoRoot"
if ($All) { $selected = $defs }
elseif ($Services) {
    # Gọi qua powershell -File / .bat thì "A,B" đến dưới dạng 1 chuỗi
    $Services = @($Services | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $selected = @($defs | Where-Object { $Services -contains $_.name })
    $unknown = @($Services | Where-Object { $n = $_; -not ($defs | Where-Object { $_.name -eq $n }) })
    if ($unknown.Count) { throw "Không có trong deploy-manifest.json: $($unknown -join ', ')" }
}
else {
    for ($i = 0; $i -lt $defs.Count; $i++) {
        $pkg = Join-Path $Root "packages\$($defs[$i].name)\.package-info.json"
        $last = if (Test-Path $pkg) { ' (gói hiện có: ' + (Get-Content $pkg -Raw -Encoding UTF8 | ConvertFrom-Json).builtAt + ')' } else { '' }
        Write-Host ('   {0,-4}{1,-22}{2}{3}' -f ($i + 1), $defs[$i].name, $defs[$i].title, $last)
    }
    while ($true) {
        $in = Read-Value 'Chọn service cần build (vd 1,3,5-7 | A = tất cả)' 'A'
        if ($in -match '^(?i)a$') { $selected = $defs; break }
        $nums = ConvertFrom-NumberList $in $defs.Count
        if ($nums -and $nums.Count) { $selected = @($nums | ForEach-Object { $defs[$_ - 1] }); break }
        Write-Warn 'Lựa chọn không hợp lệ.'
    }
    $hasCoreSel = @($selected | Where-Object { -not (Test-NetFxService $_) }).Count -gt 0
    if ($hasCoreSel) { $SelfContained = Read-YesNo 'Build dạng self-contained (máy chủ không cần cài .NET runtime, gói nặng hơn)?' $false }
    $Zip = Read-YesNo 'Nén thư mục Deploy thành file zip để copy sang máy chủ?' $true
    if ($Zip -and $hasCoreSel) { $IncludePrereq = Read-YesNo 'Kèm bộ cài ASP.NET Core Hosting Bundle (cho máy chủ không có internet, thêm ~65 MB)?' $false }
}

# dotnet SDK chỉ cần khi build service ASP.NET Core; service .NET Framework build bằng MSBuild
if (@($selected | Where-Object { -not (Test-NetFxService $_) }).Count -and -not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'Không tìm thấy dotnet SDK trên máy này.' }

$results = New-Object System.Collections.Generic.List[object]
foreach ($def in $selected) {
    Write-Step "Build $($def.name)"
    $proj = Join-Path $RepoRoot $def.project
    $out = Join-Path $Root "packages\$($def.name)"
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }

    if (Test-NetFxService $def) {
        $built = Invoke-NetFxPublish $proj $out
    }
    else {
        $dnArgs = @('publish', $proj, '-c', $Configuration, '-o', $out, '--nologo', '-v', 'minimal')
        if ($SelfContained) { $dnArgs += @('-r', 'win-x64', '--self-contained', 'true') }
        & dotnet @dnArgs
        $built = ($LASTEXITCODE -eq 0)
    }
    if (-not $built -or -not (Test-Path (Join-Path $out $def.dll))) {
        Write-Err "Build $($def.name) lỗi"
        $results.Add([pscustomobject]@{ Service = $def.name; Result = 'LỖI'; Version = '' })
        if (Test-Path $out) { Remove-Item $out -Recurse -Force }
        continue
    }

    # Máy chủ chạy môi trường Production, không cần file Development
    Remove-Item (Join-Path $out 'appsettings.Development.json') -ErrorAction SilentlyContinue
    if (-not $KeepSecrets) {
        $cfgName = Get-ServiceConfigName $def
        $cleared = Clear-PackageSecrets $def (Join-Path $out $cfgName)
        if ($cleared) { Write-Ok "Xoá trắng $cleared giá trị bí mật trong $cfgName của gói (nhập trên máy chủ khi cài)" }
    }
    $ver = (Get-Item (Join-Path $out $def.dll)).VersionInfo.FileVersion
    [ordered]@{
        service       = $def.name
        version       = $ver
        builtAt       = ('{0:yyyy-MM-dd HH:mm}' -f (Get-Date))
        builtOn       = $env:COMPUTERNAME
        configuration = $Configuration
        selfContained = [bool]$SelfContained -and -not (Test-NetFxService $def)
    } | ConvertTo-Json | Set-Content (Join-Path $out '.package-info.json') -Encoding UTF8
    Write-Ok "Gói: $out (v$ver)"
    $results.Add([pscustomobject]@{ Service = $def.name; Result = 'OK'; Version = $ver })
}

Write-Step 'Kết quả'
$results | Format-Table -AutoSize | Out-Host

if ($IncludePrereq) {
    Write-Step 'Bộ cài ASP.NET Core Hosting Bundle'
    $channels = ConvertTo-RuntimeChannels (@([string]$manifest.defaults.aspNetCoreRuntime) + @($defs | ForEach-Object { [string]$_.runtime }))
    foreach ($channel in $channels) {
        $exe = Get-HostingBundleInstaller $channel (Join-Path $Root 'prereq')
        if ($exe) { Write-Ok "Kèm trong gói: prereq\$(Split-Path $exe -Leaf)" }
        else { Write-Warn "Không lấy được bộ cài $channel - gói vẫn tạo, máy chủ cần internet hoặc bỏ bộ cài vào prereq bằng tay." }
    }
}

if ($Zip -and @($results | Where-Object { $_.Result -eq 'OK' }).Count -gt 0) {
    $dist = Join-Path $Root 'dist'
    New-Item -ItemType Directory -Force $dist | Out-Null
    $zipFile = Join-Path $dist ('{0}_{1:yyyyMMdd_HHmm}.zip' -f $zipPrefix, (Get-Date))
    $items = Get-ChildItem $Root -Force | Where-Object { $_.Name -notin 'dist', 'logs', '_backup', 'AP_DUNG_PROJECT_KHAC.md' } | ForEach-Object { $_.FullName }
    Compress-Archive -Path $items -DestinationPath $zipFile -CompressionLevel Optimal -Force
    Write-Ok "File zip: $zipFile ($([Math]::Round((Get-Item $zipFile).Length / 1MB, 1)) MB)"
    Write-Info 'Copy file zip sang máy chủ, giải nén rồi chạy Deploy.bat.'
}

if (@($results | Where-Object { $_.Result -ne 'OK' }).Count -gt 0) { exit 1 }
