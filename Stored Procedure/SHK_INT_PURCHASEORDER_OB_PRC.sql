USE [PMWeb]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/* 
SHK_INT_PURCHASEORDER_OB_PRC PO Outbound stored procedure (PMWeb -> SAP) 
Purchase Order Create via Z_PO_CREATE_SRV SAP API

SCOPE: create-only, "item without material", ACCTASSCAT='P'

MANDATORY (rejected here, before the SAP call): po_item, quantity > 0, delivery_date, tax_code
(exactly 2 characters), preq_no, preq_item, and a valid account assignment (WBS element only, or
Network + Activity only - see the 02/11/26 Change Log entry).

PO is always created through a PR and must carry the PR reference.

SAP PO number is wtitten back to  -> CostManagement_Commitments.Reference
and each line's PoItem -> CostManagement_CommitmentDetails.Field10,

preq_item is CostManagement_CommitmentDetails.MfrNumber .PR Outbound writes the PR's own item number into
Estimate_PreBidDetails.MfrNumber on success, and PMWeb is assumed to carry that value forward
PreBid -> Procurement -> Commitment line (PO should have it in the payload so it will be copied forward").

Change Log

23/10/26 - Pallavi M - New procedure

28/10/26  purch_org '9999'; commitment_detail_id saved; Reference + Field10 write-back.

30/10/26  @txn_type 'Commitments' (matches START_INTEGRATION);
          Reference/Field10 confirmed.

02/11/26  PO depends on the PR it came from, so two different POs are possible, one at WBS level and one
          at Activity level). A line with CommitmentDetails.WBSId sends Network + Activity only
           a line without WBSId sends WBS element only (CostCodes.Notes). Invalid
          combinations (Network without Activity, Activity without Network, neither, or both) are
          now rejected before the SAP call, same validation PR has.
*/

ALTER PROC [dbo].[SHK_INT_PURCHASEORDER_OB_PRC]
    @TRAN_ID BIGINT   -- dbo.CostManagement_Commitments.Id
AS
BEGIN
    SET XACT_ABORT ON
    SET NOCOUNT ON

    DECLARE @ERROR_DESC VARCHAR(MAX) = '';
    DECLARE @hdr_record_id BIGINT = 0;
    DECLARE @URL NVARCHAR(500);
    DECLARE @MSG VARCHAR(MAX);

    DECLARE @API_STATUS VARCHAR(1);
    DECLARE @sap_po_id VARCHAR(20);
    DECLARE @con_error VARCHAR(MAX);

    DECLARE @bad_item_qty BIT;
    DECLARE @bad_deliv BIT;
    DECLARE @bad_tax BIT;
    DECLARE @bad_preq_no BIT;
    DECLARE @bad_preq_item BIT;
    DECLARE @bad_acct_lines VARCHAR(MAX);

    -- Must match the tran_type SHK_INT_START_INTEGRATION writes for Commitments 
    DECLARE @txn_type VARCHAR(30) = 'Commitments';
    DECLARE @DocumentId BIGINT;
    DECLARE @CurrStepId BIGINT;
    DECLARE @PrevStepId BIGINT;

    DECLARE @ErrorNumber INT;
    DECLARE @ErrorProcedure NVARCHAR(200);
    DECLARE @ErrorLine INT;
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorDesc NVARCHAR(4000);

    DECLARE @BASE_URL NVARCHAR(200) = 'http://Shaker.pmweb.local:8080/SHKRIntegration/api/Outbound/purchaseorder';

    BEGIN TRY

        ------ Cleanup Previous Failed Staging Records --------------

        DELETE FROM dbo.xx_purchaseorder_hdr_stg_tbl_ob
        WHERE record_id IN (
            SELECT h.record_id
            FROM dbo.xx_purchaseorder_hdr_stg_tbl_ob h
            JOIN dbo.xx_purchaseorder_line_stg_tbl_ob l ON l.hdr_record_id = h.record_id
            WHERE h.commitment_id = @TRAN_ID
              AND h.process_status <> 'S'
        );

        DELETE FROM dbo.xx_purchaseorder_line_stg_tbl_ob
        WHERE hdr_record_id NOT IN (SELECT record_id FROM dbo.xx_purchaseorder_hdr_stg_tbl_ob);

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

        IF NOT EXISTS (SELECT 1 FROM dbo.CostManagement_Commitments WHERE Id = @TRAN_ID)
        BEGIN
            SET @ERROR_DESC = 'No CostManagement_Commitments row found for Id ' + CAST(@TRAN_ID AS VARCHAR(20)) + '.';

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

        IF NOT EXISTS (SELECT 1 FROM dbo.CostManagement_CommitmentDetails WHERE CommitmentId = @TRAN_ID)
        BEGIN
            SET @ERROR_DESC = 'CostManagement_Commitments ' + CAST(@TRAN_ID AS VARCHAR(20)) + ' has no CostManagement_CommitmentDetails lines.';

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

            INSERT INTO dbo.xx_purchaseorder_hdr_stg_tbl_ob
                (sap_po_id, commitment_id, commitment_code, project, description,
                 comp_code, doc_type, vendor, purch_org, pur_group, currency, doc_date,
                 process_status, operation_flag, creation_date, last_update_date)
            SELECT
                NULL,
                h.Id,
                h.CommitmentCode,
                proj.ProjectName,
                h.Description,
                '1000',                                -- comp_code: hardcoded per user mapping
                pgm.SpecField5,                        -- doc_type: same as PR,
                comp.CompanyCode,                      -- vendor: SAP vendor number stored by the vendor sync
                '9999',                                -- purch_org: hardcoded "for now" 
                pgm.SpecField7,                        -- pur_group: same as PR
                cur.Code,                              -- currency: Commitment header CurrencyId
                CONVERT(VARCHAR(10), GETDATE(), 23) + 'T00:00:00',  -- doc_date: system date; ISO format
                'N', 'I', GETDATE(), GETDATE()
           FROM dbo.CostManagement_Commitments h
            JOIN dbo.Projects proj ON proj.Id = h.ProjectId
            JOIN dbo.Programs pgm ON pgm.Id = proj.ProgramId
            LEFT JOIN dbo.Companies comp ON comp.Id = h.CompanyId
            -- The SAP PO has one Currency, on the header (POHEADSet), so it comes from the
            -- Commitment header, not from the lines.
						 
									 
															
            LEFT JOIN dbo.Currencies cur ON cur.Id = h.CurrencyId
											
									  
					 
            WHERE h.Id = @TRAN_ID;
			
            IF @@ROWCOUNT = 0
            BEGIN
                SET @ERROR_DESC = 'Could not stage header for CostManagement_Commitments ' + CAST(@TRAN_ID AS VARCHAR(20)) + '.';

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

            SET @hdr_record_id = SCOPE_IDENTITY();

            --------- Stage Line Data -------------

            ;WITH WbsCode AS (
                -- Same resolution as PR's WbsCode - SAP code taken from Code directly per
                -- SHK_INT_SAPCOSTCODE_IB_PRC procedure.
                SELECT w.Id, w.ParentId,
                    ResolvedCode = w.Code
                FROM dbo.WBS w
            )
            INSERT INTO dbo.xx_purchaseorder_line_stg_tbl_ob
                (hdr_record_id, po_item, short_text, mat_grp, plant, quantity, po_unit, net_price,
                 price_unit, tax_code, acctasscat, cost_code_id, wbs_element, gl_account, co_area,
                 network, activity, preq_no, preq_item, item_cat, delivery_date, commitment_detail_id,
                 process_status, operation_flag, creation_date, last_update_date)
            SELECT
                @hdr_record_id,
                RIGHT('00000' + CAST(ROW_NUMBER() OVER (ORDER BY d.LineNumber) * 10 AS VARCHAR(5)), 5),  -- same as PR
                LEFT(ISNULL(d.Description, ''), 40),
                'S000001',                             -- mat_grp: hardcoded per user mapping
                pgm.SpecField1,                        -- plant: same as PR
                d.Quantity,
                LTRIM(RTRIM(LEFT(uom.UOM, CHARINDEX(' - ', uom.UOM + ' - ') - 1))),
                d.ExtCost,                             -- net_price: line total, same as PR -
                '1',                                   -- price_unit
                -- NULL when missing, so the mandatory check below rejects it
                CASE WHEN LEN(taxres.TaxCode) = 2 THEN taxres.TaxCode END,
                'P',
                d.CostCodeId,
                -- Same split as PR (we will have two different POs, one at
                -- activity level and one at WBS level): a line with a WBSId is sent as
                -- Network + Activity only (CostCodeId ignored, even when both are filled); a line
                -- without a WBSId is sent as WBS element only (CostCodes.Notes).
                CASE WHEN NULLIF(d.WBSId, 0) IS NULL THEN wbsres.ResolvedWbsElement ELSE '' END,
                pgm.SpecField6,                        -- gl_account: same as PR
                '1000',
                CASE WHEN NULLIF(d.WBSId, 0) IS NOT NULL THEN ISNULL(wbsnet.ResolvedNetwork, '') ELSE '' END,
                CASE WHEN NULLIF(d.WBSId, 0) IS NOT NULL THEN ISNULL(wbsnet.ResolvedActivity, '') ELSE '' END,
                LEFT(ISNULL(pb.SpecField4, ''), 10),   -- preq_no: SAP PR number (BANFN) written back by PR Outbound
                LEFT(ISNULL(d.MfrNumber, ''), 5),      -- preq_item: PR line's item number, carried forward by
                                                        -- PMWeb from Estimate_PreBidDetails.MfrNumber (PR
                                                        -- Outbound write-back) through Estimate_ProcurementDetails
                                                        -- to this CommitmentDetails row
                '',                                    -- item_cat: always blank this scope
                CONVERT(VARCHAR(10), h.ScheduledDeliveryDate, 104),  -- delivery_date: DD.MM.YYYY
                d.Id,                                  -- commitment_detail_id: for the Field10 write-back
                'N', 'I', GETDATE(), GETDATE()
            FROM dbo.CostManagement_CommitmentDetails d
            JOIN dbo.CostManagement_Commitments h ON h.Id = d.CommitmentId
            JOIN dbo.Projects proj ON proj.Id = h.ProjectId
            JOIN dbo.Programs pgm ON pgm.Id = proj.ProgramId
            LEFT JOIN dbo.UOM uom ON uom.Id = d.UOMId
            LEFT JOIN dbo.CostCodes cc ON cc.Id = d.CostCodeId
            -- PR reference. Header link is stored: Commitment.ProcurementId -> Estimate_Procurements
            -- .PrebidId (GeneratedFromPrebidId as fallback) -> Estimate_PreBids.
            LEFT JOIN dbo.Estimate_Procurements prc ON prc.Id = h.ProcurementId
            LEFT JOIN dbo.Estimate_PreBids pb
                   ON pb.Id = COALESCE(NULLIF(prc.PrebidId, 0), NULLIF(prc.GeneratedFromPrebidId, 0))
            -- Header SpecField1 holds e.g. 'V2-SA Input VAT 5% for domestic goods purchases' - the
            -- SAP tax code is the text before the first '-'.
            CROSS APPLY (
                SELECT LTRIM(RTRIM(LEFT(h.SpecField1, CHARINDEX('-', h.SpecField1 + '-') - 1))) AS TaxCode
            ) taxres
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
            WHERE d.CommitmentId = @TRAN_ID;

            IF @@ROWCOUNT = 0
            BEGIN
                DELETE FROM dbo.xx_purchaseorder_hdr_stg_tbl_ob WHERE record_id = @hdr_record_id;

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
        SELECT
            @bad_item_qty = MAX(CASE WHEN po_item IS NULL OR LTRIM(RTRIM(po_item)) = ''
                                       OR quantity IS NULL OR quantity <= 0 THEN 1 ELSE 0 END),
            @bad_deliv    = MAX(CASE WHEN delivery_date IS NULL OR LTRIM(RTRIM(delivery_date)) = '' THEN 1 ELSE 0 END),
            @bad_tax      = MAX(CASE WHEN tax_code IS NULL OR LEN(tax_code) <> 2 THEN 1 ELSE 0 END),
            @bad_preq_no  = MAX(CASE WHEN preq_no IS NULL OR LTRIM(RTRIM(preq_no)) = '' THEN 1 ELSE 0 END),
            @bad_preq_item = MAX(CASE WHEN preq_item IS NULL OR LTRIM(RTRIM(preq_item)) = '' THEN 1 ELSE 0 END)
        FROM dbo.xx_purchaseorder_line_stg_tbl_ob
        WHERE hdr_record_id = @hdr_record_id;

        IF @bad_item_qty = 1 OR @bad_deliv = 1 OR @bad_tax = 1 OR @bad_preq_no = 1 OR @bad_preq_item = 1
        BEGIN
            SET @ERROR_DESC = LTRIM(
                  CASE WHEN @bad_item_qty = 1 THEN 'Line item number and quantity must not be blank/zero. ' ELSE '' END
                + CASE WHEN @bad_deliv = 1 THEN 'Delivery date missing (Scheduled Delivery Date on the Commitment). ' ELSE '' END
                + CASE WHEN @bad_tax = 1 THEN 'Tax code missing or invalid (Commitment SpecField1 must start with a 2-character SAP tax code, e.g. ''V2-...''). ' ELSE '' END
                + CASE WHEN @bad_preq_no = 1 THEN 'SAP PR number missing - the Commitment must come from a Procurement generated from a PR that was successfully sent to SAP. ' ELSE '' END
                + CASE WHEN @bad_preq_item = 1 THEN 'PR item not found - one or more Commitment lines have no MfrNumber (PR line reference) carried forward from the PreBid line. ' ELSE '' END);

            UPDATE dbo.xx_purchaseorder_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_purchaseorder_line_stg_tbl_ob
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
        ---- Same rule as PR . ACCTASSCAT is always 'P'. A line is
        ---- valid in exactly one of two cases:
        ----   1) WBS element only       - WBSId blank, CostCodes.Notes has the SAP WBS element
        ----   2) Network + Activity only - WBSId is an Activity under a 12-digit Network
        ---- Anything else (all blank, Network without Activity, Activity without Network, or both
        ---- WBS element and Network/Activity present) is rejected here before calling SAP.

        SET @bad_acct_lines = STUFF((
            SELECT ', ' + ISNULL(l.po_item, '?') + ' (' +
                CASE
                    WHEN ISNULL(LTRIM(RTRIM(l.network)), '') <> '' AND ISNULL(LTRIM(RTRIM(l.activity)), '') = ''
                        THEN 'Network ' + LTRIM(RTRIM(l.network)) + ' has no Activity'
                    WHEN ISNULL(LTRIM(RTRIM(l.network)), '') = '' AND ISNULL(LTRIM(RTRIM(l.activity)), '') <> ''
                        THEN 'Activity ' + LTRIM(RTRIM(l.activity)) + ' is not under a Network'
                    WHEN ISNULL(LTRIM(RTRIM(l.wbs_element)), '') = ''
                        THEN 'no WBS element in Cost Code Notes and no valid Activity selected in WBS'
                    ELSE 'both WBS element and Network/Activity present'
                END + ')'
            FROM dbo.xx_purchaseorder_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id
              AND NOT (
                    (ISNULL(LTRIM(RTRIM(l.wbs_element)), '') <> ''
                     AND ISNULL(LTRIM(RTRIM(l.network)), '') = ''
                     AND ISNULL(LTRIM(RTRIM(l.activity)), '') = '')
                 OR (ISNULL(LTRIM(RTRIM(l.wbs_element)), '') = ''
                     AND ISNULL(LTRIM(RTRIM(l.network)), '') <> ''
                     AND ISNULL(LTRIM(RTRIM(l.activity)), '') <> '')
              )
            ORDER BY l.po_item
            FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '');

        IF @bad_acct_lines IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'Invalid account assignment on line(s): ' + @bad_acct_lines
                + '. Each line needs either a Cost Code whose Notes holds the SAP WBS element (WBS left blank),'
                + ' or a WBS selection that is an Activity under a Network.';

            UPDATE dbo.xx_purchaseorder_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_purchaseorder_line_stg_tbl_ob
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

        SELECT @API_STATUS = process_status, @sap_po_id = sap_po_id, @con_error = error_msg
        FROM dbo.xx_purchaseorder_hdr_stg_tbl_ob
        WHERE record_id = @hdr_record_id;

        IF @API_STATUS = 'S' AND @sap_po_id IS NOT NULL
        BEGIN
            UPDATE dbo.xx_integration_tbl
            SET status = 'S', error_msg = 'Purchase Order created successfully, SAP PO ' + @sap_po_id, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            -- Write the SAP PO number back to the Commitment header and each line's PO item to
            -- the Commitment line 
            UPDATE dbo.CostManagement_Commitments
            SET Reference = @sap_po_id
            WHERE Id = @TRAN_ID;

            UPDATE d
            SET d.Field10 = l.po_item
            FROM dbo.CostManagement_CommitmentDetails d
            JOIN dbo.xx_purchaseorder_line_stg_tbl_ob l ON l.commitment_detail_id = d.Id
            WHERE l.hdr_record_id = @hdr_record_id
              AND d.CommitmentId = @TRAN_ID;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 7
                    ,@DeliveredToStepId = 0
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = 'Purchase Order created successfully'
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = 0;
                EXEC dbo.Workflow_UpdateWorkflowDocumentStatus @DocumentId = @DocumentId, @ActionTypeId = 7, @StepId = @CurrStepId, @UserId = 5, @ChangeLastAction = 0;
            END

            SELECT 'Purchase Order created successfully' AS Message, @sap_po_id AS SapPoId, @hdr_record_id AS HdrRecordId;
        END
        ELSE
        BEGIN
            SET @ERROR_DESC = ISNULL(@con_error, 'Purchase Order API call did not return a success status.')
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
        SET @ERROR_DESC = ERROR_MESSAGE();

        IF @hdr_record_id > 0
        BEGIN
            UPDATE dbo.xx_purchaseorder_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_purchaseorder_line_stg_tbl_ob
            SET process_status = 'E', error_msg = @ERROR_DESC, last_update_date = GETDATE()
            WHERE hdr_record_id = @hdr_record_id;
        END

        SELECT @ERROR_DESC AS Message;
    END CATCH

    SET NOCOUNT OFF
END
GO
