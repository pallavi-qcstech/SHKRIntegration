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

MANDATORY parameters: PO Document Type on the project,
po_item, quantity > 0, delivery_date, tax_code
, preq_no, preq_item, and a valid account assignment (WBS element only, or
Network + Activity only .

preq_item is CostManagement_CommitmentDetails.MfrNumber .PR Outbound writes the 
PR's own item number into Estimate_PreBidDetails.MfrNumber on success

PO is always created through a PR and must carry the PR reference.

SAP PO number is wtitten back to  -> CostManagement_Commitments.Reference
and each line's PoItem -> CostManagement_CommitmentDetails.Field10,


Change Log

23/10/26 - Pallavi M - New procedure

28/10/26  purch_org '9999'; commitment_detail_id saved; Reference + Field10 write-back.

30/10/26  @txn_type 'Commitments' (matches START_INTEGRATION);
          
02/11/26  PO depends on the PR it came from, so two different POs are possible, one at WBS level and one
          at Activity level). A line with CommitmentDetails.ProjectWBSId sends Network + Activity only
           a line without ProjectWBSId sends WBS element only (CostCodes.Notes). Invalid
          combinations (Network without Activity, Activity without Network, neither, or both) are
          now rejected before the SAP call, same validation PR has.

03/11/26  PO is created at Activity level, same as PR: a line whose ProjectWBSId has children in dbo.WBS
          (a Network or WBS group node) is rejected "PO can be created either at
          WBS level or at Activity level. Please select correct activity".

03/11/26  Line WBS is read from CommitmentDetails.ProjectWBSId, not WBSId. PMWeb copies the PreBid
          line's WBSId into ProjectWBSId when the Commitment is generated; WBSId stays NULL
          
03/11/26  doc_type is read from the project's "PO Document Type" field (dbo.Specifications,
          EntityTypeId 1 = Projects, SpecificationTemplateId 48)

05/11/26  On success each line's PoItem is also written to dbo.xx_sap_po_line_ref_tbl (SAP PO item
          register, as ROSHN xx_erp_po_line_num_tbl / AlFuttaim); Change Order reads it for the next item number.

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
    DECLARE @bad_uom BIT;
    DECLARE @bad_price BIT;
    DECLARE @bad_vendor BIT;
    DECLARE @bad_currency BIT;
    DECLARE @bad_acct_lines VARCHAR(MAX);
    DECLARE @acct_error VARCHAR(MAX);
    DECLARE @po_doc_type NVARCHAR(200);
    DECLARE @bad_doc_type BIT;
    DECLARE @existing_po NVARCHAR(100);

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
              -- keep a header that holds a SAP PO number: it is what the duplicate guard reads[TBC]
              AND NULLIF(LTRIM(RTRIM(h.sap_po_id)), '') IS NULL
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

        ----------Duplicate Guard---------
        ---- Z_PO_CREATE_SRV has no duplicate protection sending this Commitment
        ---- again would create a second PO in SAP. Rejected before anything is staged.[TBC]

        SELECT @existing_po = NULLIF(LTRIM(RTRIM(Reference)), '')
        FROM dbo.CostManagement_Commitments
        WHERE Id = @TRAN_ID;

        IF @existing_po IS NULL
            SELECT TOP 1 @existing_po = LTRIM(RTRIM(h.sap_po_id))
            FROM dbo.xx_purchaseorder_hdr_stg_tbl_ob h
            WHERE h.commitment_id = @TRAN_ID
              AND NULLIF(LTRIM(RTRIM(h.sap_po_id)), '') IS NOT NULL
            ORDER BY h.record_id DESC;

        IF @existing_po IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'SAP PO ' + @existing_po + ' already created for this Commitment - not sent again.';

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
            RETURN -10;
        END

        -- PO Document Type from the Commitment's project: dbo.SpecificationsTemplate 48
        -- 'PO Document Type' (EntityTypeId 1 = Projects). 
        SELECT TOP 1 @po_doc_type = LTRIM(RTRIM(CAST(s.Measure AS NVARCHAR(200))))
        FROM dbo.CostManagement_Commitments h
        JOIN dbo.Specifications s
          ON s.EntityTypeId = 1
         AND s.SpecificationTemplateId = 48
         AND s.EntityId = h.ProjectId
        WHERE h.Id = @TRAN_ID
        ORDER BY s.Id DESC;

        -----------  Stage Header Data -----------------------------------

        BEGIN TRY

            INSERT INTO dbo.xx_purchaseorder_hdr_stg_tbl_ob
                (sap_po_id, commitment_id,
                 comp_code, doc_type, vendor, purch_org, pur_group, currency, doc_date,
                 process_status, operation_flag, creation_date, last_update_date)
            SELECT
                NULL,
                h.Id,
                '1000',                                -- comp_code: hardcoded per user mapping
                -- doc_type: project's PO Document Type; NULL when blank, so the mandatory check
                -- below rejects it
                NULLIF(@po_doc_type, ''),
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
                 price_unit, tax_code, acctasscat, wbs_element, gl_account,
                 network, activity, preq_no, preq_item, delivery_date, commitment_detail_id,
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
                -- Same split as PR (we will have two different POs, one at
                -- activity level and one at WBS level): a line with a ProjectWBSId is sent as
                -- Network + Activity only (CostCodeId ignored, even when both are filled); a line
                -- without a ProjectWBSId is sent as WBS element only (CostCodes.Notes).
                CASE WHEN NULLIF(d.ProjectWBSId, 0) IS NULL THEN wbsres.ResolvedWbsElement ELSE '' END,
                pgm.SpecField6,                        -- gl_account: same as PR
                CASE WHEN NULLIF(d.ProjectWBSId, 0) IS NOT NULL THEN ISNULL(wbsnet.ResolvedNetwork, '') ELSE '' END,
                CASE WHEN NULLIF(d.ProjectWBSId, 0) IS NOT NULL THEN ISNULL(wbsnet.ResolvedActivity, '') ELSE '' END,
                LEFT(ISNULL(pb.SpecField4, ''), 10),   -- preq_no: SAP PR number (BANFN) written back by PR Outbound
                LEFT(ISNULL(d.MfrNumber, ''), 5),      -- preq_item: PR line's item number, carried forward by
                                                        -- PMWeb from Estimate_PreBidDetails.MfrNumber (PR
                                                        -- Outbound write-back) through Estimate_ProcurementDetails
                                                        -- to this CommitmentDetails row
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
            -- .PrebidId -> Estimate_PreBids.
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
                WHERE wc.Id = d.ProjectWBSId
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
            @bad_preq_item = MAX(CASE WHEN preq_item IS NULL OR LTRIM(RTRIM(preq_item)) = '' THEN 1 ELSE 0 END),
            @bad_uom      = MAX(CASE WHEN po_unit IS NULL OR LTRIM(RTRIM(po_unit)) = '' THEN 1 ELSE 0 END),
            @bad_price    = MAX(CASE WHEN net_price IS NULL OR net_price <= 0 THEN 1 ELSE 0 END)
        FROM dbo.xx_purchaseorder_line_stg_tbl_ob
        WHERE hdr_record_id = @hdr_record_id;

        SELECT @bad_doc_type = CASE WHEN doc_type IS NULL OR LTRIM(RTRIM(doc_type)) = '' THEN 1 ELSE 0 END,
               @bad_vendor   = CASE WHEN vendor IS NULL OR LTRIM(RTRIM(vendor)) = '' THEN 1 ELSE 0 END,
               @bad_currency = CASE WHEN currency IS NULL OR LTRIM(RTRIM(currency)) = '' THEN 1 ELSE 0 END
        FROM dbo.xx_purchaseorder_hdr_stg_tbl_ob
        WHERE record_id = @hdr_record_id;

        IF @bad_doc_type = 1 OR @bad_item_qty = 1 OR @bad_deliv = 1 OR @bad_tax = 1 OR @bad_preq_no = 1 OR @bad_preq_item = 1
           OR @bad_uom = 1 OR @bad_price = 1 OR @bad_vendor = 1 OR @bad_currency = 1
        BEGIN
            SET @ERROR_DESC = LTRIM(
                  CASE WHEN @bad_doc_type = 1 THEN 'PO Document Type is not set on the project (Project > PO Document Type, e.g. ZLOC). ' ELSE '' END
                + CASE WHEN @bad_vendor = 1 THEN 'Vendor missing - the Commitment has no vendor company, or the company has no SAP vendor number (Company Code). ' ELSE '' END
                + CASE WHEN @bad_currency = 1 THEN 'Currency missing on the Commitment header. ' ELSE '' END
                + CASE WHEN @bad_item_qty = 1 THEN 'Line item number and quantity must not be blank/zero. ' ELSE '' END
                + CASE WHEN @bad_uom = 1 THEN 'Unit of measure missing on one or more Commitment lines. ' ELSE '' END
                + CASE WHEN @bad_price = 1 THEN 'Amount must be greater than zero on every Commitment line. ' ELSE '' END
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
        ----   1) WBS element only       - ProjectWBSId blank, CostCodes.Notes has the SAP WBS element
        ----   2) Network + Activity only - ProjectWBSId is an Activity under a 12-digit Network
        ---- Anything else (all blank, Network without Activity, Activity without Network, or both
        ---- WBS element and Network/Activity present) is rejected here before calling SAP.
        ---- A populated ProjectWBSId must also be a leaf node in dbo.WBS (same check as PR): PO is created at
        ---- Activity level, so a Network or WBS group node with children under it is rejected.
      

        SET @acct_error = NULL;

        IF EXISTS (
            SELECT 1
            FROM dbo.CostManagement_CommitmentDetails d
            WHERE d.CommitmentId = @TRAN_ID
              AND NULLIF(d.ProjectWBSId, 0) IS NOT NULL
              AND EXISTS (SELECT 1 FROM dbo.WBS c WHERE c.ParentId = d.ProjectWBSId)
        )
            SET @acct_error = 'PO can be created either at WBS level or at Activity level. Please select correct activity';

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

        IF @acct_error IS NULL AND @bad_acct_lines IS NOT NULL
            SET @acct_error = 'Invalid account assignment on line(s): ' + @bad_acct_lines
                + '. Each line needs either a Cost Code whose Notes holds the SAP WBS element (WBS left blank),'
                + ' or a WBS selection that is an Activity under a Network.';

        IF @acct_error IS NOT NULL
        BEGIN
            SET @ERROR_DESC = @acct_error;

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

            -- PO items into the SAP PO item register read by Change Order
            INSERT INTO dbo.xx_sap_po_line_ref_tbl
                (commitment_id, po_number, po_item, change_order_id, change_order_detail_id, creation_date)
            SELECT @TRAN_ID, @sap_po_id, l.po_item, NULL, NULL, GETDATE()
            FROM dbo.xx_purchaseorder_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id;

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
        SET @ErrorNumber = ERROR_NUMBER();
        SET @ErrorProcedure = ERROR_PROCEDURE();
        SET @ErrorLine = ERROR_LINE();
        SET @ErrorMessage = ERROR_MESSAGE();
        SET @ErrorDesc = 'Unexpected exception in PO procedure';
        SET @ERROR_DESC = @ErrorDesc + ': ' + @ErrorMessage;

        INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
        VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, CAST(@TRAN_ID AS VARCHAR(100)), GETDATE(), @ErrorDesc);

        -- Re-read from staging: the error may have happened after SAP created the PO
        IF @hdr_record_id > 0
            SELECT @sap_po_id = NULLIF(LTRIM(RTRIM(sap_po_id)), '')
            FROM dbo.xx_purchaseorder_hdr_stg_tbl_ob
            WHERE record_id = @hdr_record_id;

        IF @sap_po_id IS NULL
        BEGIN
            -- No PO in SAP: same handling as the other errors, back to the submitter
            IF @hdr_record_id > 0
            BEGIN
                UPDATE dbo.xx_purchaseorder_hdr_stg_tbl_ob
                SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
                WHERE record_id = @hdr_record_id;

                UPDATE dbo.xx_purchaseorder_line_stg_tbl_ob
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

        -- PO already created in SAP: finish the success steps that the error interrupted
        -- (never send it back - a resubmit would create a second PO in SAP)[TBC]
        BEGIN TRY
            UPDATE dbo.xx_integration_tbl
            SET status = 'S', error_msg = 'Purchase Order created successfully, SAP PO ' + @sap_po_id
                + ' (completed after error: ' + @ErrorMessage + ')', last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            UPDATE dbo.CostManagement_Commitments
            SET Reference = @sap_po_id
            WHERE Id = @TRAN_ID;

            -- Same line-level Field10 write as the main success path above
            UPDATE d
            SET d.Field10 = l.po_item
            FROM dbo.CostManagement_CommitmentDetails d
            JOIN dbo.xx_purchaseorder_line_stg_tbl_ob l ON l.commitment_detail_id = d.Id
            WHERE l.hdr_record_id = @hdr_record_id
              AND d.CommitmentId = @TRAN_ID;

            -- Same register write as the main success path (items it already wrote are skipped)
            INSERT INTO dbo.xx_sap_po_line_ref_tbl
                (commitment_id, po_number, po_item, change_order_id, change_order_detail_id, creation_date)
            SELECT @TRAN_ID, @sap_po_id, l.po_item, NULL, NULL, GETDATE()
            FROM dbo.xx_purchaseorder_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id
              AND NOT EXISTS (SELECT 1 FROM dbo.xx_sap_po_line_ref_tbl r
                              WHERE r.commitment_id = @TRAN_ID AND r.po_item = l.po_item);

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

            SELECT 'Purchase Order created successfully (completed after error: ' + @ErrorMessage + ')' AS Message,
                   @sap_po_id AS SapPoId, @hdr_record_id AS HdrRecordId;
            RETURN -9;  
        END TRY
        BEGIN CATCH
           
            SET @ErrorMessage = ERROR_MESSAGE();
            SET @ErrorDesc = 'PO ' + @sap_po_id + ' created in SAP but completion failed - complete manually, do not re-send';

            INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
            VALUES (ERROR_NUMBER(), ERROR_PROCEDURE(), ERROR_LINE(), @ErrorMessage, CAST(@TRAN_ID AS VARCHAR(100)), GETDATE(), @ErrorDesc);

           
            UPDATE dbo.xx_integration_tbl
            SET error_msg = @ErrorDesc + ': ' + @ErrorMessage, last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            SELECT @ErrorDesc + ': ' + @ErrorMessage AS Message, @sap_po_id AS SapPoId, @hdr_record_id AS HdrRecordId;
            RETURN -9;
        END CATCH
    END CATCH

    SET NOCOUNT OFF
END
GO
