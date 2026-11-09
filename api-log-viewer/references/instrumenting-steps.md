# Gắn Steps / Calls vào luồng nghiệp vụ

Template chỉ cung cấp hạ tầng. Phần đáng giá nhất của màn hình log là **các bước** của từng API. Phần
này phải viết tay theo đúng luồng của service, vì mỗi service gọi ra ngoài theo cách khác nhau.

## Mục lục
1. Khái niệm
2. Điểm vào: controller action
3. Điểm vào: job chạy nền (hàng đợi)
4. Chia bước trong hàm xử lý
5. Ghi Calls ở hàm gọi ra ngoài
6. Tóm tắt Request/Response
7. Đặt tên tag
8. Chuyển code dùng kiểu cũ (FPT.Service)
9. Gợi ý điểm cần gắn trong API_Signer

---

## 1. Khái niệm

| Thành phần | Ý nghĩa | Ai tạo |
|---|---|---|
| Entry (`ApiLogEntry`) | 1 dòng log = 1 lần xử lý (1 request hoặc 1 lần thử của job), cả khi thành công lẫn thất bại | Điểm vào, trong `finally` |
| Trace (`ApiTrace`) | Đồng hồ + danh sách Steps/Calls, đi theo luồng async qua `AsyncLocal` | `ApiCallRecorder.Begin()` |
| Step (`ApiStepLog`) | 1 bước nghiệp vụ: thời điểm bắt đầu (`OffsetMs`), `DurationMs`, Input/Output, `OK`/`Error`/`Skipped` | `using var step = ApiCallRecorder.BeginStep(...)` |
| Call (`ApiCallLog`) | 1 lần gọi ra ngoài (HTTP, FTP, SP, SDK). Tự gắn vào bước đang mở (`StepOrder`) | `ApiCallRecorder.Record(...)` |

Lý do dùng `AsyncLocal`: không phải truyền danh sách log qua từng tầng hàm. Hàm sâu bên trong chỉ cần gọi
`Record`/`BeginStep`. Khi không có `Begin()` (vd. hàm được gọi từ chỗ khác), các lệnh này tự bỏ qua, không lỗi.

## 2. Điểm vào: controller action

```csharp
[HttpPost("KySo2ID")]
public async Task<SignCloudResp> KySo2ID(KySoICAModel model)
{
    ApiCallRecorder.Begin();
    SignCloudResp result = null;
    try
    {
        result = await _processor.ProcessAsync(model);
        return result;
    }
    finally
    {
        // Overload có trace tự điền StartTime, DurationMs, Steps, Calls.
        ApiLogger.Log("KySo_2ID", new ApiLogEntry
        {
            Url = Request.Path,
            Method = "POST",
            ClientIp = HttpContext.Connection.RemoteIpAddress?.ToString(),
            Request = SignCloudProcessor.SummarizeInput(model),
            Response = SignCloudProcessor.SummarizeResult(result),
            Error = result == null || result.responseCode != 0 ? "Ký số thất bại (responseCode = " + result?.responseCode + ")" : null
        }, ApiCallRecorder.EndAndGet());
    }
}
```

- Ghi trong `finally` để exception cũng có log.
- `Error` khác null tức là API thất bại. Nếu entry không có Error nhưng có Step/Call lỗi, trang log hiện "Cảnh báo"
  (vd. ký xong nhưng upload FTP lỗi). Cả hai trường hợp đều tự được chép thêm vào `Tong_Hop_Loi`.

## 3. Điểm vào: job chạy nền (hàng đợi)

Gọi `Begin()` cho **mỗi lần xử lý 1 job**, không gọi 1 lần cho cả vòng lặp. Thêm `EnqueuedAt` vào item của
hàng đợi để biết job phải chờ bao lâu:

```csharp
public class SignJobItem
{
    // ...
    public DateTime EnqueuedAt { get; set; } = DateTime.Now; // mỗi lần requeue là item mới
}

// trong vòng lặp consumer
long queueWaitMs = (long)Math.Max(0, (DateTime.Now - job.EnqueuedAt).TotalMilliseconds);
ApiCallRecorder.Begin();
// ... xử lý, bắt lỗi vào biến error ...
var trace = ApiCallRecorder.EndAndGet();
ApiLogger.Log("KySo_2ID_Queue", new ApiLogEntry
{
    RequestId = job.RequestId,
    Url = "KySo2IDQueue (background)",
    Method = "POST",
    QueueWaitMs = queueWaitMs,
    Request = SignCloudProcessor.SummarizeInput(job.Model),
    Response = SignCloudProcessor.SummarizeResult(result),
    Error = error,
    Attempt = job.Attempt,
    MaxAttempt = MaxAttempts
}, trace);
```

Nhánh thất bại hoặc retry nhận `ApiTrace trace` làm tham số. Không gọi `EndAndGet()` lần 2 (lần 2 trả về trace rỗng).

## 4. Chia bước trong hàm xử lý

Mỗi bước nên là 1 hàm con có `using var step` ở đầu hàm. Phạm vi `using` chính là ranh giới của bước. Nếu
exception làm thoát khỏi bước khi chưa gọi `Ok/Fail/Skip`, bước tự bị đánh dấu `Error` ("Bước bị dừng giữa
chừng do exception"). Nhờ vậy log chỉ ra đúng bước gây lỗi, kể cả khi exception được bắt ở tầng ngoài.

```csharp
public async Task<SignCloudResp> ProcessAsync(KySoICAModel model)
{
    var resp = new SignCloudResp();
    try
    {
        string data = await GetPdfToSignAsync(model);      // Bước 1
        SigningReq req = BuildSigningReq(model, data);     // Bước 2
        var result = await SignStepAsync(req);             // Bước 3
        // ... Bước 4 giải mã, Bước 5 upload FTP
    }
    catch (Exception ex)
    {
        resp.responseCode = -1;
        ApiCallRecorder.Record(new ApiCallLog { Name = "Unexpected_Exception", Error = ex.ToString() });
    }
    return resp;
}

private SigningReq BuildSigningReq(KySoICAModel model, string data)
{
    using var step = ApiCallRecorder.BeginStep("Tạo yêu cầu ký (trang, vị trí, hồ sơ ký)", new
    {
        model.CertAlias, model.PageCKS, model.PositionLeft, model.PositionBottom
    });
    // ... float.Parse(...) có thể ném -> bước tự thành Error
    step.Ok(additionAppearanceSetting);
    return req;
}

private void UploadSignedFileStep(KySoICAModel model, SignCloudResp resp)
{
    using var step = ApiCallRecorder.BeginStep("Upload file đã ký lên FTP");
    if (string.IsNullOrEmpty(model.FolderName))
    {
        step.Skip("Request không truyền FolderName - không upload FTP");
        return;
    }
    step.SetInput(new { ftpHost, remotePath, dataLength = resp.signedFileData.Length });
    // ... gọi FTP (Record Call bên trong, xem mục 5)
    if (resp.ftpUploaded) step.Ok(new { resp.ftpPath }); else step.Fail(resp.ftpError);
}
```

Nguyên tắc chia bước:
- Mỗi API thường có 3–7 bước, đặt tên theo nghiệp vụ, dễ hiểu với người vận hành ("Lấy file PDF cần ký",
  "Gửi yêu cầu ký lên 2sign cloud"). Không lấy tên hàm làm tên bước.
- Mỗi lần gọi ra ngoài nên nằm trọn trong 1 bước. Khi đó thanh thời gian chỉ ra ngay bước nào chậm.
- Input/Output của bước là **tóm tắt**: tham số quyết định, độ dài dữ liệu, mã kết quả. Không đưa nguyên file.
- Nhánh không chạy (không cấu hình, không truyền tham số) thì dùng `Skip(lý do)`. Như vậy log trả lời được câu
  "sao không upload?".
- Khi tách code cũ thành hàm con, giữ nguyên logic và thứ tự xử lý. Chỉ thêm phần ghi log.

## 5. Ghi Calls ở hàm gọi ra ngoài

Gắn `Record` vào **hàm dùng chung** gọi ra ngoài (HTTP helper, FTP helper, hàm gọi SP), đặt trong `finally`
để cả lỗi cũng được ghi:

```csharp
var sw = Stopwatch.StartNew();
string body = null, error = null;
try
{
    var response = await client.PostAsync(url, content);
    body = await response.Content.ReadAsStringAsync();
    if (!response.IsSuccessStatusCode) error = $"HTTP {(int)response.StatusCode}";
}
catch (Exception ex) { error = ex.Message; }
finally
{
    sw.Stop();
    ApiCallRecorder.Record(new ApiCallLog
    {
        Name = "Report_Export_PDF",          // tên ngắn, dạng Tu_Noi
        Url = url,
        Method = "POST",
        Request = requestObject,              // object thật; ApiLogger tự che mật khẩu/base64
        Response = JsonHelper.TryParse(body), // parse để hiển thị đẹp, không parse được thì giữ chuỗi
        Error = error,
        DurationMs = sw.ElapsedMilliseconds
    });                                       // OffsetMs, StepOrder tự điền
}
```

Không tự cắt chuỗi hay che mật khẩu ở đây. `ApiLogger` làm việc đó ở 1 chỗ duy nhất: che field có tên kiểu
password/secret/apikey/keyauth/token..., thay base64 từ 100 ký tự trở lên bằng `<chuỗi base64, length=N>`,
che `password=...` trong chuỗi thô. Muốn che thêm tên field riêng của service thì thêm vào
`SensitiveNameParts`/`SensitiveExactNames` trong `JsonHelper`.

## 6. Tóm tắt Request/Response

Không truyền model có `byte[]` lớn vào log. Json.NET sẽ serialize cả file ra base64 trong bộ nhớ, sau đó mới
bị lọc. Viết 2 hàm static tóm tắt và dùng chung cho controller lẫn job nền:

```csharp
public static object SummarizeInput(KySoICAModel model) => model == null ? null : new
{
    model.CertAlias, model.SigningProfileId, model.PageCKS, model.FolderName, model.FileName,
    FileDataLength = model.FileData?.Length ?? 0,   // byte[] -> độ dài
    model.SourceFilePath,                            // chuỗi base64 ảnh -> ApiLogger tự che
    model.Report
};

public static object SummarizeResult(SignCloudResp r) => r == null ? null : new
{
    r.responseCode, signedFileDataLength = r.signedFileData?.Length ?? 0, r.ftpUploaded, r.ftpPath, r.ftpError
};
```

## 7. Đặt tên tag

- Tên file log = tag. Viết theo dạng `Ten_Api` có dấu `_`, không khoảng trắng (regex hợp lệ: `^[\w\-]+$`).
  Ví dụ: `Signer_PDF`, `Signer_PDF_Queue`, `KySo_2ID`.
- Tag có sẵn, không dùng cho việc khác: `Api_Input`, `Api_Error` (middleware ghi), `Tong_Hop_Loi` (tự chép các
  dòng lỗi), `Log_Admin` (ghi lại thao tác xoá log, đổi cấu hình, tự dọn log).
- Mỗi API chính ghi đúng 1 tag, cả thành công lẫn thất bại. Không tách thành file `_OK` và `_Loi` riêng.

## 8. Chuyển code dùng kiểu cũ (FPT.Service)

Bản cũ: `ApiCallRecorder.EndAndGet()` trả `List<ApiCallLog>` và tự đo bằng `Stopwatch`. Bản mới trả `ApiTrace`.
`Install-LogViewer.ps1` sẽ liệt kê các chỗ cần sửa.

```csharp
// Cũ
var stopwatch = Stopwatch.StartNew();
ApiCallRecorder.Begin();
...
ApiLogger.Log("Signer_PDF", new ApiLogEntry
{
    Url = ..., Request = ..., Response = ..., Error = ...,
    Calls = ApiCallRecorder.EndAndGet(),
    DurationMs = stopwatch.ElapsedMilliseconds
});

// Mới
ApiCallRecorder.Begin();
...
ApiLogger.Log("Signer_PDF", new ApiLogEntry
{
    Url = ..., ClientIp = ..., Request = ..., Response = ..., Error = ...
}, ApiCallRecorder.EndAndGet());
```

Nếu `ApiLogger` cũ gọi `SignerController.RegLog(...)` thì template mới đã đổi sang `LogHelper.RegLog`. Phải đổi
`SignerController.RegLog` (và mọi bản `RegLog` khác) thành gọi `LogHelper.RegLog`, xem SKILL.md bước 3.

## 9. Gợi ý điểm cần gắn trong API_Signer

Đây là điểm khởi đầu để đọc code, cần xác minh lại trên code hiện tại trước khi sửa:

| Service | Điểm vào | Lệnh gọi ra ngoài cần Record |
|---|---|---|
| 2ID.Service | `SignerController.KySo2ID`, `SignQueueBackgroundService` | Report export, 2sign cloud, FTP (đã làm, dùng làm mẫu) |
| FPT.Service | `SignerController` (PDF, PDF/Base64, XML/HS06), `FptSignQueueBackgroundService` | `DemoFunction`/eSignCloud HSM, `FptReportPdfFetcher`, `FileStorage` (FTP/Share), `CksSignQueueStatusUpdater` (SP) |
| Vnpt.Service | `SignerController.SignerPDF`… (`_signSmartCATHPDF`) | SmartCA REST (token, sign, get status) |
| Visnam.Service | `SignerController.SignerPDF` | VIN-HSM SDK (`VinHsmServiceClient`) |
| ViewPDF.Service | `ViewPDFController` (`get-report-pdf`) | đọc file/Report |
