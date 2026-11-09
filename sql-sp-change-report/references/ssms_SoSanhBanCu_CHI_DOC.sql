/* CHI DOC - so 1 SP voi ban o CSDL khac tren cung may (ban sao luu) -> dong them / dong bo - DucNT 05/11/2026
   Can SQL Server 2022 (STRING_SPLIT ... enable_ordinal). Doi @Ten / @DbCu roi chay.
   Ban cu co the lay tu: CSDL sao luu cung may (vd TEN_CSDL_old, TEN_CSDL_ddMMyyyy),
   hoac dan file Documents\Backup_SP_TruocKhiDeploy_*\*.sql vao @cu (bo comment dong SET @cu = ... ben duoi). */
USE TEN_CSDL;  -- doi TEN_CSDL thanh ten CSDL that
SET NOCOUNT ON;
DECLARE @Ten sysname = N'sp_CLSYEUCAUCHITIET';
DECLARE @DbCu sysname = N'TEN_CSDL_old';

DECLARE @moi nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @Ten));
DECLARE @cu nvarchar(max), @md_cu datetime, @exec nvarchar(400) = QUOTENAME(@DbCu) + N'.sys.sp_executesql';
DECLARE @TenDayDu nvarchar(300) = N'dbo.' + @Ten;
EXEC @exec N'SELECT @cu = OBJECT_DEFINITION(o.object_id), @md = o.modify_date FROM sys.objects o WHERE o.object_id = OBJECT_ID(@t)',
     N'@t nvarchar(300), @cu nvarchar(max) OUTPUT, @md datetime OUTPUT',
     @t = @TenDayDu, @cu = @cu OUTPUT, @md = @md_cu OUTPUT;
-- SET @cu = N'<dan nguyen van ban cu vao day>';

SELECT @Ten AS ten,
       CONVERT(varchar(23), (SELECT modify_date FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.' + @Ten)), 121) AS modify_hien_tai,
       CONVERT(varchar(23), @md_cu, 121) AS modify_ban_cu,
       CHECKSUM(@moi) AS checksum_hien_tai, CHECKSUM(@cu) AS checksum_ban_cu,
       CASE WHEN @moi = @cu COLLATE Latin1_General_BIN2 THEN N'GIONG HET' ELSE N'KHAC' END AS ket_qua;

/* Dong co o ban nay ma khong co o ban kia (so theo noi dung dong, khong theo vi tri -> them/bot dong khong lam lech) */
;WITH m AS (SELECT CAST(ordinal AS int) AS dong, value COLLATE Latin1_General_BIN2 AS nd
            FROM STRING_SPLIT(REPLACE(@moi, NCHAR(13), N''), NCHAR(10), 1)),
      c AS (SELECT CAST(ordinal AS int) AS dong, value COLLATE Latin1_General_BIN2 AS nd
            FROM STRING_SPLIT(REPLACE(ISNULL(@cu, N''), NCHAR(13), N''), NCHAR(10), 1)),
      mn AS (SELECT dong, nd, ROW_NUMBER() OVER (PARTITION BY nd ORDER BY dong) AS lan FROM m WHERE LTRIM(RTRIM(nd)) <> N''),
      cn AS (SELECT dong, nd, ROW_NUMBER() OVER (PARTITION BY nd ORDER BY dong) AS lan FROM c WHERE LTRIM(RTRIM(nd)) <> N'')
SELECT N'+ them (ban hien tai)' AS loai, mn.dong, mn.nd AS noi_dung
FROM mn WHERE NOT EXISTS (SELECT 1 FROM cn WHERE cn.nd = mn.nd AND cn.lan = mn.lan)
UNION ALL
SELECT N'- bo (ban cu)', cn.dong, cn.nd
FROM cn WHERE NOT EXISTS (SELECT 1 FROM mn WHERE mn.nd = cn.nd AND mn.lan = cn.lan)
ORDER BY loai, dong;
