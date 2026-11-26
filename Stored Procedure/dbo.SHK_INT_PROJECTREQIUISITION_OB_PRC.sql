USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_PROJECTREQUISITION_OB_PRC]    Script Date: 11/26/2026 8:55:00 AM ******/
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
                       or Network + Activity only (ACCTASSCAT always 'P'), else rejected .
                       A line with both CostCode and WBSId follows the WBS.
28/10/26 - Pallavi M - WBSId = 0 means no WBS selected , so the line takes the WBS element (CostCodes.Notes) path.
29/10/26 - Pallavi M - SAP PR number also written to dbo.Specifications ('Integration Reference',
                       template 45, EntityTypeId 244) so it shows on the PreBid screen.
02/11/26 - Pallavi M - Line-level Estimate_PreBidDetails.MfrNumber write-back added the item number
                       from SAP's PR response payload ,so PO can later link a Commitment line back
                       to its PR line.
03/11/26 - Pallavi M - doc_type (BSART on the header, DOC_TYPE on every line) is read from the
                       project's "PR Document Type" field (dbo.Specifications, EntityTypeId 1 =
                       Projects, SpecificationTemplateId 47), not Programs.SpecField5.
                       (SAP sends the value to PMWeb through the Project API).
16/11/26 - Pallavi M - On success the workflow is no longer completed here: the queue row is set to
                       'P' (Pending SAP approval) and SHK_INT_APPROVE_PR_IB_PRC completes or returns it.
                       Only this run's queue row is updated. A PreBid whose PR is pending approval is
                       not sent again and its workflow is not returned.
19/11/26 - Pallavi M - The 'P' row also gets erp_txn_number = SAP PR number, so that
                       SHK_INT_APPROVE_PR_IB_PRC picks it up.
19/11/26 - Pallavi M - Line SHORT_TEXT now comes from the line description (Estimate_PreBidDetails.Description)
                       instead of the header (Estimate_PreBids.Description), cut to SAP's 40 characters.
                       The header staging description is not changed. A line with a blank description
                       stops the PR before SAP is called .
24/11/26 - Pallavi M - Service PR: every PR line is sent as a service item (ITEM_CAT 9), following the
                       payloads "Single line Single Item" / "Pr Multiline + service".
                       Item quantity 1 and no PRICE_UNIT. Per line n: PCKG_NO 2n-1 (outline, LINE_NO 2n-1,
                       SUBPCKG_NO 2n) and service package 2n (LINE_NO 2n): SHORT_TEXT = line description
                       (40), QUANTITY 1, BASE_UOM = line UOM, GR_PRICE = EstimatedUnitCost,
                       MATL_GROUP = PreBid SpecField3. SRVACCSet: SernoLine 01, Percentage 100, Quantity 1.
                       A line with unit cost 0 or blank stops the PR before SAP is called.
                       Service PRs are on Network + Activity only: a line on the WBS element path
                       (CostCodes.Notes, no WBS selected) stops the PR before SAP is called.
                       Project PR values kept in comments (Project PR:) until clarified.
26/11/26 - Pallavi M - Quantity = line quantity (Estimate_PreBidDetails.Quantity) with the decimals cut off,
                       the same on the item (PRHEADERSet), the service line (ZSRVSet) and SRVACCSet
                       (was 1). A line with quantity blank or less than 1 stops the PR before SAP is called.
                       C_AMT_BAPI stays EstimatedTotal.
                       SerialNo (ACCOUNTSet and SRVACCSet) and SRVACCSet SernoLine = one number per GL account
                       in the PR: 01 for the GL account of the first line, +1 for each next GL account.
                       A blank GL account (Programs.SpecField6) stops the PR before SAP is called.
                     
*/

CREATE PROC [dbo].[SHK_INT_PROJECTREQUISITION_OB_PRC]
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
    DECLARE @blank_text_lines VARCHAR(MAX);   -- 19/11/26 lines without a description (SHORT_TEXT)
    DECLARE @no_price_lines VARCHAR(MAX);     -- 24/11/26 service lines without a unit cost (GR_PRICE)
    DECLARE @wbs_srv_lines VARCHAR(MAX);      -- 24/11/26 service lines on the WBS element path (not Network + Activity)
    DECLARE @no_qty_lines VARCHAR(MAX);       -- 26/11/26 lines with quantity blank or less than 1
    DECLARE @blank_gl_lines VARCHAR(MAX);     -- 26/11/26 lines without a GL account
    DECLARE @pr_doc_type NVARCHAR(200);
    DECLARE @bad_doc_type BIT;
    DECLARE @existing_pr NVARCHAR(100);

    DECLARE @txn_type VARCHAR(30) = 'PREBID';
    DECLARE @DocumentId BIGINT;
    DECLARE @CurrStepId BIGINT;
    DECLARE @PrevStepId BIGINT;
    DECLARE @queue_record_id INT;

   
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
              -- keep a header that holds a SAP PR number: it is what the duplicate guard reads
              AND NULLIF(LTRIM(RTRIM(h.sap_pr_id)), '') IS NULL
        );

        DELETE FROM dbo.xx_projectrequisition_line_stg_tbl_ob
        WHERE prebid_id = @TRAN_ID
          AND hdr_record_id NOT IN (SELECT record_id FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob);

       ---- Get Workflow Information-----------

        ---- Only this run's own queue row (N/I, the latest one) is read and updated here.
        SELECT TOP 1 @queue_record_id = record_id, @CurrStepId = wf_curr_step_id, @DocumentId = wf_document_id
        FROM dbo.xx_integration_tbl
        WHERE tran_id = @TRAN_ID
          AND tran_type = @txn_type
          AND status IN ('N', 'I')
        ORDER BY record_id DESC;

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
            WHERE record_id = @queue_record_id;

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

        ----------Duplicate Guard---------
        ---- Z_PR_CREATION_SRV has no duplicate protection: sending this PreBid again would create a
        ---- second PR in SAP. Rejected before anything is staged.

        SELECT @existing_pr = NULLIF(LTRIM(RTRIM(SpecField4)), '')
        FROM dbo.Estimate_PreBids
        WHERE Id = @TRAN_ID;

        IF @existing_pr IS NULL
            SELECT TOP 1 @existing_pr = LTRIM(RTRIM(h.sap_pr_id))
            FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob h
            WHERE NULLIF(LTRIM(RTRIM(h.sap_pr_id)), '') IS NOT NULL
              AND EXISTS (SELECT 1 FROM dbo.xx_projectrequisition_line_stg_tbl_ob l
                          WHERE l.hdr_record_id = h.record_id AND l.prebid_id = @TRAN_ID)
            ORDER BY h.record_id DESC;

        ---- PR pending SAP approval: not sent again and the workflow is left where it is.
        ---- Only this run's queue row is closed.
        IF @existing_pr IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.xx_integration_tbl
                       WHERE tran_id = @TRAN_ID AND tran_type = @txn_type AND status = 'P')
        BEGIN
            SET @ERROR_DESC = 'SAP PR ' + @existing_pr + ' already created for this PreBid and is Pending SAP approval - not sent again.';

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

            SELECT @ERROR_DESC AS Message;
            RETURN -1;
        END

        IF @existing_pr IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'SAP PR ' + @existing_pr + ' already created for this PreBid - not sent again.';

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

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

        -- PR Document Type from the PreBid's project: dbo.SpecificationsTemplate 47
        -- 'PR Document Type' (EntityTypeId 1 = Projects). Checked after staging, before the
        -- other mandatory fields.
        SELECT TOP 1 @pr_doc_type = LTRIM(RTRIM(CAST(s.Measure AS NVARCHAR(200))))
        FROM dbo.Estimate_PreBids pb
        JOIN dbo.Specifications s
          ON s.EntityTypeId = 1
         AND s.SpecificationTemplateId = 47
         AND s.EntityId = pb.ProjectId
        WHERE pb.Id = @TRAN_ID
        ORDER BY s.Id DESC;

        -----------  Stage Header Data -----------------------------------

        BEGIN TRY

      
        INSERT INTO dbo.xx_projectrequisition_hdr_stg_tbl_ob
            (sap_pr_id, doc_type, project, prebid_no, description,
             process_status, operation_flag, creation_date, last_update_date)
        SELECT
            NULL,
            NULLIF(@pr_doc_type, ''),   -- doc_type (BSART): project's PR Document Type; NULL when blank
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
            WHERE record_id = @queue_record_id;

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
            WHERE record_id = @queue_record_id;

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

        ;WITH WbsCode AS (
            -- SAP code now is taken from Code directly per SHK_INT_SAPCOSTCODE_IB_PRC procedure
            SELECT w.Id, w.ParentId,
                ResolvedCode = w.Code
            FROM dbo.WBS w
        )
        INSERT INTO dbo.xx_projectrequisition_line_stg_tbl_ob
            (hdr_record_id, tracking_no, prebid_id, prebid_detail_id, prebid_line_no, doc_type, short_text, material, mat_grp,
             plant, pur_group, quantity, uom, prebid_date, rel_date, deliv_date, item_cat,
             acctasscat, prebid_amount, price_unit, currency, prebid_no, serial_no,
             wbs_element, network, activity, proj_ext, gl_acct, co_area,
             pckg_no, outline_line_no, subpckg_no, srv_line_no, srv_short_text, srv_quantity,   -- 24/11/26 service PR
             srv_uom, srv_gr_price, srv_matl_group, srvacc_serno_line, srvacc_percentage, srvacc_quantity,
             process_status, operation_flag, creation_date, last_update_date)
        SELECT
            @hdr_record_id,
            pb.PreBidNumber,
            pb.Id,
            d.Id,              -- prebid_detail_id: the exact line this row is staged from (for the MfrNumber write-back)
            RIGHT('00000' + CAST(ROW_NUMBER() OVER (ORDER BY d.LineNumber) * 10 AS VARCHAR(5)), 5),
            NULLIF(@pr_doc_type, ''),   -- doc_type (DOC_TYPE): same value as the header
            LEFT(ISNULL(d.Description, ''), 40),   -- short_text: line description, SAP SHORT_TEXT max 40 (19/11/26)
            '',
            pb.SpecField3,
            pgm.SpecField1,
            pgm.SpecField7,
            ROUND(d.Quantity, 0, 1),   ---26/11/26 item QUANTITY = line quantity, decimals cut off (was 1)
            LTRIM(RTRIM(LEFT(uom.UOM, CHARINDEX(' - ', uom.UOM + ' - ') - 1))),
            CONVERT(VARCHAR(10), pb.BidsDueDate, 104),
            CONVERT(VARCHAR(10), DATEADD(SECOND, CAST(pb.SpecField1 AS BIGINT) / 1000, '1970-01-01'), 104),
            CONVERT(VARCHAR(10), DATEADD(SECOND, CAST(pb.SpecField2 AS BIGINT) / 1000, '1970-01-01'), 104),
            '9',  ---24/11/26 service PR: ITEM_CAT 9.  ---24/11/26 Project PR: '',
            'P',  -- acctasscat: always P per explicit even on the network+activity (WBSId-populated) path
            d.EstimatedTotal,
            NULL, ---24/11/26 service PR: PRICE_UNIT not sent (not in the samples).  ---24/11/26 Project PR: '1',
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
            ---24/11/26 service PR: line n -> outline package 2n-1 (LINE_NO 2n-1, SUBPCKG_NO 2n), service package 2n (LINE_NO 2n)
            CAST(ROW_NUMBER() OVER (ORDER BY d.LineNumber) * 2 - 1 AS VARCHAR(10)),   -- pckg_no
            CAST(ROW_NUMBER() OVER (ORDER BY d.LineNumber) * 2 - 1 AS VARCHAR(10)),   -- outline_line_no
            CAST(ROW_NUMBER() OVER (ORDER BY d.LineNumber) * 2 AS VARCHAR(10)),       -- subpckg_no
            CAST(ROW_NUMBER() OVER (ORDER BY d.LineNumber) * 2 AS VARCHAR(10)),       -- srv_line_no
            LEFT(ISNULL(d.Description, ''), 40),                                      -- srv_short_text: same as the item text
            ROUND(d.Quantity, 0, 1),                                                  -- srv_quantity: line quantity, decimals cut off (26/11/26)
            LTRIM(RTRIM(LEFT(uom.UOM, CHARINDEX(' - ', uom.UOM + ' - ') - 1))),       -- srv_uom: same as the item UNIT
            d.EstimatedUnitCost,                                                      -- srv_gr_price: price per unit
            pb.SpecField3,                                                            -- srv_matl_group: same as MAT_GRP
            '01',                                                                     -- srvacc_serno_line: set per GL account below (26/11/26)
            100,                                                                      -- srvacc_percentage
            ROUND(d.Quantity, 0, 1),                                                  -- srvacc_quantity: line quantity, decimals cut off (26/11/26)
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
            WHERE record_id = @queue_record_id;

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

        ---26/11/26 SerialNo (ACCOUNTSet and SRVACCSet) and SRVACCSet SernoLine: one number per GL account
        ---in the PR, 01 for the GL account of the first line, +1 for each next different GL account.
        ;WITH gl_first AS (
            SELECT ISNULL(LTRIM(RTRIM(gl_acct)), '') AS gl_key, MIN(prebid_line_no) AS first_item
            FROM dbo.xx_projectrequisition_line_stg_tbl_ob
            WHERE hdr_record_id = @hdr_record_id
            GROUP BY ISNULL(LTRIM(RTRIM(gl_acct)), '')
        ), gl_serial AS (
            SELECT gl_key, RIGHT('0' + CAST(ROW_NUMBER() OVER (ORDER BY first_item) AS VARCHAR(2)), 2) AS serial
            FROM gl_first
        )
        UPDATE l
        SET serial_no = s.serial, srvacc_serno_line = s.serial
        FROM dbo.xx_projectrequisition_line_stg_tbl_ob l
        JOIN gl_serial s ON s.gl_key = ISNULL(LTRIM(RTRIM(l.gl_acct)), '')
        WHERE l.hdr_record_id = @hdr_record_id;

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
            WHERE record_id = @queue_record_id;

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
        END CATCH


        ----------PR Document Type Validation---------
      
        SELECT @bad_doc_type = CASE WHEN doc_type IS NULL OR LTRIM(RTRIM(doc_type)) = '' THEN 1 ELSE 0 END
        FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob
        WHERE record_id = @hdr_record_id;

        IF @bad_doc_type = 1
        BEGIN
            SET @ERROR_DESC = 'PR Document Type is not set on the project (Project > PR Document Type, e.g. Z015).';

            UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
            SET process_status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE hdr_record_id = @hdr_record_id;

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

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
            WHERE record_id = @queue_record_id;

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

        ----------Line description (SHORT_TEXT) Validation---------  19/11/26
        ---- Every line needs a description; it is sent to SAP as SHORT_TEXT (first 40 characters).

        SET @blank_text_lines = STUFF((
            SELECT ', ' + ISNULL(l.prebid_line_no, '?')
            FROM dbo.xx_projectrequisition_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id
              AND ISNULL(LTRIM(RTRIM(l.short_text)), '') = ''
            ORDER BY l.prebid_line_no
            FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '');

        IF @blank_text_lines IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'Item description is blank on line(s): ' + @blank_text_lines
                + '. Each PR line needs a description (sent to SAP as short text, max 40 characters).';

            UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE hdr_record_id = @hdr_record_id;

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

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

        ----------Service line unit cost (GR_PRICE) Validation---------  24/11/26
        ---- Every service line needs a unit cost; it is sent to SAP as GR_PRICE (price per unit).

        SET @no_price_lines = STUFF((
            SELECT ', ' + ISNULL(l.prebid_line_no, '?')
            FROM dbo.xx_projectrequisition_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id
              AND l.item_cat = '9'
              AND ISNULL(l.srv_gr_price, 0) = 0
            ORDER BY l.prebid_line_no
            FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '');

        IF @no_price_lines IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'Unit cost is blank or 0 on line(s): ' + @no_price_lines
                + '. Each service PR line needs a unit cost (sent to SAP as the service price).';

            UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE hdr_record_id = @hdr_record_id;

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

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

        ----------Line quantity Validation---------  26/11/26

        SET @no_qty_lines = STUFF((
            SELECT ', ' + ISNULL(l.prebid_line_no, '?')
            FROM dbo.xx_projectrequisition_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id
              AND ISNULL(l.quantity, 0) < 1
            ORDER BY l.prebid_line_no
            FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '');

        IF @no_qty_lines IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'Quantity is blank or less than 1 on line(s): ' + @no_qty_lines
                + '. Each PR line needs a quantity of at least 1 (decimals are cut off before sending to SAP).';

            UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE hdr_record_id = @hdr_record_id;

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

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

        ----------GL account Validation---------  26/11/26

        SET @blank_gl_lines = STUFF((
            SELECT ', ' + ISNULL(l.prebid_line_no, '?')
            FROM dbo.xx_projectrequisition_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id
              AND ISNULL(LTRIM(RTRIM(l.gl_acct)), '') = ''
            ORDER BY l.prebid_line_no
            FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '');

        IF @blank_gl_lines IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'GL account is blank on line(s): ' + @blank_gl_lines
                + '. The GL account is taken from the Program; please fill it there.';

            UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE hdr_record_id = @hdr_record_id;

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

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

        ----------Service line account assignment Validation---------  24/11/26
        ---- Service PRs are on Network + Activity only. A service line on the WBS element path
        ---- (no WBS selected, WBS element from CostCodes.Notes) stops the PR before SAP is called.

        SET @wbs_srv_lines = STUFF((
            SELECT ', ' + ISNULL(l.prebid_line_no, '?')
            FROM dbo.xx_projectrequisition_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id
              AND l.item_cat = '9'
              AND ISNULL(LTRIM(RTRIM(l.wbs_element)), '') <> ''
            ORDER BY l.prebid_line_no
            FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '');

        IF @wbs_srv_lines IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'Service PR lines must be on a Network and Activity. Please select an Activity in WBS on line(s): '
                + @wbs_srv_lines + '.';

            UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE hdr_record_id = @hdr_record_id;

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

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
            WHERE record_id = @queue_record_id;

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

        --------Call Shaker API-----------------------

        SELECT @URL = CONCAT(@BASE_URL, '?recordId=', @hdr_record_id);

        EXEC dbo.SHK_INT_APICALL_PRC @URL = @URL, @MSG = @MSG OUTPUT;

        SELECT @API_STATUS = process_status, @sap_pr_id = sap_pr_id, @con_error = error_msg
        FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob
        WHERE record_id = @hdr_record_id;

        IF @API_STATUS = 'S' AND @sap_pr_id IS NOT NULL
        BEGIN
            ---- 'P' = pending SAP approval: the workflow stays at the Integration step.
            UPDATE dbo.xx_integration_tbl
            SET status = 'P', erp_txn_number = @sap_pr_id, error_msg = 'Project Requisition created in SAP, PR ' + @sap_pr_id + ' - Pending SAP approval', last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

            -- Write the SAP-assigned PR number (BANFN) back into the PMWeb source entity, header level
            UPDATE dbo.Estimate_PreBids
            SET SpecField4 = @sap_pr_id
            WHERE Id = @TRAN_ID;

            -- Line level: MfrNumber = the item number from SAP's PR response payload (PREQ_ITEM, e.g.
            -- '00010') - ShkrProjectRequisitionService overwrites prebid_line_no with the confirmed
            -- response value before this runs, so this reads the response.
            UPDATE pbd
            SET pbd.MfrNumber = l.prebid_line_no
            FROM dbo.Estimate_PreBidDetails pbd
            JOIN dbo.xx_projectrequisition_line_stg_tbl_ob l ON l.prebid_detail_id = pbd.Id
            WHERE l.hdr_record_id = @hdr_record_id;

            -- The PreBid screen shows 'Integration Reference' (template 45, field 4) from
            -- dbo.Specifications.
            IF EXISTS (SELECT 1 FROM dbo.Specifications
                       WHERE EntityTypeId = 244 AND EntityId = @TRAN_ID AND SpecificationTemplateId = 45)
                UPDATE dbo.Specifications
                SET Measure = @sap_pr_id
                WHERE EntityTypeId = 244 AND EntityId = @TRAN_ID AND SpecificationTemplateId = 45;
            ELSE
                INSERT INTO dbo.Specifications (EntityTypeId, EntityId, SpecificationTemplateId, Measure, Notes, ListItemId)
                VALUES (244, @TRAN_ID, 45, @sap_pr_id, '', -1);

            SELECT 'Project Requisition created in SAP - Pending SAP approval' AS Message, @sap_pr_id AS SapPrId, @hdr_record_id AS HdrRecordId;
        END
        ELSE
        BEGIN
         
            SET @ERROR_DESC = ISNULL(@con_error, 'Project Requisition API call did not return a success status.')
                + ' | Raw API response: ' + ISNULL(@MSG, '(empty)');

            UPDATE dbo.xx_integration_tbl
            SET status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

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
            RETURN -2;
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
            WHERE record_id = @queue_record_id;

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
            RETURN -2;
        END

        -- PR already created in SAP: finish the write-backs that the error interrupted, then wait for SAP approval
        -- (never send it back - a resubmit would create a second PR in SAP)
        BEGIN TRY
            UPDATE dbo.xx_integration_tbl
            SET status = 'P', erp_txn_number = @sap_pr_id, error_msg = 'Project Requisition created in SAP, PR ' + @sap_pr_id
                + ' - Pending SAP approval (write-back completed after error: ' + @ErrorMessage + ')', last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

            UPDATE dbo.Estimate_PreBids
            SET SpecField4 = @sap_pr_id
            WHERE Id = @TRAN_ID;

            -- Same line-level MfrNumber write as the main success path above - a PR that succeeded in
            -- SAP but hit a later error must still get its line references completed. 
            UPDATE pbd
            SET pbd.MfrNumber = l.prebid_line_no
            FROM dbo.Estimate_PreBidDetails pbd
            JOIN dbo.xx_projectrequisition_line_stg_tbl_ob l ON l.prebid_detail_id = pbd.Id
            WHERE l.hdr_record_id = @hdr_record_id;

            IF EXISTS (SELECT 1 FROM dbo.Specifications
                       WHERE EntityTypeId = 244 AND EntityId = @TRAN_ID AND SpecificationTemplateId = 45)
                UPDATE dbo.Specifications
                SET Measure = @sap_pr_id
                WHERE EntityTypeId = 244 AND EntityId = @TRAN_ID AND SpecificationTemplateId = 45;
            ELSE
                INSERT INTO dbo.Specifications (EntityTypeId, EntityId, SpecificationTemplateId, Measure, Notes, ListItemId)
                VALUES (244, @TRAN_ID, 45, @sap_pr_id, '', -1);

            SELECT 'Project Requisition created in SAP - Pending SAP approval (write-back completed after error: ' + @ErrorMessage + ')' AS Message,
                   @sap_pr_id AS SapPrId, @hdr_record_id AS HdrRecordId;
            RETURN -2;  -- same code for every unexpected error ; the message tells the cases apart
        END TRY
        BEGIN CATCH
            -- Completion failed : Do NOT re-run this PreBid, it would create a second PR in SAP.
          
            SET @ErrorMessage = ERROR_MESSAGE();
            SET @ErrorDesc = 'PR ' + @sap_pr_id + ' created in SAP but the write-back failed - complete it manually, do not re-send';

            INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
            VALUES (ERROR_NUMBER(), ERROR_PROCEDURE(), ERROR_LINE(), @ErrorMessage, CAST(@TRAN_ID AS VARCHAR(100)), GETDATE(), @ErrorDesc);

            -- the queue status is left as it is (the PR exists); the message shows it still needs completing
            UPDATE dbo.xx_integration_tbl
            SET error_msg = @ErrorDesc + ': ' + @ErrorMessage, last_update_date = GETDATE()
            WHERE record_id = @queue_record_id;

            SELECT @ErrorDesc + ': ' + @ErrorMessage AS Message, @sap_pr_id AS SapPrId, @hdr_record_id AS HdrRecordId;
            RETURN -2;
        END CATCH
    END CATCH

    SET NOCOUNT OFF
END

GO

