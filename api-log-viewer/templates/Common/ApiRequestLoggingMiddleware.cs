using Microsoft.AspNetCore.Http;
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace %%NAMESPACE%%.Common
{
    /// <summary>
    /// Ghi log input (method, path, query/body) của MỌI request gọi vào các API của %%SERVICE_TITLE%%,
    /// ngay khi nhận được - độc lập với log thành công/thất bại riêng của từng action. Dùng chung
    /// ApiLogger (chia theo ngày, cùng cấu trúc Url/Method/Request/Response/Error với các API khác).
    /// </summary>
    public class ApiRequestLoggingMiddleware
    {
        // Body không phải JSON có thể rất lớn - cắt bớt (sau khi đã lọc base64) để log không phình
        // to, vẫn đủ để biết request có tới và chứa gì.
        private const int MaxBodyLogLength = 10000;

        private readonly RequestDelegate _next;

        public ApiRequestLoggingMiddleware(RequestDelegate next)
        {
            _next = next;
        }

        public async Task InvokeAsync(HttpContext context)
        {
            string path = context.Request.Path.ToString();

            // Bỏ qua swagger/static asset và API của chính màn hình xem log để log đỡ rác (thao tác xoá
            // log/đổi cấu hình đã có audit riêng ở tag Log_Admin).
            if (path.StartsWith("/swagger", StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith("/%%LOG_ROUTE%%", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(path, "/logs.html", StringComparison.OrdinalIgnoreCase))
            {
                await _next(context);
                return;
            }

            string body;
            try
            {
                if (string.Equals(context.Request.Method, "GET", StringComparison.OrdinalIgnoreCase))
                {
                    body = context.Request.QueryString.ToString();
                }
                else if (context.Request.ContentLength > 0)
                {
                    // EnableBuffering cho phép đọc body xong rồi "tua lại" để MVC model binding vẫn
                    // đọc được bình thường phía sau.
                    context.Request.EnableBuffering();
                    using (var reader = new StreamReader(context.Request.Body, Encoding.UTF8, false, 4096, leaveOpen: true))
                    {
                        body = await reader.ReadToEndAsync();
                    }
                    context.Request.Body.Position = 0;
                }
                else
                {
                    body = "";
                }
            }
            catch (Exception ex)
            {
                // Đọc body lỗi (stream bất thường...) không được làm hỏng cả request - chỉ ghi chú lại
                // và để request đi tiếp bình thường.
                body = $"(không đọc được body: {ex.Message})";
            }

            // Parse NGUYÊN body thành object thật nếu là JSON hợp lệ (để xem log hiển thị đẹp, tìm kiếm
            // được theo field) - ApiLogger tự lọc field bí mật/chuỗi base64 dài (byte[] file...). Không cắt
            // trước khi parse: cắt giữa chừng làm JSON hỏng, cả chuỗi base64 bị ghi nguyên văn vào log.
            object requestForLog = JsonHelper.TryParse(body);
            if (requestForLog is string rawBody)
            {
                // Không phải JSON: lọc base64/mật khẩu trong chuỗi thô trước, rồi mới cắt cho gọn.
                rawBody = JsonHelper.SanitizeString(rawBody);
                if (rawBody.Length > MaxBodyLogLength)
                    rawBody = rawBody.Substring(0, MaxBodyLogLength) + $"...(truncated, length={rawBody.Length})";
                requestForLog = rawBody;
            }

            string clientIp = context.Connection.RemoteIpAddress?.ToString();

            ApiLogger.Log("Api_Input", new ApiLogEntry
            {
                Url = path,
                Method = context.Request.Method,
                ClientIp = clientIp,
                Request = requestForLog
            });

            try
            {
                await _next(context);
            }
            catch (Exception ex)
            {
                // Exception chưa được controller/action nào bắt (vượt qua mọi try/catch bên trong) -
                // ghi lại kèm input gốc của chính request đó để biết request nào gây lỗi, rồi re-throw
                // để pipeline xử lý lỗi (DeveloperExceptionPage, status code...) vẫn chạy như bình thường.
                ApiLogger.Log("Api_Error", new ApiLogEntry
                {
                    Url = path,
                    Method = context.Request.Method,
                    ClientIp = clientIp,
                    Request = requestForLog,
                    Error = ex.ToString()
                });
                throw;
            }
        }
    }
}
