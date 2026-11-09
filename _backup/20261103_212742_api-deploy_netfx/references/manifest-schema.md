# Schema `deploy-manifest.json`

`New-ApiDeploy.ps1` sinh ra file này, và có thể sửa tay. File được lưu UTF-8 có BOM.

## `defaults`

| Field | Ý nghĩa | Mặc định khi tạo mới | Khi cập nhật manifest cũ thiếu field |
|---|---|---|---|
| `toolTitle` | Tiêu đề trên màn hình công cụ | `<ProjectName>` | `<ProjectName>` |
| `installRoot` | Thư mục lưu API gợi ý ở lần thiết lập đầu. Thư mục thật do người dùng chọn trên máy chủ | `C:\<ProjectName>` | giữ nguyên |
| `sitePrefix` | Tiền tố tên site IIS và app pool | `<ProjectName bỏ "API_">_` | giữ nguyên |
| `aspNetCoreRuntime` | Các kênh runtime cần có, phân tách bằng dấu phẩy | kênh của các service | hợp của giá trị cũ và kênh mới |
| `dataDir` | Thư mục trong `%ProgramData%` chứa config/state/backup/log | `<ProjectName>.Deploy` | `HIS.API.Deploy` |
| `firewallPrefix` | Tiền tố tên rule firewall | = `sitePrefix` | `HISAPI_` |
| `firewallGroup` | Nhóm rule firewall | `<ProjectName>` | `HIS API` |
| `packageName` | Tiền tố file zip trong `dist\` | `<ProjectName>_Deploy` | `<ProjectName>_Deploy` |
| `repoRoot` | Thư mục mã nguồn: đường dẫn tuyệt đối, hoặc tương đối với thư mục Deploy. Không khai báo thì dùng thư mục cha của Deploy | bỏ trống nếu Deploy nằm ngay dưới repo | tính lại |

Hai bộ công cụ có **cùng `dataDir`** sẽ dùng chung `config.json` (thư mục lưu API) và `state.json`. Nếu 2 bộ có service trùng tên thì chúng quản lý chung 1 site.

## `services[]`

| Field | Ý nghĩa |
|---|---|
| `name` | Tên assembly, trùng tên thư mục gói `packages\<name>` |
| `title` | Mô tả hiện trên menu |
| `note` | Lưu ý hiện trong menu của service và trong HUONG_DAN.md |
| `project` | Đường dẫn `.csproj` tương đối với repoRoot, dùng `/` |
| `dll` | Tên file dll chính, dùng để nhận biết gói hợp lệ |
| `runtime` | Kênh runtime của service (`3.1`, `8.0`...). Công cụ hợp nhất kênh này với `defaults.aspNetCoreRuntime` |
| `defaultPort` | Port gợi ý khi tạo site |
| `apiSwitch` | `false` nghĩa là service không có ApiSwitchFilter: bỏ bước chọn API, mọi controller coi như đang bật |
| `healthPath` | Đường dẫn gọi thử sau khi khởi động, vd `swagger/index.html`. `""` = trang gốc. HTTP 2xx–4xx được coi là đang chạy |
| `cryptoScheme` | `aes256-zeroiv` \| `aes128-md5-randiv` \| `none`. Không khai báo thì dùng `aes256-zeroiv` (tương thích bộ cũ) |
| `cryptoKey` | `aes256-zeroiv`: chuỗi 32 byte UTF-8. `aes128-md5-randiv`: passphrase (khoá = MD5 của chuỗi này) |
| `connections[]` | `{ name, type: sqlserver\|oracle, title }`. `name` là key trong `ConnectionStrings` |
| `settings[]` | Tham số dùng chung của service |
| `controllers[]` | `{ name, title, actions[], settings[], note }`. `name` là tên class bỏ hậu tố `Controller` |

### Tham số (`settings[]`)

| Field | Ý nghĩa |
|---|---|
| `key` | Đường dẫn theo kiểu IConfiguration, vd `Bhxh:Password`, `Users:0:Password` |
| `title` | Mô tả hiện khi hỏi |
| `type` | `string` (mặc định) \| `url` \| `path` \| `int` \| `bool` \| `secret` \| `encrypted` \| `token` |
| `default` | Giá trị đề xuất khi appsettings chưa có key |
| `required` | `true` = không cho để trống |
| `advanced` | `true` = chỉ hỏi khi người dùng chọn cấu hình nâng cao |
| `generate` | Dùng cho `token`: `hex32` \| `base64-32` \| `base64-48` |
| `note` | Ghi chú hiện dưới tiêu đề |

Cách chọn `type`:

| Code đọc giá trị thế nào | `type` |
|---|---|
| Mật khẩu / secret dùng trực tiếp | `secret` (nhập ẩn 2 lần, lưu nguyên văn) |
| Code gọi `Cryptography.DecryptString(...)` trên giá trị | `encrypted` |
| Khoá / token do mình cấp cho đối tác, khoá ký JWT | `token` |
| URL gọi sang hệ thống khác | `url` (chỉ nhận http/https; `ftp://...` thì dùng `string`) |
| Đường dẫn file / thư mục trên máy chủ | `path` |

Khi chạy `Build-Package`, giá trị của `secret` / `encrypted` / `token` và `ConnectionStrings` bị xoá trắng trong gói, trừ khi có `-KeepSecrets`.

## Mẫu ApiSwitchFilter (chỉ thêm khi người dùng yêu cầu bật/tắt từng API)

`Filters\ApiSwitchFilter.cs` (thay `<Namespace>`):

```csharp
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.Extensions.Configuration;

namespace <Namespace>.Filters
{
    // Bật/tắt controller / API theo appsettings "ApiSwitch": Actions:{Controller}.{Action} > Controllers:{Controller} > Default.
    // API bị tắt trả HTTP 404. Sửa appsettings có hiệu lực ngay.
    public class ApiSwitchFilter : IAuthorizationFilter
    {
        private readonly IConfiguration _configuration;
        public ApiSwitchFilter(IConfiguration configuration) { _configuration = configuration; }

        public void OnAuthorization(AuthorizationFilterContext context)
        {
            if (!(context.ActionDescriptor is ControllerActionDescriptor d)) return;
            if (!IsEnabled(_configuration, d.ControllerName, d.ActionName))
                context.Result = new ObjectResult(new { status = false, data = "API " + d.ControllerName + "/" + d.ActionName + " chưa được mở (ApiSwitch)", code = "404" })
                { StatusCode = StatusCodes.Status404NotFound };
        }

        public static bool IsEnabled(IConfiguration c, string controller, string action)
        {
            if (c == null) return true;
            bool? a = c.GetValue<bool?>("ApiSwitch:Actions:" + controller + "." + action);
            if (a.HasValue) return a.Value;
            bool? ctl = c.GetValue<bool?>("ApiSwitch:Controllers:" + controller);
            if (ctl.HasValue) return ctl.Value;
            return c.GetValue<bool?>("ApiSwitch:Default").GetValueOrDefault(true);
        }
    }
}
```

Đăng ký filter: `services.AddControllers(o => o.Filters.Add<ApiSwitchFilter>());`. Muốn ẩn API bị tắt khỏi Swagger thì thêm `c.DocInclusionPredicate((_, api) => !(api.ActionDescriptor is ControllerActionDescriptor d) || ApiSwitchFilter.IsEnabled(Configuration, d.ControllerName, d.ActionName));`. Sau đó thêm section `"ApiSwitch": { "Default": true, "Controllers": { ... }, "Actions": { } }` vào appsettings. Chạy lại skill: script tự đổi `apiSwitch` thành `true`.
