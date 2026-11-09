Thư mục chứa bộ cài ASP.NET Core Hosting Bundle (runtime + module IIS).

Máy chủ CÓ internet:
    Không cần làm gì. Trong Deploy.bat chọn K: công cụ tự tải bản mới nhất của kênh runtime
    (defaults.aspNetCoreRuntime trong deploy-manifest.json) từ Microsoft vào thư mục này,
    kiểm tra SHA512 + chữ ký số rồi cài.

Máy chủ KHÔNG có internet:
    Trên máy có internet, tải "ASP.NET Core Runtime <kênh> - Hosting Bundle" tại
        https://dotnet.microsoft.com/download/dotnet/<kênh>
    (file dạng dotnet-hosting-<phiên bản>-win.exe), bỏ vào thư mục này, rồi chọn K trong Deploy.bat.
    Hoặc build gói bằng: Build-Package.bat -All -Zip -IncludePrereq (công cụ tự tải vào đây).

Không cần runtime nếu build gói dạng self-contained (Build-Package -SelfContained),
khi đó chỉ cần module IIS (có trong Hosting Bundle bất kỳ phiên bản nào).