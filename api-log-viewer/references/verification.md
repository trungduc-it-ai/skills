# Kiểm thử sau khi cài

Mục tiêu: chạy app thật, gửi request thật, xem file log và trang `/logs.html`, rồi mới báo xong. Không chạm
vào thư mục `Logs` hay cấu hình thật của service.

## 1. Build

```powershell
dotnet build "<ServiceDir>\<Project>.csproj" -nologo -v q 2>&1 | Select-String " error |Build succeeded|Error\(s\)"
```

Nên build 1 lần **trước** khi cài để biết lỗi nào có sẵn từ trước.

## 2. Chạy cô lập

`LogsRoot = "Logs"` là đường dẫn tương đối theo **thư mục làm việc (CWD)**. Vì vậy chạy dll từ một thư mục
tạm, còn `--contentRoot` trỏ về project để vẫn đọc được `appsettings.json` và `wwwroot`. Log thử sẽ nằm trong
thư mục tạm, không làm bẩn project:

```powershell
# chạy nền (run_in_background), CWD = thư mục tạm
Set-Location "<scratch>\run"
$env:ASPNETCORE_URLS = "http://127.0.0.1:18202"
$env:ASPNETCORE_ENVIRONMENT = "Production"
# trỏ mọi dịch vụ bên ngoài về fake upstream, FTP về cổng đóng để thử nhánh lỗi
$env:KySo2ID__Url = "http://127.0.0.1:18110/sign"
$env:FTP__Host = "ftp://127.0.0.1:1"
$env:LogSettings__AdminKey = "test123"
dotnet "<ServiceDir>\bin\Debug\netcoreapp3.1\<Assembly>.dll" --contentRoot "<ServiceDir>"
```

Chờ đến khi `GET /logs.html` trả 200. Dừng app bằng cách tìm tiến trình đang nghe cổng:
`(Get-NetTCPConnection -LocalPort 18202 -State Listen).OwningProcess | % { Stop-Process -Id $_ -Force }`.
Phải dừng app trước khi build lại, vì dll đang bị khoá.

## 3. Dữ liệu giả

```powershell
# log kiểu cũ còn mật khẩu/base64 + các ngày cũ để thử tự xoá (chạy TRƯỚC khi khởi động app)
powershell -File "<skill>\scripts\New-SeedLogs.ps1" -LogsDir "<scratch>\run\Logs"

# fake upstream (chạy nền)
powershell -File "<skill>\scripts\Start-FakeUpstream.ps1" -Port 18110 -RoutesFile "<scratch>\routes.json"
```

Viết `routes.json` theo đúng các dịch vụ mà service gọi ra. Xem định dạng trong phần đầu của script.
Nên có ít nhất 1 route với `failWhen` để thử nhánh dịch vụ báo lỗi.

## 4. Request cần gửi

Gửi đủ các trường hợp sau (sửa theo API thật của service):

| Trường hợp | Kỳ vọng trên log |
|---|---|
| Thành công trọn vẹn | Thành công, đủ bước, các bước đều OK |
| Thành công nhưng 1 bước phụ lỗi (FTP về `127.0.0.1:1`) | Cảnh báo, bước đó Error, có trong `Tong_Hop_Loi` |
| Dịch vụ ngoài trả mã lỗi (body chứa `failWhen`) | Lỗi, bước gọi dịch vụ Error kèm mã lỗi |
| Tham số sai làm hàm ném exception giữa chừng (vd. số toạ độ = "abc") | Lỗi, bước đang chạy có "Bước bị dừng giữa chừng do exception" |
| Đi qua hàng đợi (nếu có) | Entry của job có `QueueWaitMs`, `Attempt`/`MaxAttempt` |
| `GET ...?password=Secret123&token=abc` | `Api_Input` ghi `?password=<đã ẩn>&token=<đã ẩn>` (che đúng 1 lần, không lặp) |

PowerShell gửi JSON có `byte[]`: `ConvertTo-Json` của chuỗi base64, rồi
`Invoke-WebRequest -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType "application/json; charset=utf-8"`.

## 5. Kiểm tra file log

```powershell
powershell -File "<skill>\scripts\Test-LogLeaks.ps1" -LogsDir "<scratch>\run\Logs" `
    -Secrets 'mật khẩu trong appsettings', 'SeedP@ssw0rd!' -Exclude Legacy_Input.txt
```

`Legacy_Input.txt` là log kiểu cũ do script tạo ra. Trên đĩa nó vẫn còn nguyên mật khẩu, vì bộ lọc chỉ che khi
hiển thị, nên phải loại trừ khi quét. Mở 1 dòng của API chính rồi parse JSON để xem đủ `Steps` (Order, Name,
OffsetMs, DurationMs, Status, Input/Output) và `Calls` có `StepOrder`.

## 6. Kiểm tra API của trang log

| Gọi | Kỳ vọng |
|---|---|
| `GET <route>/Tags` | Danh sách tag thật |
| `GET <route>/Search?tag=Legacy_Input&fromDate=<hôm qua>` | Mật khẩu/base64 đã bị che trong `message` |
| `GET <route>/Search?tag=*&fromDate=<hôm nay>&keyword=...` | Có `tag` trong mỗi entry, không có `Tong_Hop_Loi` |
| `GET <route>/Search?tag=..%5C..%5Cappsettings&fromDate=...` | 400 |
| `POST <route>/Delete?tag=*&fromDate=..&toDate=..` không có header | 401 (khi có AdminKey) |
| như trên + `X-Log-Admin-Key: test123` | 200, `deletedFiles` đúng |
| `POST <route>/Delete?tag=X&keepDays=1` / `&all=true` | Chỉ xoá tag X, thư mục rỗng được dọn |
| `POST <route>/Settings?retentionDays=60&cleanupIntervalHours=12&applyNow=true` | Ghi `Logs/log-settings.json`, trả kết quả dọn |
| `GET <route>/Stats` | Dung lượng theo tag, có `(ILogger)`, `adminKeyRequired` |

Tự dọn chạy sau khi app khởi động 1 phút. Chờ khoảng 70 giây rồi xem `Log_Admin`. Với RetentionDays = 30, các
ngày -90, -45 và file ILogger cũ phải bị xoá, ngày -10 vẫn còn.

## 7. Giao diện

```powershell
powershell -File "<skill>\scripts\Test-LogViewerUi.ps1" -BaseUrl http://127.0.0.1:18202 -Tag <tag chính> -OutDir "<scratch>\ui"
```

Đạt khi: số bước trong chi tiết lớn hơn 0, có placeholder bị che, không tràn ngang ở 390px, lỗi JS = 0. Xem các
ảnh PNG (bằng công cụ Read) để kiểm tra bố cục. Trang tĩnh được đọc thẳng từ `wwwroot` của project, nên sửa
`logs.html` xong chỉ cần chạy lại script, không phải khởi động lại app.

## 8. Dọn dẹp

`GET http://127.0.0.1:18110/stop` để dừng fake upstream, dừng app theo cổng, và kiểm tra trong project không phát
sinh thư mục `Logs`.
