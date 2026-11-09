using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Globalization;
using System.Linq;

namespace %%NAMESPACE%%.Common
{
    /// <summary>
    /// Ghi 1 ApiLogEntry ra file log theo ngày (dùng chung LogHelper.RegLog, tên tag = tên file .txt).
    /// Mỗi dòng log là đúng 1 JSON object duy nhất - viết và xem log theo cùng 1 cấu trúc
    /// (Url/Method/Request/Response/Error/Steps/Calls), không còn ghép chuỗi "Key=value" như trước.
    /// Trước khi ghi, quét sạch field đăng nhập/bí mật và mọi chuỗi base64 dài (PDF/ảnh...) thành
    /// placeholder, bỏ field null - áp dụng 1 chỗ duy nhất cho mọi tag, không phải tự lọc ở từng action.
    /// Nếu entry có lỗi (của chính nó hoặc của 1 Step/Call con nào đó) thì ghi thêm 1 bản sao (kèm
    /// field Source = tag gốc) vào Tong_Hop_Loi.txt - 1 chỗ duy nhất liệt kê MỌI sự cố/exception của
    /// toàn bộ %%SERVICE_TITLE%%, để tra cứu/chẩn đoán mà không cần mở từng file log riêng của từng API.
    /// </summary>
    public static class ApiLogger
    {
        private const string AggregatedErrorTag = "Tong_Hop_Loi";
        private const string TimeFormat = "yyyy-MM-dd HH:mm:ss.fff";

        private static readonly JsonSerializerSettings SerializerSettings = new JsonSerializerSettings
        {
            NullValueHandling = NullValueHandling.Ignore
        };

        /// <summary>Ghi entry kèm Steps/Calls/thời gian bắt đầu/tổng thời gian lấy từ ApiTrace
        /// (ApiCallRecorder.EndAndGet()).</summary>
        public static void Log(string tag, ApiLogEntry entry, ApiTrace trace)
        {
            if (trace != null)
            {
                entry.StartTime = entry.StartTime ?? FormatTime(trace.StartTime);
                entry.DurationMs = trace.ElapsedMs;
                if (trace.Steps.Count > 0)
                    entry.Steps = trace.Steps;
                if (trace.Calls.Count > 0)
                    entry.Calls = trace.Calls;
            }
            Log(tag, entry);
        }

        public static void Log(string tag, ApiLogEntry entry)
        {
            DateTime now = DateTime.Now;
            entry.EndTime = entry.EndTime ?? FormatTime(now);
            entry.StartTime = entry.StartTime ?? FormatTime(now.AddMilliseconds(-entry.DurationMs));

            JToken token = JToken.FromObject(entry, JsonSerializer.Create(SerializerSettings));
            JToken sanitized = JsonHelper.SanitizeForLog(token);
            LogHelper.RegLog(tag, sanitized.ToString(Formatting.None));

            if (tag != AggregatedErrorTag && HasError(entry) && sanitized is JObject sanitizedObj)
            {
                var mirrored = (JObject)sanitizedObj.DeepClone();
                mirrored["Source"] = tag;
                LogHelper.RegLog(AggregatedErrorTag, mirrored.ToString(Formatting.None));
            }
        }

        public static string FormatTime(DateTime time)
        {
            return time.ToString(TimeFormat, CultureInfo.InvariantCulture);
        }

        private static bool HasError(ApiLogEntry entry)
        {
            if (!string.IsNullOrEmpty(entry.Error))
                return true;
            if (entry.Steps != null && entry.Steps.Any(s => s.Status == ApiStepLog.StatusError))
                return true;
            return entry.Calls != null && entry.Calls.Any(c => !string.IsNullOrEmpty(c.Error));
        }
    }
}
