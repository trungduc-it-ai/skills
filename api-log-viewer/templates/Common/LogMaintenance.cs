using Microsoft.Extensions.Configuration;
using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace %%NAMESPACE%%.Common
{
    /// <summary>Cấu hình tự xoá log. Đọc từ Logs/log-settings.json (lưu từ màn hình xem log) nếu có,
    /// không thì lấy LogSettings trong appsettings.json.</summary>
    public class LogRetentionSettings
    {
        // Giữ log của N ngày gần nhất (tính cả hôm nay), cũ hơn thì tự xoá. 0 = không tự xoá.
        public int RetentionDays { get; set; }
        // Bao lâu chạy dọn log tự động 1 lần (giờ).
        public int CleanupIntervalHours { get; set; }
        public string UpdatedAt { get; set; }
        public string UpdatedBy { get; set; }
        [JsonIgnore]
        public string Source { get; set; }
    }

    public class LogDeleteResult
    {
        public string Tag { get; set; }
        public string FromDate { get; set; }
        public string ToDate { get; set; }
        public int DeletedFiles { get; set; }
        public long DeletedBytes { get; set; }
        public List<string> FailedFiles { get; set; } = new List<string>();
    }

    public class LogTagStat
    {
        public string Tag { get; set; }
        public int Files { get; set; }
        public long Bytes { get; set; }
    }

    public class LogStats
    {
        public long TotalBytes { get; set; }
        public int FileCount { get; set; }
        public int DayCount { get; set; }
        public string OldestDay { get; set; }
        public string NewestDay { get; set; }
        public List<LogTagStat> Tags { get; set; } = new List<LogTagStat>();
    }

    public interface ILogMaintenance
    {
        LogRetentionSettings GetSettings();
        LogRetentionSettings SaveSettings(int retentionDays, int cleanupIntervalHours, string updatedBy);
        LogStats GetStats();
        LogDeleteResult Delete(DateTime? fromDate, DateTime? toDate, string tag);
        LogDeleteResult ApplyRetention();
    }

    /// <summary>
    /// Thống kê/xoá file log trên đĩa: Logs/{năm}/{tháng}/{ngày}/{Tag}.txt (LogHelper.RegLog) và
    /// Logs/yyyyMMdd.txt (ILogger - loggerFactory.AddFile trong Startup.cs). Dùng chung cho màn hình
    /// xem log (xoá theo yêu cầu) và LogCleanupBackgroundService (tự xoá theo số ngày giữ log).
    /// </summary>
    public class LogMaintenance : ILogMaintenance
    {
        public const string LogsRoot = "Logs";
        // Tag "ảo" đại diện cho file ILogger Logs/yyyyMMdd.txt khi thống kê.
        public const string SystemLogTag = "(ILogger)";

        private const string SettingsFileName = "log-settings.json";
        private const int DefaultRetentionDays = 30;
        private const int DefaultCleanupIntervalHours = 6;
        private const int MaxRetentionDays = 3650;
        private const int MaxCleanupIntervalHours = 168;

        private static readonly Regex TagPattern = new Regex(@"^[\w\-]+$", RegexOptions.Compiled);
        private static readonly Regex SystemLogFileName = new Regex(@"^\d{8}$", RegexOptions.Compiled);

        private readonly IConfiguration _configuration;
        private readonly object _settingsLock = new object();

        public LogMaintenance(IConfiguration configuration)
        {
            _configuration = configuration;
        }

        /// <summary>Tag chỉ gồm chữ/số/_/- - chặn "..\" để không đọc/xoá được file ngoài thư mục Logs.</summary>
        public static bool IsValidTag(string tag)
        {
            return !string.IsNullOrEmpty(tag) && TagPattern.IsMatch(tag);
        }

        public LogRetentionSettings GetSettings()
        {
            string path = Path.Combine(LogsRoot, SettingsFileName);
            lock (_settingsLock)
            {
                if (File.Exists(path))
                {
                    try
                    {
                        var saved = JsonConvert.DeserializeObject<LogRetentionSettings>(File.ReadAllText(path));
                        if (saved != null)
                        {
                            saved.Source = LogsRoot + "/" + SettingsFileName;
                            return Normalize(saved);
                        }
                    }
                    catch (Exception ex) when (ex is IOException || ex is JsonException)
                    {
                        // File hỏng/đang bị khoá - dùng tạm appsettings.json, không làm hỏng việc dọn log.
                    }
                }
            }

            return Normalize(new LogRetentionSettings
            {
                RetentionDays = _configuration.GetValue("LogSettings:RetentionDays", DefaultRetentionDays),
                CleanupIntervalHours = _configuration.GetValue("LogSettings:CleanupIntervalHours", DefaultCleanupIntervalHours),
                Source = "appsettings.json"
            });
        }

        public LogRetentionSettings SaveSettings(int retentionDays, int cleanupIntervalHours, string updatedBy)
        {
            var settings = Normalize(new LogRetentionSettings
            {
                RetentionDays = retentionDays,
                CleanupIntervalHours = cleanupIntervalHours,
                UpdatedAt = ApiLogger.FormatTime(DateTime.Now),
                UpdatedBy = updatedBy
            });

            lock (_settingsLock)
            {
                Directory.CreateDirectory(LogsRoot);
                File.WriteAllText(Path.Combine(LogsRoot, SettingsFileName), JsonConvert.SerializeObject(settings, Formatting.Indented));
            }

            settings.Source = LogsRoot + "/" + SettingsFileName;
            return settings;
        }

        private static LogRetentionSettings Normalize(LogRetentionSettings s)
        {
            s.RetentionDays = Math.Min(Math.Max(s.RetentionDays, 0), MaxRetentionDays);
            s.CleanupIntervalHours = Math.Min(Math.Max(s.CleanupIntervalHours, 1), MaxCleanupIntervalHours);
            return s;
        }

        public LogStats GetStats()
        {
            var stats = new LogStats();
            var tags = new Dictionary<string, LogTagStat>(StringComparer.OrdinalIgnoreCase);
            var days = new SortedSet<DateTime>();

            void Add(string tag, string file, DateTime day)
            {
                long size;
                try
                {
                    size = new FileInfo(file).Length;
                }
                catch (IOException)
                {
                    return; // vừa bị xoá/đang bị khoá - bỏ qua
                }
                if (!tags.TryGetValue(tag, out var t))
                    tags[tag] = t = new LogTagStat { Tag = tag };
                t.Files++;
                t.Bytes += size;
                stats.FileCount++;
                stats.TotalBytes += size;
                days.Add(day);
            }

            foreach (var (day, dir) in EnumerateDayDirs())
                foreach (string file in SafeGetFiles(dir))
                    Add(Path.GetFileNameWithoutExtension(file), file, day);

            foreach (var (day, file) in EnumerateSystemLogFiles())
                Add(SystemLogTag, file, day);

            stats.DayCount = days.Count;
            if (days.Count > 0)
            {
                stats.OldestDay = days.Min.ToString("yyyy-MM-dd");
                stats.NewestDay = days.Max.ToString("yyyy-MM-dd");
            }
            stats.Tags = tags.Values.OrderByDescending(t => t.Bytes).ToList();
            return stats;
        }

        /// <summary>
        /// Xoá log trong khoảng ngày [fromDate, toDate] (null = không giới hạn phía đó). tag rỗng/"*" =
        /// mọi tag, kể cả file ILogger Logs/yyyyMMdd.txt (trừ file của hôm nay - ILogger đang mở để ghi).
        /// Thư mục ngày/tháng/năm trống sau khi xoá cũng được dọn luôn.
        /// </summary>
        public LogDeleteResult Delete(DateTime? fromDate, DateTime? toDate, string tag)
        {
            bool allTags = string.IsNullOrWhiteSpace(tag) || tag == "*";
            if (!allTags && !IsValidTag(tag))
                throw new ArgumentException("Tên loại log không hợp lệ: " + tag);

            DateTime? from = fromDate?.Date;
            DateTime? to = toDate?.Date;
            var result = new LogDeleteResult
            {
                Tag = allTags ? "*" : tag,
                FromDate = from?.ToString("yyyy-MM-dd"),
                ToDate = to?.ToString("yyyy-MM-dd")
            };

            bool InRange(DateTime day) => (from == null || day >= from) && (to == null || day <= to);

            foreach (var (day, dir) in EnumerateDayDirs())
            {
                if (!InRange(day))
                    continue;

                IEnumerable<string> files = allTags
                    ? SafeGetFiles(dir)
                    : new[] { Path.Combine(dir, tag + ".txt") }.Where(File.Exists);
                foreach (string file in files)
                    DeleteFile(file, result);

                RemoveEmptyDirs(dir);
            }

            if (allTags)
            {
                foreach (var (day, file) in EnumerateSystemLogFiles())
                {
                    if (InRange(day) && day != DateTime.Today)
                        DeleteFile(file, result);
                }
            }

            return result;
        }

        /// <summary>Xoá log cũ hơn số ngày giữ log đang cấu hình. Trả về null nếu đang tắt tự xoá.</summary>
        public LogDeleteResult ApplyRetention()
        {
            var settings = GetSettings();
            if (settings.RetentionDays <= 0)
                return null;
            // Giữ N ngày gần nhất tính cả hôm nay -> xoá mọi ngày <= hôm nay - N.
            return Delete(null, DateTime.Today.AddDays(-settings.RetentionDays), "*");
        }

        private static void DeleteFile(string file, LogDeleteResult result)
        {
            try
            {
                lock (LogHelper.SyncRoot)
                {
                    long size = new FileInfo(file).Length;
                    File.Delete(file);
                    result.DeletedFiles++;
                    result.DeletedBytes += size;
                }
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
            {
                result.FailedFiles.Add(Path.GetRelativePath(LogsRoot, file) + ": " + ex.Message);
            }
        }

        // Dọn thư mục ngày -> tháng -> năm nếu đã trống.
        private static void RemoveEmptyDirs(string dayDir)
        {
            string dir = dayDir;
            for (int level = 0; level < 3 && dir != null; level++)
            {
                try
                {
                    lock (LogHelper.SyncRoot)
                    {
                        if (!Directory.Exists(dir) || Directory.EnumerateFileSystemEntries(dir).Any())
                            return;
                        Directory.Delete(dir);
                    }
                }
                catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
                {
                    return;
                }
                dir = Path.GetDirectoryName(dir);
            }
        }

        // Liệt kê trước toàn bộ thư mục Logs/{năm}/{tháng}/{ngày} (bỏ qua thư mục tên không phải số/ngày
        // không hợp lệ) - trả về List để vừa duyệt vừa xoá không bị lỗi enumerator.
        public static List<(DateTime Day, string Dir)> EnumerateDayDirs()
        {
            var result = new List<(DateTime, string)>();
            if (!Directory.Exists(LogsRoot))
                return result;

            foreach (string yearDir in SafeGetDirectories(LogsRoot))
            {
                if (!int.TryParse(Path.GetFileName(yearDir), out int year))
                    continue;
                foreach (string monthDir in SafeGetDirectories(yearDir))
                {
                    if (!int.TryParse(Path.GetFileName(monthDir), out int month))
                        continue;
                    foreach (string dayDir in SafeGetDirectories(monthDir))
                    {
                        if (!int.TryParse(Path.GetFileName(dayDir), out int day))
                            continue;
                        if (year >= 1 && year <= 9999 && month >= 1 && month <= 12 && day >= 1 && day <= DateTime.DaysInMonth(year, month))
                            result.Add((new DateTime(year, month, day), dayDir));
                    }
                }
            }
            return result.OrderBy(x => x.Item1).ToList();
        }

        private static List<(DateTime Day, string File)> EnumerateSystemLogFiles()
        {
            var result = new List<(DateTime, string)>();
            if (!Directory.Exists(LogsRoot))
                return result;

            foreach (string file in SafeGetFiles(LogsRoot))
            {
                string name = Path.GetFileNameWithoutExtension(file);
                if (SystemLogFileName.IsMatch(name) &&
                    DateTime.TryParseExact(name, "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day))
                    result.Add((day, file));
            }
            return result;
        }

        private static string[] SafeGetFiles(string dir)
        {
            try
            {
                return Directory.GetFiles(dir, "*.txt");
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
            {
                return Array.Empty<string>();
            }
        }

        private static string[] SafeGetDirectories(string dir)
        {
            try
            {
                return Directory.GetDirectories(dir);
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
            {
                return Array.Empty<string>();
            }
        }
    }
}
