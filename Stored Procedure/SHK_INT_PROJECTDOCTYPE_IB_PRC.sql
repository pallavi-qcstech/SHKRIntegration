USE [PMWeb]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROC [dbo].[SHK_INT_PROJECTDOCTYPE_IB_PRC]
AS
/*
Dedicated procedure for PR/PO Document Type (dbo.Specifications templates 47 = PR Document Type,
48 = PO Document Type, EntityTypeId = 1 (Projects)). Reads dbo.xx_project_doctype_stg_tbl_ib - one
row per project - and writes/updates dbo.Specifications.

Only processes rows with process_status IN ('N','E') - re-running this procedure does not reprocess
rows already marked 'S'. A row whose project_code can't be resolved to an active PMWeb project is
marked 'E' with an explanatory error_msg and skipped, same as the other 2 staging tables' convention.

Change Log
05/11/26 - New procedure (SAP hierarchySet PRDocType/PODocType -> Specifications templates 47/48)
06/11/26 - Redesigned to read the new dedicated dbo.xx_project_doctype_stg_tbl_ib (one row per
           project) . Added process_status gating (N/E processed, S skipped) to match the other 2 staging tables.
*/

SET NOCOUNT ON
SET XACT_ABORT ON

DECLARE @ERROR_DESC VARCHAR(MAX) = ''
DECLARE @systemdate DATETIME = GETDATE()

DECLARE @record_id BIGINT
DECLARE @project_code VARCHAR(150)
DECLARE @project_id BIGINT
DECLARE @pr_doc_type VARCHAR(10)
DECLARE @po_doc_type VARCHAR(10)
DECLARE @existing_spec_id BIGINT

DECLARE @ErrorNumber BIGINT
DECLARE @ErrorProcedure NVARCHAR(200)
DECLARE @ErrorLine INT
DECLARE @ErrorMessage NVARCHAR(4000)

BEGIN TRY

UPDATE a
SET a.project_id = p.Id
FROM dbo.xx_project_doctype_stg_tbl_ib a
JOIN dbo.Projects p
  ON REPLACE(p.ProjectNumber, '-', '') = REPLACE(a.project_code, '-', '')
 AND p.IsActive = 1
WHERE a.process_status IN ('N', 'E')

UPDATE a
SET a.process_status = 'E',
    a.error_msg = 'No active project exists in PMWeb for this project_code',
    a.last_update_date = @systemdate
FROM dbo.xx_project_doctype_stg_tbl_ib a
WHERE a.process_status IN ('N', 'E')
  AND a.project_id IS NULL

DECLARE doctype_cursor CURSOR FOR
SELECT record_id, project_code, project_id, pr_doc_type, po_doc_type
FROM dbo.xx_project_doctype_stg_tbl_ib
WHERE process_status IN ('N', 'E') AND project_id IS NOT NULL

OPEN doctype_cursor
FETCH NEXT FROM doctype_cursor INTO @record_id, @project_code, @project_id, @pr_doc_type, @po_doc_type

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        -- Template 47: PR Document Type
        SELECT TOP 1 @existing_spec_id = Id
        FROM dbo.Specifications
        WHERE EntityTypeId = 1 AND SpecificationTemplateId = 47 AND EntityId = @project_id
        ORDER BY Id DESC

        IF @existing_spec_id IS NOT NULL
            UPDATE dbo.Specifications SET Measure = @pr_doc_type WHERE Id = @existing_spec_id
        ELSE
            INSERT INTO dbo.Specifications (EntityTypeId, EntityId, SpecificationTemplateId, Measure)
            VALUES (1, @project_id, 47, @pr_doc_type)

        SET @existing_spec_id = NULL

        -- Template 48: PO Document Type
        SELECT TOP 1 @existing_spec_id = Id
        FROM dbo.Specifications
        WHERE EntityTypeId = 1 AND SpecificationTemplateId = 48 AND EntityId = @project_id
        ORDER BY Id DESC

        IF @existing_spec_id IS NOT NULL
            UPDATE dbo.Specifications SET Measure = @po_doc_type WHERE Id = @existing_spec_id
        ELSE
            INSERT INTO dbo.Specifications (EntityTypeId, EntityId, SpecificationTemplateId, Measure)
            VALUES (1, @project_id, 48, @po_doc_type)

        SET @existing_spec_id = NULL

        UPDATE dbo.xx_project_doctype_stg_tbl_ib
        SET process_status = 'S', error_msg = NULL, last_update_date = @systemdate
        WHERE record_id = @record_id
    END TRY
    BEGIN CATCH
        SET @ErrorNumber = ERROR_NUMBER()
        SET @ErrorProcedure = ERROR_PROCEDURE()
        SET @ErrorLine = ERROR_LINE()
        SET @ErrorMessage = ERROR_MESSAGE()

        UPDATE dbo.xx_project_doctype_stg_tbl_ib
        SET process_status = 'E', error_msg = @ErrorMessage, last_update_date = @systemdate
        WHERE record_id = @record_id

        INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
        VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, @project_id, @systemdate,
                'Exception in SHK_INT_PROJECTDOCTYPE_IB_PRC for project_code ' + @project_code)
    END CATCH

    FETCH NEXT FROM doctype_cursor INTO @record_id, @project_code, @project_id, @pr_doc_type, @po_doc_type
END

CLOSE doctype_cursor
DEALLOCATE doctype_cursor

END TRY
BEGIN CATCH
    IF CURSOR_STATUS('global', 'doctype_cursor') >= -1
    BEGIN
        CLOSE doctype_cursor
        DEALLOCATE doctype_cursor
    END

    SET @ErrorNumber = ERROR_NUMBER()
    SET @ErrorProcedure = ERROR_PROCEDURE()
    SET @ErrorLine = ERROR_LINE()
    SET @ErrorMessage = ERROR_MESSAGE()

    INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
    VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, NULL, @systemdate,
            'Exception in SHK_INT_PROJECTDOCTYPE_IB_PRC')

    SELECT @ErrorMessage AS Message
END CATCH

SET NOCOUNT OFF
GO
