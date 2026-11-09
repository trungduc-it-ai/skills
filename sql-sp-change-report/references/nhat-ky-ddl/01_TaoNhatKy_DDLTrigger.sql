/* ============================================================
   TUY CHON - GHI CSDL: tu nay ve sau tu luu lich su moi lan CREATE/ALTER/DROP SP, ham, view, trigger
   - Bang dbo.DBA_NhatKySuaDoiTuong: thoi gian, login, may, phan mem, ten doi tuong, NGUYEN VAN cau lenh moi.
   - Muon biet "sua cai gi": so 2 dong nhat ky lien tiep cua cung doi tuong (xem 02_XemNhatKy_CHI_DOC.sql).
     scripts\BaoCaoSuaSP.ps1 tu doc bang nay neu co.
   - Trigger khong bao gio chan lenh ALTER: XACT_ABORT OFF + TRY/CATCH, loi ghi nhat ky thi bo qua.
   Chay may thu truoc, production sau. Go bo: 99_GoNhatKy.sql.   DucNT 05/11/2026
   ============================================================ */
USE TEN_CSDL;  -- doi TEN_CSDL thanh ten CSDL that
GO
IF OBJECT_ID(N'dbo.DBA_NhatKySuaDoiTuong', N'U') IS NULL
CREATE TABLE dbo.DBA_NhatKySuaDoiTuong (
    NhatKy_Id      bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DBA_NhatKySuaDoiTuong PRIMARY KEY,
    ThoiGian       datetime2(3)  NOT NULL CONSTRAINT DF_DBA_NhatKySuaDoiTuong_ThoiGian DEFAULT (SYSDATETIME()),
    LoaiSuKien     nvarchar(100) NULL,     -- ALTER_PROCEDURE, CREATE_FUNCTION...
    TenDoiTuong    nvarchar(300) NULL,     -- schema.ten
    LoginName      nvarchar(256) NULL,
    MayTram        nvarchar(256) NULL,
    PhanMem        nvarchar(256) NULL,
    CauLenh        nvarchar(max) NULL      -- nguyen van CREATE/ALTER (ban MOI)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DBA_NhatKySuaDoiTuong_Ten' AND object_id = OBJECT_ID(N'dbo.DBA_NhatKySuaDoiTuong'))
CREATE INDEX IX_DBA_NhatKySuaDoiTuong_Ten ON dbo.DBA_NhatKySuaDoiTuong (TenDoiTuong, ThoiGian);
GO
CREATE OR ALTER TRIGGER TR_DBA_NhatKySuaDoiTuong
ON DATABASE
FOR DDL_PROCEDURE_EVENTS, DDL_FUNCTION_EVENTS, DDL_VIEW_EVENTS, DDL_TRIGGER_EVENTS
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;   -- trong trigger mac dinh ON: loi ghi nhat ky se huy luon lenh ALTER
    BEGIN TRY
        DECLARE @e xml = EVENTDATA();
        INSERT dbo.DBA_NhatKySuaDoiTuong (LoaiSuKien, TenDoiTuong, LoginName, MayTram, PhanMem, CauLenh)
        VALUES (@e.value('(/EVENT_INSTANCE/EventType)[1]', 'nvarchar(100)'),
                @e.value('(/EVENT_INSTANCE/SchemaName)[1]', 'nvarchar(128)') + N'.' + @e.value('(/EVENT_INSTANCE/ObjectName)[1]', 'nvarchar(128)'),
                ORIGINAL_LOGIN(), HOST_NAME(), APP_NAME(),
                @e.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'nvarchar(max)'));
    END TRY
    BEGIN CATCH
        -- bo qua: khong de nhat ky lam hong viec deploy
    END CATCH
END;
GO
SELECT name, is_disabled, CONVERT(varchar(19), modify_date, 120) AS modify_date
FROM sys.triggers WHERE parent_class_desc = N'DATABASE' AND name = N'TR_DBA_NhatKySuaDoiTuong';
