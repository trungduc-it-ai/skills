/* CHI DOC - SP bi sua luc nao, ai sua - DucNT 05/11/2026
   Doi @Ten / @SoNgay roi chay. Phan 2 can quyen ALTER TRACE (sysadmin); khong co quyen thi chi in canh bao. */
USE TEN_CSDL;  -- doi TEN_CSDL thanh ten CSDL that
SET NOCOUNT ON;
DECLARE @Ten sysname = N'sp_CLSYEUCAUCHITIET';   -- N'%' = moi doi tuong
DECLARE @SoNgay int = 7;

/* 1. Doi tuong sua trong @SoNgay ngay gan day (modify_date = lan sua CUOI, khong co lich su) */
SELECT o.name, o.type_desc,
       CONVERT(varchar(23), o.create_date, 121) AS create_date,
       CONVERT(varchar(23), o.modify_date, 121) AS modify_date,
       CHECKSUM(OBJECT_DEFINITION(o.object_id)) AS checksum_def,
       LEN(OBJECT_DEFINITION(o.object_id)) AS do_dai
FROM sys.objects o
WHERE o.type IN ('P', 'FN', 'IF', 'TF', 'V', 'TR')
  AND o.modify_date >= DATEADD(DAY, -@SoNgay, GETDATE())
  AND o.name LIKE @Ten
ORDER BY o.modify_date DESC;

/* 2. Default trace: ai (login, may, phan mem) tao/sua/xoa doi tuong.
      Chi giu ~5 file x 20 MB gan nhat -> may ban thi chi con vai gio/vai ngay. */
SELECT CAST(value_in_use AS int) AS default_trace_bat FROM sys.configurations WHERE name = N'default trace enabled';

DECLARE @path nvarchar(260);
SELECT @path = REVERSE(SUBSTRING(REVERSE([path]), CHARINDEX(N'\', REVERSE([path])), 260)) + N'log.trc'
FROM sys.traces WHERE is_default = 1;

BEGIN TRY
    SELECT CONVERT(varchar(23), t.StartTime, 121) AS thoi_gian,
           te.name AS su_kien, t.DatabaseName, t.ObjectName,
           t.LoginName, t.NTDomainName + N'\' + t.NTUserName AS windows_user,
           t.HostName AS may, t.ApplicationName AS phan_mem, t.SPID
    FROM sys.fn_trace_gettable(@path, DEFAULT) t
    JOIN sys.trace_events te ON te.trace_event_id = t.EventClass
    WHERE t.EventClass IN (46, 47, 164)          -- Object:Created / Object:Deleted / Object:Altered
      AND t.EventSubClass = 0                    -- 0 = Begin (bo dong Commit trung)
      AND t.DatabaseName = DB_NAME()
      AND t.ObjectName LIKE @Ten
    ORDER BY t.StartTime DESC;

    SELECT MIN(StartTime) AS trace_giu_tu_luc FROM sys.fn_trace_gettable(@path, DEFAULT);
END TRY
BEGIN CATCH
    PRINT N'Khong doc duoc default trace: ' + ERROR_MESSAGE();
END CATCH;
