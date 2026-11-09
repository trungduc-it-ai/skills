# =====================================================================
#  JsonC.ps1 - Đọc / sửa file appsettings.json (JSON có comment //, /* */)
#  mà KHÔNG làm mất comment, thứ tự key, định dạng của file gốc.
#
#  Đường dẫn key theo kiểu IConfiguration của ASP.NET Core: "Section:Key",
#  phần tử mảng dùng chỉ số: "Auth:Clients:0:ClientId". So khớp key không
#  phân biệt hoa thường (giống IConfiguration); key trùng thì lấy key cuối.
#
#  Hàm dùng bên ngoài:
#    Read-JsonCFile / New-JsonCDoc / Save-JsonCFile
#    Get-JsonCValue / Test-JsonCPath / Get-JsonCNode / Get-JsonCKeys
#    Set-JsonCValue / Remove-JsonCValue / Merge-JsonCMissing
# =====================================================================

$script:JcStringRx = New-Object System.Text.RegularExpressions.Regex('\G"((?:[^"\\]|\\.)*)"', [System.Text.RegularExpressions.RegexOptions]::Singleline)
$script:JcNumberRx = New-Object System.Text.RegularExpressions.Regex('\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?')
$script:JcText = ''
$script:JcPos = 0

#region ---------- Parser ----------

function JcFail([string]$message) {
    $t = $script:JcText
    $p = [Math]::Min($script:JcPos, $t.Length)
    $line = 1
    for ($i = 0; $i -lt $p; $i++) { if ($t[$i] -eq "`n") { $line++ } }
    throw "JSON không hợp lệ (dòng $line): $message"
}

function JcSkip {
    $t = $script:JcText; $n = $t.Length; $p = $script:JcPos
    while ($p -lt $n) {
        $c = $t[$p]
        if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`r" -or $c -eq "`n" -or $c -eq [char]0xFEFF) { $p++; continue }
        if ($c -eq '/' -and ($p + 1) -lt $n) {
            $c2 = $t[$p + 1]
            if ($c2 -eq '/') {
                $e = $t.IndexOf("`n", $p)
                if ($e -lt 0) { $p = $n } else { $p = $e + 1 }
                continue
            }
            if ($c2 -eq '*') {
                $e = $t.IndexOf('*/', $p + 2)
                if ($e -lt 0) { $script:JcPos = $p; JcFail 'comment /* chưa đóng' }
                $p = $e + 2
                continue
            }
        }
        break
    }
    $script:JcPos = $p
}

function JcUnescape([string]$s) {
    if ($s.IndexOf('\') -lt 0) { return $s }
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $s.Length
    while ($i -lt $n) {
        $c = $s[$i]
        if ($c -ne '\' -or ($i + 1) -ge $n) { [void]$sb.Append($c); $i++; continue }
        $e = $s[$i + 1]
        switch -CaseSensitive ([string]$e) {
            'n' { [void]$sb.Append("`n") }
            'r' { [void]$sb.Append("`r") }
            't' { [void]$sb.Append("`t") }
            'b' { [void]$sb.Append([char]8) }
            'f' { [void]$sb.Append([char]12) }
            'u' {
                [void]$sb.Append([char][Convert]::ToInt32($s.Substring($i + 2, 4), 16))
                $i += 4
            }
            default { [void]$sb.Append($e) }
        }
        $i += 2
    }
    return $sb.ToString()
}

function JcReadString {
    $m = $script:JcStringRx.Match($script:JcText, $script:JcPos)
    if (-not $m.Success) { JcFail 'chuỗi không hợp lệ' }
    $script:JcPos += $m.Length
    return (JcUnescape $m.Groups[1].Value)
}

function JcParseValue {
    JcSkip
    $t = $script:JcText; $p = $script:JcPos
    if ($p -ge $t.Length) { JcFail 'thiếu giá trị' }
    $c = $t[$p]

    if ($c -eq '{') {
        $node = @{ Kind = 'object'; Start = $p; End = 0; Members = (New-Object System.Collections.Generic.List[object]) }
        $script:JcPos = $p + 1
        while ($true) {
            JcSkip
            if ($script:JcPos -ge $t.Length) { JcFail 'thiếu dấu }' }
            $c = $t[$script:JcPos]
            if ($c -eq '}') { $script:JcPos++; break }
            if ($c -ne '"') { JcFail 'cần tên key trong dấu "' }
            $keyStart = $script:JcPos
            $key = JcReadString
            JcSkip
            if ($script:JcPos -ge $t.Length -or $t[$script:JcPos] -ne ':') { JcFail "thiếu dấu : sau key '$key'" }
            $script:JcPos++
            $val = JcParseValue
            $node.Members.Add(@{ Key = $key; KeyStart = $keyStart; Value = $val })
            JcSkip
            if ($script:JcPos -ge $t.Length) { JcFail 'thiếu dấu }' }
            $c = $t[$script:JcPos]
            if ($c -eq ',') { $script:JcPos++; continue }
            if ($c -eq '}') { $script:JcPos++; break }
            JcFail "cần dấu , hoặc } sau key '$key'"
        }
        $node.End = $script:JcPos
        return $node
    }

    if ($c -eq '[') {
        $node = @{ Kind = 'array'; Start = $p; End = 0; Items = (New-Object System.Collections.Generic.List[object]) }
        $script:JcPos = $p + 1
        while ($true) {
            JcSkip
            if ($script:JcPos -ge $t.Length) { JcFail 'thiếu dấu ]' }
            if ($t[$script:JcPos] -eq ']') { $script:JcPos++; break }
            $node.Items.Add((JcParseValue))
            JcSkip
            if ($script:JcPos -ge $t.Length) { JcFail 'thiếu dấu ]' }
            $c = $t[$script:JcPos]
            if ($c -eq ',') { $script:JcPos++; continue }
            if ($c -eq ']') { $script:JcPos++; break }
            JcFail 'cần dấu , hoặc ]'
        }
        $node.End = $script:JcPos
        return $node
    }

    if ($c -eq '"') {
        $v = JcReadString
        return @{ Kind = 'string'; Start = $p; End = $script:JcPos; Value = $v }
    }

    foreach ($lit in 'true', 'false', 'null') {
        if ((($p + $lit.Length) -le $t.Length) -and $t.Substring($p, $lit.Length) -ceq $lit) {
            $script:JcPos = $p + $lit.Length
            $v = $null
            if ($lit -eq 'true') { $v = $true } elseif ($lit -eq 'false') { $v = $false }
            return @{ Kind = $lit; Start = $p; End = $script:JcPos; Value = $v }
        }
    }

    $m = $script:JcNumberRx.Match($t, $p)
    if ($m.Success -and $m.Length -gt 0) {
        $script:JcPos = $p + $m.Length
        return @{ Kind = 'number'; Start = $p; End = $script:JcPos; Value = $m.Value }
    }

    JcFail "ký tự không hợp lệ '$c'"
}

function JcParse([string]$text) {
    $script:JcText = $text
    $script:JcPos = 0
    $rootNode = JcParseValue
    JcSkip
    if ($script:JcPos -lt $text.Length) { JcFail 'còn nội dung thừa sau JSON' }
    if ($rootNode.Kind -ne 'object') { throw 'appsettings phải là 1 object JSON { ... }' }
    return $rootNode
}

#endregion

#region ---------- Tiện ích văn bản ----------

function JcQuote([string]$s) {
    if ($null -eq $s) { return 'null' }
    $s = $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    $s = [regex]::Replace($s, '[\x00-\x1f]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    return '"' + $s + '"'
}

# Chuyển giá trị PowerShell thành JSON thô; $kindHint = kiểu của giá trị cũ (giữ đúng kiểu khi ghi đè)
function JcToRaw($value, [string]$kindHint) {
    if ($null -eq $value) { return 'null' }
    if ($value -is [bool]) { if ($value) { return 'true' } else { return 'false' } }
    if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
        return ([string]$value).Replace(',', '.')
    }
    $s = [string]$value
    if ($kindHint -eq 'number' -and $s -match '^-?\d+(\.\d+)?$') { return $s }
    if (($kindHint -eq 'true' -or $kindHint -eq 'false') -and $s -match '^(?i:true|false)$') { return $s.ToLowerInvariant() }
    return (JcQuote $s)
}

function JcLineStart([string]$t, [int]$pos) {
    if ($pos -le 0) { return 0 }
    return ($t.LastIndexOf("`n", $pos - 1) + 1)
}

function JcLineIndent([string]$t, [int]$pos) {
    $ls = JcLineStart $t $pos
    $i = $ls
    while ($i -lt $t.Length -and ($t[$i] -eq ' ' -or $t[$i] -eq "`t")) { $i++ }
    return $t.Substring($ls, $i - $ls)
}

# Bỏ qua khoảng trắng + comment từ vị trí $pos, trả về vị trí ký tự có nghĩa tiếp theo
function JcSkipFrom([string]$t, [int]$pos) {
    $saveT = $script:JcText; $saveP = $script:JcPos
    $script:JcText = $t; $script:JcPos = $pos
    JcSkip
    $r = $script:JcPos
    $script:JcText = $saveT; $script:JcPos = $saveP
    return $r
}

function JcSplitPath([string]$path) {
    return , ([string[]]($path -split ':'))
}

#endregion

#region ---------- Document ----------

function New-JsonCDoc([string]$text, [string]$path = '', [bool]$bom = $false) {
    if ([string]::IsNullOrWhiteSpace($text)) { $text = "{`r`n}`r`n" }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1); $bom = $true }
    $nl = "`n"
    if ($text.Contains("`r`n")) { $nl = "`r`n" }
    $doc = @{ Text = $text; Root = $null; Bom = $bom; NL = $nl; Path = $path; Changed = $false }
    $doc.Root = JcParse $text
    return $doc
}

function Read-JsonCFile([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    try {
        return (New-JsonCDoc $text $path $bom)
    }
    catch {
        throw "Lỗi đọc $path : $($_.Exception.Message)"
    }
}

function Save-JsonCFile($doc, [string]$path = '') {
    if (-not $path) { $path = $doc.Path }
    # Kiểm tra lại cú pháp trước khi ghi để không bao giờ ghi ra file hỏng
    [void](JcParse $doc.Text)
    $enc = New-Object System.Text.UTF8Encoding($doc.Bom)
    [System.IO.File]::WriteAllText($path, $doc.Text, $enc)
    $doc.Changed = $false
}

function JcReplace($doc, [int]$start, [int]$end, [string]$newText) {
    $doc.Text = $doc.Text.Substring(0, $start) + $newText + $doc.Text.Substring($end)
}

function JcReparse($doc) {
    $doc.Root = JcParse $doc.Text
    $doc.Changed = $true
}

#endregion

#region ---------- Tìm node ----------

function JcFindMember($objNode, [string]$key) {
    $found = $null
    foreach ($m in $objNode.Members) { if ($m.Key -ieq $key) { $found = $m } }
    return $found
}

# Trả về @{ Node; Depth; Parent; Member } - Depth = số segment đã đi được
function JcWalk($doc, [string[]]$segs) {
    $node = $doc.Root; $parent = $null; $member = $null
    for ($i = 0; $i -lt $segs.Length; $i++) {
        $s = $segs[$i]
        $next = $null; $nextMember = $null
        if ($node.Kind -eq 'object') {
            $nextMember = JcFindMember $node $s
            if ($nextMember) { $next = $nextMember.Value }
        }
        elseif ($node.Kind -eq 'array' -and $s -match '^\d+$') {
            $idx = [int]$s
            if ($idx -lt $node.Items.Count) { $next = $node.Items[$idx] }
        }
        if ($null -eq $next) { return @{ Node = $node; Depth = $i; Parent = $parent; Member = $member } }
        $parent = $node; $member = $nextMember; $node = $next
    }
    return @{ Node = $node; Depth = $segs.Length; Parent = $parent; Member = $member }
}

function Get-JsonCNode($doc, [string]$path) {
    $segs = JcSplitPath $path
    $w = JcWalk $doc $segs
    if ($w.Depth -lt $segs.Length) { return $null }
    return $w.Node
}

function Test-JsonCPath($doc, [string]$path) {
    return ($null -ne (Get-JsonCNode $doc $path))
}

# Giá trị dạng chuỗi (bool -> "true"/"false", số -> chuỗi số). Không có -> $null
function Get-JsonCValue($doc, [string]$path) {
    $n = Get-JsonCNode $doc $path
    if ($null -eq $n) { return $null }
    switch ($n.Kind) {
        'string' { return $n.Value }
        'number' { return $n.Value }
        'true' { return 'true' }
        'false' { return 'false' }
        'null' { return $null }
        default { return $null }
    }
}

# Danh sách key con của 1 object (giữ nguyên thứ tự trong file)
function Get-JsonCKeys($doc, [string]$path) {
    $n = $doc.Root
    if ($path) { $n = Get-JsonCNode $doc $path }
    $keys = New-Object System.Collections.Generic.List[string]
    if ($n -and $n.Kind -eq 'object') { foreach ($m in $n.Members) { $keys.Add($m.Key) } }
    return , $keys
}

#endregion

#region ---------- Sửa ----------

# Dựng chuỗi member lồng nhau cho các segment còn thiếu: "a": { "b": raw }
function JcBuildNested([string[]]$segs, [string]$raw, [string]$indent, [string]$nl) {
    if ($segs.Length -eq 1) { return (JcQuote $segs[0]) + ': ' + $raw }
    $inner = $indent + '  '
    $rest = [string[]]$segs[1..($segs.Length - 1)]
    if ($rest[0] -match '^\d+$') {
        # Tạo mảng mới: chỉ hỗ trợ phần tử 0
        if ([int]$rest[0] -ne 0) { throw "Không tạo được phần tử mảng $($rest[0]) khi mảng chưa có" }
        if ($rest.Length -eq 1) { return (JcQuote $segs[0]) + ': [' + $nl + $inner + $raw + $nl + $indent + ']' }
        $inner2 = $inner + '  '
        $obj = '{' + $nl + $inner2 + (JcBuildNested ([string[]]$rest[1..($rest.Length - 1)]) $raw $inner2 $nl) + $nl + $inner + '}'
        return (JcQuote $segs[0]) + ': [' + $nl + $inner + $obj + $nl + $indent + ']'
    }
    return (JcQuote $segs[0]) + ': {' + $nl + $inner + (JcBuildNested $rest $raw $inner $nl) + $nl + $indent + '}'
}

# Chỉnh thụt đầu dòng cho khối JSON nhiều dòng lấy từ chỗ khác
function JcReindent([string]$raw, [string]$fromIndent, [string]$toIndent, [string]$nl) {
    if (-not $raw.Contains("`n")) { return $raw }
    $lines = $raw -split "\r?\n"
    for ($i = 1; $i -lt $lines.Length; $i++) {
        if ($lines[$i].StartsWith($fromIndent)) { $lines[$i] = $toIndent + $lines[$i].Substring($fromIndent.Length) }
    }
    return ($lines -join $nl)
}

function JcChildIndent($doc, $objNode) {
    if ($objNode.Kind -eq 'object' -and $objNode.Members.Count -gt 0) { return (JcLineIndent $doc.Text $objNode.Members[0].KeyStart) }
    if ($objNode.Kind -eq 'array' -and $objNode.Items.Count -gt 0) { return (JcLineIndent $doc.Text $objNode.Items[0].Start) }
    return ((JcLineIndent $doc.Text $objNode.Start) + '  ')
}

# Chèn 1 phần tử (member "k": v hoặc item mảng) vào cuối object/array
function JcAppend($doc, $container, [string]$entryText) {
    $t = $doc.Text; $nl = $doc.NL
    $closePos = $container.End - 1
    $count = if ($container.Kind -eq 'object') { $container.Members.Count } else { $container.Items.Count }
    $childIndent = JcChildIndent $doc $container

    if ($count -eq 0) {
        $inner = $t.Substring($container.Start + 1, $closePos - ($container.Start + 1))
        if ($inner.Trim() -eq '') {
            $closeIndent = JcLineIndent $t $container.Start
            JcReplace $doc ($container.Start + 1) $closePos ($nl + $childIndent + $entryText + $nl + $closeIndent)
            return
        }
        $needComma = $false; $lastEnd = -1
    }
    else {
        $lastEnd = if ($container.Kind -eq 'object') { $container.Members[$count - 1].Value.End } else { $container.Items[$count - 1].End }
        $afterLast = JcSkipFrom $t $lastEnd
        $needComma = -not ($afterLast -lt $t.Length -and $t[$afterLast] -eq ',')
    }

    $ls = JcLineStart $t $closePos
    if ($ls -gt $lastEnd -and $t.Substring($ls, $closePos - $ls).Trim() -eq '') {
        # Dấu đóng nằm trên dòng riêng -> chèn 1 dòng mới ngay trước nó
        JcReplace $doc $ls $ls ($childIndent + $entryText + $nl)
    }
    else {
        JcReplace $doc $closePos $closePos (' ' + $entryText + ' ')
    }
    if ($needComma -and $lastEnd -ge 0) { JcReplace $doc $lastEnd $lastEnd ',' }
}

# Ghi giá trị vào đường dẫn. Thiếu section nào thì tạo section đó.
#   -Raw: $value là JSON thô (object/array/...) chứ không phải giá trị đơn
function Set-JsonCValue($doc, [string]$path, $value, [switch]$Raw) {
    $segs = JcSplitPath $path
    $w = JcWalk $doc $segs

    if ($w.Depth -eq $segs.Length) {
        $node = $w.Node
        $newRaw = if ($Raw) { [string]$value } else { JcToRaw $value $node.Kind }
        $oldRaw = $doc.Text.Substring($node.Start, $node.End - $node.Start)
        if ($oldRaw -ceq $newRaw) { return $false }
        if ($Raw) { $newRaw = JcReindent $newRaw '' (JcLineIndent $doc.Text $node.Start) $doc.NL }
        JcReplace $doc $node.Start $node.End $newRaw
        JcReparse $doc
        return $true
    }

    $container = $w.Node
    $rest = [string[]]$segs[$w.Depth..($segs.Length - 1)]
    $childIndent = JcChildIndent $doc $container
    $valueText = if ($Raw) { [string]$value } else { JcToRaw $value '' }
    if ($Raw) { $valueText = JcReindent $valueText '' ($childIndent + ('  ' * ($rest.Length - 1))) $doc.NL }

    if ($container.Kind -eq 'object') {
        $entry = JcBuildNested $rest $valueText $childIndent $doc.NL
    }
    elseif ($container.Kind -eq 'array' -and $rest[0] -match '^\d+$' -and [int]$rest[0] -eq $container.Items.Count) {
        if ($rest.Length -eq 1) { $entry = $valueText }
        else {
            $inner = $childIndent + '  '
            $entry = '{' + $doc.NL + $inner + (JcBuildNested ([string[]]$rest[1..($rest.Length - 1)]) $valueText $inner $doc.NL) + $doc.NL + $childIndent + '}'
        }
    }
    else {
        throw "Không ghi được '$path': '$($segs[$w.Depth - 1])' không phải object"
    }

    JcAppend $doc $container $entry
    JcReparse $doc
    return $true
}

# Xoá 1 key (kèm dấu phẩy). Không có -> bỏ qua
function Remove-JsonCValue($doc, [string]$path) {
    $segs = JcSplitPath $path
    $w = JcWalk $doc $segs
    if ($w.Depth -lt $segs.Length -or $null -eq $w.Member) { return $false }

    $parent = $w.Parent
    $t = $doc.Text
    $idx = -1
    for ($i = 0; $i -lt $parent.Members.Count; $i++) { if ([object]::ReferenceEquals($parent.Members[$i], $w.Member)) { $idx = $i } }
    $m = $parent.Members[$idx]
    $after = JcSkipFrom $t $m.Value.End
    $hasComma = ($after -lt $t.Length -and $t[$after] -eq ',')

    if ($idx -lt $parent.Members.Count - 1) {
        $start = $m.KeyStart; $end = $after + 1
    }
    elseif ($idx -gt 0) {
        # Phần tử cuối: xoá dấu phẩy của phần tử đứng trước
        $prevEnd = $parent.Members[$idx - 1].Value.End
        $start = JcSkipFrom $t $prevEnd
        $end = $m.Value.End
        if ($hasComma) { $end = $after + 1; $start = $prevEnd }
    }
    else {
        $start = $m.KeyStart; $end = $m.Value.End
        if ($hasComma) { $end = $after + 1 }
    }

    JcReplace $doc $start $end ''
    # Dòng chỉ còn khoảng trắng thì xoá luôn dòng đó
    $t = $doc.Text
    $ls = JcLineStart $t $start
    $le = $t.IndexOf("`n", $start)
    if ($le -ge 0 -and $t.Substring($ls, $le - $ls).Trim() -eq '') { JcReplace $doc $ls ($le + 1) '' }
    JcReparse $doc
    return $true
}

# Thêm các key có trong $sourceDoc mà $doc chưa có (không ghi đè giá trị đang có).
# Dùng khi cập nhật bản build mới: appsettings mới có thêm tham số thì tự bổ sung.
function Merge-JsonCMissing($doc, $sourceDoc) {
    $added = New-Object System.Collections.Generic.List[string]
    $ops = New-Object System.Collections.Generic.List[object]
    JcCollectMissing $doc $sourceDoc $sourceDoc.Root $doc.Root '' $ops
    foreach ($op in $ops) {
        [void](Set-JsonCValue $doc $op.Path $op.Raw -Raw)
        $added.Add($op.Path)
    }
    return , $added
}

function JcCollectMissing($doc, $srcDoc, $srcObj, $tgtObj, [string]$prefix, $ops) {
    foreach ($sm in $srcObj.Members) {
        $path = if ($prefix) { "$prefix`:$($sm.Key)" } else { $sm.Key }
        $tm = if ($tgtObj -and $tgtObj.Kind -eq 'object') { JcFindMember $tgtObj $sm.Key } else { $null }
        if ($null -eq $tm) {
            $raw = $srcDoc.Text.Substring($sm.Value.Start, $sm.Value.End - $sm.Value.Start)
            $raw = JcReindent $raw (JcLineIndent $srcDoc.Text $sm.KeyStart) '' $doc.NL
            $ops.Add(@{ Path = $path; Raw = $raw })
        }
        elseif ($sm.Value.Kind -eq 'object' -and $tm.Value.Kind -eq 'object') {
            JcCollectMissing $doc $srcDoc $sm.Value $tm.Value $path $ops
        }
    }
}

#endregion
