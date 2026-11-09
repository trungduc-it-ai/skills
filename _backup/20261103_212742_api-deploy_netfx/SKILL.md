---
name: api-deploy
description: Tạo hoặc cập nhật bộ cài đặt (thư mục Deploy) cho các API ASP.NET Core chạy trên IIS. Đầu vào là tên dự án và đường dẫn lưu bộ cài. Bộ cài hỏi mật khẩu trước khi làm bất cứ việc gì (chỉ lưu hash PBKDF2). Bộ cài kiểm tra đầy đủ môi trường và tự cài phần còn thiếu (IIS, ASP.NET Core Hosting Bundle, Application Initialization). Bộ cài cho tạo mới hoặc cập nhật service, đặt tên site (tên API) và tên AppPool, mở port trên Windows Firewall, nhập chuỗi kết nối CSDL và mã hoá đúng như Cryptography.cs của service, hỏi tham số appsettings, sao lưu, khôi phục, gỡ cài đặt. Engine lấy từ bộ Deploy của API_Signer (đã chạy thật) và được tổng quát hoá. Dùng skill này khi người dùng muốn "tạo bộ cài", "đóng gói deploy", "script cài API lên IIS", "tạo AppPool / site / mở port firewall", "bộ cài có mật khẩu", "cập nhật bộ deploy", hoặc áp dụng thư mục Deploy của API / API_Signer cho repo khác. Dùng cả khi người dùng không nhắc tới chữ skill.
---

# api-deploy: bộ cài API ASP.NET Core lên IIS

## Đầu vào

| Tham số | Bắt buộc | Ý nghĩa |
|---|---|---|
| `-ProjectName` | Có | Tên dự án, vd `API_BaoSon`. Dùng làm tiêu đề công cụ, tiền tố site/AppPool (`BaoSon_`), thư mục dữ liệu trên máy chủ (`%ProgramData%\API_BaoSon.Deploy`), rule firewall, tên file zip |
| `-DeployPath` | Có | Thư mục lưu bộ cài. Quy ước của các repo HIS là `<repo>\Deploy`. Nếu thư mục đã có `deploy-manifest.json` thì skill chạy chế độ cập nhật |
| `-RepoRoot` | Không | Thư mục chứa `.sln`. Mặc định là thư mục cha của DeployPath (nếu có .sln), không thì thư mục hiện tại |
| `-Password` | Không | `SecureString`, dùng để đặt mật khẩu công cụ mới. Bỏ trống thì giữ hash đang có, hoặc dùng hash mặc định của template |
| `-StartPort` | Không | Port gợi ý cho service mới đầu tiên, mặc định `8301`. Repo API dùng 81xx, API_Signer dùng 82xx, nên chọn dải khác để tránh trùng |
| `-Zip` | Không | Ghi bộ cài xong thì build mọi service và nén zip vào `<DeployPath>\dist\` |
| `-SitePrefix`, `-InstallRoot`, `-Services`, `-ScanOnly`, `-Force` | Không | Xem phần đầu `scripts/New-ApiDeploy.ps1` |

Nếu đối số đầu tiên là tên **một service** (vd `/api-deploy Duoc.Service <path>`), dùng tên đó làm `-ProjectName` và thêm `-Services <tên>`, để bộ cài chỉ chứa service này. Nên truyền thêm `-SitePrefix` để tên site không bị lặp kiểu `Duoc.Service_Duoc.Service`.

**Mật khẩu mặc định**: `template/lib/Auth.ps1` đã nhúng sẵn hash PBKDF2 của mật khẩu mà người dùng chọn khi tạo skill. Mật khẩu dạng chữ **không được ghi** vào bất kỳ file nào của skill hay của bộ cài. Muốn đổi mật khẩu thì truyền `-Password`. Khi người dùng đưa mật khẩu trong chat, truyền vào bằng `-Command` như sau và không ghi ra file:

```powershell
powershell -NoProfile -Command "& '<skill>\scripts\New-ApiDeploy.ps1' -ProjectName X -DeployPath '...' -Password (ConvertTo-SecureString '<mật khẩu>' -AsPlainText -Force)"
```

## Bộ cài làm được gì (engine trong `template/`)

- `Deploy.bat` tự xin quyền Administrator, rồi **hỏi mật khẩu trước mọi bước**. Sai 3 lần thì thoát, thời gian chờ sau mỗi lần sai tăng dần.
- Cửa sổ công cụ tự đổi font sang **Consolas**. Lý do: cửa sổ `powershell.exe` mở lại với quyền Administrator mặc định dùng Lucida Console, font này không có chữ tiếng Việt nên hiện lỗi font.
- **Kiểm tra môi trường** ở lần chạy đầu, ở menu K, và trước khi tạo site. Các mục kiểm tra: OS ≥ Server 2016 / Win10, .NET Framework, dung lượng ổ, Windows Firewall, máy đang chờ khởi động lại, IIS và dịch vụ WAS/W3SVC, ASP.NET Core Module V2, runtime của **từng kênh** (`3.1`, `8.0`...), Application Initialization, port gợi ý có bị chiếm không.
- **Tự cài phần còn thiếu**, theo đúng thứ tự: IIS (kèm AppInit) → bật dịch vụ → tải Hosting Bundle mới nhất của từng kênh từ Microsoft → kiểm tra SHA512 và chữ ký Microsoft → cài im lặng → repair nếu module chưa đăng ký với IIS → restart IIS. Máy không có internet thì dùng file đặt sẵn trong `prereq\`.
- **Tạo mới / cập nhật** từng service:
  - Copy file. Khi cập nhật thì sao lưu trước, dừng app bằng `app_offline.htm`, chỉ bổ sung key mới vào appsettings, không ghi đè giá trị đang dùng.
  - Chuỗi kết nối: nhập ẩn, đăng nhập thử SQL Server, rồi **mã hoá đúng cách Cryptography.cs của service**.
  - Tham số appsettings theo kiểu: `secret` nhập ẩn 2 lần, `token` gõ `G` để sinh ngẫu nhiên, `encrypted` mã hoá.
  - Đặt **tên site (tên API) và tên AppPool**. AppPool: No Managed Code, AlwaysRunning, không có idle timeout. Site: binding `http://*:port`, bật preload.
  - Cấp quyền ghi thư mục cho `IIS AppPool\<pool>`.
  - **Mở port trên Firewall**, có thể giới hạn IP / dải IP.
  - Health check sau khi cài. Gặp lỗi 500.30 thì tạm bật stdout log để xem nguyên nhân.
- Có menu đổi CSDL / port / tham số, khởi động lại, xem cấu hình (mật khẩu được che), khôi phục bản sao lưu, gỡ cài đặt.
- `Build-Package.bat` chạy `dotnet publish` từng service rồi nén zip. Mặc định nó **xoá trắng mật khẩu / token / chuỗi kết nối** trong `appsettings.json` của gói (`-KeepSecrets` để giữ lại). Vì vậy file zip không mang theo mật khẩu của máy dev.

## Quy trình

### 1. Khảo sát repo trước khi chạy script

Đọc code trước, đừng tin hoàn toàn vào kết quả quét tự động:
- **Cryptography.cs** mà service dùng để giải mã chuỗi kết nối. Lần theo cả `ProjectReference`, vì có thể nằm trong thư viện chung, vd `APICommonLibrary/Helpers`. Script nhận ra 2 kiểu: `aes256-zeroiv` (bộ HIS cũ, `encryptionKey` 32 ký tự, IV = 0) và `aes128-md5-randiv` (khoá = MD5(passphrase), IV ngẫu nhiên đặt trước bản mã). Nếu gặp kiểu khác thì phải viết thêm nhánh trong `Protect-HisString` / `Unprotect-HisString` (`template/lib/Common.ps1`), và thêm kiểm tra vào `Test-ApiDeploy.ps1`.
- **Section appsettings** mà code đọc thật: `GetSection("X")`, `Configuration["X:Y"]`, Options. Script bỏ các section không có tên trong code, vd `EMrHub11111` là bản sao lưu.
- **Đặc thù cần ghi `note`**: Ocelot.json của gateway, job chạy nền (cần AppInit), chứng thư trong `CurrentUser` (cần nạp vào profile của AppPool hoặc chuyển sang `LocalMachine`).
- **ApiSwitchFilter**: không có thì `apiSwitch: false`, và bước chọn API bị bỏ qua. Chỉ thêm ApiSwitch khi người dùng yêu cầu (mẫu ở `references/manifest-schema.md`).

### 2. Quét thử rồi tạo / cập nhật

```powershell
powershell -NoProfile -File "<skill>\scripts\New-ApiDeploy.ps1" -ProjectName API_BaoSon -DeployPath "<repo>\Deploy" -ScanOnly
powershell -NoProfile -File "<skill>\scripts\New-ApiDeploy.ps1" -ProjectName API_BaoSon -DeployPath "<repo>\Deploy"
```

- **Tạo mới**: sinh `deploy-manifest.json`, chép engine, `lib\Auth.ps1` (hash), `HUONG_DAN.md`, `prereq\README.txt`.
- **Cập nhật**: giữ phần đã sửa tay trong manifest, chỉ bổ sung service / kết nối / tham số / controller / action mới. Kiểu mã hoá được cập nhật theo code. Những mục không còn thấy trong code thì chỉ báo, không xoá. Engine được thay bằng bản mới, file cũ khác nội dung được chép sang `_backup\<thời điểm>\`. Hash mật khẩu đang dùng được giữ nguyên.
- Manifest của bộ HIS cũ không có `dataDir` / `firewallPrefix` / `firewallGroup`. Khi cập nhật, script điền giá trị cũ (`HIS.API.Deploy`, `HISAPI_`, `HIS API`) để máy chủ đã cài không bị mất trạng thái và rule firewall.

### 3. Rà manifest

Sửa `title` của service, kết nối và tham số sang tiếng Việt dễ hiểu cho người triển khai. Thêm `required: true` cho tham số bắt buộc, thêm `note` cho các lưu ý ở bước 1, chỉnh `type` nếu đoán sai. Sau đó chạy lại skill để `HUONG_DAN.md` nhận tiêu đề mới. Lần chạy lại này phải báo "không có thay đổi từ mã nguồn".

### 4. Kiểm thử + đóng gói zip (bắt buộc trước khi báo xong)

```powershell
powershell -NoProfile -Command "& '<skill>\scripts\Test-ApiDeploy.ps1' -DeployPath '<repo>\Deploy' -Password (ConvertTo-SecureString '<mật khẩu>' -AsPlainText -Force) -Build"
```

`-Build` chạy `Build-Package -All -Zip`, nên lần chạy này **tạo luôn file zip** giao cho máy chủ, đặt trong `<DeployPath>\dist\<packageName>_<thời điểm>.zip`. Script kiểm tra các mục sau:
- Mã hoá file và xuống dòng: `.ps1` là UTF-8 có BOM, `.bat` là ASCII + CRLF.
- Không có chữ tiếng Việt bị lỗi mã hoá.
- Cú pháp, các lệnh gọi tới hàm không tồn tại, và có bước đổi font console.
- Manifest.
- Mật khẩu: đúng thì được nhận, sai thì bị từ chối, hash SHA1 khớp, không có mật khẩu dạng chữ trong bộ cài.
- Giải mã được chuỗi kết nối có sẵn trong mã nguồn.
- Build thật: gói có dll và `web.config`, đã xoá trắng các giá trị bí mật.
- Zip: là file mới tạo, đủ công cụ và gói của mọi service, không chứa `_backup` / `dist`, không chứa mật khẩu dạng chữ.

Script phải báo "Tất cả ... mục ĐẠT". Nếu `ConnectionStrings` của service đang trống thì không có mẫu để so. Khi đó, và khi gặp kiểu mã hoá mới, cần thử chéo: dùng dll thật trong `packages\<Service>` để giải mã chuỗi do PowerShell mã hoá. Cách làm ở `references/lessons.md`.

### 5. Áp dụng trên máy

`Deploy.bat` cần quyền Administrator (UAC) và cần người nhập liệu, nên **Claude không tự chạy được**. Hướng dẫn người dùng tự chạy `<DeployPath>\Deploy.bat`, chọn K để kiểm tra môi trường, rồi chọn service → 1. Không tự chạy lệnh elevated để cài IIS, tạo site hay mở firewall khi người dùng chưa đồng ý rõ ràng.

### 6. Báo cáo cho người dùng

Báo các mục sau: đường dẫn bộ cài, **đường dẫn và dung lượng file zip**, bảng service (port, site/pool, kiểu mã hoá), kết quả test. Kèm theo các việc người dùng cần quyết định:
1. Dải port gợi ý.
2. Các giá trị bí mật đang nằm trong `appsettings.json` của mã nguồn: gói build sẽ xoá trắng, nhưng nên xoá luôn khỏi repo.
3. `cryptoKey` nằm trong manifest và trong dll. Mã hoá chỉ che giá trị khỏi người đọc appsettings.
4. Các `note` đặc thù, vd Ocelot.json phải sửa tay theo port đã cài.

## Tài nguyên

| Đường dẫn | Dùng khi |
|---|---|
| `scripts/New-ApiDeploy.ps1` | Bước 2: quét, sinh / cập nhật bộ cài |
| `scripts/Test-ApiDeploy.ps1` | Bước 4 |
| `template/` | Engine được chép sang DeployPath. Sửa engine thì sửa ở đây, rồi chạy lại skill cho từng repo để cập nhật |
| `template/HUONG_DAN.template.md` | Mẫu hướng dẫn cho người triển khai. Token: `%%PROJECT%%`, `%%SERVICE_TABLE%%`, `%%DATA_DIR%%`, `%%RUNTIME%%`, `%%FIREWALL_PREFIX%%`, `%%FIREWALL_GROUP%%`, `%%PACKAGE_NAME%%`, `%%NOTES%%` |
| `references/manifest-schema.md` | Schema `deploy-manifest.json` và mẫu ApiSwitchFilter |
| `references/lessons.md` | Lỗi đã gặp, quy ước encoding, cách thử chéo mã hoá |

Bản gốc của engine nằm ở `H:\01. Project\07. HIS\API_Signer\Deploy` (giống `API\Deploy`). Các thay đổi so với bản gốc:
- Lấy tiêu đề, thư mục dữ liệu, firewall, tên zip và repoRoot từ manifest.
- Hỗ trợ nhiều kiểu mã hoá (`cryptoScheme`) và nhiều kênh runtime.
- `apiSwitch: false` và `healthPath` khai báo theo từng service.
- Kiểm tra môi trường đầy đủ hơn, thêm AppInit và preload.
- Xoá trắng giá trị bí mật trong gói build.
- Tự đổi font console sang Consolas để không lỗi font tiếng Việt.
