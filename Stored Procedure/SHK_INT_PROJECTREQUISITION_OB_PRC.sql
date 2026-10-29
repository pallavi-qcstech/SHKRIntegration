USE [PMWeb]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/* 
SHK_INT_PROJECTREQUISITION_OB_PRC stages a PMWeb PreBid/estimate (header + line data) into the outbound staging tables and 
pushes it to SAP's Z_PR_CREATION_SRV OData service to create a real Project Requisition.

Change Log
23/10/26 - Pallavi M - New procedure
28/10/26 - Pallavi M - Account assignment validation: each line must be either WBS element only
                       or Network + Activity only (ACCTASSCAT always 'P'), else rejected (RETURN -8).
                       A line with both CostCode and WBSId follows the WBS.
28/10/26 - Pallavi M - WBSId = 0 means no WBS selected (PMWeb stores 0, not NULL), so it is
                       treated like NULL: the line takes the WBS element (CostCodes.Notes) path.
29/10/26 - Pallavi M - SAP PR number also written to dbo.Specifications ('Integration Reference',
                       template 45, EntityTypeId 244) so it shows on the PreBid screen.
*/

ALTER PROC [dbo].[SHK_INT_PROJECTREQUISITION_OB_PRC]
    @TRAN_ID BIGINT   -- dbo.Estimate_PreBids.Id
AS
BEGIN
    SET XACT_ABORT ON
    SET NOCOUNT ON

    DECLARE @ERROR_DESC VARCHAR(MAX) = '';
    DECLARE @hdr_record_id BIGINT = 0;
    DECLARE @URL NVARCHAR(500);
    DECLARE @MSG VARCHAR(MAX);
   
    DECLARE @API_STATUS VARCHAR(1);
    DECLARE @sap_pr_id VARCHAR(10);
    DECLARE @con_error VARCHAR(MAX);
    DECLARE @bad_acct_lines VARCHAR(MAX);

    DECLARE @txn_type VARCHAR(30) = 'PREBID';
    DECLARE @DocumentId BIGINT;
    DECLARE @CurrStepId BIGINT;
    DECLARE @PrevStepId BIGINT;

   
    DECLARE @ErrorNumber INT;
    DECLARE @ErrorProcedure NVARCHAR(200);
    DECLARE @ErrorLine INT;
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorDesc NVARCHAR(4000);

  
    DECLARE @BASE_URL NVARCHAR(200) = 'http://Shaker.pmweb.local:8080/SHKRIntegration/api/Outbound/projectrequisition';

    BEGIN TRY

        ------ Cleanup Previous Failed Staging Records --------------

        DELETE FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob
        WHERE record_id IN (
            SELECT h.record_id
            FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob h
            JOIN dbo.xx_projectrequisition_line_stg_tbl_ob l ON l.hdr_record_id = h.record_id
            WHERE l.prebid_id = @TRAN_ID
              AND h.process_status <> 'S'
        );

        DELETE FROM dbo.xx_projectrequisition_line_stg_tbl_ob
        WHERE prebid_id = @TRAN_ID
          AND hdr_record_id NOT IN (SELECT record_id FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob);

       ---- Get Workflow Information-----------

        SELECT @CurrStepId = wf_curr_step_id, @DocumentId = wf_document_id
        FROM dbo.xx_integration_tbl
        WHERE tran_id = @TRAN_ID
          AND tran_type = @txn_type;

        IF @DocumentId IS NOT NULL
        BEGIN
            SELECT @PrevStepId = ReturnToStepId
            FROM dbo.Workflow_DocumentSteps
            WHERE DocumentId = @DocumentId AND Id = @CurrStepId;

            IF @PrevStepId IS NULL
            BEGIN
                SELECT @PrevStepId = Id
                FROM dbo.Workflow_DocumentSteps
                WHERE DocumentId = @DocumentId AND StepNumber = 0;
            END
        END

     -------------------Validate Source Document -------------

        IF NOT EXISTS (SELECT 1 FROM dbo.Estimate_PreBids WHERE Id = @TRAN_ID)
        BEGIN
            SET @ERROR_DESC = 'No Estimate_PreBids row found for Id ' + CAST(@TRAN_ID AS VARCHAR(20)) + '.';

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message;
            RETURN -1;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Estimate_PreBidDetails WHERE PreBidId = @TRAN_ID)
        BEGIN
            SET @ERROR_DESC = 'Estimate_PreBids ' + CAST(@TRAN_ID AS VARCHAR(20)) + ' has no Estimate_PreBidDetails lines.';

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message;
            RETURN -2;
        END

        -----------  Stage Header Data -----------------------------------

        BEGIN TRY

      
        INSERT INTO dbo.xx_projectrequisition_hdr_stg_tbl_ob
            (sap_pr_id, doc_type, project, prebid_no, description,
             process_status, operation_flag, creation_date, last_update_date)
        SELECT
            NULL,                 
            pgm.SpecField5,       
            proj.ProjectName,
            pb.PreBidNumber,
            pb.Description,
            'N', 'I', GETDATE(), GETDATE()
        FROM dbo.Estimate_PreBids pb
        JOIN dbo.Projects proj ON proj.Id = pb.ProjectId
        JOIN dbo.Programs pgm ON pgm.Id = proj.ProgramId
        WHERE pb.Id = @TRAN_ID;

        IF @@ROWCOUNT = 0
        BEGIN
            SET @ERROR_DESC = 'Could not resolve Project/Program for Estimate_PreBids ' + CAST(@TRAN_ID AS VARCHAR(20)) + ' (FK chain broken).';

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message;
            RETURN -3;
        END

        --------- Stage Line Data -------------

        SET @hdr_record_id = SCOPE_IDENTITY();

        ---- Validation: a populated WBSId must be a terminal/leaf node in dbo.WBS (no children).
        ---- WBS is either left blank (plain WBS-element path,
        ---- handled separately via CostCodeId) or it must point at the Activity itself - selecting
        ---- a Network/WBS group node that still has a child underneath is not a valid PR target.
        IF EXISTS (
            SELECT 1
            FROM dbo.Estimate_PreBidDetails d
            WHERE d.PreBidId = @TRAN_ID
              AND NULLIF(d.WBSId, 0) IS NOT NULL
              AND EXISTS (SELECT 1 FROM dbo.WBS c WHERE c.ParentId = d.WBSId)
        )
        BEGIN
            DELETE FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob WHERE record_id = @hdr_record_id;

            SET @ERROR_DESC = 'PR can be created either at WBS level or at Activity level. Please select correct activity';

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message;
            RETURN -3;
        END

        ;WITH WbsCode AS (
            -- SAP code now is taken from Code directly per SHK_INT_SAPCOSTCODE_IB_PRC procedure
            SELECT w.Id, w.ParentId,
                ResolvedCode = w.Code
            FROM dbo.WBS w
        )
        INSERT INTO dbo.xx_projectrequisition_line_stg_tbl_ob
            (hdr_record_id, tracking_no, prebid_id, prebid_line_no, doc_type, short_text, material, mat_grp,
             plant, pur_group, quantity, uom, prebid_date, rel_date, deliv_date, item_cat,
             acctasscat, prebid_amount, price_unit, currency, prebid_no, serial_no,
             wbs_element, network, activity, proj_ext, gl_acct, co_area,
             process_status, operation_flag, creation_date, last_update_date)
        SELECT
            @hdr_record_id,
            pb.PreBidNumber,   
            pb.Id,             
            RIGHT('00000' + CAST(ROW_NUMBER() OVER (ORDER BY d.LineNumber) * 10 AS VARCHAR(5)), 5),
            pgm.SpecField5,
            LEFT(pb.Description, 40),
            '',
            pb.SpecField3,
            pgm.SpecField1,
            pgm.SpecField7,
            d.Quantity,
            LTRIM(RTRIM(LEFT(uom.UOM, CHARINDEX(' - ', uom.UOM + ' - ') - 1))),
            CONVERT(VARCHAR(10), pb.BidsDueDate, 104),
            CONVERT(VARCHAR(10), DATEADD(SECOND, CAST(pb.SpecField1 AS BIGINT) / 1000, '1970-01-01'), 104),
            CONVERT(VARCHAR(10), DATEADD(SECOND, CAST(pb.SpecField2 AS BIGINT) / 1000, '1970-01-01'), 104),
            '',
            'P',  -- acctasscat: always P per explicit even on the network+activity (WBSId-populated) path
            d.EstimatedTotal,
            '1',
            cur.Code,
            '',  -- prebid_no (PreqNo): left blank on create, SAP assigns it
            '01',
            --  a line with a WBSId is sent as Network + Activity only and its
            -- CostCodeId is ignored, even when both are filled. A line without a WBSId is sent as WBS
            -- element only (CostCodes.Notes).
            CASE WHEN NULLIF(d.WBSId, 0) IS NULL THEN wbsres.ResolvedWbsElement ELSE '' END,
            CASE WHEN NULLIF(d.WBSId, 0) IS NOT NULL THEN ISNULL(wbsnet.ResolvedNetwork, '') ELSE '' END,
            CASE WHEN NULLIF(d.WBSId, 0) IS NOT NULL THEN ISNULL(wbsnet.ResolvedActivity, '') ELSE '' END,
            '',
            pgm.SpecField6,
            '1000',
            'N', 'I', GETDATE(), GETDATE()
        FROM dbo.Estimate_PreBids pb
        JOIN dbo.Projects proj ON proj.Id = pb.ProjectId
        JOIN dbo.Programs pgm ON pgm.Id = proj.ProgramId
        JOIN dbo.Estimate_PreBidDetails d ON d.PreBidId = pb.Id
        LEFT JOIN dbo.Currencies cur ON cur.Id = d.CurrencyId
        LEFT JOIN dbo.UOM uom ON uom.Id = d.UOMId
        LEFT JOIN dbo.CostCodes cc ON cc.Id = d.CostCodeId
        CROSS APPLY (
            -- wbs_element comes straight from CostCodes.Notes.
            SELECT ISNULL(cc.Notes, '') AS ResolvedWbsElement
        ) wbsres
        OUTER APPLY (
            SELECT TOP 1 wc.Id, wc.ParentId, wc.ResolvedCode
            FROM WbsCode wc
            WHERE wc.Id = d.WBSId
        ) selfCode
        OUTER APPLY (
            SELECT
                IsNumeric = CASE WHEN selfCode.ResolvedCode NOT LIKE '%[^0-9]%' THEN 1 ELSE 0 END,
                CodeLen = LEN(selfCode.ResolvedCode)
        ) selfFlags
        OUTER APPLY (
            SELECT TOP 1 wc.ResolvedCode
            FROM WbsCode wc
            WHERE wc.Id = selfCode.ParentId
              AND selfFlags.IsNumeric = 1 AND selfFlags.CodeLen <> 12
        ) parentCode
        OUTER APPLY (
            SELECT TOP 1 wc.Id, wc.ResolvedCode
            FROM WbsCode wc
            WHERE wc.ParentId = selfCode.Id
              AND selfFlags.IsNumeric = 0
              AND wc.ResolvedCode NOT LIKE '%[^0-9]%'
              AND LEN(wc.ResolvedCode) = 12
        ) networkChild
        OUTER APPLY (
            SELECT TOP 1 wc.ResolvedCode
            FROM WbsCode wc
            WHERE wc.ParentId = COALESCE(
                      networkChild.Id,
                      CASE WHEN selfFlags.IsNumeric = 1 AND selfFlags.CodeLen = 12 THEN selfCode.Id END)
              AND wc.ResolvedCode NOT LIKE '%[^0-9]%'
        ) activityChild
        CROSS APPLY (
            SELECT
                ResolvedNetwork =
                    CASE
                        WHEN selfFlags.IsNumeric = 1 AND selfFlags.CodeLen = 12 THEN selfCode.ResolvedCode
                        WHEN selfFlags.IsNumeric = 1 AND selfFlags.CodeLen <> 12 THEN parentCode.ResolvedCode
                        WHEN selfFlags.IsNumeric = 0 AND networkChild.ResolvedCode IS NOT NULL THEN networkChild.ResolvedCode
                        ELSE NULL
                    END,
                ResolvedActivity =
                    CASE
                        WHEN selfFlags.IsNumeric = 1 AND selfFlags.CodeLen <> 12 THEN selfCode.ResolvedCode
                        WHEN selfFlags.IsNumeric = 1 AND selfFlags.CodeLen = 12 THEN activityChild.ResolvedCode
                        WHEN selfFlags.IsNumeric = 0 AND networkChild.ResolvedCode IS NOT NULL THEN activityChild.ResolvedCode
                        ELSE NULL
                    END
        ) wbsnet
        WHERE pb.Id = @TRAN_ID;

        IF @@ROWCOUNT = 0
        BEGIN
            DELETE FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob WHERE record_id = @hdr_record_id;

            SET @ERROR_DESC = 'No line rows staged for header ' + CAST(@TRAN_ID AS VARCHAR(20)) + ' (record_id=' + CAST(@hdr_record_id AS VARCHAR(20)) + ').';

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message;
            RETURN -4;
        END

        END TRY

        -----Exception Handling During Staging------

        BEGIN CATCH
            SET @ErrorNumber = ERROR_NUMBER();
            SET @ErrorProcedure = ERROR_PROCEDURE();
            SET @ErrorLine = ERROR_LINE();
            SET @ErrorMessage = ERROR_MESSAGE();
            SET @ErrorDesc = 'Exception while staging header/line data';
            SET @ERROR_DESC = @ErrorDesc + ': ' + @ErrorMessage;

            INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
            VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, CAST(@TRAN_ID AS VARCHAR(100)), GETDATE(), @ErrorDesc);

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message;
            RETURN -7;
        END CATCH


        ----------Mandatory Field Validation---------

        IF EXISTS (
            SELECT 1 FROM dbo.xx_projectrequisition_line_stg_tbl_ob
            WHERE hdr_record_id = @hdr_record_id
              AND (prebid_date IS NULL OR LTRIM(RTRIM(prebid_date)) = ''
                   OR rel_date IS NULL OR LTRIM(RTRIM(rel_date)) = ''
                   OR deliv_date IS NULL OR LTRIM(RTRIM(deliv_date)) = ''
                   OR mat_grp IS NULL OR LTRIM(RTRIM(mat_grp)) = ''
                   OR uom IS NULL OR LTRIM(RTRIM(uom)) = '')
        )
        BEGIN
            SET @ERROR_DESC = 'Bid due date, release date, delivery date, material group and UOM must not be blank.';

            UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
            SET process_status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE hdr_record_id = @hdr_record_id;

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message;
            RETURN -5;
        END

        ----------Account Assignment Validation---------
        ---- ACCTASSCAT is always 'P'. A line is valid in exactly one of two cases:
        ----   1) WBS element only       - WBSId blank, CostCodes.Notes has the SAP WBS element
        ----   2) Network + Activity only - WBSId is an Activity under a 12-digit Network
        ---- Anything else (all blank, Network without Activity, Activity without Network)
        ---- is rejected here before calling SAP.[TBC]

        SET @bad_acct_lines = STUFF((
            SELECT ', ' + ISNULL(l.prebid_line_no, '?') + ' (' +
                CASE
                    WHEN ISNULL(LTRIM(RTRIM(l.network)), '') <> '' AND ISNULL(LTRIM(RTRIM(l.activity)), '') = ''
                        THEN 'Network ' + LTRIM(RTRIM(l.network)) + ' has no Activity'
                    WHEN ISNULL(LTRIM(RTRIM(l.network)), '') = '' AND ISNULL(LTRIM(RTRIM(l.activity)), '') <> ''
                        THEN 'Activity ' + LTRIM(RTRIM(l.activity)) + ' is not under a Network'
                    WHEN ISNULL(LTRIM(RTRIM(l.wbs_element)), '') = ''
                        THEN 'no WBS element in Cost Code Notes and no valid Activity selected in WBS'
                    ELSE 'both WBS element and Network/Activity present'
                END + ')'
            FROM dbo.xx_projectrequisition_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id
              AND NOT (
                    (ISNULL(LTRIM(RTRIM(l.wbs_element)), '') <> ''
                     AND ISNULL(LTRIM(RTRIM(l.network)), '') = ''
                     AND ISNULL(LTRIM(RTRIM(l.activity)), '') = '')
                 OR (ISNULL(LTRIM(RTRIM(l.wbs_element)), '') = ''
                     AND ISNULL(LTRIM(RTRIM(l.network)), '') <> ''
                     AND ISNULL(LTRIM(RTRIM(l.activity)), '') <> '')
              )
            ORDER BY l.prebid_line_no
            FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '');

        IF @bad_acct_lines IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'Invalid account assignment on line(s): ' + @bad_acct_lines
                + '. Each line needs either a Cost Code whose Notes holds the SAP WBS element (WBS left blank),'
                + ' or a WBS selection that is an Activity under a Network.';

            UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE hdr_record_id = @hdr_record_id;

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message;
            RETURN -8;
        END

        --------Call Shaker API-----------------------

        SELECT @URL = CONCAT(@BASE_URL, '?recordId=', @hdr_record_id);

        EXEC dbo.SHK_INT_APICALL_PRC @URL = @URL, @MSG = @MSG OUTPUT;

        SELECT @API_STATUS = process_status, @sap_pr_id = sap_pr_id, @con_error = error_msg
        FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob
        WHERE record_id = @hdr_record_id;

        IF @API_STATUS = 'S' AND @sap_pr_id IS NOT NULL
        BEGIN
            UPDATE dbo.xx_integration_tbl
            SET status = 'S', error_msg = 'Project Requisition created successfully, SAP PR ' + @sap_pr_id, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            -- Write the SAP-assigned PR number (BANFN) back into the PMWeb source entity, header
            -- level only for now (line-level deferred as it is not sent back)
            UPDATE dbo.Estimate_PreBids
            SET SpecField4 = @sap_pr_id
            WHERE Id = @TRAN_ID;

            -- The PreBid screen shows 'Integration Reference' (template 45, field 4) from
            -- dbo.Specifications, not from SpecField4, so need to write it there
            IF EXISTS (SELECT 1 FROM dbo.Specifications
                       WHERE EntityTypeId = 244 AND EntityId = @TRAN_ID AND SpecificationTemplateId = 45)
                UPDATE dbo.Specifications
                SET Measure = @sap_pr_id
                WHERE EntityTypeId = 244 AND EntityId = @TRAN_ID AND SpecificationTemplateId = 45;
            ELSE
                INSERT INTO dbo.Specifications (EntityTypeId, EntityId, SpecificationTemplateId, Measure, Notes, ListItemId)
                VALUES (244, @TRAN_ID, 45, @sap_pr_id, '', -1);

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 7
                    ,@DeliveredToStepId = 0
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = 'Project Requisition created successfully'
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = 0;
                EXEC dbo.Workflow_UpdateWorkflowDocumentStatus @DocumentId = @DocumentId, @ActionTypeId = 7, @StepId = @CurrStepId, @UserId = 5, @ChangeLastAction = 0;
            END

            SELECT 'Project Requisition created successfully' AS Message, @sap_pr_id AS SapPrId, @hdr_record_id AS HdrRecordId;
        END
        ELSE
        BEGIN
         
            SET @ERROR_DESC = ISNULL(@con_error, 'Project Requisition API call did not return a success status.')
                + ' | Raw API response: ' + ISNULL(@MSG, '(empty)');

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message, @hdr_record_id AS HdrRecordId;
            RETURN -6;
        END

    END TRY
    BEGIN CATCH
        SET @ErrorNumber = ERROR_NUMBER();
        SET @ErrorProcedure = ERROR_PROCEDURE();
        SET @ErrorLine = ERROR_LINE();
        SET @ErrorMessage = ERROR_MESSAGE();
        SET @ErrorDesc = 'Unexpected exception in PR procedure';
        SET @ERROR_DESC = @ErrorDesc + ': ' + @ErrorMessage;

        INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
        VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, CAST(@TRAN_ID AS VARCHAR(100)), GETDATE(), @ErrorDesc);

        -- Re-read from staging: the error may have happened after SAP created the PR
        IF @hdr_record_id > 0
            SELECT @sap_pr_id = NULLIF(LTRIM(RTRIM(sap_pr_id)), '')
            FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob
            WHERE record_id = @hdr_record_id;

        IF @sap_pr_id IS NULL
        BEGIN
            -- No PR in SAP: same handling as the other errors, back to the submitter
            IF @hdr_record_id > 0
            BEGIN
                UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
                SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
                WHERE record_id = @hdr_record_id;

                UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
                SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
                WHERE hdr_record_id = @hdr_record_id;
            END

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            IF @DocumentId IS NOT NULL AND @PrevStepId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @ERROR_DESC
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = @PrevStepId;
                EXEC dbo.Workflow_RecalculateDueDate @DocumentId = @DocumentId;
            END

            SELECT @ERROR_DESC AS Message;
            RETURN -9;
        END

        -- PR already created in SAP: finish the success steps that the error interrupted
        -- (never send it back - a resubmit would create a second PR in SAP)
        BEGIN TRY
            UPDATE dbo.xx_integration_tbl
            SET status = 'S', error_msg = 'Project Requisition created successfully, SAP PR ' + @sap_pr_id
                + ' (completed after error: ' + @ErrorMessage + ')', last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            UPDATE dbo.Estimate_PreBids
            SET SpecField4 = @sap_pr_id
            WHERE Id = @TRAN_ID;

            IF EXISTS (SELECT 1 FROM dbo.Specifications
                       WHERE EntityTypeId = 244 AND EntityId = @TRAN_ID AND SpecificationTemplateId = 45)
                UPDATE dbo.Specifications
                SET Measure = @sap_pr_id
                WHERE EntityTypeId = 244 AND EntityId = @TRAN_ID AND SpecificationTemplateId = 45;
            ELSE
                INSERT INTO dbo.Specifications (EntityTypeId, EntityId, SpecificationTemplateId, Measure, Notes, ListItemId)
                VALUES (244, @TRAN_ID, 45, @sap_pr_id, '', -1);

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 7
                    ,@DeliveredToStepId = 0
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = 'Project Requisition created successfully'
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = 0;
                EXEC dbo.Workflow_UpdateWorkflowDocumentStatus @DocumentId = @DocumentId, @ActionTypeId = 7, @StepId = @CurrStepId, @UserId = 5, @ChangeLastAction = 0;
            END

            SELECT 'Project Requisition created successfully (completed after error: ' + @ErrorMessage + ')' AS Message,
                   @sap_pr_id AS SapPrId, @hdr_record_id AS HdrRecordId;
            RETURN -9;  -- same code for every unexpected error (user 29.10); the message tells the cases apart
        END TRY
        BEGIN CATCH
            -- Completion failed : Do NOT re-run this PreBid, it would create a second PR in SAP.
          
            SET @ErrorMessage = ERROR_MESSAGE();
            SET @ErrorDesc = 'PR ' + @sap_pr_id + ' created in SAP but completion failed - complete manually, do not re-send';

            INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
            VALUES (ERROR_NUMBER(), ERROR_PROCEDURE(), ERROR_LINE(), @ErrorMessage, CAST(@TRAN_ID AS VARCHAR(100)), GETDATE(), @ErrorDesc);

            -- status stays 'S' (the PR exists); the message shows it still needs completing
            UPDATE dbo.xx_integration_tbl
            SET error_msg = @ErrorDesc + ': ' + @ErrorMessage, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            SELECT @ErrorDesc + ': ' + @ErrorMessage AS Message, @sap_pr_id AS SapPrId, @hdr_record_id AS HdrRecordId;
            RETURN -9;
        END CATCH
    END CATCH

    SET NOCOUNT OFF
END
GO
