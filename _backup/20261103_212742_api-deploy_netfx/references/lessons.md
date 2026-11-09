# Lỗi đã gặp và quy ước khi sửa skill / engine

| Hiện tượng | Nguyên nhân | Cách tránh |
|---|---|---|
| Tiếng Việt trong `.ps1` bị lỗi font, hoặc script báo lỗi cú pháp | PowerShell 5.1 đọc file không có BOM theo mã ANSI | Mọi `.ps1` lưu UTF-8 **có BOM**. Sau khi sửa bằng công cụ khác, chạy lại `Test-ApiDeploy.ps1` (có kiểm tra BOM) |
| `.bat` báo lỗi ở dòng đầu | File `.bat` có BOM / ký tự không phải ASCII | `.bat` lưu ASCII, CRLF, comment không dấu |
| **Lỗi font**: cửa sổ công cụ hiện tiếng Việt thành ô vuông / `?`, dù file đúng UTF-8 có BOM | Khi Deploy.bat mở lại cửa sổ `powershell.exe` với quyền Administrator, cửa sổ đó dùng font **Lucida Console** (theo key `HKCU\Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe`). Font này không có chữ tiếng Việt dựng sẵn (ạ, ế, ở, ữ...) | `Set-ConsoleUnicodeFont` (lib\Common.ps1) gọi `SetCurrentConsoleFontEx` để đổi sang Consolas ngay đầu Deploy.ps1 / Build-Package.ps1. Đã thử thật: một cửa sổ mới chuyển từ Lucida Console sang Consolas và hiện đúng chữ. Muốn kiểm tra lại thì mở cửa sổ bằng `Start-Process powershell.exe -WindowStyle Minimized`, đọc font bằng `GetCurrentConsoleFontEx`, đọc chữ bằng `$Host.UI.RawUI.GetBufferContents` |
| Chuỗi regex / lệnh PowerShell có `‘` `’` `“` `”` bị cắt giữa chừng (`The string is missing the terminator`) | PowerShell coi dấu nháy cong là dấu nháy thường | Không dán ký tự này trực tiếp. Dựng bằng `[char]0x2018` (vd `'{0}' -f [char]0x2018`) |
| Sửa file `.ps1` bằng công cụ Edit/Write của Claude thì `‘` trong chuỗi biến thành ký tự `‘` thật, và script lỗi cú pháp | Công cụ giải mã chuỗi escape `\uXXXX` trong nội dung trước khi ghi file | Trong `.ps1`, ký tự ngoài ASCII của regex luôn viết bằng `[char]0x....`. Sau mỗi lần sửa, chạy parser kiểm tra cú pháp (`Test-ApiDeploy.ps1` làm việc này cho bộ cài) |
| Người dùng không thấy file zip | Chỉ chạy `Build-Package -All` mà quên `-Zip` | `Test-ApiDeploy.ps1 -Build` luôn chạy `-All -Zip` rồi kiểm tra nội dung zip. `New-ApiDeploy.ps1 -Zip` cũng nén luôn. Báo cáo cuối luôn ghi đường dẫn file zip |
| `Argument types do not match` | Trong PowerShell 5.1, `@($list)` với `$list` là `List[object]` chứa `OrderedDictionary` sẽ lỗi | Dùng `$list.ToArray()` hoặc duyệt thẳng `foreach ($i in $list)`, không bọc `@()` |
| Biến trong hàm có giá trị sai | PowerShell không phân biệt hoa thường tên biến, và dùng dynamic scope | Không đặt biến cục bộ trùng biến cấp script (`$Root`, `$State`, `$Config`, `$Manifest`, `$Defaults`) |
| `appcmd` nhận sai tham số | `Invoke-AppCmd @(...)` truyền cả mảng thành 1 tham số | Gán mảng vào biến rồi splat |
| `Keyword not supported: 'DataSource'` | `SqlConnectionStringBuilder` là IDictionary, nên PowerShell hiểu `.DataSource` là key | Dùng keyword chuẩn: `$b['Data Source']` |
| Báo thiếu ASP.NET Core Module dù đã cài | Module V2 nằm ở `%ProgramFiles%\IIS\Asp.Net Core Module\V2\`, phải có thêm dòng đăng ký trong `applicationHost.config` | Giữ cách kiểm tra trong `Test-AncmInstalled` |
| Có module nhưng site không chạy | Hosting Bundle được cài trước IIS | Cài IIS trước, rồi repair Hosting Bundle. Nếu repair lỗi (bản tải về khác bản đang cài) thì engine tự chuyển sang `/install` |
| Job nền (BackgroundService) không chạy sau khi IIS restart | App chỉ khởi động khi có request đầu tiên | AppPool `AlwaysRunning` + `preloadEnabled` (cần IIS Application Initialization; engine tự đề nghị cài) |
| appsettings mất comment sau khi lưu | `ConvertFrom-Json` / `ConvertTo-Json` bỏ comment | Đọc / ghi appsettings bằng `lib\JsonC.ps1` |
| Gói zip mang theo mật khẩu của máy dev | `dotnet publish` chép nguyên `appsettings.json` | `Build-Package` xoá trắng các key bí mật theo manifest (`Clear-PackageSecrets`) |
| Cập nhật bộ cài cũ làm máy chủ "quên" service đã cài | Engine mới dùng `dataDir` / `firewallPrefix` theo dự án | Manifest cũ thiếu các field này: `New-ApiDeploy` điền giá trị cũ (`HIS.API.Deploy`, `HISAPI_`, `HIS API`) |
| Mã hoá IV ngẫu nhiên thì mỗi lần mã hoá ra 1 chuỗi khác | Đúng thiết kế của `aes128-md5-randiv` | Kiểm tra bằng cách giải mã, không so chuỗi mã hoá. Với `aes256-zeroiv` thì mã hoá lại phải ra đúng chuỗi cũ |
| `ConvertFrom-Json` của PS 5.1 đổi số nguyên lớn | JavaScriptSerializer | Manifest chỉ chứa port (int nhỏ), không lưu số lớn |

## Thử chéo kiểu mã hoá với code C# thật

Cách này chứng minh service giải mã được chuỗi mà `Deploy.bat` ghi vào. Làm trong thư mục tạm, sau khi đã có gói build:

```powershell
. '<DeployPath>\lib\Common.ps1'
$cipher = Protect-HisString 'Data Source=x;Initial Catalog=y;User ID=u;Password=Mật_khẩu' '<cryptoKey>' '<cryptoScheme>'
# Console app netcoreapp3.1 tham chiếu <DeployPath>\packages\<Service>\<thư viện chứa Cryptography>.dll
# (global.json chọn SDK 3.1), Main gọi Cryptography.DecryptString(args[0]) và so với chuỗi gốc
dotnet run -- $cipher 'Data Source=x;...'
```

Làm thêm chiều ngược lại: dùng C# `EncryptString` rồi gọi `Unprotect-HisString`. Với API_BaoSon (`aes128-md5-randiv`, khoá trong `APICommonLibrary/Helpers/Cryptography.cs`), cả 2 chiều đều khớp, kể cả với chuỗi có tiếng Việt.

## Engine khác bản gốc (API_Signer\Deploy) ở đâu

- `lib\Common.ps1`: `Protect-HisString` / `Unprotect-HisString` nhận thêm tham số `$scheme`.
- `lib\Iis.ps1`: thêm `$script:FirewallPrefix` / `$script:FirewallGroup`, `Test-AppInitInstalled`, bật preload trong `Set-IisSite`.
- `lib\Prereq.ps1`: thêm `ConvertTo-RuntimeChannels`; `Get-EnvironmentStatus` và `Install-Prerequisites` xử lý nhiều kênh; thêm `Test-IisServiceRunning`, `Start-IisServices`, `Test-PendingReboot`, `Install-IisAppInit`.
- `lib\Auth.ps1`: hash mật khẩu mới.
- `Deploy.ps1`:
  - Đọc `toolTitle` / `dataDir` / `firewallPrefix` / `firewallGroup` từ manifest.
  - Thêm `$RuntimeChannels`, `Protect-SvcString` / `Unprotect-SvcString`, `Test-ApiSwitch`, `healthPath`, `note`.
  - `Show-Environment` kiểm tra đầy đủ hơn.
- `Build-Package.ps1`:
  - Thêm `repoRoot`, `packageName`, `-KeepSecrets` / `Clear-PackageSecrets`.
  - Tải bộ cài prereq cho nhiều kênh runtime.
  - Không đưa `_backup` vào file zip.
