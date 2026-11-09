# Công cụ triển khai %%PROJECT%%

Công cụ cài đặt và cấu hình các API của %%PROJECT%% lên IIS. Chạy lại bất kỳ lúc nào để cập nhật bản mới hoặc sửa cấu hình. Khi chạy lại, giá trị đang dùng được giữ làm mặc định.

## Thư mục

| File / thư mục | Dùng để |
|---|---|
| `Build-Package.bat` | Máy build: `dotnet publish` từng service vào `packages\<Service>`, nén zip vào `dist\` |
| `Deploy.bat` | Máy chủ: menu cài đặt / cập nhật / cấu hình (tự xin quyền Administrator) |
| `deploy-manifest.json` | Danh sách service, port gợi ý, kết nối CSDL, tham số appsettings, kiểu mã hoá |
| `lib\` | Thư viện của công cụ (đọc/ghi appsettings giữ nguyên comment, IIS, firewall, mã hoá, mật khẩu, cài môi trường) |
| `prereq\` | Bộ cài ASP.NET Core Hosting Bundle (công cụ tự tải vào đây, hoặc bỏ sẵn khi máy chủ không có internet) |
| `packages\` | Gói cài đặt do `Build-Package` tạo ra |

Dữ liệu của công cụ trên máy chủ nằm ở `%ProgramData%\%%DATA_DIR%%\`. Chỉ Administrators và SYSTEM đọc được thư mục này.

| File / thư mục | Nội dung |
|---|---|
| `config.json` | Thư mục lưu API |
| `state.json` | Site, app pool, port, đường dẫn của từng service |
| `backup\<Service>\` | Bản sao lưu chương trình và appsettings.json |
| `logs\` | Log thao tác |

## Service

%%SERVICE_TABLE%%

Tên site IIS và app pool mặc định là `<tiền tố><Service>`, đổi được ở lần cài đầu tiên. Rule firewall: `%%FIREWALL_PREFIX%%<Service>`, nhóm `%%FIREWALL_GROUP%%`.

%%NOTES%%

## 1. Build gói (máy có .NET SDK)

```bat
Build-Package.bat                                  :: chọn service bằng menu
Build-Package.bat -All -Zip                        :: build tất cả + nén zip vào dist\
Build-Package.bat -Services <Service1>,<Service2> -Zip
Build-Package.bat -All -SelfContained -Zip         :: máy chủ không cần cài .NET runtime
Build-Package.bat -All -Zip -IncludePrereq         :: kèm bộ cài Hosting Bundle cho máy chủ không có internet
```

Gói build ra đã **xoá trắng** chuỗi kết nối và các tham số bí mật (mật khẩu, token) trong `appsettings.json`, nên máy chủ cài mới phải nhập giá trị thật. Thêm `-KeepSecrets` nếu muốn giữ nguyên giá trị của máy dev.

Copy file `dist\%%PACKAGE_NAME%%_*.zip` sang máy chủ, giải nén vào 1 thư mục riêng (vd `D:\Deploy_%%PROJECT%%`).

## 2. Triển khai (máy chủ)

Yêu cầu: Windows Server 2016 / Windows 10 trở lên, PowerShell 5.1. Công cụ tự cài IIS và ASP.NET Core Hosting Bundle %%RUNTIME%% nếu máy còn thiếu.

Cửa sổ công cụ tự đổi font sang Consolas để hiện đúng tiếng Việt, vì font mặc định Lucida Console của PowerShell không có các chữ như ạ, ế, ở. Nếu vẫn thấy ô vuông hoặc dấu `?`, chuột phải vào thanh tiêu đề cửa sổ → Properties → Font → chọn Consolas.

### Mật khẩu

Mỗi lần mở `Deploy.bat`, công cụ hỏi mật khẩu trước mọi bước. Nhập sai 3 lần thì công cụ thoát.

- Mật khẩu cố định cho mọi máy chủ, do nhóm triển khai cung cấp. Không đổi được trong công cụ.
- Gói triển khai chỉ chứa hash PBKDF2 (200.000 vòng, có salt) của mật khẩu trong `lib\Auth.ps1`, không chứa mật khẩu dạng chữ.
- Mật khẩu chỉ ngăn người không có mật khẩu dùng công cụ. Người có quyền Administrator trên máy chủ vẫn sửa được script.

### Lần chạy đầu tiên

1. **Thư mục lưu các API**, ví dụ `D:\%%PROJECT%%`. Mỗi service cài vào 1 thư mục con. Thư mục phải nằm trên ổ cứng của máy chủ, không phải thư mục gốc ổ đĩa, không nằm trong thư mục hệ thống.
2. **Kiểm tra môi trường**: hệ điều hành, .NET Framework, dung lượng ổ, Windows Firewall, máy đang chờ khởi động lại, IIS và dịch vụ WAS/W3SVC, ASP.NET Core Module V2, ASP.NET Core Runtime %%RUNTIME%%, IIS Application Initialization, port gợi ý có bị chiếm không. Thiếu thành phần nào thì công cụ hỏi 1 lần rồi tự cài theo thứ tự:
   1. Cài IIS (kèm Application Initialization), bật dịch vụ IIS.
   2. Lấy bản ASP.NET Core Hosting Bundle mới nhất của kênh runtime từ nguồn chính thức của Microsoft.
   3. Kiểm tra mã SHA512 và chữ ký số Microsoft.
   4. Cài ở chế độ im lặng. Đã có runtime mà thiếu module IIS thì chạy repair.
   5. Khởi động lại IIS.

   Máy chủ không có internet: bỏ `dotnet-hosting-<phiên bản>-win.exe` vào `prereq\` rồi chọn **K**.

Menu **C. Cài đặt chung** dùng để đổi thư mục lưu API.

### Triển khai 1 service (tạo mới)

Ở menu chính chọn số thứ tự của service, rồi chọn **1. Triển khai đầy đủ**:

1. Thư mục cài đặt (mặc định `<thư mục lưu API>\<Service>`).
2. Copy file chương trình từ gói.
3. Kết nối CSDL: nhập server, database, user, mật khẩu (nhập ẩn). SQL Server: công cụ đăng nhập thử. Oracle: chỉ kiểm tra cổng TCP. Chuỗi kết nối được mã hoá đúng cách `Cryptography.cs` của service trước khi ghi vào `appsettings.json`.
4. Chọn API chạy (chỉ với service có ApiSwitch).
5. Tham số appsettings. `Enter` giữ giá trị cũ, `-` xoá trắng, token nhập `G` để sinh ngẫu nhiên. Mật khẩu nhập ẩn và nhập 2 lần.
6. Port, IIS, Firewall:
   - Đặt **tên site (tên API)** và **tên app pool** (lần đầu).
   - Kiểm tra port có bị site / chương trình khác dùng không.
   - Tạo hoặc cập nhật app pool: No Managed Code, Integrated, AlwaysRunning, không tự dừng khi rảnh, nạp user profile.
   - Tạo hoặc cập nhật site, binding `http://*:<port>`, bật preload nếu có Application Initialization.
   - Cấp quyền ghi thư mục cho `IIS AppPool\<tên pool>`.
   - Mở port trên Windows Firewall (có thể giới hạn IP / dải IP).
   - Khởi động lại và gọi thử API. Lỗi 500.30 thì tạm bật log stdout và hiện nội dung log.

## 3. Chạy lại để cập nhật

Trong menu của từng service:

| Mục | Việc |
|---|---|
| 2 | Cập nhật bản build mới: sao lưu bản đang chạy, dừng app bằng `app_offline.htm`, copy file, bổ sung tham số mới có trong gói. Giá trị đang dùng không bị ghi đè |
| 3 | Đổi CSDL / mật khẩu |
| 4 | Đổi port, IP được phép truy cập |
| 5 | Bật/tắt API (service có ApiSwitch) |
| 6 | Sửa tham số |
| 7 | Khởi động lại và kiểm tra |
| 8 | Xem cấu hình hiện tại (mật khẩu được che) |
| 9 | Khôi phục bản sao lưu (toàn bộ chương trình hoặc chỉ appsettings.json) |
| X | Gỡ cài đặt (xoá site, app pool, rule firewall; tuỳ chọn xoá thư mục, có sao lưu trước) |

Mỗi lần lưu, công cụ hiện danh sách thay đổi để xác nhận và sao lưu `appsettings.json` trước khi ghi. Comment trong file được giữ nguyên.

## Đổi mật khẩu công cụ (dành cho dev)

Chạy lại skill `api-deploy` với tham số `-Password`, hoặc chạy đoạn PowerShell dưới đây trên máy dev rồi chép 3 giá trị vào `$script:ToolPasswordSalt`, `$script:ToolPasswordHashSha256`, `$script:ToolPasswordHashSha1` trong `lib\Auth.ps1`, sau đó build lại gói.

```powershell
$ss = Read-Host 'Mật khẩu mới' -AsSecureString; $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
$s = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($s)
$a = New-Object Security.Cryptography.Rfc2898DeriveBytes($pw, $s, 200000, [Security.Cryptography.HashAlgorithmName]::SHA256)
$b = New-Object Security.Cryptography.Rfc2898DeriveBytes($pw, $s, 200000)
"Salt=$([Convert]::ToBase64String($s))"; "Sha256=$([Convert]::ToBase64String($a.GetBytes(32)))"; "Sha1=$([Convert]::ToBase64String($b.GetBytes(32)))"
```

## Lưu ý

- Công cụ chỉ tạo binding HTTP. Cần HTTPS thì thêm binding và certificate trong IIS Manager. Công cụ không xoá các binding khác.
- `cryptoKey` trong `deploy-manifest.json` phải trùng khoá trong `Cryptography.cs` của service. Khoá này cũng nằm trong file dll, nên mã hoá chuỗi kết nối chỉ che giá trị khỏi người đọc `appsettings.json`.
- Tham số kiểu `secret` (mật khẩu đối tác...) được lưu nguyên văn trong `appsettings.json` vì service đọc trực tiếp. Thư mục cài đặt chỉ nên cấp quyền cho Administrators và app pool.
