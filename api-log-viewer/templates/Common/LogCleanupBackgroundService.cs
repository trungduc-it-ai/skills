using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System;
using System.Threading;
using System.Threading.Tasks;

namespace %%NAMESPACE%%.Common
{
    /// <summary>
    /// Tự xoá log cũ hơn số ngày giữ log (LogSettings:RetentionDays, hoặc giá trị đã lưu trên màn hình
    /// xem log). Chạy lần đầu sau khi app khởi động 1 phút, sau đó mỗi CleanupIntervalHours giờ. Cấu
    /// hình được đọc lại mỗi lần kiểm tra nên đổi trên màn hình có hiệu lực mà không cần restart.
    /// Lần dọn nào có xoá/không xoá được file thì ghi kết quả vào tag Log_Admin.
    /// </summary>
    public class LogCleanupBackgroundService : BackgroundService
    {
        private static readonly TimeSpan StartupDelay = TimeSpan.FromMinutes(1);
        // Chu kỳ kiểm tra đã tới giờ dọn chưa - ngắn để đổi CleanupIntervalHours có hiệu lực sớm.
        private static readonly TimeSpan CheckInterval = TimeSpan.FromMinutes(5);

        private readonly ILogMaintenance _maintenance;
        private readonly ILogger<LogCleanupBackgroundService> _logger;

        public LogCleanupBackgroundService(ILogMaintenance maintenance, ILogger<LogCleanupBackgroundService> logger)
        {
            _maintenance = maintenance;
            _logger = logger;
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            try
            {
                await Task.Delay(StartupDelay, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            DateTime lastRun = DateTime.MinValue;
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    var settings = _maintenance.GetSettings();
                    if (DateTime.Now - lastRun >= TimeSpan.FromHours(settings.CleanupIntervalHours))
                    {
                        lastRun = DateTime.Now;
                        RunOnce(settings);
                    }
                }
                catch (Exception ex)
                {
                    // Lỗi dọn log không được làm chết vòng lặp - lần kiểm tra sau thử lại.
                    _logger.LogError(ex, "Tự động dọn log %%SERVICE_TITLE%% thất bại");
                }

                try
                {
                    await Task.Delay(CheckInterval, stoppingToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }

        private void RunOnce(LogRetentionSettings settings)
        {
            var trace = new ApiTrace();
            var result = _maintenance.ApplyRetention();
            if (result == null || (result.DeletedFiles == 0 && result.FailedFiles.Count == 0))
                return;

            ApiLogger.Log("Log_Admin", new ApiLogEntry
            {
                Url = "LogCleanup (background)",
                Method = "AUTO",
                Request = new { settings.RetentionDays, settings.CleanupIntervalHours, Nguon = settings.Source },
                Response = result
            }, trace);
        }
    }
}
