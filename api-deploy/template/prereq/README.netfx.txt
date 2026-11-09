Bộ cài này chỉ có service ASP.NET trên .NET Framework (runtime "netfx" trong deploy-manifest.json):
KHÔNG cần ASP.NET Core Hosting Bundle, thư mục này để trống.

Môi trường cần có trên máy chủ:
    - IIS kèm ASP.NET 4.x (Windows feature Web-Asp-Net45 trên Windows Server, IIS-ASPNET45 trên Windows 10/11).
      Trong Deploy.bat chọn K: công cụ tự bật các feature này (không cần internet, dùng nguồn cài của Windows).
    - .NET Framework đúng phiên bản service cần (netFramework trong deploy-manifest.json) trở lên.
      Windows Server 2016 có sẵn 4.6.2, Windows Server 2019 có sẵn 4.7.2. Máy cũ hơn: cài .NET Framework 4.8
      từ https://dotnet.microsoft.com/download/dotnet-framework rồi khởi động lại máy.
