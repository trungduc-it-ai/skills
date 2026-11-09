/* Go bo nhat ky sua SP (dao nguoc 03). Bang nhat ky GIU LAI; muon xoa bang thi bo comment dong cuoi. DucNT 05/11/2026 */
USE TEN_CSDL;  -- doi TEN_CSDL thanh ten CSDL that
GO
IF EXISTS (SELECT 1 FROM sys.triggers WHERE parent_class_desc = N'DATABASE' AND name = N'TR_DBA_NhatKySuaDoiTuong')
    DROP TRIGGER TR_DBA_NhatKySuaDoiTuong ON DATABASE;
GO
-- DROP TABLE IF EXISTS dbo.DBA_NhatKySuaDoiTuong;
