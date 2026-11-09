/* CHI DOC - xem nhat ky sua SP (sau khi da chay 03) - DucNT 05/11/2026 */
USE TEN_CSDL;  -- doi TEN_CSDL thanh ten CSDL that
SET NOCOUNT ON;
DECLARE @Ten nvarchar(300) = N'dbo.sp_CLSYEUCAUCHITIET';

/* Cac lan sua */
SELECT NhatKy_Id, CONVERT(varchar(23), ThoiGian, 121) AS ThoiGian, LoaiSuKien, TenDoiTuong, LoginName, MayTram, PhanMem, LEN(CauLenh) AS do_dai
FROM dbo.DBA_NhatKySuaDoiTuong WHERE TenDoiTuong = @Ten ORDER BY NhatKy_Id DESC;

/* Lan sua moi nhat so voi lan truoc: dong them / dong bo */
DECLARE @moi nvarchar(max), @cu nvarchar(max);
SELECT TOP (1) @moi = CauLenh FROM dbo.DBA_NhatKySuaDoiTuong WHERE TenDoiTuong = @Ten ORDER BY NhatKy_Id DESC;
SELECT @cu = CauLenh FROM dbo.DBA_NhatKySuaDoiTuong WHERE TenDoiTuong = @Ten ORDER BY NhatKy_Id DESC OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY;

;WITH m AS (SELECT CAST(ordinal AS int) AS dong, value COLLATE Latin1_General_BIN2 AS nd FROM STRING_SPLIT(REPLACE(@moi, NCHAR(13), N''), NCHAR(10), 1)),
      c AS (SELECT CAST(ordinal AS int) AS dong, value COLLATE Latin1_General_BIN2 AS nd FROM STRING_SPLIT(REPLACE(ISNULL(@cu, N''), NCHAR(13), N''), NCHAR(10), 1)),
      mn AS (SELECT dong, nd, ROW_NUMBER() OVER (PARTITION BY nd ORDER BY dong) AS lan FROM m WHERE LTRIM(RTRIM(nd)) <> N''),
      cn AS (SELECT dong, nd, ROW_NUMBER() OVER (PARTITION BY nd ORDER BY dong) AS lan FROM c WHERE LTRIM(RTRIM(nd)) <> N'')
SELECT N'+ them' AS loai, mn.dong, mn.nd AS noi_dung FROM mn WHERE NOT EXISTS (SELECT 1 FROM cn WHERE cn.nd = mn.nd AND cn.lan = mn.lan)
UNION ALL
SELECT N'- bo', cn.dong, cn.nd FROM cn WHERE NOT EXISTS (SELECT 1 FROM mn WHERE mn.nd = cn.nd AND mn.lan = cn.lan)
ORDER BY loai, dong;
