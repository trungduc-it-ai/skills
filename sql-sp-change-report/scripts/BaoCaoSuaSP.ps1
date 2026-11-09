<#
.SYNOPSIS
    Báo cáo stored procedure / hàm / view / trigger: sửa lúc nào, ai sửa, sửa gì.

.DESCRIPTION
    - Lúc nào : sys.objects.modify_date (chỉ là lần sửa CUỐI).
    - Ai sửa  : default trace của SQL Server (login, máy, phần mềm, giờ từng lần CREATE/ALTER/DROP).
                Cần quyền ALTER TRACE; trace chỉ giữ vài file gần nhất.
                Nếu CSDL có bảng dbo.DBA_NhatKySuaDoiTuong (DDL trigger, xem references\) thì đọc thêm bảng đó.
    - Sửa gì  : so từng dòng với 1 bản cũ: ảnh chụp lần chạy trước (mặc định), CSDL khác cùng server,
                server khác, hoặc file .sql. Mỗi lần chạy, script lưu ảnh chụp bản hiện tại vào output\AnhChup.
    Mật khẩu chỉ nhập lúc chạy (SecureString), không ghi ra file. Script chỉ ĐỌC CSDL.

.EXAMPLE
    .\BaoCaoSuaSP.ps1
    (hỏi lần lượt server, CSDL, login, mật khẩu, tên SP, nguồn so sánh)

.EXAMPLE
    .\BaoCaoSuaSP.ps1 -Server TEN_SERVER -Database TEN_CSDL -Login TEN_LOGIN -Objects sp_CLSYEUCAUCHITIET -CompareWith Database -CompareDatabase TEN_CSDL_old

.EXAMPLE
    .\BaoCaoSuaSP.ps1 -Server TEN_SERVER -Database TEN_CSDL -Login TEN_LOGIN -Objects "sp_%" -Days 3
    (mọi SP tên bắt đầu sp_ sửa trong 3 ngày, so với ảnh chụp lần trước)

.EXAMPLE
    .\BaoCaoSuaSP.ps1 -SnapshotAll -Server TEN_SERVER -Database TEN_CSDL -Login TEN_LOGIN
    (chụp toàn bộ SP/hàm/view/trigger làm mốc, để lần sau biết sửa gì)

.EXAMPLE
    .\BaoCaoSuaSP.ps1 -OldFile .\sp_X_BanGoc.sql -NewFile .\sp_X_Moi.sql
    (so 2 file .sql, không cần CSDL)
#>
[CmdletBinding(DefaultParameterSetName = 'CSDL')]
param(
    [Parameter(ParameterSetName = 'CSDL')][string]$Server,
    [Parameter(ParameterSetName = 'CSDL')][string]$Database,
    [Parameter(ParameterSetName = 'CSDL')][ValidateSet('', 'Sql', 'Windows')][string]$Auth = '',
    [Parameter(ParameterSetName = 'CSDL')][string]$Login,
    [Parameter(ParameterSetName = 'CSDL')][System.Management.Automation.PSCredential]$Credential,
    # Tên đối tượng, cách nhau dấu phẩy. Có % = LIKE. Để trống = mọi đối tượng sửa trong -Days ngày.
    [Parameter(ParameterSetName = 'CSDL')][string]$Objects,
    [Parameter(ParameterSetName = 'CSDL')][int]$Days = -1,
    [Parameter(ParameterSetName = 'CSDL')][ValidateSet('', 'Snapshot', 'Database', 'Server', 'File', 'None')][string]$CompareWith = '',
    [Parameter(ParameterSetName = 'CSDL')][string]$CompareDatabase,
    [Parameter(ParameterSetName = 'CSDL')][string]$CompareServer,
    [Parameter(ParameterSetName = 'CSDL')][string]$CompareFile,
    [Parameter(ParameterSetName = 'CSDL')][switch]$SnapshotAll,
    [Parameter(ParameterSetName = 'CSDL')][int]$MaxObjects = 30,
    [Parameter(ParameterSetName = 'File', Mandatory = $true)][string]$OldFile,
    [Parameter(ParameterSetName = 'File', Mandatory = $true)][string]$NewFile,
    [string]$OutputDir,
    [switch]$NoOpen,
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'Báo cáo sửa SP' } catch { }

$SkillDir = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $SkillDir 'output' }
$DirBaoCao = Join-Path $OutputDir 'BaoCao'
$DirAnhChup = Join-Path $OutputDir 'AnhChup'
$FileLanTruoc = Join-Path $OutputDir 'lan-truoc.json'
New-Item -ItemType Directory -Force -Path $DirBaoCao, $DirAnhChup | Out-Null
$Utf8Bom = New-Object Text.UTF8Encoding($true)
$Utf8 = New-Object Text.UTF8Encoding($false)
$LoaiDoiTuong = "'P','FN','IF','TF','V','TR'"

#region So sánh dòng (Myers, C#)
if (-not ('BCSP.LineDiff' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace BCSP {
    public class DiffOp {
        public string Kind;      // " " giống, "-" chỉ có ở bản cũ, "+" chỉ có ở bản mới
        public int OldLine;      // số dòng bản cũ (với "+": số dòng cũ đứng trước)
        public int NewLine;      // số dòng bản mới (với "-": số dòng mới đứng trước)
        public string Text;
    }
    public static class LineDiff {
        static DiffOp Op(string k, int o, int n, string t) {
            DiffOp d = new DiffOp(); d.Kind = k; d.OldLine = o; d.NewLine = n; d.Text = t; return d;
        }
        static string Key(string s, bool trimEnd) { return trimEnd ? s.TrimEnd() : s; }
        static int[] Keys(string[] lines, Dictionary<string, int> map, bool trimEnd) {
            int[] r = new int[lines.Length];
            for (int i = 0; i < lines.Length; i++) {
                string k = Key(lines[i], trimEnd);
                int id;
                if (!map.TryGetValue(k, out id)) { id = map.Count; map[k] = id; }
                r[i] = id;
            }
            return r;
        }
        // Myers O((N+M)D). Trả null nếu số chỗ khác vượt maxD.
        public static List<DiffOp> Myers(string[] a, string[] b, bool trimEnd, int maxD) {
            Dictionary<string, int> map = new Dictionary<string, int>(StringComparer.Ordinal);
            int[] ka = Keys(a, map, trimEnd);
            int[] kb = Keys(b, map, trimEnd);
            int n = a.Length, m = b.Length, max = n + m, off = max + 1;
            int[] v = new int[2 * max + 3];
            List<int[]> trace = new List<int[]>();
            int dEnd = -1;
            for (int d = 0; d <= max; d++) {
                if (d > maxD) return null;
                int[] snap = new int[2 * d + 3];
                Array.Copy(v, off - d - 1, snap, 0, 2 * d + 3);
                trace.Add(snap);
                for (int k = -d; k <= d; k += 2) {
                    int x = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1;
                    int y = x - k;
                    while (x < n && y < m && ka[x] == kb[y]) { x++; y++; }
                    v[off + k] = x;
                    if (x >= n && y >= m) { dEnd = d; break; }
                }
                if (dEnd >= 0) break;
            }
            List<DiffOp> ops = new List<DiffOp>();
            int cx = n, cy = m;
            for (int d = dEnd; d >= 0; d--) {
                int[] s = trace[d];
                int k = cx - cy;
                int prevK = (k == -d || (k != d && s[k + d] < s[k + d + 2])) ? k + 1 : k - 1;
                int prevX = s[prevK + d + 1];
                int prevY = prevX - prevK;
                while (cx > prevX && cy > prevY) { ops.Add(Op(" ", cx, cy, b[cy - 1])); cx--; cy--; }
                if (d > 0) {
                    if (cx == prevX) ops.Add(Op("+", cx, cy, b[cy - 1]));
                    else ops.Add(Op("-", cx, cy, a[cx - 1]));
                    cx = prevX; cy = prevY;
                }
            }
            ops.Reverse();
            return ops;
        }
        // Dự phòng khi khác quá nhiều: dòng có ở bản này mà không có ở bản kia (theo nội dung, bỏ dòng trống).
        public static List<DiffOp> SetDiff(string[] a, string[] b, bool trimEnd) {
            Dictionary<string, int> ca = new Dictionary<string, int>(StringComparer.Ordinal);
            Dictionary<string, int> cb = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (string l in a) { string k = Key(l, trimEnd); if (k.Trim().Length == 0) continue; int c; ca.TryGetValue(k, out c); ca[k] = c + 1; }
            foreach (string l in b) { string k = Key(l, trimEnd); if (k.Trim().Length == 0) continue; int c; cb.TryGetValue(k, out c); cb[k] = c + 1; }
            List<DiffOp> ops = new List<DiffOp>();
            Dictionary<string, int> used = new Dictionary<string, int>(StringComparer.Ordinal);
            for (int i = 0; i < a.Length; i++) {
                string k = Key(a[i], trimEnd); if (k.Trim().Length == 0) continue;
                int u; used.TryGetValue(k, out u); int c; cb.TryGetValue(k, out c);
                used[k] = u + 1; if (u >= c) ops.Add(Op("-", i + 1, 0, a[i]));
            }
            used.Clear();
            for (int j = 0; j < b.Length; j++) {
                string k = Key(b[j], trimEnd); if (k.Trim().Length == 0) continue;
                int u; used.TryGetValue(k, out u); int c; ca.TryGetValue(k, out c);
                used[k] = u + 1; if (u >= c) ops.Add(Op("+", 0, j + 1, b[j]));
            }
            return ops;
        }
    }
}
'@
}
#endregion

#region Tiện ích chung
function Hoi([string]$cau, [string]$macDinh) {
    if ($NoPrompt) { return $macDinh }
    $nhac = $cau
    if ($macDinh) { $nhac = "$cau [$macDinh]" }
    $v = Read-Host $nhac
    if ([string]::IsNullOrWhiteSpace($v)) { return $macDinh }
    return $v.Trim()
}

function HtmlE($s) {
    if ($null -eq $s -or $s -is [DBNull]) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$s)
}

function Ngay($d) {
    if ($null -eq $d -or $d -is [DBNull]) { return '' }
    return ([datetime]$d).ToString('dd/MM/yyyy HH:mm:ss.fff')
}

function Ten-AnToan([string]$s) {
    if (-not $s) { return '_' }
    $x = $s
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $x = $x.Replace([string]$c, '_') }
    return $x.Replace(',', '_')
}

function QN([string]$s) { return '[' + $s.Replace(']', ']]') + ']' }

function Tach-Dong([string]$t) {
    if ($null -eq $t) { return , ([string[]]@()) }
    $x = $t.Replace("`r`n", "`n").Replace("`r", "`n")
    $ds = New-Object System.Collections.Generic.List[string]
    $ds.AddRange([string[]]$x.Split([char]10))
    while ($ds.Count -gt 0 -and [string]::IsNullOrWhiteSpace($ds[$ds.Count - 1])) { $ds.RemoveAt($ds.Count - 1) }
    return , ($ds.ToArray())
}

function Doc-File([string]$p) {
    $b = [IO.File]::ReadAllBytes($p)
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return $Utf8.GetString($b, 3, $b.Length - 3) }
    return $Utf8.GetString($b)
}
#endregion

#region So sánh + vẽ diff
function So-Sanh([string]$cu, [string]$moi) {
    $a = Tach-Dong $cu
    $b = Tach-Dong $moi
    $ops = [BCSP.LineDiff]::Myers($a, $b, $true, 3000)
    $cheDo = 'Theo thứ tự dòng'
    if ($null -eq $ops) {
        $ops = [BCSP.LineDiff]::SetDiff($a, $b, $true)
        $cheDo = 'Khác quá nhiều, chỉ liệt kê dòng thêm / bỏ theo nội dung'
    }
    $them = 0; $bo = 0
    foreach ($o in $ops) { if ($o.Kind -eq '+') { $them++ } elseif ($o.Kind -eq '-') { $bo++ } }
    return [pscustomobject]@{ Ops = $ops; Them = $them; Bo = $bo; CheDo = $cheDo; DongCu = $a; DongMoi = $b }
}

function Tim-NhanhAction([string[]]$dong, [int]$soDong) {
    # SP kiểu "If @Action = 'X'": tìm nhánh chứa dòng thay đổi
    for ($i = [Math]::Min($soDong, $dong.Length) - 1; $i -ge 0; $i--) {
        if ($dong[$i] -match "(?i)^\s*(else\s+)?if\s*\(?\s*@Action\s*=\s*N?'([^']+)'") { return "@Action = '" + $Matches[2] + "' (dòng " + ($i + 1) + ")" }
    }
    return ''
}

function Ve-Diff($kq, [int]$ngu = 3) {
    $ops = $kq.Ops
    $n = $ops.Count
    $doi = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $n; $i++) { if ($ops[$i].Kind -ne ' ') { $doi.Add($i) } }
    if ($doi.Count -eq 0) { return '<p class="ok">Hai bản giống hệt nhau (bỏ qua khoảng trắng cuối dòng).</p>' }
    $khoang = New-Object System.Collections.Generic.List[object]
    $s = [Math]::Max(0, $doi[0] - $ngu); $e = [Math]::Min($n - 1, $doi[0] + $ngu)
    foreach ($c in $doi) {
        $cs = [Math]::Max(0, $c - $ngu); $ce = [Math]::Min($n - 1, $c + $ngu)
        if ($cs -le $e + 1) { if ($ce -gt $e) { $e = $ce } }
        else { $khoang.Add(@($s, $e)); $s = $cs; $e = $ce }
    }
    $khoang.Add(@($s, $e))
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('<div class="diff"><table>')
    foreach ($k in $khoang) {
        $oMin = $null; $oMax = $null; $nMin = $null; $nMax = $null; $dauDoi = $null
        for ($i = $k[0]; $i -le $k[1]; $i++) {
            $o = $ops[$i]
            if ($o.Kind -ne '+' -and $o.OldLine -gt 0) { if ($null -eq $oMin) { $oMin = $o.OldLine }; $oMax = $o.OldLine }
            if ($o.Kind -ne '-' -and $o.NewLine -gt 0) { if ($null -eq $nMin) { $nMin = $o.NewLine }; $nMax = $o.NewLine }
            if ($null -eq $dauDoi -and $o.Kind -ne ' ') { $dauDoi = $o }
        }
        $nhanh = ''
        if ($dauDoi) {
            $nhanh = Tim-NhanhAction $kq.DongMoi ([Math]::Max(1, $dauDoi.NewLine))
            if (-not $nhanh) { $nhanh = Tim-NhanhAction $kq.DongCu ([Math]::Max(1, $dauDoi.OldLine)) }
        }
        $tieuDe = 'Bản cũ dòng ' + $(if ($null -ne $oMin) { "$oMin–$oMax" } else { '—' }) + '  ·  bản mới dòng ' + $(if ($null -ne $nMin) { "$nMin–$nMax" } else { '—' })
        if ($nhanh) { $tieuDe += '  ·  trong nhánh ' + $nhanh }
        [void]$sb.Append('<tr class="hunk"><td colspan="4">' + (HtmlE $tieuDe) + '</td></tr>')
        for ($i = $k[0]; $i -le $k[1]; $i++) {
            $o = $ops[$i]
            $lop = ''; $soCu = ''; $soMoi = ''
            if ($o.Kind -eq '+') { $lop = ' class="add"'; $soMoi = $o.NewLine }
            elseif ($o.Kind -eq '-') { $lop = ' class="del"'; $soCu = $o.OldLine }
            else { $soCu = $o.OldLine; $soMoi = $o.NewLine }
            if ($soCu -eq 0) { $soCu = '' }; if ($soMoi -eq 0) { $soMoi = '' }
            [void]$sb.Append('<tr' + $lop + '><td class="ln">' + $soCu + '</td><td class="ln">' + $soMoi + '</td><td class="sg">' + (HtmlE $o.Kind) + '</td><td class="code">' + (HtmlE $o.Text) + '</td></tr>')
        }
    }
    [void]$sb.Append('</table></div>')
    return $sb.ToString()
}
#endregion

#region HTML khung
$Css = @'
:root{--bg:#f5f6f8;--card:#fff;--fg:#1c2330;--mut:#5b6474;--line:#dde2ea;--hd:#eef2f8;--add:#e3f5e8;--addfg:#14532d;--del:#fdeaea;--delfg:#7f1d1d;--warn:#fff6dd;--warnfg:#6b4500;--acc:#1f57c3}
@media (prefers-color-scheme:dark){:root{--bg:#13161b;--card:#1b1f26;--fg:#e4e8ef;--mut:#9aa3b1;--line:#2b313b;--hd:#232a35;--add:#16371f;--addfg:#bfeecd;--del:#41181a;--delfg:#ffcaca;--warn:#3a2e10;--warnfg:#ffe2a1;--acc:#7ea4ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 "Segoe UI",Tahoma,Arial,sans-serif}
.wrap{max-width:1320px;margin:0 auto;padding:20px 16px 40px}h1{font-size:22px;margin:0 0 4px}h2{font-size:18px;margin:28px 0 8px;padding-top:4px}h3{font-size:15px;margin:16px 0 6px}
a{color:var(--acc)}.meta{color:var(--mut)}.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 16px;margin:12px 0;overflow-x:auto}
table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}th{background:var(--hd);font-weight:600;white-space:nowrap}
.num{text-align:right;font-variant-numeric:tabular-nums}.them{color:#15803d;font-weight:600}.bo{color:#b91c1c;font-weight:600}
@media (prefers-color-scheme:dark){.them{color:#6ee7a0}.bo{color:#ff9b9b}}
.note{background:var(--warn);color:var(--warnfg);padding:8px 12px;border-radius:6px;margin:8px 0}.ok{color:var(--mut)}
dl.kv{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;margin:0}dl.kv dt{color:var(--mut)}dl.kv dd{margin:0;word-break:break-all}
.diff{overflow-x:auto;border:1px solid var(--line);border-radius:6px;margin-top:6px}
.diff table{font:12.5px/1.45 Consolas,"Cascadia Mono","Courier New",monospace;width:auto;min-width:100%}
.diff td{border:0;padding:0 8px;white-space:pre;tab-size:4}.diff td.ln{color:var(--mut);text-align:right;user-select:none;min-width:48px;border-right:1px solid var(--line)}
.diff td.sg{user-select:none;width:14px;padding:0 4px}.diff tr.add td{background:var(--add);color:var(--addfg)}.diff tr.del td{background:var(--del);color:var(--delfg)}
.diff tr.hunk td{background:var(--hd);color:var(--mut);padding:4px 8px;font-family:"Segoe UI",Tahoma,sans-serif}
footer{color:var(--mut);font-size:12.5px;margin-top:28px}
'@

function Mo-Html([string]$tieuDe) {
    return '<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' + (HtmlE $tieuDe) + '</title><style>' + $Css + '</style></head><body><div class="wrap">'
}
function Dong-Html() { return '</div></body></html>' }

function Ghi-BaoCao([string]$html, [string]$tenFile) {
    $p = Join-Path $DirBaoCao $tenFile
    [IO.File]::WriteAllText($p, $html, $Utf8)
    Write-Host ''
    Write-Host "Báo cáo: $p" -ForegroundColor Green
    if (-not $NoOpen) { try { Invoke-Item -LiteralPath $p } catch { } }
    return $p
}
#endregion

#region Chế độ so 2 file (không cần CSDL)
if ($PSCmdlet.ParameterSetName -eq 'File') {
    $cu = Doc-File (Resolve-Path -LiteralPath $OldFile).Path
    $moi = Doc-File (Resolve-Path -LiteralPath $NewFile).Path
    $kq = So-Sanh $cu $moi
    $h = New-Object Text.StringBuilder
    [void]$h.Append((Mo-Html 'So sánh 2 file SQL'))
    [void]$h.Append('<h1>So sánh 2 file SQL</h1><p class="meta">Lập lúc ' + (Get-Date).ToString('dd/MM/yyyy HH:mm:ss') + '</p>')
    [void]$h.Append('<div class="card"><dl class="kv"><dt>Bản cũ</dt><dd>' + (HtmlE $OldFile) + ' (' + $kq.DongCu.Length + ' dòng)</dd><dt>Bản mới</dt><dd>' + (HtmlE $NewFile) + ' (' + $kq.DongMoi.Length + ' dòng)</dd>')
    [void]$h.Append('<dt>Kết quả</dt><dd><span class="them">+' + $kq.Them + '</span> dòng thêm, <span class="bo">−' + $kq.Bo + '</span> dòng bỏ · ' + (HtmlE $kq.CheDo) + '</dd></dl></div>')
    [void]$h.Append((Ve-Diff $kq))
    [void]$h.Append((Dong-Html))
    Write-Host ("+{0} dòng thêm, -{1} dòng bỏ" -f $kq.Them, $kq.Bo)
    $null = Ghi-BaoCao $h.ToString() ('SoSanhFile_{0:yyyyMMdd_HHmmss}.html' -f (Get-Date))
    return
}
#endregion

#region Kết nối CSDL
$script:KieuDN = 'Sql'
$script:SqlCred = $null

function Mo-KetNoi([string]$srv, [string]$db) {
    $cs = "Server=$srv;Database=$db;Encrypt=False;Connect Timeout=15;Application Name=BaoCaoSuaSP"
    if ($script:KieuDN -eq 'Windows') { $cn = New-Object System.Data.SqlClient.SqlConnection("$cs;Integrated Security=SSPI") }
    else { $cn = New-Object System.Data.SqlClient.SqlConnection($cs, $script:SqlCred) }
    $cn.Open()
    return $cn
}

function Truy-Van($cn, [string]$sql, [hashtable]$thamSo) {
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = 600
    if ($thamSo) {
        foreach ($k in $thamSo.Keys) {
            $v = $thamSo[$k]; if ($null -eq $v) { $v = [DBNull]::Value }
            [void]$cmd.Parameters.AddWithValue($k, $v)
        }
    }
    $da = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt = New-Object System.Data.DataTable
    [void]$da.Fill($dt)
    return , $dt
}

function Lay-DinhNghia($cn, [string]$db, [string]$schema, [string]$ten) {
    $q = 'EXEC ' + (QN $db) + ".sys.sp_executesql N'SELECT OBJECT_DEFINITION(o.object_id) AS def, o.modify_date FROM sys.objects o WHERE o.object_id = OBJECT_ID(@t)', N'@t nvarchar(600)', @t = @ten"
    $dt = Truy-Van $cn $q @{ '@ten' = ((QN $schema) + '.' + (QN $ten)) }
    if ($dt.Rows.Count -eq 0) { return $null }
    return [pscustomobject]@{ Def = $(if ($dt.Rows[0]['def'] -is [DBNull]) { $null } else { [string]$dt.Rows[0]['def'] }); Sua = $dt.Rows[0]['modify_date'] }
}

function Lay-Trace($cn) {
    $r = [pscustomobject]@{ Ok = $false; ThongBao = ''; Rows = @(); TuLuc = $null }
    try {
        $p = Truy-Van $cn 'SELECT [path] FROM sys.traces WHERE is_default = 1'
        if ($p.Rows.Count -eq 0 -or $p.Rows[0][0] -is [DBNull]) {
            $r.ThongBao = 'Không thấy default trace: trace đã tắt, hoặc login không có quyền ALTER TRACE.'
            return $r
        }
        $path = [string]$p.Rows[0][0]
        $goc = $path.Substring(0, $path.LastIndexOf('\') + 1) + 'log.trc'   # đọc mọi file xoay vòng
        $sql = 'SELECT t.StartTime, t.EventClass, t.ObjectName, t.LoginName, t.NTDomainName, t.NTUserName, t.HostName, t.ApplicationName, t.SPID ' +
               'FROM sys.fn_trace_gettable(@p, DEFAULT) t WHERE t.EventClass IN (46, 47, 164) AND t.EventSubClass = 0 AND t.DatabaseName = DB_NAME() ORDER BY t.StartTime DESC'
        try { $dt = Truy-Van $cn $sql @{ '@p' = $goc }; $dung = $goc }
        catch { $dt = Truy-Van $cn $sql @{ '@p' = $path }; $dung = $path }
        $mn = Truy-Van $cn 'SELECT MIN(StartTime) FROM sys.fn_trace_gettable(@p, DEFAULT)' @{ '@p' = $dung }
        $r.Ok = $true
        $r.Rows = @($dt.Rows)
        if ($mn.Rows.Count -gt 0 -and -not ($mn.Rows[0][0] -is [DBNull])) { $r.TuLuc = $mn.Rows[0][0] }
    } catch {
        $r.ThongBao = 'Không đọc được default trace: ' + $_.Exception.Message
    }
    return $r
}

function Lay-NhatKyDDL($cn) {
    try {
        $c = Truy-Van $cn "SELECT OBJECT_ID(N'dbo.DBA_NhatKySuaDoiTuong', N'U')"
        if ($c.Rows[0][0] -is [DBNull]) { return $null }
        return , (Truy-Van $cn 'SELECT TOP (2000) NhatKy_Id, ThoiGian, LoaiSuKien, TenDoiTuong, LoginName, MayTram, PhanMem, LEN(CauLenh) AS DoDai FROM dbo.DBA_NhatKySuaDoiTuong ORDER BY NhatKy_Id DESC')
    } catch { return $null }
}
#endregion

#region Ảnh chụp
function Thu-MucAnh([string]$srv, [string]$db, [string]$schema, [string]$ten) {
    return Join-Path $DirAnhChup ((Ten-AnToan $srv) + '\' + (Ten-AnToan $db) + '\' + (Ten-AnToan "$schema.$ten"))
}
function Luu-AnhChup([string]$srv, [string]$db, [string]$schema, [string]$ten, $sua, [string]$def) {
    $dir = Thu-MucAnh $srv $db $schema $ten
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $p = Join-Path $dir (([datetime]$sua).ToString('yyyyMMdd_HHmmss_fff') + '.sql')
    if (Test-Path -LiteralPath $p) { return [pscustomobject]@{ Path = $p; Moi = $false } }
    [IO.File]::WriteAllText($p, $def, $Utf8Bom)
    return [pscustomobject]@{ Path = $p; Moi = $true }
}
function Tim-AnhChupTruoc([string]$srv, [string]$db, [string]$schema, [string]$ten, $sua) {
    $dir = Thu-MucAnh $srv $db $schema $ten
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $moc = ([datetime]$sua).ToString('yyyyMMdd_HHmmss_fff')
    $f = Get-ChildItem -LiteralPath $dir -Filter '*.sql' | Where-Object { $_.BaseName -lt $moc } | Sort-Object BaseName -Descending | Select-Object -First 1
    if (-not $f) { return $null }
    $d = [datetime]::ParseExact($f.BaseName, 'yyyyMMdd_HHmmss_fff', $null)
    return [pscustomobject]@{ Path = $f.FullName; Sua = $d }
}
#endregion

#region Hỏi thông tin
$lt = $null
if (Test-Path -LiteralPath $FileLanTruoc) { try { $lt = Get-Content -LiteralPath $FileLanTruoc -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $lt = $null } }
function LT([string]$ten, [string]$macDinh) { if ($lt -and $lt.$ten) { return [string]$lt.$ten }; return $macDinh }

Write-Host '=== Báo cáo sửa Stored Procedure: lúc nào · ai sửa · sửa gì ===' -ForegroundColor Cyan
Write-Host 'Script chỉ ĐỌC CSDL. Mật khẩu không được lưu.'
Write-Host ''

$cheDoChup = [bool]$SnapshotAll
if (-not $cheDoChup -and -not $PSBoundParameters.ContainsKey('Objects') -and -not $NoPrompt) {
    Write-Host 'Chọn việc:'
    Write-Host '  1 = Báo cáo cho SP / hàm / view (mặc định)'
    Write-Host '  2 = Chụp toàn bộ SP / hàm / view / trigger của CSDL làm mốc (để lần sau biết sửa gì)'
    $cheDoChup = ((Hoi 'Chọn' '1') -eq '2')
}

if (-not $Server) { $Server = Hoi 'Server' (LT 'Server' '') }
if (-not $Database) { $Database = Hoi 'CSDL' (LT 'Database' '') }
if (-not $Server -or -not $Database) { throw 'Thiếu Server hoặc CSDL: nhập khi được hỏi, hoặc truyền -Server / -Database.' }
if (-not $Auth) {
    if ($Credential) { $Auth = 'Sql' }
    else {
        $macDinhDN = '1'; if ((LT 'Auth' 'Sql') -eq 'Windows') { $macDinhDN = '2' }
        $Auth = $(if ((Hoi 'Đăng nhập: 1 = SQL login, 2 = Windows' $macDinhDN) -eq '2') { 'Windows' } else { 'Sql' })
    }
}
$script:KieuDN = $Auth

$cn = $null
for ($lan = 1; $lan -le 3 -and $null -eq $cn; $lan++) {
    if ($Auth -eq 'Sql') {
        if ($Credential -and $lan -eq 1) {
            $Login = $Credential.UserName
            $matKhau = $Credential.Password.Copy()
        } else {
            if (-not $Login -or $lan -gt 1) {
                $macDinhLogin = $Login; if (-not $macDinhLogin) { $macDinhLogin = LT 'Login' '' }
                $Login = Hoi 'Login SQL' $macDinhLogin
            }
            if ($NoPrompt) { throw 'Thiếu mật khẩu: dùng -Credential khi chạy -NoPrompt.' }
            $matKhau = Read-Host 'Mật khẩu' -AsSecureString
        }
        $matKhau.MakeReadOnly()
        $script:SqlCred = New-Object System.Data.SqlClient.SqlCredential($Login, $matKhau)
    }
    try {
        $cn = Mo-KetNoi $Server $Database
        Write-Host "  Kết nối $Server / $Database : OK" -ForegroundColor Green
    } catch {
        Write-Host ('  Không kết nối được: ' + $_.Exception.Message) -ForegroundColor Red
        $cn = $null
        if ($Auth -eq 'Windows' -or $NoPrompt) { break }
    }
}
if ($null -eq $cn) { throw 'Không kết nối được CSDL.' }
$tenServer = [string](Truy-Van $cn 'SELECT @@SERVERNAME').Rows[0][0]
$nguoiChay = $(if ($Auth -eq 'Windows') { "$env:USERDOMAIN\$env:USERNAME (Windows)" } else { $Login })

try {
    @{ Server = $Server; Database = $Database; Auth = $Auth; Login = $Login } | ConvertTo-Json | Set-Content -LiteralPath $FileLanTruoc -Encoding UTF8
} catch { }
#endregion

#region Chế độ chụp toàn bộ
if ($cheDoChup) {
    Write-Host 'Đang chụp định nghĩa toàn bộ đối tượng...'
    $cmd = $cn.CreateCommand()
    $cmd.CommandTimeout = 900
    $cmd.CommandText = "SELECT s.name, o.name, o.modify_date, OBJECT_DEFINITION(o.object_id) FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id WHERE o.type IN ($LoaiDoiTuong) AND o.is_ms_shipped = 0"
    $rd = $cmd.ExecuteReader()
    $moi = 0; $daCo = 0; $rong = 0
    try {
        while ($rd.Read()) {
            if ($rd.IsDBNull(3)) { $rong++; continue }
            $x = Luu-AnhChup $Server $Database $rd.GetString(0) $rd.GetString(1) $rd.GetDateTime(2) $rd.GetString(3)
            if ($x.Moi) { $moi++ } else { $daCo++ }
        }
    } finally { $rd.Close() }
    $cn.Close()
    Write-Host ("Xong: {0} ảnh mới, {1} đã có sẵn, {2} không đọc được nội dung (mã hoá / thiếu quyền)." -f $moi, $daCo, $rong) -ForegroundColor Green
    Write-Host ('Thư mục: ' + (Join-Path $DirAnhChup ((Ten-AnToan $Server) + '\' + (Ten-AnToan $Database))))
    return
}
#endregion

#region Chọn đối tượng + nguồn so sánh
if (-not $PSBoundParameters.ContainsKey('Objects')) {
    Write-Host ''
    Write-Host 'Tên SP / hàm / view: nhiều tên cách nhau dấu phẩy; có % để tìm theo mẫu (vd sp_CLS%);'
    Write-Host '  để trống = mọi đối tượng sửa trong N ngày gần đây.'
    $Objects = Hoi 'Tên' ''
}
$dsTen = @(); $dsMau = @()
foreach ($p in ($Objects -split '[,;]')) {
    $t = $p.Trim()
    if (-not $t) { continue }
    if ($t.Contains('.')) { $t = $t.Substring($t.LastIndexOf('.') + 1) }
    $t = $t.Trim('[', ']', ' ')
    if ($t.Contains('%')) { $dsMau += $t } else { $dsTen += $t }
}
$apNgay = ($dsMau.Count -gt 0 -or $dsTen.Count -eq 0)
if ($apNgay -and $Days -lt 0) { $Days = [int](Hoi 'Số ngày xem lại' '7') }

if (-not $CompareWith) {
    Write-Host ''
    Write-Host 'So sánh với bản nào để biết sửa gì:'
    Write-Host '  1 = Ảnh chụp lần chạy trước của script này (mặc định)'
    Write-Host '  2 = CSDL khác trên cùng server (bản sao lưu, vd TEN_CSDL_old)'
    Write-Host '  3 = Server khác (vd server test so với production)'
    Write-Host '  4 = File .sql (chỉ khi xem 1 SP)'
    Write-Host '  0 = Không so sánh'
    switch (Hoi 'Chọn' '1') {
        '2' { $CompareWith = 'Database' }
        '3' { $CompareWith = 'Server' }
        '4' { $CompareWith = 'File' }
        '0' { $CompareWith = 'None' }
        default { $CompareWith = 'Snapshot' }
    }
}

$cn2 = $null
if ($CompareWith -eq 'Database' -and -not $CompareDatabase) {
    $dbs = Truy-Van $cn 'SELECT name FROM sys.databases WHERE state = 0 AND database_id > 4 AND HAS_DBACCESS(name) = 1 AND name <> DB_NAME() ORDER BY name'
    $ds = @($dbs.Rows | ForEach-Object { [string]$_['name'] })
    if ($ds.Count -eq 0) { throw 'Không có CSDL nào khác truy cập được trên server này.' }
    Write-Host ''
    Write-Host 'CSDL trên cùng server:'
    for ($i = 0; $i -lt $ds.Count; $i++) {
        $ghiChu = ''
        if ($dsTen.Count -gt 0) {
            try { $x = Lay-DinhNghia $cn $ds[$i] 'dbo' $dsTen[0]; if ($x -and $x.Sua) { $ghiChu = "  ($($dsTen[0]) sửa $(Ngay $x.Sua))" } else { $ghiChu = "  (không có $($dsTen[0]))" } } catch { $ghiChu = '  (không đọc được)' }
        }
        Write-Host ('  {0,2} = {1}{2}' -f ($i + 1), $ds[$i], $ghiChu)
    }
    $chon = [int](Hoi 'Chọn số' '1')
    if ($chon -lt 1 -or $chon -gt $ds.Count) { throw 'Số không hợp lệ.' }
    $CompareDatabase = $ds[$chon - 1]
}
if ($CompareWith -eq 'Server') {
    if (-not $CompareServer) { $CompareServer = Hoi 'Server so sánh' '' }
    if (-not $CompareServer) { throw 'Thiếu server so sánh: nhập khi được hỏi, hoặc truyền -CompareServer.' }
    if (-not $CompareDatabase) { $CompareDatabase = Hoi 'CSDL trên server so sánh' $Database }
    Write-Host "  Dùng cùng kiểu đăng nhập / login cho $CompareServer."
    $cn2 = Mo-KetNoi $CompareServer $CompareDatabase
    Write-Host "  Kết nối $CompareServer / $CompareDatabase : OK" -ForegroundColor Green
}
if ($CompareWith -eq 'File') {
    if ($dsTen.Count -ne 1 -or $dsMau.Count -gt 0) { throw 'So với file chỉ dùng khi nhập đúng 1 tên SP.' }
    if (-not $CompareFile) { $CompareFile = (Hoi 'Đường dẫn file .sql bản cũ' '').Trim('"') }
    if (-not (Test-Path -LiteralPath $CompareFile)) { throw "Không thấy file: $CompareFile" }
}
#endregion

#region Lấy dữ liệu
$dk = @(); $ts = @{ '@top' = $MaxObjects + 1 }
$hoac = @(); $i = 0
foreach ($t in $dsTen) { $hoac += "o.name = @n$i"; $ts["@n$i"] = $t; $i++ }
foreach ($t in $dsMau) { $hoac += "o.name LIKE @n$i"; $ts["@n$i"] = $t; $i++ }
if ($hoac.Count -gt 0) { $dk += '(' + ($hoac -join ' OR ') + ')' }
if ($apNgay) { $dk += 'o.modify_date >= DATEADD(DAY, -@soNgay, GETDATE())'; $ts['@soNgay'] = $Days }
$where = "o.type IN ($LoaiDoiTuong) AND o.is_ms_shipped = 0"
if ($dk.Count -gt 0) { $where += ' AND ' + ($dk -join ' AND ') }
$sqlDT = 'SELECT TOP (@top) s.name AS sch, o.name, o.type_desc, o.create_date, o.modify_date, OBJECT_DEFINITION(o.object_id) AS def ' +
         "FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id WHERE $where ORDER BY o.modify_date DESC"
Write-Host ''
Write-Host 'Đang đọc đối tượng...'
$dtDT = Truy-Van $cn $sqlDT $ts
$dsDT = @($dtDT.Rows)
$catBot = $false
if ($dsDT.Count -gt $MaxObjects) { $dsDT = $dsDT[0..($MaxObjects - 1)]; $catBot = $true }
$khongThay = @($dsTen | Where-Object { $t = $_; -not ($dsDT | Where-Object { $_['name'] -eq $t }) })
Write-Host ("  {0} đối tượng." -f $dsDT.Count)

Write-Host 'Đang đọc default trace...'
$trace = Lay-Trace $cn
if (-not $trace.Ok) { Write-Host ('  ' + $trace.ThongBao) -ForegroundColor Yellow }
$nhatKy = Lay-NhatKyDDL $cn

$tenTrace = @{ 46 = 'Tạo (CREATE)'; 47 = 'Xoá (DROP)'; 164 = 'Sửa (ALTER)' }
$ketQua = New-Object System.Collections.Generic.List[object]
foreach ($r in $dsDT) {
    $sch = [string]$r['sch']; $ten = [string]$r['name']
    $def = $(if ($r['def'] -is [DBNull]) { $null } else { [string]$r['def'] })
    $kq = [pscustomobject]@{
        Schema = $sch; Ten = $ten; Loai = [string]$r['type_desc']; Tao = $r['create_date']; Sua = $r['modify_date']
        SoDong = 0; Checksum = ''; AnhChup = ''; AnhChupMoi = $false
        Trace = @(); NhatKy = @(); NguonSoSanh = ''; SuaBanCu = $null; Diff = $null; Loi = ''
    }
    try {
        if ($null -eq $def) { $kq.Loi = 'Không đọc được nội dung (đối tượng mã hoá hoặc login thiếu quyền VIEW DEFINITION).' }
        else {
            $kq.SoDong = (Tach-Dong $def).Length
            $kq.Checksum = ([BitConverter]::ToString((New-Object Security.Cryptography.SHA1Managed).ComputeHash($Utf8.GetBytes($def)))).Replace('-', '').Substring(0, 12)
            $x = Luu-AnhChup $Server $Database $sch $ten $kq.Sua $def
            $kq.AnhChup = $x.Path; $kq.AnhChupMoi = $x.Moi
        }
        if ($trace.Ok) { $kq.Trace = @($trace.Rows | Where-Object { [string]$_['ObjectName'] -eq $ten }) }
        if ($nhatKy) { $kq.NhatKy = @($nhatKy.Rows | Where-Object { [string]$_['TenDoiTuong'] -eq "$sch.$ten" }) }

        $cu = $null
        switch ($CompareWith) {
            'Snapshot' {
                $t = Tim-AnhChupTruoc $Server $Database $sch $ten $kq.Sua
                if ($t) { $cu = Doc-File $t.Path; $kq.SuaBanCu = $t.Sua; $kq.NguonSoSanh = 'Ảnh chụp lần chạy trước: ' + $t.Path }
                else { $kq.NguonSoSanh = 'Chưa có ảnh chụp của bản trước. Lần này đã chụp bản hiện tại; lần sau SP bị sửa sẽ thấy sửa gì.' }
            }
            'Database' {
                $x = Lay-DinhNghia $cn $CompareDatabase $sch $ten
                if ($x -and $null -ne $x.Def) { $cu = $x.Def; $kq.SuaBanCu = $x.Sua; $kq.NguonSoSanh = "CSDL $CompareDatabase (cùng server)" }
                else { $kq.NguonSoSanh = "CSDL $CompareDatabase không có đối tượng này." }
            }
            'Server' {
                $x = Lay-DinhNghia $cn2 $CompareDatabase $sch $ten
                if ($x -and $null -ne $x.Def) { $cu = $x.Def; $kq.SuaBanCu = $x.Sua; $kq.NguonSoSanh = "Server $CompareServer / $CompareDatabase" }
                else { $kq.NguonSoSanh = "Server $CompareServer / $CompareDatabase không có đối tượng này." }
            }
            'File' { $cu = Doc-File $CompareFile; $kq.NguonSoSanh = "File $CompareFile" }
            default { $kq.NguonSoSanh = 'Không so sánh.' }
        }
        if ($null -ne $cu -and $null -ne $def) { $kq.Diff = So-Sanh $cu $def }
    } catch {
        $kq.Loi = 'Lỗi: ' + $_.Exception.Message
    }
    $ketQua.Add($kq)
    $tom = ''
    if ($kq.Diff) { $tom = ('  +{0} -{1}' -f $kq.Diff.Them, $kq.Diff.Bo) }
    Write-Host ('  {0}.{1}  sửa {2}{3}' -f $sch, $ten, (Ngay $kq.Sua), $tom)
}
$cn.Close()
if ($cn2) { $cn2.Close() }
#endregion

#region Báo cáo HTML
$h = New-Object Text.StringBuilder
function A([string]$s) { [void]$h.Append($s) }
A (Mo-Html "Báo cáo sửa SP · $Database")
A ('<h1>Báo cáo sửa Stored Procedure</h1><p class="meta">Lập lúc ' + (Get-Date).ToString('dd/MM/yyyy HH:mm:ss') + ' · chỉ đọc CSDL</p>')
A '<div class="card"><dl class="kv">'
A ('<dt>Server</dt><dd>' + (HtmlE $Server) + ' (' + (HtmlE $tenServer) + ')</dd><dt>CSDL</dt><dd>' + (HtmlE $Database) + '</dd><dt>Người chạy</dt><dd>' + (HtmlE $nguoiChay) + '</dd>')
$moTaLoc = $(if ($dsTen.Count + $dsMau.Count -gt 0) { (($dsTen + $dsMau) -join ', ') } else { 'mọi đối tượng' })
if ($apNgay) { $moTaLoc += " · sửa trong $Days ngày gần đây" }
A ('<dt>Lọc</dt><dd>' + (HtmlE $moTaLoc) + '</dd>')
$moTaSS = switch ($CompareWith) { 'Snapshot' { 'Ảnh chụp lần chạy trước' } 'Database' { "CSDL $CompareDatabase" } 'Server' { "Server $CompareServer / $CompareDatabase" } 'File' { "File $CompareFile" } default { 'Không so sánh' } }
A ('<dt>So sánh với</dt><dd>' + (HtmlE $moTaSS) + '</dd>')
if ($trace.Ok) { A ('<dt>Default trace</dt><dd>còn dữ liệu từ ' + (Ngay $trace.TuLuc) + '</dd>') }
else { A ('<dt>Default trace</dt><dd>' + (HtmlE $trace.ThongBao) + '</dd>') }
A ('<dt>Nhật ký DDL</dt><dd>' + $(if ($nhatKy) { 'có bảng dbo.DBA_NhatKySuaDoiTuong' } else { 'chưa cài (xem references\nhat-ky-ddl trong skill)' }) + '</dd>')
A '</dl></div>'
if ($catBot) { A ('<p class="note">Chỉ hiện ' + $MaxObjects + ' đối tượng sửa gần nhất. Lọc hẹp hơn hoặc tăng -MaxObjects.</p>') }
if ($khongThay.Count -gt 0) { A ('<p class="note">Không thấy trong CSDL: ' + (HtmlE ($khongThay -join ', ')) + '</p>') }

A '<h2>Tổng hợp</h2><div class="card"><table><tr><th>#</th><th>Đối tượng</th><th>Loại</th><th>Sửa lần cuối</th><th>Ai sửa gần nhất (trace)</th><th>Bản so sánh sửa lúc</th><th class="num">Thêm</th><th class="num">Bỏ</th></tr>'
$stt = 0
foreach ($k in $ketQua) {
    $stt++
    $ai = ''
    $suaTrace = @($k.Trace | Where-Object { [int]$_['EventClass'] -ne 47 })
    if ($suaTrace.Count -gt 0) { $t0 = $suaTrace[0]; $ai = [string]$t0['LoginName'] + ' @ ' + [string]$t0['HostName'] + ' · ' + (Ngay $t0['StartTime']) }
    elseif ($k.NhatKy.Count -gt 0) { $t0 = $k.NhatKy[0]; $ai = [string]$t0['LoginName'] + ' @ ' + [string]$t0['MayTram'] + ' · ' + (Ngay $t0['ThoiGian']) + ' (nhật ký DDL)' }
    $them = ''; $bo = ''
    if ($k.Diff) { $them = '<span class="them">+' + $k.Diff.Them + '</span>'; $bo = '<span class="bo">−' + $k.Diff.Bo + '</span>' }
    A ('<tr><td class="num">' + $stt + '</td><td><a href="#dt' + $stt + '">' + (HtmlE "$($k.Schema).$($k.Ten)") + '</a></td><td>' + (HtmlE $k.Loai) + '</td><td>' + (Ngay $k.Sua) + '</td><td>' + (HtmlE $ai) + '</td><td>' + (Ngay $k.SuaBanCu) + '</td><td class="num">' + $them + '</td><td class="num">' + $bo + '</td></tr>')
}
if ($ketQua.Count -eq 0) { A '<tr><td colspan="8">Không có đối tượng nào khớp điều kiện.</td></tr>' }
A '</table></div>'

$stt = 0
foreach ($k in $ketQua) {
    $stt++
    A ('<h2 id="dt' + $stt + '">' + $stt + '. ' + (HtmlE "$($k.Schema).$($k.Ten)") + '</h2>')
    if ($k.Loi) { A ('<p class="note">' + (HtmlE $k.Loi) + '</p>') }
    A '<div class="card"><dl class="kv">'
    A ('<dt>Loại</dt><dd>' + (HtmlE $k.Loai) + '</dd><dt>Tạo lúc</dt><dd>' + (Ngay $k.Tao) + '</dd><dt>Sửa lần cuối</dt><dd>' + (Ngay $k.Sua) + '</dd>')
    A ('<dt>Số dòng</dt><dd>' + $k.SoDong + '</dd><dt>Mã băm (SHA1, 12 ký tự)</dt><dd>' + (HtmlE $k.Checksum) + '</dd>')
    if ($k.AnhChup) { A ('<dt>Ảnh chụp bản hiện tại</dt><dd>' + (HtmlE $k.AnhChup) + $(if ($k.AnhChupMoi) { ' (mới lưu)' } else { ' (đã có từ lần trước)' }) + '</dd>') }
    A '</dl></div>'

    A '<h3>Sửa gì</h3>'
    A ('<p class="meta">' + (HtmlE $k.NguonSoSanh) + $(if ($k.SuaBanCu) { ' · bản so sánh sửa lúc ' + (Ngay $k.SuaBanCu) } else { '' }) + '</p>')
    if ($k.Diff) {
        A ('<p><span class="them">+' + $k.Diff.Them + '</span> dòng thêm, <span class="bo">−' + $k.Diff.Bo + '</span> dòng bỏ · ' + (HtmlE $k.Diff.CheDo) + ' · cột trái là số dòng bản cũ, cột phải là số dòng bản hiện tại.</p>')
        A (Ve-Diff $k.Diff)
    }

    A '<h3>Ai sửa, lúc nào: default trace</h3>'
    if (-not $trace.Ok) { A ('<p class="note">' + (HtmlE $trace.ThongBao) + '</p>') }
    elseif ($k.Trace.Count -eq 0) { A ('<p class="ok">Không có sự kiện nào trong trace (trace còn dữ liệu từ ' + (Ngay $trace.TuLuc) + '; lần sửa cũ hơn đã bị xoay vòng).</p>') }
    else {
        $toiDa = 50
        if ($k.Trace.Count -gt $toiDa) { A ('<p class="meta">' + $k.Trace.Count + ' lần, hiện ' + $toiDa + ' lần gần nhất.</p>') }
        A '<div class="card"><table><tr><th>Lúc</th><th>Việc</th><th>Login</th><th>Windows user</th><th>Máy</th><th>Phần mềm</th><th class="num">SPID</th></tr>'
        foreach ($t in ($k.Trace | Select-Object -First $toiDa)) {
            $ev = $tenTrace[[int]$t['EventClass']]
            $win = (([string]$t['NTDomainName']) + '\' + ([string]$t['NTUserName'])).Trim('\')
            $khop = ''
            if ([int]$t['EventClass'] -ne 47 -and [math]::Abs((([datetime]$t['StartTime']) - ([datetime]$k.Sua)).TotalSeconds) -le 2) { $khop = ' (khớp modify_date)' }
            A ('<tr><td>' + (Ngay $t['StartTime']) + (HtmlE $khop) + '</td><td>' + (HtmlE $ev) + '</td><td>' + (HtmlE $t['LoginName']) + '</td><td>' + (HtmlE $win) + '</td><td>' + (HtmlE $t['HostName']) + '</td><td>' + (HtmlE $t['ApplicationName']) + '</td><td class="num">' + (HtmlE $t['SPID']) + '</td></tr>')
        }
        A '</table></div>'
    }

    if ($nhatKy) {
        A '<h3>Nhật ký DDL (dbo.DBA_NhatKySuaDoiTuong)</h3>'
        if ($k.NhatKy.Count -eq 0) { A '<p class="ok">Chưa có dòng nhật ký cho đối tượng này.</p>' }
        else {
            A '<div class="card"><table><tr><th class="num">Id</th><th>Lúc</th><th>Việc</th><th>Login</th><th>Máy</th><th>Phần mềm</th><th class="num">Độ dài</th></tr>'
            foreach ($t in $k.NhatKy) { A ('<tr><td class="num">' + $t['NhatKy_Id'] + '</td><td>' + (Ngay $t['ThoiGian']) + '</td><td>' + (HtmlE $t['LoaiSuKien']) + '</td><td>' + (HtmlE $t['LoginName']) + '</td><td>' + (HtmlE $t['MayTram']) + '</td><td>' + (HtmlE $t['PhanMem']) + '</td><td class="num">' + (HtmlE $t['DoDai']) + '</td></tr>') }
            A '</table></div>'
        }
    }
}

A '<footer>'
A '<p><b>Cách đọc.</b> "Sửa lần cuối" là sys.objects.modify_date, chỉ ghi lần sửa cuối cùng. Default trace ghi từng lần CREATE/ALTER/DROP kèm login, máy, phần mềm, nhưng không ghi nội dung và chỉ giữ vài file gần nhất. "Sửa gì" là so từng dòng với bản cũ đã chọn: bỏ qua khoảng trắng cuối dòng; nếu bản cũ cách xa nhiều lần sửa thì kết quả là thay đổi dồn lại.</p>'
A '<p>Muốn lưu đủ lịch sử từ nay: cài DDL trigger trong references\nhat-ky-ddl\ của skill (ghi CSDL, chạy .97 trước rồi .96).</p>'
A '</footer>'
A (Dong-Html)

$ten = 'BaoCaoSuaSP_{0}_{1}_{2:yyyyMMdd_HHmmss}.html' -f (Ten-AnToan $Server), (Ten-AnToan $Database), (Get-Date)
$null = Ghi-BaoCao $h.ToString() $ten
#endregion
