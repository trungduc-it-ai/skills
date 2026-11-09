using System.Collections.Generic;

namespace %%NAMESPACE%%.Common
{
    /// <summary>
    /// 1 lần gọi ra 1 API/dịch vụ khác trong lúc xử lý (HTTP sang service khác, FTP, stored procedure...).
    /// Mỗi API chính (ApiLogEntry) có thể có 0..n call như vậy trong Calls.
    /// </summary>
    public class ApiCallLog
    {
        public string Name { get; set; }
        public string Url { get; set; }
        public string Method { get; set; }
        public object Request { get; set; }
        public object Response { get; set; }
        public string Error { get; set; }
        public long DurationMs { get; set; }
        // Bắt đầu sau bao nhiêu ms kể từ lúc API chính nhận request - ApiCallRecorder.Record tự tính.
        public long? OffsetMs { get; set; }
        // Thuộc bước nào (ApiStepLog.Order) - ApiCallRecorder.Record tự gán theo bước đang mở.
        public int? StepOrder { get; set; }
    }

    /// <summary>
    /// 1 bước xử lý bên trong 1 API (vd. lấy file, tạo yêu cầu, gọi dịch vụ ngoài, upload FTP...),
    /// ghi lại thời điểm bắt đầu/thời gian chạy, đầu vào/đầu ra và kết quả của riêng bước đó - để
    /// xem log biết request chậm/lỗi ở đúng bước nào, không chỉ biết tổng thời gian.
    /// </summary>
    public class ApiStepLog
    {
        public const string StatusOk = "OK";
        public const string StatusError = "Error";
        public const string StatusSkipped = "Skipped";

        public int Order { get; set; }
        public string Name { get; set; }
        // Bắt đầu sau bao nhiêu ms kể từ lúc API chính nhận request.
        public long OffsetMs { get; set; }
        public long DurationMs { get; set; }
        public string Status { get; set; }
        public object Input { get; set; }
        public object Output { get; set; }
        public string Error { get; set; }
    }

    /// <summary>
    /// 1 dòng log hoàn chỉnh cho 1 API của %%SERVICE_TITLE%% - luôn có Url/Method/Request/Response (hoặc
    /// Error nếu thất bại), cộng thêm Steps (các bước xử lý + thời gian từng bước) và Calls (các
    /// API/dịch vụ khác đã gọi ra ngoài) nếu có. Serialize nguyên object này thành JSON rồi ghi qua
    /// LogHelper.RegLog - mỗi dòng log là 1 JSON object trên 1 dòng, không còn ghép chuỗi "Key=value"
    /// rời rạc như trước. Field null không được ghi ra file (ApiLogger bỏ qua) để log gọn nhẹ.
    /// </summary>
    public class ApiLogEntry
    {
        public string RequestId { get; set; }
        public string Url { get; set; }
        public string Method { get; set; }
        public string ClientIp { get; set; }
        // yyyy-MM-dd HH:mm:ss.fff - ApiLogger tự điền nếu bỏ trống.
        public string StartTime { get; set; }
        public string EndTime { get; set; }
        public long DurationMs { get; set; }
        // Thời gian job nằm chờ trong hàng đợi trước khi được xử lý (chỉ có ở %%DEFAULT_TAG%%).
        public long? QueueWaitMs { get; set; }
        public object Request { get; set; }
        public object Response { get; set; }
        public string Error { get; set; }
        public List<ApiStepLog> Steps { get; set; }
        public List<ApiCallLog> Calls { get; set; }
        public int? Attempt { get; set; }
        public int? MaxAttempt { get; set; }
    }
}
