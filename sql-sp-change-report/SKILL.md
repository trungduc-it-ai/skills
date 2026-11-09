---
name: sql-sp-change-report
description: Báo cáo stored procedure / hàm / view / trigger SQL Server bị sửa lúc nào, ai sửa (login, máy, phần mềm, giờ từng lần ALTER lấy từ default trace), sửa gì (so từng dòng với ảnh chụp lần trước, CSDL sao lưu cùng server, server khác hoặc file .sql, có ghi nhánh @Action chứa chỗ sửa). Người dùng chạy script PowerShell, tự nhập server/CSDL/login/mật khẩu/tên SP, nhận báo cáo HTML. Script chỉ đọc CSDL và không lưu mật khẩu. Kèm script DDL trigger để lưu đủ lịch sử từ nay về sau. Dùng skill này khi người dùng hỏi "SP X bị sửa lúc mấy giờ", "ai sửa store", "store bị sửa cái gì", "so sánh SP với bản cũ / .96 với .97", "lịch sử sửa stored procedure", "kiểm tra SP bị ghi đè", "chụp lại toàn bộ SP làm mốc", hoặc muốn so 2 file .sql. Dùng cả khi người dùng không nhắc tới chữ skill.
---

# Báo cáo sửa Stored Procedure (lúc nào · ai sửa · sửa gì)

SQL Server chỉ giữ **lần sửa cuối** (`sys.objects.modify_date`). Nó không lưu bản cũ và không lưu ai sửa. Skill
này ghép 3 nguồn thành 1 báo cáo HTML:

| Câu hỏi | Nguồn | Giới hạn |
|---|---|---|
| Sửa lúc nào | `modify_date` | Chỉ lần cuối |
| Ai sửa, từng lần | Default trace (`sys.fn_trace_gettable`, sự kiện 46/47/164) → login, Windows user, máy, phần mềm, SPID, giờ | Cần quyền `ALTER TRACE`. Trace chỉ giữ ~5 file × 20 MB, máy bận chỉ còn vài giờ đến vài ngày. Không có nội dung code |
| Sửa gì | So từng dòng (Myers) với một bản cũ | Phải có bản cũ: ảnh chụp lần trước, CSDL sao lưu, server khác hoặc file |
| Lịch sử đầy đủ | Bảng `dbo.DBA_NhatKySuaDoiTuong` (DDL trigger, tuỳ chọn) | Phải cài trước. Chỉ ghi các lần sửa sau khi cài |

## Chạy

Double-click `scripts\BaoCaoSuaSP.cmd`. Script hỏi lần lượt:

1. Việc: báo cáo cho SP (mặc định), hoặc chụp toàn bộ SP/hàm/view/trigger của CSDL làm mốc.
2. Server, CSDL, kiểu đăng nhập (SQL login / Windows), login, mật khẩu. Mật khẩu nhập dạng ẩn, chỉ giữ trong bộ nhớ.
   Script ghi nhớ server/CSDL/login (không có mật khẩu) vào `output\lan-truoc.json`.
3. Tên đối tượng:
   - Nhiều tên thì cách nhau dấu phẩy.
   - Có `%` thì tìm theo mẫu (`sp_CLS%`).
   - Để trống là lấy mọi đối tượng sửa trong N ngày.
   - Có thể ghi kèm schema (`dbo.sp_X`, `[dbo].[sp_X]`).
4. Bản để so sánh:
   - `1` ảnh chụp lần chạy trước (mặc định)
   - `2` CSDL khác cùng server: script liệt kê CSDL kèm giờ sửa của SP trong từng CSDL
   - `3` server khác, dùng cùng login (vd .96 ↔ .97)
   - `4` file .sql, chỉ khi xem đúng 1 SP
   - `0` không so sánh

Báo cáo lưu ở `output\BaoCao\BaoCaoSuaSP_<server>_<CSDL>_<thời điểm>.html` và tự mở.

Chạy bằng tham số, không cần hỏi (mật khẩu vẫn được hỏi, hoặc truyền `-Credential`):

```powershell
$s = "H:\88. Skills\sql-sp-change-report\scripts\BaoCaoSuaSP.ps1"
# 1 SP, so với bản trong CSDL sao lưu cùng server
& $s -Server TEN_SERVER -Database TEN_CSDL -Login TEN_LOGIN -Objects sp_CLSYEUCAUCHITIET -CompareWith Database -CompareDatabase TEN_CSDL_old
# mọi SP tên sp_CLS% sửa trong 3 ngày, so với ảnh chụp lần trước
& $s -Server TEN_SERVER -Database TEN_CSDL -Login TEN_LOGIN -Objects "sp_CLS%" -Days 3 -CompareWith Snapshot
# so với server khác (vd production)
& $s -Server TEN_SERVER -Database TEN_CSDL -Login TEN_LOGIN -Objects sp_NHANVIEN -CompareWith Server -CompareServer TEN_SERVER_2
# chụp toàn bộ làm mốc (nên chạy định kỳ, vd đầu ngày)
& $s -SnapshotAll -Server TEN_SERVER -Database TEN_CSDL -Login TEN_LOGIN
# so 2 file .sql, không cần CSDL
& $s -OldFile "D:\sp_X_BanGoc.sql" -NewFile "D:\sp_X_Moi.sql"
```

Tham số khác:
- `-OutputDir`: mặc định `<skill>\output`.
- `-MaxObjects`: số đối tượng tối đa trong 1 báo cáo, mặc định 30.
- `-NoOpen`: không tự mở báo cáo.
- `-NoPrompt`: không hỏi gì, thiếu thông tin thì dùng giá trị mặc định. Cần kèm `-Credential`.

## Báo cáo có gì

- **Đầu trang**:
  - server (kèm `@@SERVERNAME`), CSDL, người chạy, điều kiện lọc, bản so sánh;
  - default trace còn dữ liệu từ lúc nào;
  - có hay chưa có bảng nhật ký DDL.
- **Tổng hợp**: mỗi đối tượng 1 dòng gồm sửa lần cuối, ai sửa gần nhất theo trace, giờ sửa của bản so sánh, số dòng thêm/bỏ.
- **Từng đối tượng**:
  - Thông tin: loại, giờ tạo / sửa, số dòng, mã băm SHA1, đường dẫn ảnh chụp.
  - **Sửa gì**: các khối thay đổi, mỗi khối kèm 3 dòng ngữ cảnh. Có số dòng bản cũ và bản mới. Ghi **nhánh `@Action = '...'`** chứa chỗ sửa (kiểu SP `SP_<Bảng>` + `@Action` của eHospital).
  - **Ai sửa**: tối đa 50 lần gần nhất. Dòng trùng `modify_date` (lệch ≤ 2 giây) được đánh dấu "khớp modify_date".
  - **Nhật ký DDL**, nếu đã cài.

So sánh bỏ qua khoảng trắng cuối dòng. Nếu khác quá nhiều (trên 3000 chỗ), báo cáo chuyển sang liệt kê dòng thêm/bỏ
theo nội dung. Bản cũ cách nhiều lần sửa thì kết quả là thay đổi **dồn lại**.

## Ảnh chụp

Mỗi lần chạy, bản hiện tại của từng đối tượng được lưu vào
`output\AnhChup\<server>\<CSDL>\<schema.tên>\<modify_date yyyyMMdd_HHmmss_fff>.sql` (UTF-8 BOM, mở được bằng SSMS).
Bản đã có thì không lưu lại.

Chế độ so sánh `1` lấy ảnh có `modify_date` gần nhất **trước** bản hiện tại. Vì vậy:

- Lần đầu chạy cho 1 SP thì chưa có gì để so. Lần đó chỉ chụp làm mốc.
- Nên chạy `-SnapshotAll` định kỳ (vd Task Scheduler mỗi sáng) để luôn có mốc.
- Thư mục `output\` chứa mã nguồn SP. Không chia sẻ ra ngoài.

## Lưu lịch sử đủ từ nay: DDL trigger (ghi CSDL, tuỳ chọn)

`references\nhat-ky-ddl\`:

- `01_TaoNhatKy_DDLTrigger.sql`: tạo bảng `dbo.DBA_NhatKySuaDoiTuong` và trigger `TR_DBA_NhatKySuaDoiTuong ON DATABASE`.
  Mỗi lần CREATE/ALTER/DROP SP, hàm, view, trigger, trigger ghi giờ, login, máy, phần mềm và nguyên văn lệnh.
  Trigger đặt `XACT_ABORT OFF` + `TRY/CATCH`, nên lỗi ghi nhật ký **không chặn** lệnh ALTER.
- `02_XemNhatKy_CHI_DOC.sql`: xem các lần sửa và khác biệt giữa 2 lần liên tiếp, dùng trong SSMS.
- `99_GoNhatKy.sql`: gỡ trigger. Bảng được giữ lại.

Chạy trên máy thử trước, production sau. Bảng lớn dần vì lưu cả code SP lớn. Khi có bảng này, `BaoCaoSuaSP.ps1` tự
đọc và hiện thêm mục "Nhật ký DDL".

Script SSMS chỉ đọc, dùng khi không chạy được PowerShell:
- `references\ssms_AiSua_CHI_DOC.sql`: modify_date + default trace.
- `references\ssms_SoSanhBanCu_CHI_DOC.sql`: so với CSDL sao lưu. Cần SQL Server 2022 vì dùng `STRING_SPLIT ... enable_ordinal`.

## Ghi chú cho Claude

- Script **chỉ đọc** (SELECT, `sys.fn_trace_gettable`, `OBJECT_DEFINITION`). Nó chỉ ghi file vào `output\`.
- Mật khẩu: **người dùng tự nhập** trong cửa sổ PowerShell. Không đọc mật khẩu từ file cấu hình. Không truyền mật
  khẩu qua tham số dòng lệnh. Không ghi mật khẩu vào file hay memory.
- Khi người dùng hỏi về 1 SP: mở cửa sổ cho họ nhập mật khẩu, dùng `-NoExit` để thấy lỗi nếu có:
  ```powershell
  Start-Process powershell.exe -ArgumentList '-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-File',"`"<skill>\scripts\BaoCaoSuaSP.ps1`"",'-Server','<ip>','-Database','<db>','-Auth','Sql','-Login','<login>','-Objects','<sp>','-CompareWith','Database','-CompareDatabase','<db_sao_luu>','-NoOpen'
  ```
  Sau đó chờ file mới trong `output\BaoCao\`, rồi đọc HTML (hoặc chụp bằng `msedge --headless=new --screenshot`).
  Auto mode có thể chặn Claude đọc server production. Khi đó để người dùng tự chạy.
- Tên máy (`HostName`) trùng `$env:COMPUTERNAME` nghĩa là lần sửa đó làm từ chính máy đang chạy.
- PowerShell 5.1: file `.ps1` phải là UTF-8 **có BOM**, nếu không tiếng Việt bị hỏng. Phần diff là C# biên dịch bằng
  `Add-Type`, viết theo cú pháp C# 5.

## Đã kiểm thử (05/11/2026)

- Myers: 300 cặp ngẫu nhiên, dựng lại đúng cả bản cũ lẫn bản mới.
- So 2 file: 2 bản thật của `sp_CLSYEUCAUCHITIET` (25/09 ↔ 04/11) ra +2 / −1, đúng như đối chiếu tay. Nhánh `@Action` ghi đúng.
- CSDL thật (TEN_SERVER, login TEN_LOGIN): so với `TEN_CSDL_old`.
  - Diff ra +3 / −2.
  - Default trace đọc được, còn dữ liệu từ 19/01/2026, với 25 lần ALTER (login, máy, SSMS).
  - Ảnh chụp lưu đúng.
