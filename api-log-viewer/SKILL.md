---
name: api-log-viewer
description: Thêm log có cấu trúc chi tiết cho 1 API ASP.NET Core. Log ghi các bước xử lý kèm thời gian từng bước, đầu vào/đầu ra, các lệnh gọi ra API/FTP/SP khác, che mật khẩu và không lưu chuỗi base64 nặng. Kèm màn hình tra cứu /logs.html chạy chung cổng với API, xoá log theo yêu cầu, tự xoá log cũ theo số ngày, mã quản trị và audit. Bộ template lấy từ 2ID.Service trong API_Signer, đã chạy thử thật. Dùng skill này khi người dùng muốn "làm log cho dự án/service X", "thêm màn hình tra log", "log chi tiết các bước / thời gian hoàn thành", "xem đầu vào đầu ra của API", "xoá log tự động / dọn log cũ", "log nặng quá", "log lộ mật khẩu", hoặc áp dụng phần log của 2ID.Service sang FPT.Service, Vnpt.Service, Visnam.Service, ViewPDF.Service hay API .NET khác. Dùng cả khi người dùng không nhắc tới chữ skill hay logs.html.
---

# API log viewer (log chi tiết + tra cứu + xoá log)

Kết quả sau khi áp dụng cho 1 service:

- **Log có cấu trúc**: mỗi lần xử lý 1 API ghi đúng 1 dòng JSON vào `Logs/{năm}/{tháng}/{ngày}/{Tag}.txt`.
  Dòng gồm `StartTime/EndTime` (đến mili giây), `DurationMs`, `ClientIp`, `Request`, `Response`, `Error`,
  `Steps[]` (từng bước: lúc bắt đầu, thời gian chạy, Input/Output, OK/Error/Skipped), `Calls[]` (lệnh gọi ra
  ngoài, gắn với bước), và `QueueWaitMs`/`Attempt` cho job chạy nền.
- **Che dữ liệu nhạy cảm, bỏ dữ liệu nặng**, làm ở 1 chỗ trong `ApiLogger`. Field password/secret/apikey/keyauth/
  token... thành `<đã ẩn>`. Base64 từ 100 ký tự trở lên thành `<chuỗi base64, length=N>`. `password=...` trong
  chuỗi thô cũng bị che. Field null không ghi. Log cũ được che lại khi hiển thị.
- `Api_Input`/`Api_Error` (middleware), `Tong_Hop_Loi` (tự chép mọi dòng có lỗi), `Log_Admin` (ghi lại thao tác xoá
  log, đổi cấu hình, tự dọn).
- **Trang `/logs.html`** (HTML + JS thuần, 1 file):
  - Tab tra cứu: lọc theo loại log, "tất cả loại log", ngày, từ khoá, kết quả. Chi tiết có thanh thời gian các
    bước, Request/Response, khối lỗi màu đỏ, JSON tô màu, nút sao chép.
  - Tab quản lý: dung lượng theo tag, cấu hình tự xoá, xoá theo khoảng ngày / giữ N ngày / xoá toàn bộ.
- **Tự xoá** bằng `LogCleanupBackgroundService` theo `LogSettings:RetentionDays`. Đổi trên trang thì lưu vào
  `Logs/log-settings.json`, file này ưu tiên hơn appsettings. Xoá và đổi cấu hình cần header `X-Log-Admin-Key`
  nếu có cấu hình `LogSettings:AdminKey`.

Yêu cầu: ASP.NET Core 3.1 trở lên (C# 8: `using var`, tuple), Newtonsoft.Json, Windows/IIS.
Lệnh shell dùng PowerShell.

## Quy trình

### 1. Khảo sát service đích

Đọc code trước khi chạy script. Các service trong cùng repo khác nhau nhiều hơn tên thư mục:

- **Namespace gốc**: lấy từ `namespace` trong `Startup.cs`, không lấy theo tên thư mục. Ví dụ `Vnpt.Service`
  khai báo `namespace Visnam.Service`.
- **LogRoute**: lấy tiền tố route của controller nghiệp vụ rồi thêm `/Logs`. Ví dụ `api/2ID/Logs`, `API/FPT/Logs`,
  `api/VNPT/Logs`. Nhờ vậy trang log đi cùng đường dẫn và cùng quy tắc mở cổng/IIS với API.
- **Các bản `RegLog`**: `Grep "static void RegLog"`. Nhiều controller có bản riêng, mỗi bản có `lock` riêng.
- **Hạ tầng log có sẵn**: `ApiCallRecorder`, `ApiLogger`, `LogViewerController`, `logs.html`. FPT.Service có bản
  cũ: `EndAndGet()` trả `List`, viewer chỉ đọc.
- **Luồng nghiệp vụ chính và các chỗ gọi ra ngoài**: HttpClient/RestSharp, FtpWebRequest, Dapper/SP, SDK ký số.
  Đây là nơi sẽ gắn Steps/Calls.
- **Serializer của MVC**: JS của trang đọc JSON dạng camelCase. Đây là mặc định của cả System.Text.Json lẫn
  `AddNewtonsoftJson`. Nếu service cấu hình PascalCase thì phải báo lại.
- **TargetFramework** trong csproj, và build 1 lần để biết lỗi có sẵn từ trước.

### 2. Cài template

```powershell
powershell -NoProfile -File "<skill-dir>\scripts\Install-LogViewer.ps1" `
    -ServiceDir "<...>\APIService\FPT.Service" -Namespace FPT.Service `
    -LogRoute "API/FPT/Logs" -ServiceTitle "FPT.Service" -DefaultTag "Signer_PDF_Queue"
```

- Script chép 9 file vào `Common/`, `Controllers/`, `wwwroot/`, giữ kiểu xuống dòng của project. File cũ khác
  nội dung được chép sang `<repo>\_backup\<thời điểm>_logviewer_<service>\` trước khi ghi đè (theo quy ước
  `_backup` sẵn có của repo).
- Dùng `-DryRun` để xem trước. Cuối cùng script in danh sách việc còn phải làm tay: các bản RegLog, các chỗ dùng
  `EndAndGet()` kiểu cũ, Startup, appsettings.
- Nếu service đã có class cùng tên ở chỗ khác (`LogHelper`, `JsonHelper` trong namespace `<ns>.Common`), build sẽ
  báo trùng. Khi đó gộp lại, không để 2 bản song song.

### 3. Gom mọi `RegLog` về `LogHelper`

Đổi thân của từng `static void RegLog(string IMEI, string Mess)` có sẵn thành 1 dòng, giữ nguyên chữ ký để các
chỗ đang gọi không phải sửa:

```csharp
public static void RegLog(string IMEI, string Mess) => LogHelper.RegLog(IMEI, Mess);
```

Lý do: chức năng xoá log khoá cùng `LogHelper.SyncRoot` với lúc ghi log. Nếu còn bản ghi log dùng `lock` riêng, nó
có thể ghi đúng lúc thư mục ngày vừa bị xoá, làm mất log. Trước khi gom, kiểm tra bản cũ có cùng định dạng
`Logs\{năm}\{tháng}\{ngày}\{tag}.txt` và dòng `DateTime: dd/MM/yyyy HH:mm:ss, Data: ...` không. Nếu khác định dạng
thì dừng lại và hỏi người dùng.

### 4. Nối vào Startup và appsettings

```csharp
// ConfigureServices
services.AddSingleton<ILogMaintenance, LogMaintenance>();
services.AddHostedService<LogCleanupBackgroundService>();

// Configure — thứ tự quan trọng
app.UseHttpsRedirection();
app.UseStaticFiles();                              // phục vụ wwwroot/logs.html
app.UseMiddleware<ApiRequestLoggingMiddleware>();  // ghi Api_Input / Api_Error
app.UseRouting();
```

```jsonc
// appsettings.json
"LogSettings": {
  "RetentionDays": 30, // giữ log N ngày gần nhất (tính cả hôm nay), cũ hơn tự xoá; 0 = không tự xoá
  "CleanupIntervalHours": 6, // bao lâu chạy dọn log tự động 1 lần
  "AdminKey": "" // mã phải nhập khi xoá log / đổi cấu hình trên màn hình log; để trống = không yêu cầu
},
"ApiSwitch": { "Controllers": { "LogViewer": true } } // nếu service có ApiSwitchFilter
```

Repo API_Signer: thêm vào `Deploy\deploy-manifest.json` trong `controllers` của service:

```json
{
  "name": "LogViewer", "title": "Tra cứu / quản lý log API (/logs.html)",
  "note": "Tắt controller này thì trang /logs.html không lấy được dữ liệu. Tắt riêng DeleteLogs/SaveSettings nếu không muốn cho xoá log trên màn hình",
  "actions": [ "GetTags", "Search", "GetStats", "GetSettings", "SaveSettings", "DeleteLogs" ],
  "settings": [
    { "key": "LogSettings:RetentionDays", "type": "int", "default": "30", "title": "Giữ log bao nhiêu ngày (cũ hơn tự xoá, 0 = không tự xoá)" },
    { "key": "LogSettings:CleanupIntervalHours", "type": "int", "default": "6", "title": "Chu kỳ tự dọn log (giờ)", "advanced": true },
    { "key": "LogSettings:AdminKey", "type": "secret", "title": "Mã quản trị bắt buộc khi xoá log / đổi cấu hình trên /logs.html (để trống = không yêu cầu)" }
  ]
}
```

Bộ công cụ deploy dùng `robocopy /XD Logs`, nên thư mục `Logs` (gồm cả `log-settings.json`) không bị ghi đè khi deploy.

### 5. Gắn Steps và Calls vào luồng nghiệp vụ

Đọc `references/instrumenting-steps.md` trước khi sửa. Tóm tắt:

```csharp
ApiCallRecorder.Begin();                                    // đầu action / đầu mỗi lần xử lý job
try { ... }
finally { ApiLogger.Log("Ten_Api", new ApiLogEntry { ... }, ApiCallRecorder.EndAndGet()); }

using var step = ApiCallRecorder.BeginStep("Tên bước nghiệp vụ", new { /* input tóm tắt */ });
step.Ok(new { /* output tóm tắt */ });   // hoặc step.Fail("lỗi") / step.Skip("lý do")
// thoát using khi chưa Ok/Fail/Skip (do exception) -> bước tự thành Error

ApiCallRecorder.Record(new ApiCallLog { Name, Url, Method, Request, Response, Error, DurationMs }); // trong finally của hàm gọi ra ngoài
```

Khi tách hàm dài thành các hàm con theo bước, giữ nguyên logic và thứ tự. Không truyền `byte[]` hay model chứa file
vào log, hãy viết `SummarizeInput`/`SummarizeResult` trả về độ dài thay cho dữ liệu.

### 6. Build và kiểm thử thật

Làm theo `references/verification.md`:
- Chạy dll từ thư mục tạm với `--contentRoot`, để log thử không ghi vào project.
- Dựng fake upstream bằng `scripts/Start-FakeUpstream.ps1` và tạo log cũ giả bằng `scripts/New-SeedLogs.ps1`.
- Gửi đủ các trường hợp: thành công, cảnh báo, dịch vụ báo lỗi, exception giữa bước, hàng đợi, query có mật khẩu.
- Quét rò rỉ bằng `scripts/Test-LogLeaks.ps1`, gọi thử các API xoá/cấu hình, rồi chạy `scripts/Test-LogViewerUi.ps1`
  và xem ảnh chụp.

Chỉ báo xong khi những bước này đạt. Nếu bước nào bỏ qua (vd. không có dịch vụ thật), phải nói rõ là chưa kiểm.

### 7. Báo cáo cho người dùng

Ngoài danh sách file đã đổi, luôn nêu 2 việc cần người dùng quyết định trước khi deploy:
1. `RetentionDays` mặc định **30**: sau khi deploy, log cũ hơn 30 ngày sẽ **tự bị xoá**. Muốn tắt thì đặt `0`.
2. `AdminKey` để trống: ai mở được `/logs.html` cũng xoá được log. Nên đặt mã, hoặc giới hạn IP cho `/logs.html` và
   `/<LogRoute>/*`, vì log có dữ liệu nghiệp vụ.

## Lỗi đã gặp: giữ nguyên cách xử lý trong template

- **Middleware cắt body trước khi parse JSON**: JSON bị cắt dở nên hỏng, cả chuỗi base64 bị lưu nguyên văn. Phải
  parse nguyên body, che xong mới cắt (template đã làm đúng).
- **Che mật khẩu 2 lần** (middleware rồi ApiLogger) ra `<đã ẩn> ẩn>`: regex có lookahead bỏ qua giá trị đã che. Đừng
  "đơn giản hoá" regex đó. Kết quả phải giống nhau dù lọc bao nhiêu lần, vì lúc đọc log cũng lọc lại.
- **Json.NET tự đổi chuỗi ngày giờ** khi parse: `JsonHelper` đọc với `DateParseHandling.None`.
- **System.Text.Json (3.1) không serialize field**: DTO trả về cho trang log phải dùng property. `[JsonIgnore]` của
  Newtonsoft chỉ có tác dụng khi ghi file, không có tác dụng với JSON API.
- **Tìm "Tất cả loại log"** bỏ qua `Tong_Hop_Loi`, vì tag này chỉ là bản sao nên sẽ hiện trùng.
- **Xoá file ILogger** (`Logs/yyyyMMdd.txt`) của hôm nay luôn thất bại do Serilog đang mở file, nên template bỏ qua file
  của hôm nay.
- **Tag** dùng làm tên file, phải khớp `^[\w\-]+$`, nếu không thì trả 400. Điều này chặn `..\` đọc/xoá file ngoài `Logs`.
- **Trùng tên `JsonHelper`** với `APICommonLibrary.Helpers.JsonHelper`: file nào `using` cả hai namespace và gọi
  `JsonHelper.` thì phải ghi đủ namespace.
- **PowerShell 5.1** đọc file `.ps1` không có BOM theo mã ANSI. Các script trong skill được lưu UTF-8 có BOM, nếu chỉnh
  sửa thì giữ nguyên BOM.

## Tài nguyên trong skill

| Đường dẫn | Dùng khi |
|---|---|
| `templates/` | Nguồn của `Install-LogViewer.ps1`. Token: `%%NAMESPACE%%`, `%%LOG_ROUTE%%`, `%%SERVICE_TITLE%%`, `%%DEFAULT_TAG%%` |
| `scripts/Install-LogViewer.ps1` | Bước 2 |
| `scripts/Start-FakeUpstream.ps1`, `scripts/New-SeedLogs.ps1`, `scripts/Test-LogLeaks.ps1`, `scripts/Test-LogViewerUi.ps1` | Bước 6 |
| `references/instrumenting-steps.md` | Bước 5: mẫu controller, job nền, chia bước, Record, chuyển code cũ, gợi ý cho từng service API_Signer |
| `references/verification.md` | Bước 6: lệnh chạy cô lập, bảng request và kỳ vọng, API cần gọi |

Bản gốc đã chạy thật nằm ở `H:\01. Project\07. HIS\API_Signer\APIService\2ID.Service` (Common/, Controllers/
LogViewerController.cs, wwwroot/logs.html, Common/SignCloudProcessor.cs là mẫu chia bước). Khi template và bản gốc
khác nhau, đọc bản gốc để đối chiếu.
