using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;

namespace %%NAMESPACE%%.Common
{
    /// <summary>
    /// Gom các bước xử lý (Steps) và các lệnh gọi ra API/dịch vụ khác (Calls: gọi HTTP sang service
    /// khác, FTP, stored procedure...) phát sinh trong lúc xử lý 1 request, để gắn vào ApiLogEntry khi
    /// ghi log - không cần truyền danh sách xuyên qua từng tầng gọi hàm. Dùng AsyncLocal nên mỗi
    /// request (hoặc mỗi lần xử lý 1 job trong queue) có 1 ApiTrace riêng, chạy song song không lẫn
    /// vào nhau, và vẫn đi theo đúng luồng async/await của chính request đó.
    /// </summary>
    public static class ApiCallRecorder
    {
        private static readonly AsyncLocal<ApiTrace> _current = new AsyncLocal<ApiTrace>();

        /// <summary>Gọi 1 lần ở đầu mỗi API/mỗi lần xử lý job, trước khi có thể phát sinh bước/lệnh gọi ra ngoài.</summary>
        public static void Begin()
        {
            _current.Value = new ApiTrace();
        }

        /// <summary>Gọi từ hàm dùng chung gọi ra ngoài (HTTP, FTP, SP...) mỗi khi thực sự gọi ra 1 API/dịch vụ khác.</summary>
        public static void Record(ApiCallLog call)
        {
            _current.Value?.AddCall(call);
        }

        /// <summary>
        /// Mở 1 bước xử lý, dùng với using: trong bước gọi Ok/Fail/Skip để chốt kết quả; nếu thoát
        /// khỏi using mà chưa chốt (do exception) thì bước tự bị đánh dấu lỗi. Không có Begin() thì
        /// mọi thao tác đều bỏ qua, không ném lỗi.
        /// </summary>
        public static ApiStepScope BeginStep(string name, object input = null)
        {
            return new ApiStepScope(_current.Value, name, input);
        }

        /// <summary>Lấy ApiTrace đã ghi nhận và dọn lại AsyncLocal, gọi ở cuối mỗi API/mỗi lần xử lý job.</summary>
        public static ApiTrace EndAndGet()
        {
            var trace = _current.Value ?? new ApiTrace();
            _current.Value = null;
            return trace;
        }
    }

    /// <summary>Toàn bộ Steps/Calls của 1 lần xử lý, kèm đồng hồ tính thời gian kể từ Begin().</summary>
    public sealed class ApiTrace
    {
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private readonly object _sync = new object();
        private ApiStepLog _currentStep;

        public DateTime StartTime { get; } = DateTime.Now;
        public List<ApiStepLog> Steps { get; } = new List<ApiStepLog>();
        public List<ApiCallLog> Calls { get; } = new List<ApiCallLog>();
        public long ElapsedMs => _clock.ElapsedMilliseconds;

        internal void AddCall(ApiCallLog call)
        {
            lock (_sync)
            {
                // Record được gọi ngay sau khi lệnh gọi kết thúc nên thời điểm bắt đầu = hiện tại - DurationMs.
                if (call.OffsetMs == null)
                    call.OffsetMs = Math.Max(0, ElapsedMs - call.DurationMs);
                if (call.StepOrder == null)
                    call.StepOrder = _currentStep?.Order;
                Calls.Add(call);
            }
        }

        internal ApiStepLog OpenStep(string name, object input, out ApiStepLog parent)
        {
            lock (_sync)
            {
                parent = _currentStep;
                var step = new ApiStepLog
                {
                    Order = Steps.Count + 1,
                    Name = name,
                    OffsetMs = ElapsedMs,
                    Input = input
                };
                Steps.Add(step);
                _currentStep = step;
                return step;
            }
        }

        internal void CloseStep(ApiStepLog step, ApiStepLog parent)
        {
            lock (_sync)
            {
                step.DurationMs = ElapsedMs - step.OffsetMs;
                if (_currentStep == step)
                    _currentStep = parent;
            }
        }
    }

    public sealed class ApiStepScope : IDisposable
    {
        private readonly ApiTrace _trace;
        private readonly ApiStepLog _step;
        private readonly ApiStepLog _parent;
        private bool _disposed;

        internal ApiStepScope(ApiTrace trace, string name, object input)
        {
            _trace = trace;
            if (trace != null)
                _step = trace.OpenStep(name, input, out _parent);
        }

        public void SetInput(object input)
        {
            if (_step != null)
                _step.Input = input;
        }

        public void Ok(object output = null)
        {
            Finish(ApiStepLog.StatusOk, output, null);
        }

        public void Fail(string error, object output = null)
        {
            Finish(ApiStepLog.StatusError, output, error);
        }

        public void Skip(string reason)
        {
            Finish(ApiStepLog.StatusSkipped, reason, null);
        }

        private void Finish(string status, object output, string error)
        {
            if (_step == null)
                return;
            _step.Status = status;
            if (output != null)
                _step.Output = output;
            _step.Error = error;
        }

        public void Dispose()
        {
            if (_step == null || _disposed)
                return;
            _disposed = true;
            if (_step.Status == null)
            {
                _step.Status = ApiStepLog.StatusError;
                _step.Error = "Bước bị dừng giữa chừng do exception (xem lỗi chung / Unexpected_Exception)";
            }
            _trace.CloseStep(_step, _parent);
        }
    }

    /// <summary>Parse JSON để log hiển thị đẹp, và lọc dữ liệu nhạy cảm/nặng trước khi ghi hoặc
    /// trả log ra màn hình xem log.</summary>
    public static class JsonHelper
    {
        // Chuỗi base64 (ảnh, PDF, file ký, chuỗi mã hoá...) dài từ ngưỡng này trở lên thì khi ghi log
        // chỉ ghi "đã có chuỗi base64, độ dài bao nhiêu" thay vì lưu nguyên văn - tránh log nặng/chậm
        // (vd. byte[] file PDF tự serialize ra base64, chuỗi base64 trả về từ dịch vụ khác).
        private const int Base64LengthThreshold = 100;
        private static readonly Regex Base64Pattern = new Regex(@"^[A-Za-z0-9+/]+={0,2}$", RegexOptions.Compiled);
        // Đoạn base64 dài nằm lẫn trong 1 chuỗi khác (data URI ảnh chữ ký, message lỗi, body thô...).
        private static readonly Regex EmbeddedBase64Pattern = new Regex(
            @"(?:data:[\w/+.-]*;base64,)?[A-Za-z0-9+/]{" + Base64LengthThreshold + @",}={0,2}", RegexOptions.Compiled);
        private const string MaskedValue = "<đã ẩn>";

        // "password=abc", "Pwd: abc", "\"keyAuth\":\"abc\"" nằm trong chuỗi thô (query string, connection
        // string, body không phải JSON...) - giữ tên field, che phần giá trị. Bỏ qua giá trị đã che để
        // lọc nhiều lần (middleware + ApiLogger + lúc đọc log) vẫn ra cùng 1 kết quả.
        private static readonly Regex InlineSecretPattern = new Regex(
            @"(\b\w*(?:password|passwd|pwd|secret|apikey|api_key|keyauth|passcode|token|matkhau|mat_khau)\b""?\s*[=:]\s*""?)(?!" + Regex.Escape(MaskedValue) + @")[^;&,\s""']+",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        // Tên field chứa thông tin đăng nhập/bí mật - che nguyên văn bất kể độ dài (khác với base64,
        // các chuỗi này thường ngắn như mật khẩu/API key nên không lọt qua được ngưỡng base64 ở trên).
        // So khớp sau khi bỏ "_"/"-" và về chữ thường: chứa 1 trong các cụm sau (vd. ftpPassword, api_key)...
        private static readonly string[] SensitiveNameParts =
        {
            "password", "passwd", "matkhau", "secret", "apikey", "keyauth", "authorizecode", "passcode",
            "token", "credential", "privatekey", "connectionstring"
        };
        // ...hoặc trùng đúng 1 trong các tên ngắn sau (tránh che nhầm field có chứa cụm ngắn này).
        private static readonly string[] SensitiveExactNames = { "pwd", "pass", "pin", "otp", "authorization" };

        public static object TryParse(string json)
        {
            if (string.IsNullOrWhiteSpace(json))
                return json;
            try
            {
                return ParseToken(json);
            }
            catch
            {
                return json;
            }
        }

        // Không tự đổi chuỗi ngày giờ thành DateTime (mặc định của Json.NET) - giữ nguyên văn như
        // request/response gốc, và ghi lại ra log không bị đổi định dạng.
        private static JToken ParseToken(string json)
        {
            using (var reader = new JsonTextReader(new StringReader(json)) { DateParseHandling = DateParseHandling.None })
            {
                JToken token = JToken.ReadFrom(reader);
                // Còn nội dung thừa sau JSON (vd. "{...}abc") thì reader tự ném lỗi -> coi như không phải JSON.
                while (reader.Read())
                {
                }
                return token;
            }
        }

        /// <summary>Duyệt toàn bộ cây JSON của 1 ApiLogEntry trước khi ghi ra file: che các field
        /// đăng nhập/bí mật theo tên, và thay mọi chuỗi base64 dài bằng placeholder - áp dụng chung
        /// cho mọi tag, không cần từng nơi gọi tự lọc.</summary>
        public static JToken SanitizeForLog(JToken token)
        {
            switch (token)
            {
                case JObject obj:
                    var newObj = new JObject();
                    foreach (var prop in obj.Properties())
                    {
                        if (IsSensitiveFieldName(prop.Name) && !IsEmpty(prop.Value))
                            newObj.Add(prop.Name, new JValue(MaskedValue));
                        else
                            newObj.Add(prop.Name, SanitizeForLog(prop.Value));
                    }
                    return newObj;
                case JArray arr:
                    var newArr = new JArray();
                    foreach (var item in arr)
                        newArr.Add(SanitizeForLog(item));
                    return newArr;
                case JValue val when val.Type == JTokenType.String:
                    return new JValue(SanitizeString((string)val.Value));
                default:
                    return token;
            }
        }

        /// <summary>Lọc 1 chuỗi thô (không phải JSON): base64 nguyên khối/lẫn trong chuỗi -> placeholder,
        /// "password=..." -> "password=&lt;đã ẩn&gt;".</summary>
        public static string SanitizeString(string s)
        {
            if (string.IsNullOrEmpty(s))
                return s;

            if (s.Length >= Base64LengthThreshold)
            {
                // Base64 kiểu MIME có xuống dòng mỗi 76 ký tự - bỏ xuống dòng rồi mới so mẫu.
                string compact = s.IndexOf('\n') >= 0 ? s.Replace("\r", "").Replace("\n", "") : s;
                if (Base64Pattern.IsMatch(compact))
                    return $"<chuỗi base64, length={s.Length}>";
                s = EmbeddedBase64Pattern.Replace(s, m => $"<chuỗi base64, length={m.Length}>");
            }

            return InlineSecretPattern.Replace(s, "$1" + MaskedValue);
        }

        /// <summary>Lọc lại 1 dòng log khi trả ra màn hình xem log - để cả log ghi từ trước khi có bộ
        /// lọc hiện tại (còn mật khẩu/base64 nguyên văn) cũng không bị hiển thị.</summary>
        public static string SanitizeLogMessage(string message)
        {
            if (string.IsNullOrEmpty(message))
                return message;

            string trimmed = message.TrimStart();
            if (trimmed.StartsWith("{") || trimmed.StartsWith("["))
            {
                try
                {
                    return SanitizeForLog(ParseToken(message)).ToString(Formatting.None);
                }
                catch (JsonException)
                {
                    // Không phải JSON hợp lệ (log kiểu cũ "Key=value...") - lọc như chuỗi thô bên dưới.
                }
            }
            return SanitizeString(message);
        }

        private static bool IsEmpty(JToken value)
        {
            return value.Type == JTokenType.Null ||
                   (value.Type == JTokenType.String && string.IsNullOrEmpty((string)((JValue)value).Value));
        }

        private static bool IsSensitiveFieldName(string name)
        {
            string n = name.Replace("_", "").Replace("-", "").ToLowerInvariant();
            foreach (string s in SensitiveExactNames)
                if (n == s)
                    return true;
            foreach (string s in SensitiveNameParts)
                if (n.Contains(s))
                    return true;
            return false;
        }
    }
}
