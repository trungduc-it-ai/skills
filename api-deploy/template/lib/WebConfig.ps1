# =====================================================================
#  WebConfig.ps1 - Cấu hình của service ASP.NET trên .NET Framework (runtime "netfx" trong manifest):
#    <appSettings><add key="..." value="..." /> và <connectionStrings><add name="..." connectionString="..." />
#    trong Web.config. Key đặt giống appsettings.json của ASP.NET Core để dùng chung 1 luồng:
#      "ConnectionStrings:<name>" -> connectionStrings, key khác -> appSettings (giữ nguyên key, kể cả dấu ':').
#  Các hàm *-Cfg* tự chọn Web.config hay appsettings.json (lib\JsonC.ps1) theo loại file.
#  Ghi file giữ nguyên định dạng, comment, thứ tự của Web.config gốc.
# =====================================================================

#region ---------- Loại service ----------

# Service chạy ASP.NET (.NET Framework 4.x, app pool CLR v4.0) thay vì ASP.NET Core Module
function Test-NetFxService($def) { return ([string]$def.runtime -eq 'netfx') }

# Tên file cấu hình trong thư mục cài đặt / gói của service
function Get-ServiceConfigName($def) {
    if (Test-NetFxService $def) { return 'Web.config' }
    return 'appsettings.json'
}

# managedRuntimeVersion của app pool: '' = No Managed Code (ASP.NET Core), v4.0 = .NET Framework 4.x
function Get-PoolRuntime($def) {
    if (Test-NetFxService $def) { return 'v4.0' }
    return ''
}

# Phiên bản .NET Framework cao nhất mà các service netfx cần ('' = không có service netfx).
# Duyệt thẳng, không bọc @(): PS 5.1 lỗi "Argument types do not match" với List chứa OrderedDictionary
function Get-NetFxRequirement($services) {
    $best = $null
    foreach ($s in $services) {
        if (-not $s -or -not (Test-NetFxService $s)) { continue }
        $v = [string]$s.netFramework
        if ($v -notmatch '^\d+\.\d+(\.\d+)?$') { $v = '4.5' }
        if (-not $best -or [version]$v -gt [version]$best) { $best = $v }
    }
    if ($best) { return $best }
    return ''
}

#endregion

#region ---------- Web.config ----------

function Read-WebConfigFile([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $x = New-Object System.Xml.XmlDocument
    $x.PreserveWhitespace = $true
    try { $x.LoadXml($text) }
    catch { throw "Lỗi đọc $path : $($_.Exception.Message)" }
    if (-not $x.DocumentElement -or $x.DocumentElement.LocalName -ne 'configuration') { throw "$path không phải Web.config (thiếu thẻ <configuration>)" }
    $nl = "`n"
    if ($text.Contains("`r`n")) { $nl = "`r`n" }
    return @{ Kind = 'webconfig'; Xml = $x; Path = $path; Bom = $bom; NL = $nl; Changed = $false }
}

function Save-WebConfigFile($doc, [string]$path = '') {
    if (-not $path) { $path = $doc.Path }
    $ws = New-Object System.Xml.XmlWriterSettings
    $ws.Encoding = New-Object System.Text.UTF8Encoding($doc.Bom)
    $ws.NewLineChars = $doc.NL
    $ws.NewLineHandling = [System.Xml.NewLineHandling]::Replace
    $ms = New-Object System.IO.MemoryStream
    $w = [System.Xml.XmlWriter]::Create($ms, $ws)
    try { $doc.Xml.Save($w) } finally { $w.Dispose() }
    $bytes = $ms.ToArray()
    # Kiểm tra lại cú pháp trước khi ghi để không bao giờ ghi ra file hỏng
    $check = New-Object System.Xml.XmlDocument
    $check.LoadXml([System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF))
    [System.IO.File]::WriteAllBytes($path, $bytes)
    $doc.Changed = $false
}

# "ConnectionStrings:X" -> connectionStrings/add[@name=X]/@connectionString; key khác -> appSettings/add[@key]/@value
function WcSplitKey([string]$key) {
    if ($key -match '^(?i)ConnectionStrings:(.+)$') { return @{ Section = 'connectionStrings'; Id = 'name'; Name = $Matches[1]; Attr = 'connectionString' } }
    return @{ Section = 'appSettings'; Id = 'key'; Name = $key; Attr = 'value' }
}

# Phần tử con trực tiếp theo tên (không dùng XPath để không vướng xmlns của Web.config đời cũ)
function WcChild($parent, [string]$localName) {
    foreach ($n in $parent.ChildNodes) { if ($n.NodeType -eq 'Element' -and $n.LocalName -eq $localName) { return $n } }
    return $null
}

# Thẻ <add> đang có hiệu lực của key (tính cả <remove> / <clear> phía sau). Key không phân biệt hoa thường như .NET
function WcFindAdd($doc, $k) {
    $sec = WcChild $doc.Xml.DocumentElement $k.Section
    if (-not $sec) { return $null }
    $found = $null
    foreach ($n in $sec.ChildNodes) {
        if ($n.NodeType -ne 'Element') { continue }
        if ($n.LocalName -eq 'clear') { $found = $null; continue }
        if ($n.GetAttribute($k.Id) -ine $k.Name) { continue }
        if ($n.LocalName -eq 'add') { $found = $n }
        elseif ($n.LocalName -eq 'remove') { $found = $null }
    }
    return $found
}

# Khoảng trắng đầu dòng ngay trước node ($null nếu node không bắt đầu dòng mới)
function WcIndentOf($node) {
    $p = $node.PreviousSibling
    if ($p -and ($p.NodeType -eq 'Whitespace' -or $p.NodeType -eq 'SignificantWhitespace')) {
        $t = $p.Value
        $i = $t.LastIndexOf("`n")
        if ($i -ge 0) { return $t.Substring($i + 1) }
    }
    return $null
}

# Thêm phần tử con vào cuối (sau phần tử con cuối cùng), thụt lề theo các phần tử anh em
function WcAppendChild($doc, $parent, $child) {
    $nl = $doc.NL
    $parentIndent = WcIndentOf $parent
    if ($null -eq $parentIndent) { $parentIndent = '' }
    $lastEl = $null
    foreach ($n in $parent.ChildNodes) { if ($n.NodeType -eq 'Element') { $lastEl = $n } }
    $childIndent = $null
    if ($lastEl) { $childIndent = WcIndentOf $lastEl }
    if ($null -eq $childIndent) { $childIndent = $parentIndent + '  ' }
    $x = $doc.Xml
    if ($lastEl) {
        $ws = $x.CreateWhitespace($nl + $childIndent)
        [void]$parent.InsertAfter($ws, $lastEl)
        [void]$parent.InsertAfter($child, $ws)
        return
    }
    # Chưa có phần tử con (section rỗng, có thể chỉ có comment): thêm vào cuối, ngay trước thẻ đóng
    $last = $parent.LastChild
    if ($last -and $last.NodeType -eq 'Whitespace') { [void]$parent.RemoveChild($last) }
    [void]$parent.AppendChild($x.CreateWhitespace($nl + $childIndent))
    [void]$parent.AppendChild($child)
    [void]$parent.AppendChild($x.CreateWhitespace($nl + $parentIndent))
}

# Section <appSettings> / <connectionStrings>: chưa có thì tạo, đặt sau <configSections> (bắt buộc đứng đầu)
function WcEnsureSection($doc, [string]$name) {
    $root = $doc.Xml.DocumentElement
    $sec = WcChild $root $name
    if ($sec) { return $sec }
    $sec = $doc.Xml.CreateElement($name, $root.NamespaceURI)
    $after = $null
    foreach ($n in 'configSections', 'appSettings', 'connectionStrings') { $c = WcChild $root $n; if ($c) { $after = $c } }
    $firstEl = $null
    foreach ($n in $root.ChildNodes) { if ($n.NodeType -eq 'Element') { $firstEl = $n; break } }
    $indent = '  '
    if ($firstEl) { $i = WcIndentOf $firstEl; if ($null -ne $i) { $indent = $i } }
    $ws = $doc.Xml.CreateWhitespace($doc.NL + $indent)
    if ($after) {
        [void]$root.InsertAfter($ws, $after)
        [void]$root.InsertAfter($sec, $ws)
    }
    elseif ($firstEl) {
        [void]$root.InsertBefore($sec, $firstEl)
        [void]$root.InsertBefore($doc.Xml.CreateWhitespace($doc.NL + $indent), $firstEl)
    }
    else {
        [void]$root.AppendChild($ws)
        [void]$root.AppendChild($sec)
        [void]$root.AppendChild($doc.Xml.CreateWhitespace($doc.NL))
    }
    return $sec
}

function Get-WebConfigValue($doc, [string]$key) {
    $k = WcSplitKey $key
    $n = WcFindAdd $doc $k
    if ($n -and $n.HasAttribute($k.Attr)) { return $n.GetAttribute($k.Attr) }
    return $null
}

function Test-WebConfigPath($doc, [string]$key) { return ($null -ne (WcFindAdd $doc (WcSplitKey $key))) }

# Ghi giá trị (chuỗi; bool -> true/false). Trả về $true nếu có thay đổi
function Set-WebConfigValue($doc, [string]$key, $value) {
    $k = WcSplitKey $key
    $v = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } else { [string]$value }
    $n = WcFindAdd $doc $k
    if ($n) {
        if ($n.HasAttribute($k.Attr) -and $n.GetAttribute($k.Attr) -ceq $v) { return $false }
        $n.SetAttribute($k.Attr, $v)
        $doc.Changed = $true
        return $true
    }
    $sec = WcEnsureSection $doc $k.Section
    $el = $doc.Xml.CreateElement('add', $sec.NamespaceURI)
    $el.SetAttribute($k.Id, $k.Name)
    $el.SetAttribute($k.Attr, $v)
    WcAppendChild $doc $sec $el
    $doc.Changed = $true
    return $true
}

function Remove-WebConfigValue($doc, [string]$key) {
    $n = WcFindAdd $doc (WcSplitKey $key)
    if (-not $n) { return $false }
    $p = $n.PreviousSibling
    if ($p -and $p.NodeType -eq 'Whitespace') { [void]$n.ParentNode.RemoveChild($p) }
    [void]$n.ParentNode.RemoveChild($n)
    $doc.Changed = $true
    return $true
}

# Tên các key đang có hiệu lực trong 1 section, theo thứ tự trong file
function Get-WebConfigKeys($doc, [string]$section) {
    $isConn = ($section -ieq 'connectionStrings')
    $sec = WcChild $doc.Xml.DocumentElement $(if ($isConn) { 'connectionStrings' } else { 'appSettings' })
    $names = New-Object System.Collections.Generic.List[string]
    if (-not $sec) { return , $names }
    $id = if ($isConn) { 'name' } else { 'key' }
    foreach ($n in $sec.ChildNodes) {
        if ($n.NodeType -ne 'Element') { continue }
        if ($n.LocalName -eq 'clear') { $names.Clear(); continue }
        $name = $n.GetAttribute($id)
        $idx = -1
        for ($i = 0; $i -lt $names.Count; $i++) { if ($names[$i] -ieq $name) { $idx = $i } }
        if ($n.LocalName -eq 'add' -and $idx -lt 0) { $names.Add($name) }
        elseif ($n.LocalName -eq 'remove' -and $idx -ge 0) { $names.RemoveAt($idx) }
    }
    return , $names
}

# Cập nhật bản mới: lấy Web.config của gói ($newDoc - binding redirect, module... theo bản build mới) và chép
# vào đó mọi giá trị appSettings / connectionStrings đang dùng ($oldDoc). Key chỉ có ở bản cũ cũng được giữ.
# Trả về danh sách key mới chỉ có trong gói (cần kiểm tra giá trị).
function Merge-WebConfigValues($newDoc, $oldDoc) {
    $added = New-Object System.Collections.Generic.List[string]
    $oldKeys = @{}
    foreach ($pair in @(@('connectionStrings', 'ConnectionStrings:'), @('appSettings', ''))) {
        foreach ($name in (Get-WebConfigKeys $oldDoc $pair[0])) {
            $key = $pair[1] + $name
            $oldKeys[$key.ToLowerInvariant()] = 1
            [void](Set-WebConfigValue $newDoc $key (Get-WebConfigValue $oldDoc $key))
        }
    }
    foreach ($pair in @(@('connectionStrings', 'ConnectionStrings:'), @('appSettings', ''))) {
        foreach ($name in (Get-WebConfigKeys $newDoc $pair[0])) {
            $key = $pair[1] + $name
            if (-not $oldKeys.ContainsKey($key.ToLowerInvariant())) { $added.Add($key) }
        }
    }
    return , $added
}

# Comment chứa thẻ <add ...> = cấu hình cũ bị comment lại (thường còn nguyên mật khẩu / chuỗi kết nối thật)
function Get-WebConfigCommentedEntries($doc) {
    return , @($doc.Xml.SelectNodes('//comment()') | Where-Object { $_.Value -match '<\s*add\s' })
}

# Xoá các comment cấu hình cũ khỏi Web.config của gói (giữ comment mô tả). Trả về số comment đã xoá
function Remove-WebConfigCommentedEntries($doc) {
    $n = 0
    foreach ($c in (Get-WebConfigCommentedEntries $doc)) {
        $p = $c.PreviousSibling
        if ($p -and $p.NodeType -eq 'Whitespace') { [void]$c.ParentNode.RemoveChild($p) }
        [void]$c.ParentNode.RemoveChild($c)
        $n++
    }
    if ($n) { $doc.Changed = $true }
    return $n
}

#endregion

#region ---------- Chọn loại file (Web.config / appsettings.json) ----------

function Test-WebConfigDoc($doc) { return ($doc -is [hashtable] -and $doc['Kind'] -eq 'webconfig') }

function Read-CfgFile([string]$path) {
    if ([System.IO.Path]::GetExtension($path) -ieq '.config') { return (Read-WebConfigFile $path) }
    return (Read-JsonCFile $path)
}

function Save-CfgFile($doc, [string]$path = '') {
    if (Test-WebConfigDoc $doc) { Save-WebConfigFile $doc $path } else { Save-JsonCFile $doc $path }
}

function Get-CfgValue($doc, [string]$key) {
    if (Test-WebConfigDoc $doc) { return (Get-WebConfigValue $doc $key) }
    return (Get-JsonCValue $doc $key)
}

function Test-CfgPath($doc, [string]$key) {
    if (Test-WebConfigDoc $doc) { return (Test-WebConfigPath $doc $key) }
    return (Test-JsonCPath $doc $key)
}

function Set-CfgValue($doc, [string]$key, $value) {
    if (Test-WebConfigDoc $doc) { return (Set-WebConfigValue $doc $key $value) }
    return (Set-JsonCValue $doc $key $value)
}

function Remove-CfgValue($doc, [string]$key) {
    if (Test-WebConfigDoc $doc) { return (Remove-WebConfigValue $doc $key) }
    return (Remove-JsonCValue $doc $key)
}

#endregion
