using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using %%NAMESPACE%%.Common;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace %%NAMESPACE%%.Controllers
{
    /// <summary>
    /// API JSON phục vụ màn hình tra cứu log (wwwroot/logs.html) - đọc trực tiếp các file
    /// Logs/{năm}/{tháng}/{ngày}/{Tag}.txt do LogHelper.RegLog ghi ra, không cần DB hay hệ thống log
    /// riêng. Ngoài tra cứu còn có thống kê dung lượng, xoá log theo yêu cầu và cấu hình tự xoá log
    /// (LogCleanupBackgroundService). Xoá/đổi cấu hình yêu cầu header X-Log-Admin-Key nếu có cấu hình
    /// LogSettings:AdminKey, và luôn ghi audit vào tag Log_Admin.
    /// </summary>
    [Route("%%LOG_ROUTE%%")]
    [ApiController]
    public class LogViewerController : ControllerBase
    {
        private const string LogsRoot = LogMaintenance.LogsRoot;
        private const string AllTags = "*";
        private const string AuditTag = "Log_Admin";
        private const string AggregatedErrorTag = "Tong_Hop_Loi";
        private const string AdminKeyHeader = "X-Log-Admin-Key";
        private const int MaxDayRange = 31;
        private const int DefaultLimit = 500;
        private const int MaxLimit = 2000;

        private readonly ILogMaintenance _maintenance;
        private readonly IConfiguration _configuration;

        public LogViewerController(ILogMaintenance maintenance, IConfiguration configuration)
        {
            _maintenance = maintenance;
            _configuration = configuration;
        }

        /// <summary>
        /// Danh sách tag (tên file log, không gồm .txt) đang thực sự tồn tại trên đĩa - quét cây thư
        /// mục Logs/{năm}/{tháng}/{ngày}/{Tag}.txt (đúng 3 cấp, do RegLog tạo ra), để màn hình tra
        /// cứu hiển thị đúng những loại log có thật, không cần hard-code danh sách tag ở client.
        /// Bỏ qua các file Logs/{ngày}.txt nằm thẳng ở gốc - đó là log của ILogger (loggerFactory.
        /// AddFile trong Startup.cs), khác định dạng dòng với RegLog nên Search không đọc được.
        /// </summary>
        [HttpGet("Tags")]
        public IActionResult GetTags()
        {
            var tags = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var (_, dir) in LogMaintenance.EnumerateDayDirs())
            {
                try
                {
                    foreach (string file in Directory.EnumerateFiles(dir, "*.txt"))
                        tags.Add(Path.GetFileNameWithoutExtension(file));
                }
                catch (IOException)
                {
                    // Thư mục ngày vừa bị xoá (xoá log/tự dọn log) - bỏ qua.
                }
            }

            return new OkObjectResult(tags);
        }

        /// <summary>
        /// Tìm kiếm log của 1 tag (hoặc tag = "*" cho mọi tag) trong khoảng ngày [fromDate, toDate]
        /// (mặc định toDate = fromDate), lọc thêm theo từ khoá (không phân biệt hoa/thường) nếu có.
        /// Mỗi entry trả về tương ứng đúng 1 lần gọi RegLog - kể cả khi message gốc có nhiều dòng
        /// (stack trace exception...). Message được lọc lại mật khẩu/base64 trước khi trả về, để cả
        /// log ghi từ trước khi có bộ lọc cũng không lộ ra màn hình.
        /// </summary>
        [HttpGet("Search")]
        public IActionResult Search(string tag, DateTime fromDate, DateTime? toDate = null, string keyword = null, int limit = DefaultLimit)
        {
            if (string.IsNullOrWhiteSpace(tag))
                return new BadRequestObjectResult("Thiếu tham số tag");
            bool allTags = tag == AllTags;
            if (!allTags && !LogMaintenance.IsValidTag(tag))
                return new BadRequestObjectResult("Tên loại log không hợp lệ");

            DateTime from = fromDate.Date;
            DateTime to = (toDate ?? fromDate).Date;
            if (to < from)
                return new BadRequestObjectResult("toDate phải >= fromDate");

            if ((to - from).TotalDays > MaxDayRange)
                return new BadRequestObjectResult($"Khoảng ngày tối đa {MaxDayRange} ngày");

            if (limit <= 0 || limit > MaxLimit)
                limit = DefaultLimit;

            var candidates = new List<LogEntry>();
            var skippedDays = new List<string>();

            for (DateTime day = from; day <= to; day = day.AddDays(1))
            {
                string dayDir = Path.Combine(LogsRoot, day.Year.ToString(), day.Month.ToString(), day.Day.ToString());
                if (!Directory.Exists(dayDir))
                    continue;

                // Tất cả loại log: bỏ Tong_Hop_Loi vì chỉ là bản sao các dòng lỗi của tag khác (tránh trùng).
                IEnumerable<string> paths = allTags
                    ? Directory.GetFiles(dayDir, "*.txt")
                        .Where(p => !string.Equals(Path.GetFileNameWithoutExtension(p), AggregatedErrorTag, StringComparison.OrdinalIgnoreCase))
                        .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
                    : new[] { Path.Combine(dayDir, tag + ".txt") }.Where(System.IO.File.Exists);

                foreach (string path in paths)
                {
                    List<LogEntry> fileEntries;
                    try
                    {
                        fileEntries = ReadLogFile(path, day);
                    }
                    catch (IOException)
                    {
                        // File đang được RegLog ghi đúng lúc đọc (khoá exclusive rất ngắn) - báo lại cho
                        // client biết để thử lại, không coi là lỗi toàn bộ request.
                        skippedDays.Add(day.ToString("yyyy-MM-dd") + (allTags ? " " + Path.GetFileNameWithoutExtension(path) : ""));
                        continue;
                    }

                    string fileTag = Path.GetFileNameWithoutExtension(path);
                    foreach (var entry in fileEntries)
                    {
                        // Lọc thô trước cho nhanh, sẽ kiểm tra lại trên message đã lọc mật khẩu/base64.
                        if (!string.IsNullOrEmpty(keyword) && entry.Message.IndexOf(keyword, StringComparison.OrdinalIgnoreCase) < 0)
                            continue;
                        entry.Tag = fileTag;
                        candidates.Add(entry);
                    }
                }
            }

            // Mới nhất lên đầu; cùng 1 giây thì dòng ghi sau (vị trí sau trong file) lên trước.
            var ordered = candidates
                .Select((e, index) => (e, index))
                .OrderByDescending(x => x.e.Timestamp)
                .ThenByDescending(x => x.index)
                .Select(x => x.e);

            var result = new List<LogEntry>();
            bool truncated = false;
            foreach (var entry in ordered)
            {
                entry.Message = JsonHelper.SanitizeLogMessage(entry.Message);
                if (!string.IsNullOrEmpty(keyword) && entry.Message.IndexOf(keyword, StringComparison.OrdinalIgnoreCase) < 0)
                    continue;
                if (result.Count >= limit)
                {
                    truncated = true;
                    break;
                }
                result.Add(entry);
            }

            return new OkObjectResult(new
            {
                total = result.Count,
                truncated,
                skippedDays,
                entries = result
            });
        }

        /// <summary>Thống kê dung lượng log theo tag + cấu hình tự xoá hiện tại.</summary>
        [HttpGet("Stats")]
        public IActionResult GetStats()
        {
            return new OkObjectResult(new
            {
                stats = _maintenance.GetStats(),
                settings = _maintenance.GetSettings(),
                adminKeyRequired = !string.IsNullOrEmpty(_configuration["LogSettings:AdminKey"])
            });
        }

        /// <summary>Cấu hình tự xoá log đang áp dụng.</summary>
        [HttpGet("Settings")]
        public IActionResult GetSettings()
        {
            return new OkObjectResult(new
            {
                settings = _maintenance.GetSettings(),
                adminKeyRequired = !string.IsNullOrEmpty(_configuration["LogSettings:AdminKey"])
            });
        }

        /// <summary>
        /// Lưu cấu hình tự xoá log (vào Logs/log-settings.json, ưu tiên hơn appsettings.json).
        /// retentionDays = 0 tắt tự xoá. applyNow = true thì dọn ngay theo cấu hình mới.
        /// </summary>
        [HttpPost("Settings")]
        public IActionResult SaveSettings(int retentionDays, int cleanupIntervalHours, bool applyNow = false)
        {
            if (!IsAdmin())
                return AdminKeyRejected();
            if (retentionDays < 0)
                return new BadRequestObjectResult("Số ngày giữ log phải >= 0 (0 = không tự xoá)");
            if (cleanupIntervalHours < 1)
                return new BadRequestObjectResult("Chu kỳ dọn log phải >= 1 giờ");

            var settings = _maintenance.SaveSettings(retentionDays, cleanupIntervalHours, ClientIp());
            LogDeleteResult cleanup = applyNow ? _maintenance.ApplyRetention() : null;

            ApiLogger.Log(AuditTag, new ApiLogEntry
            {
                Url = Request.Path,
                Method = "POST",
                ClientIp = ClientIp(),
                Request = new { retentionDays, cleanupIntervalHours, applyNow },
                Response = new { settings, cleanup }
            });

            return new OkObjectResult(new { settings, cleanup });
        }

        /// <summary>
        /// Xoá log theo yêu cầu. Chọn đúng 1 trong 3 cách:
        ///   keepDays = N        : giữ N ngày gần nhất (tính cả hôm nay), xoá cũ hơn
        ///   fromDate[, toDate]  : xoá trong khoảng ngày
        ///   all = true          : xoá toàn bộ
        /// tag rỗng/"*" = mọi loại log.
        /// </summary>
        [HttpPost("Delete")]
        public IActionResult DeleteLogs(string tag, DateTime? fromDate = null, DateTime? toDate = null, int? keepDays = null, bool all = false)
        {
            if (!IsAdmin())
                return AdminKeyRejected();
            if (!string.IsNullOrWhiteSpace(tag) && tag != AllTags && !LogMaintenance.IsValidTag(tag))
                return new BadRequestObjectResult("Tên loại log không hợp lệ");

            DateTime? from = null;
            DateTime? to = null;
            if (keepDays.HasValue)
            {
                if (keepDays.Value < 1)
                    return new BadRequestObjectResult("Số ngày giữ lại phải >= 1");
                to = DateTime.Today.AddDays(-keepDays.Value);
            }
            else if (fromDate.HasValue)
            {
                from = fromDate.Value.Date;
                to = (toDate ?? fromDate).Value.Date;
                if (to < from)
                    return new BadRequestObjectResult("Đến ngày phải >= từ ngày");
            }
            else if (!all)
            {
                return new BadRequestObjectResult("Chọn khoảng ngày, số ngày giữ lại, hoặc xoá toàn bộ");
            }

            var result = _maintenance.Delete(from, to, tag);

            ApiLogger.Log(AuditTag, new ApiLogEntry
            {
                Url = Request.Path,
                Method = "POST",
                ClientIp = ClientIp(),
                Request = new { tag, fromDate, toDate, keepDays, all },
                Response = result
            });

            return new OkObjectResult(result);
        }

        // Không cấu hình LogSettings:AdminKey thì không yêu cầu mã; có thì header phải khớp.
        private bool IsAdmin()
        {
            string expected = _configuration["LogSettings:AdminKey"];
            if (string.IsNullOrEmpty(expected))
                return true;
            string provided = Request.Headers[AdminKeyHeader];
            if (string.IsNullOrEmpty(provided))
                return false;
            return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(provided));
        }

        private static UnauthorizedObjectResult AdminKeyRejected()
        {
            return new UnauthorizedObjectResult("Sai hoặc thiếu mã quản trị log (LogSettings:AdminKey)");
        }

        private string ClientIp()
        {
            return HttpContext.Connection.RemoteIpAddress?.ToString();
        }

        // RegLog ghi mỗi lần gọi 1 dòng mở đầu "DateTime: dd/MM/yyyy HH:mm:ss, Data: <message>" - nếu
        // <message> có xuống dòng (vd. ex.ToString() của exception), các dòng tiếp theo KHÔNG bắt đầu
        // bằng "DateTime: " nên được gộp tiếp vào message của entry trước đó, không tách nhầm thành
        // nhiều entry rời rạc.
        private static List<LogEntry> ReadLogFile(string path, DateTime day)
        {
            const string Prefix = "DateTime: ";
            const string DataMarker = ", Data: ";

            string content = null;
            // RegLog mở file với FileMode.Append trong lúc ghi (rất ngắn) - thử lại vài lần thay vì
            // báo lỗi ngay nếu vô tình đọc trúng đúng lúc đó.
            IOException lastError = null;
            for (int attempt = 0; attempt < 3 && content == null; attempt++)
            {
                try
                {
                    using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    using var reader = new StreamReader(fs, Encoding.UTF8);
                    content = reader.ReadToEnd();
                }
                catch (Exception ex) when (ex is FileNotFoundException || ex is DirectoryNotFoundException)
                {
                    // Vừa bị xoá (xoá log/tự dọn log) giữa lúc liệt kê và lúc đọc.
                    return new List<LogEntry>();
                }
                catch (IOException ex)
                {
                    lastError = ex;
                    Thread.Sleep(50);
                }
            }
            if (content == null)
                throw lastError;

            string[] lines = content.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);

            var result = new List<LogEntry>();
            LogEntry current = null;

            foreach (string line in lines)
            {
                if (line.StartsWith(Prefix, StringComparison.Ordinal))
                {
                    if (current != null)
                        result.Add(current);

                    int dataIdx = line.IndexOf(DataMarker, StringComparison.Ordinal);
                    string message = dataIdx >= 0 ? line.Substring(dataIdx + DataMarker.Length) : line;
                    DateTime timestamp = day;

                    if (dataIdx >= 0)
                    {
                        string tsPart = line.Substring(Prefix.Length, dataIdx - Prefix.Length);
                        if (DateTime.TryParseExact(tsPart, "dd/MM/yyyy HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed))
                            timestamp = parsed;
                    }

                    current = new LogEntry { Timestamp = timestamp, Message = message };
                }
                else if (current != null)
                {
                    current.Message += "\n" + line;
                }
            }

            if (current != null)
                result.Add(current);

            return result;
        }

        public class LogEntry
        {
            public DateTime Timestamp { get; set; }
            public string Tag { get; set; }
            public string Message { get; set; }
        }
    }
}
