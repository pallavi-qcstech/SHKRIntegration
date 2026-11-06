USE [PMWeb]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/*
SHK_INT_CHANGEORDER_OB_PRC  Change Order (PMWeb "Commitment CO" / VO) Outbound stored procedure (PMWeb -> SAP)
Purchase Order CHANGE via Z_PO_CREATE_SRV (same service as PO Create; a filled PoNumber = BAPI_PO_CHANGE,
spec v1.3 section 15).

@TRAN_ID = dbo.CostManagement_CommitmentCOs.Id. The VO changes the PO (CostManagement_Commitments) it
points to through CommitmentCOs.CommitmentId; that PO must be approved (DocStatusId 5) and already
created in SAP (Commitments.Reference = SAP PO number, written by SHK_INT_PURCHASEORDER_OB_PRC).

VO line values are DIFFERENCES . Quantity +5 / -3. SAP sets each field to the value sent,
so the SP sends the new TOTAL. PMWeb is the starting point: PO line quantity + earlier approved
VOs (DocStatusId 5) on the same PO line + this VO's difference. Approving a VO does not change the PO lines
in PMWeb. dbo.xx_sap_po_line_ref_tbl keeps the SAP item numbers of the PO (written by PO Create) and of
items added by VOs; the next new item = its highest item + 10.

Per VO line (line_action) -  CommitmentCODetails.CommitmentDetailId
  UPDATE - CommitmentDetailId points to a PO line (its SAP item): only the changed field groups are sent
           (quantity on item + schedule line; text). A negative line reduces that item.
  ADD    - no CommitmentDetailId: sent in full like PO Create (incl. account row), next free item number.
           An item added by an earlier VO cannot be changed by a later VO.
  DELETE - the line's delete box (CommitmentCODetails.Field1 = 'True') is ticked: only the item number +
           DeleteInd X are sent, no quantity check (the rest of the line
           is ignored); the line must point to an item on the SAP PO.
Every ADD / UPDATE line carries the Commitment header delivery date (CostManagement_Commitments
.ScheduledDeliveryDate, as PO Create) on schedule line 0001.
Not sent: account / WBS change of an existing item. An UPDATE line must have the cost code of its
PO line (the WBS is not compared).


Change Log
03/11/26 - Pallavi M - New procedure
04/11/26 - Pallavi M - Delete (DeleteInd) and account / WBS change on existing items removed (out of scope);
                       WBS / cost-code difference and new total 0 rejected
04/11/26 - Pallavi M - Delete re-added as a line-level delete box (DeleteInd X); CO header delivery date
                       sent on every ADD / UPDATE line
04/11/26 - Pallavi M - VO line link : CommitmentDetailId only (CommitmentCoDetailId no longer used);
                       new lines must have a distinct Cost Code + Description + WBS (RETURN -5)
04/11/26 - Pallavi M - Linked line check : cost code only (WBS difference no longer rejected)
05/11/26 - Pallavi M - Only the total quantity is staged (qty_delta / prior_quantity removed);
                       the quantity checks read the staged total
05/11/26 - Pallavi M - Next new item number read from xx_sap_po_line_ref_tbl only (PO Create now writes
                       its items there; CommitmentDetails.Field10 no longer read for it[To be verified]
06/11/26 - Pallavi M - Delete box = CommitmentCODetails.Field1 ('True' = delete), also for the
                       "already deleted by an earlier VO" check

*/

CREATE OR ALTER PROC [dbo].[SHK_INT_CHANGEORDER_OB_PRC]
    @TRAN_ID BIGINT   -- dbo.CostManagement_CommitmentCOs.Id
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

    DECLARE @commitment_id BIGINT;
    DECLARE @po_number NVARCHAR(255);
    DECLARE @po_status INT;
    DECLARE @existing_co NVARCHAR(255);
    DECLARE @max_po_item INT;
    DECLARE @co_delivery_date VARCHAR(10);
    DECLARE @bad_lines VARCHAR(MAX);
    DECLARE @acct_error VARCHAR(MAX);

    -- Must match the tran_type SHK_INT_START_INTEGRATION writes for Commitment COs 
    DECLARE @txn_type VARCHAR(30) = 'CommitmentCOs';
    DECLARE @DocumentId BIGINT;
    DECLARE @CurrStepId BIGINT;
    DECLARE @PrevStepId BIGINT;

    DECLARE @ErrorNumber INT;
    DECLARE @ErrorProcedure NVARCHAR(200);
    DECLARE @ErrorLine INT;
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorDesc NVARCHAR(4000);

    DECLARE @BASE_URL NVARCHAR(200) = 'http://Shaker.pmweb.local:8080/SHKRIntegration/api/Outbound/changeorder';

    BEGIN TRY

        ------ Cleanup Previous Failed Staging Records --------------

        DELETE FROM dbo.xx_changeorder_line_stg_tbl_ob
        WHERE hdr_record_id IN (
            SELECT h.record_id
            FROM dbo.xx_changeorder_hdr_stg_tbl_ob h
            WHERE h.change_order_id = @TRAN_ID
              AND h.process_status <> 'S'
              -- keep a header that holds a SAP PO number.
              AND NULLIF(LTRIM(RTRIM(h.sap_po_id)), '') IS NULL
        );

        DELETE FROM dbo.xx_changeorder_hdr_stg_tbl_ob
        WHERE change_order_id = @TRAN_ID
          AND process_status <> 'S'
          AND NULLIF(LTRIM(RTRIM(sap_po_id)), '') IS NULL;

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

        IF NOT EXISTS (SELECT 1 FROM dbo.CostManagement_CommitmentCOs WHERE Id = @TRAN_ID)
        BEGIN
            SET @ERROR_DESC = 'No CostManagement_CommitmentCOs row found for Id ' + CAST(@TRAN_ID AS VARCHAR(20)) + '.';

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

        IF NOT EXISTS (SELECT 1 FROM dbo.CostManagement_CommitmentCODetails WHERE CommitmentCOId = @TRAN_ID)
        BEGIN
            SET @ERROR_DESC = 'CostManagement_CommitmentCOs ' + CAST(@TRAN_ID AS VARCHAR(20)) + ' has no CostManagement_CommitmentCODetails lines.';

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
        ---- Z_PO_CREATE_SRV has no duplicate protection: a VO that SAP already accepted must not be
        ---- sent again (its differences would be added a second time). Rejected before staging.

        SELECT @existing_co = NULLIF(LTRIM(RTRIM(Reference)), '')
        FROM dbo.CostManagement_CommitmentCOs
        WHERE Id = @TRAN_ID;

        IF @existing_co IS NULL
            SELECT TOP 1 @existing_co = LTRIM(RTRIM(h.sap_po_id))
            FROM dbo.xx_changeorder_hdr_stg_tbl_ob h
            WHERE h.change_order_id = @TRAN_ID
              AND NULLIF(LTRIM(RTRIM(h.sap_po_id)), '') IS NOT NULL
            ORDER BY h.record_id DESC;

        IF @existing_co IS NOT NULL
        BEGIN
            SET @ERROR_DESC = 'This Change Order was already sent to SAP (PO ' + @existing_co + ') - not sent again.';

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

        ----------Parent PO Validation---------
        ---- A VO can only be raised on an approved PO , and that PO must
        ---- already exist in SAP 

        SELECT @commitment_id = c.Id,
               @po_status = c.DocStatusId,
               @po_number = NULLIF(LTRIM(RTRIM(c.Reference)), ''),
               -- delivery date: Commitment header Scheduled Delivery Date (DD.MM.YYYY), same as PO Create
               @co_delivery_date = CONVERT(VARCHAR(10), c.ScheduledDeliveryDate, 104)
        FROM dbo.CostManagement_CommitmentCOs co
        JOIN dbo.CostManagement_Commitments c ON c.Id = co.CommitmentId
        WHERE co.Id = @TRAN_ID;

        IF @commitment_id IS NULL OR ISNULL(@po_status, 0) <> 5 OR @po_number IS NULL OR LEN(@po_number) > 10
        BEGIN
            SET @ERROR_DESC = CASE
                WHEN @commitment_id IS NULL THEN 'The Change Order is not linked to a Commitment (PO).'
                WHEN ISNULL(@po_status, 0) <> 5 THEN 'The Commitment (PO) of this Change Order is not approved.'
                WHEN @po_number IS NULL THEN 'The Commitment (PO) of this Change Order has no SAP PO number - it was never created in SAP.'
                ELSE 'The SAP PO number on the Commitment (' + @po_number + ') is longer than 10 characters.'
            END;

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

        ----------Highest SAP item number on the PO---------
        ---- dbo.xx_sap_po_line_ref_tbl: PO items (written by PO Create) + items added by earlier VOs

        SELECT @max_po_item = MAX(TRY_CAST(r.po_item AS INT))
        FROM dbo.xx_sap_po_line_ref_tbl r
        WHERE r.commitment_id = @commitment_id;

        -----------  Stage Header Data -----------------------------------

        BEGIN TRY

            INSERT INTO dbo.xx_changeorder_hdr_stg_tbl_ob
                (po_number, sap_po_id, change_order_id,
                 process_status, operation_flag, creation_date, last_update_date)
            SELECT
                @po_number,
                NULL,
                co.Id,
                'N', 'U', GETDATE(), GETDATE()
            -- joins kept: the header is staged only when the PO and its project exist
            FROM dbo.CostManagement_CommitmentCOs co
            JOIN dbo.CostManagement_Commitments c ON c.Id = co.CommitmentId
            JOIN dbo.Projects proj ON proj.Id = c.ProjectId
            WHERE co.Id = @TRAN_ID;

            IF @@ROWCOUNT = 0
            BEGIN
                SET @ERROR_DESC = 'Could not stage header for CostManagement_CommitmentCOs ' + CAST(@TRAN_ID AS VARCHAR(20)) + '.';

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
                -- Same resolution as PO Create / PR - SAP code taken from Code directly per
                -- SHK_INT_SAPCOSTCODE_IB_PRC procedure.
                SELECT w.Id, w.ParentId,
                    ResolvedCode = w.Code
                FROM dbo.WBS w
            ),
            CoLine AS (
                SELECT
                    l.Id, l.LineNumber, l.Description, l.UOMId, l.CostCodeId, l.UnitCostApproved,
                    l.CommitmentDetailId,
                    WBSId = NULLIF(l.WBSId, 0),
                    QtyDelta = ISNULL(l.Quantity, 0),
                    -- As ROSHN (RSH_INT_VARIATION): the VO line is linked to a PO line through CommitmentDetailId
                    -- -> change that PO line's SAP item; not linked -> new SAP item.
                    IsLinked = CASE WHEN ISNULL(l.CommitmentDetailId, 0) > 0 THEN 1 ELSE 0 END,
                    -- line delete box = CommitmentCODetails.Field1, ticked = 'True'; anything else (NULL, blank,
                    -- 'False') is not a delete
                    DeleteTicked = CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(l.Field1, '')))) = 'TRUE' THEN 1 ELSE 0 END,
                    -- Linked line, from PMWeb (as ROSHN): SAP item = the PO line's Field10; prior quantity =
                    -- PO line Quantity + earlier approved VOs (DocStatusId 5) on the same PO line; prior text =
                    -- the latest earlier approved VO line text on that PO line, else the PO line text
                    NULLIF(LTRIM(RTRIM(pd.Field10)), '') AS PoItem,
                    ISNULL(pd.Quantity, 0) + ISNULL(prevQty.Qty, 0) AS PriorQuantity,
                    COALESCE(prevText.ShortText, LEFT(LTRIM(RTRIM(ISNULL(pd.Description, ''))), 40)) AS PriorShortText
                FROM dbo.CostManagement_CommitmentCODetails l
                LEFT JOIN dbo.CostManagement_CommitmentDetails pd
                       ON pd.Id = l.CommitmentDetailId
                      AND pd.CommitmentId = @commitment_id
                      AND ISNULL(l.CommitmentDetailId, 0) > 0
                OUTER APPLY (
                    SELECT SUM(ISNULL(o.Quantity, 0)) AS Qty
                    FROM dbo.CostManagement_CommitmentCODetails o
                    JOIN dbo.CostManagement_CommitmentCOs oc ON oc.Id = o.CommitmentCOId
                    WHERE o.CommitmentDetailId = pd.Id
                      AND oc.Id <> @TRAN_ID
                      AND oc.DocStatusId = 5
                ) prevQty
                OUTER APPLY (
                    SELECT TOP 1 LEFT(LTRIM(RTRIM(o.Description)), 40) AS ShortText
                    FROM dbo.CostManagement_CommitmentCODetails o
                    JOIN dbo.CostManagement_CommitmentCOs oc ON oc.Id = o.CommitmentCOId
                    WHERE o.CommitmentDetailId = pd.Id
                      AND oc.Id <> @TRAN_ID
                      AND oc.DocStatusId = 5
                      AND LTRIM(RTRIM(ISNULL(o.Description, ''))) <> ''
                    ORDER BY oc.Id DESC, o.Id DESC
                ) prevText
                WHERE l.CommitmentCOId = @TRAN_ID
            )
            INSERT INTO dbo.xx_changeorder_line_stg_tbl_ob
                (hdr_record_id, line_action, po_item, delete_ind, short_text, mat_grp, plant, quantity,
                 po_unit, net_price, price_unit, tax_code, acctasscat, sched_line, delivery_date,
                 serial_no, wbs_element, gl_account, network, activity,
                 change_order_detail_id,
                 process_status, operation_flag, creation_date, last_update_date)
            SELECT
                @hdr_record_id,
                act.LineAction,
                -- ADD: next free item number after every item on the PO (register)[TBC]
                CASE WHEN act.LineAction = 'ADD'
                     THEN RIGHT('00000' + CAST(ISNULL(@max_po_item, 0)
                              + 10 * ROW_NUMBER() OVER (PARTITION BY act.LineAction ORDER BY cl.LineNumber, cl.Id)
                              AS VARCHAR(5)), 5)
                     ELSE cl.PoItem END,
                CASE WHEN act.LineAction = 'DELETE' THEN 'X' END,
                -- short_text: ADD always; UPDATE only when it differs (P4)
                CASE WHEN act.LineAction = 'ADD' THEN coText.ShortText
                     WHEN act.LineAction = 'UPDATE' AND coText.ShortText <> '' AND coText.ShortText <> ISNULL(cl.PriorShortText, '')
                         THEN coText.ShortText END,
                CASE WHEN act.LineAction = 'ADD' THEN 'S000001' END,       -- mat_grp: as PO Create
                CASE WHEN act.LineAction = 'ADD' THEN pgm.SpecField1 END,  -- plant: as PO Create
                -- quantity (as ROSHN, only the total is staged): ADD = the VO quantity; UPDATE = new total
                -- (register quantity + VO difference), only when the difference is not 0
                CASE WHEN act.LineAction = 'ADD' THEN cl.QtyDelta
                     WHEN act.LineAction = 'UPDATE' AND cl.QtyDelta <> 0 THEN act.NewQuantity END,
                CASE WHEN act.LineAction = 'ADD' THEN LTRIM(RTRIM(LEFT(uom.UOM, CHARINDEX(' - ', uom.UOM + ' - ') - 1))) END,
                -- P2 (PROVISIONAL): unit price on ADD lines only; no price change on UPDATE lines yet
                CASE WHEN act.LineAction = 'ADD' THEN cl.UnitCostApproved END,
                CASE WHEN act.LineAction = 'ADD' THEN '1' END,
                CASE WHEN act.LineAction = 'ADD' AND LEN(taxres.TaxCode) = 2 THEN taxres.TaxCode END,
                CASE WHEN act.LineAction = 'ADD' THEN 'P' END,
                -- schedule line: every ADD / UPDATE line, with the Commitment header delivery date
                CASE WHEN act.LineAction IN ('ADD', 'UPDATE') THEN '0001' END,
                CASE WHEN act.LineAction IN ('ADD', 'UPDATE') THEN @co_delivery_date END,
                -- account row: ADD lines only (an account change on an existing item is not sent, P4)
                CASE WHEN act.SendAccount = 1 THEN '01' END,
                CASE WHEN act.SendAccount = 1 THEN acct.WbsElement END,
                CASE WHEN act.SendAccount = 1 THEN pgm.SpecField6 END,
                CASE WHEN act.SendAccount = 1 THEN acct.Network END,
                CASE WHEN act.SendAccount = 1 THEN acct.Activity END,
                cl.Id,
                'N', 'U', GETDATE(), GETDATE()
            FROM CoLine cl
            JOIN dbo.CostManagement_CommitmentCOs co ON co.Id = @TRAN_ID
            JOIN dbo.CostManagement_Commitments c ON c.Id = co.CommitmentId
            JOIN dbo.Projects proj ON proj.Id = c.ProjectId
            JOIN dbo.Programs pgm ON pgm.Id = proj.ProgramId
            LEFT JOIN dbo.UOM uom ON uom.Id = cl.UOMId
            LEFT JOIN dbo.CostCodes cc ON cc.Id = cl.CostCodeId
            CROSS APPLY (
                SELECT ShortText = LEFT(LTRIM(RTRIM(ISNULL(cl.Description, ''))), 40)
            ) coText
            -- Tax code as PO Create: text before the first '-' of Commitments.SpecField1
            CROSS APPLY (
                SELECT LTRIM(RTRIM(LEFT(c.SpecField1, CHARINDEX('-', c.SpecField1 + '-') - 1))) AS TaxCode
            ) taxres
            -- Account as PO Create: a line with a WBSId -> Network + Activity only; without -> WBS element
            -- (CostCodes.Notes). The VO line has WBSId only (no ProjectWBSId).
            OUTER APPLY (
                SELECT TOP 1 wc.Id, wc.ParentId, wc.ResolvedCode
                FROM WbsCode wc
                WHERE wc.Id = cl.WBSId
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
                    WbsElement = CASE WHEN cl.WBSId IS NULL THEN ISNULL(cc.Notes, '') ELSE '' END,
                    Network = CASE WHEN cl.WBSId IS NOT NULL THEN ISNULL(
                        CASE
                            WHEN selfFlags.IsNumeric = 1 AND selfFlags.CodeLen = 12 THEN selfCode.ResolvedCode
                            WHEN selfFlags.IsNumeric = 1 AND selfFlags.CodeLen <> 12 THEN parentCode.ResolvedCode
                            WHEN selfFlags.IsNumeric = 0 AND networkChild.ResolvedCode IS NOT NULL THEN networkChild.ResolvedCode
                        END, '') ELSE '' END,
                    Activity = CASE WHEN cl.WBSId IS NOT NULL THEN ISNULL(
                        CASE
                            WHEN selfFlags.IsNumeric = 1 AND selfFlags.CodeLen <> 12 THEN selfCode.ResolvedCode
                            WHEN selfFlags.IsNumeric = 1 AND selfFlags.CodeLen = 12 THEN activityChild.ResolvedCode
                            WHEN selfFlags.IsNumeric = 0 AND networkChild.ResolvedCode IS NOT NULL THEN activityChild.ResolvedCode
                        END, '') ELSE '' END
            ) acct
            CROSS APPLY (
                SELECT
                    NewQuantity = cl.PriorQuantity + cl.QtyDelta,
                    LineAction = CASE WHEN cl.DeleteTicked = 1 THEN 'DELETE'
                                      WHEN cl.IsLinked = 0 THEN 'ADD' ELSE 'UPDATE' END,
                    -- account row on ADD lines only; an account change of an existing item is not sent
                    SendAccount = CASE WHEN cl.DeleteTicked = 0 AND cl.IsLinked = 0 THEN 1 ELSE 0 END
            ) act;

            IF @@ROWCOUNT = 0
            BEGIN
                DELETE FROM dbo.xx_changeorder_hdr_stg_tbl_ob WHERE record_id = @hdr_record_id;

                SET @ERROR_DESC = 'No line rows staged for Change Order ' + CAST(@TRAN_ID AS VARCHAR(20)) + ' (record_id=' + CAST(@hdr_record_id AS VARCHAR(20)) + ').';

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

        ----------Line Validation---------
     

        SET @bad_lines = NULL;

        SELECT @bad_lines = ISNULL(@bad_lines + ' ', '') + x.Msg
        FROM (
            -- every ADD / UPDATE line sends the Commitment header delivery date
            SELECT 0 AS Ord, CASE WHEN @co_delivery_date IS NULL AND EXISTS (
                        SELECT 1 FROM dbo.xx_changeorder_line_stg_tbl_ob
                        WHERE hdr_record_id = @hdr_record_id AND line_action IN ('ADD', 'UPDATE'))
                      THEN 'Delivery date missing (Scheduled Delivery Date on the Commitment).' END AS Msg
            UNION ALL
            -- the line points to a PO line that has no SAP item in the register
            SELECT 1, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                WHERE l.hdr_record_id = @hdr_record_id AND l.line_action IN ('UPDATE', 'DELETE') AND l.po_item IS NULL
                  AND ISNULL(d.CommitmentDetailId, 0) > 0
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': the PO line it changes has no SAP item number (not created in SAP).'
            UNION ALL
            -- delete box ticked on a line that points to no PO item
            SELECT 9, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                WHERE l.hdr_record_id = @hdr_record_id AND l.line_action = 'DELETE'
                  AND ISNULL(d.CommitmentDetailId, 0) = 0
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': the delete box is ticked but the line is not linked to a PO line.'
            UNION ALL
            -- an item an earlier Change Order deleted cannot be changed or deleted again
            SELECT 10, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                WHERE l.hdr_record_id = @hdr_record_id AND l.line_action IN ('UPDATE', 'DELETE')
                  AND EXISTS (SELECT 1
                              FROM dbo.CostManagement_CommitmentCODetails o
                              JOIN dbo.CostManagement_CommitmentCOs oc ON oc.Id = o.CommitmentCOId
                              WHERE o.CommitmentDetailId = d.CommitmentDetailId
                                AND oc.Id <> @TRAN_ID
                                AND oc.DocStatusId = 5
                                -- delete box of the earlier VO line (Field1 = 'True')
                                AND UPPER(LTRIM(RTRIM(ISNULL(o.Field1, '')))) = 'TRUE')
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': the PO item was already deleted in SAP by an earlier Change Order.'
            UNION ALL
            -- an item deleted on one line cannot be changed on another line of the same VO
            SELECT 11, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                WHERE l.hdr_record_id = @hdr_record_id AND l.po_item IS NOT NULL
                  AND l.line_action IN ('UPDATE', 'DELETE')
                  AND EXISTS (SELECT 1 FROM dbo.xx_changeorder_line_stg_tbl_ob o
                              WHERE o.hdr_record_id = @hdr_record_id AND o.po_item = l.po_item
                                AND o.record_id <> l.record_id
                                AND (o.line_action = 'DELETE' OR l.line_action = 'DELETE'))
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': the same PO item is deleted on one line and changed or deleted on another.'
            UNION ALL
            -- P4 (as ROSHN): a line linked to a PO line must have the cost code of that PO line
            -- (ROSHN does not compare the WBS; an account change is not sent anyway)
            SELECT 2, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                JOIN dbo.CostManagement_CommitmentDetails pd ON pd.Id = d.CommitmentDetailId
                WHERE l.hdr_record_id = @hdr_record_id AND l.line_action = 'UPDATE' AND l.po_item IS NOT NULL
                  AND ISNULL(d.CostCodeId, 0) <> ISNULL(pd.CostCodeId, 0)
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': the cost code differs from the PO line it changes - lines linked to a PO line must have the same cost code.'
            UNION ALL
            -- As ROSHN: new (unlinked) lines must have a distinct Cost Code + Description + WBS
            -- (ROSHN also groups by item category - Shaker has none; RFC-linked lines excluded as in ROSHN)
            SELECT 12, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.CostManagement_CommitmentCODetails d
                WHERE d.CommitmentCOId = @TRAN_ID
                  AND ISNULL(d.CommitmentDetailId, 0) = 0 AND ISNULL(d.ChangeRequestDetailId, 0) = 0
                  AND EXISTS (SELECT 1 FROM dbo.CostManagement_CommitmentCODetails o
                              WHERE o.CommitmentCOId = @TRAN_ID AND o.Id <> d.Id
                                AND ISNULL(o.CommitmentDetailId, 0) = 0 AND ISNULL(o.ChangeRequestDetailId, 0) = 0
                                AND ISNULL(o.CostCodeId, 0) = ISNULL(d.CostCodeId, 0)
                                AND ISNULL(o.Description, '') = ISNULL(d.Description, '')
                                AND ISNULL(NULLIF(o.WBSId, 0), 0) = ISNULL(NULLIF(d.WBSId, 0), 0))
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': new lines must have a distinct combination of Cost Code, Description and WBS.'
            UNION ALL
            -- P3 FLAGGED: new total exactly 0 - rejected until decided (an item is deleted only with the delete box)
            SELECT 8, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                WHERE l.hdr_record_id = @hdr_record_id AND l.line_action = 'UPDATE' AND l.po_item IS NOT NULL
                  AND l.quantity = 0
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': the new quantity of the PO item would be 0 - not supported.'
            UNION ALL
            -- P3: new total below zero
            SELECT 3, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                WHERE l.hdr_record_id = @hdr_record_id AND l.line_action = 'UPDATE' AND l.po_item IS NOT NULL
                  AND l.quantity < 0
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': the quantity reduction is larger than the PO quantity.'
            UNION ALL
            --  a negative / zero line must change an existing PO line
            SELECT 4, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                WHERE l.hdr_record_id = @hdr_record_id AND l.line_action = 'ADD' AND ISNULL(l.quantity, 0) <= 0
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': a zero or negative quantity must be linked to an existing PO line.'
            UNION ALL
            --  a linked line that changes nothing
            SELECT 5, 'Line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                WHERE l.hdr_record_id = @hdr_record_id AND l.line_action = 'UPDATE' AND l.po_item IS NOT NULL
                  AND l.quantity IS NULL AND l.short_text IS NULL AND l.net_price IS NULL
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': nothing to change on the PO item (no quantity or text difference).'
            UNION ALL
            -- ADD lines need what a PO Create line needs
            SELECT 6, 'New line(s) ' + STUFF((
                SELECT ', ' + CAST(d.LineNumber AS VARCHAR(10))
                FROM dbo.xx_changeorder_line_stg_tbl_ob l
                JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
                WHERE l.hdr_record_id = @hdr_record_id AND l.line_action = 'ADD' AND l.quantity > 0
                  AND (ISNULL(l.short_text, '') = '' OR ISNULL(l.po_unit, '') = '' OR ISNULL(l.net_price, 0) <= 0
                       OR l.tax_code IS NULL)
                ORDER BY d.LineNumber
                FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 2, '')
                + ': description, UOM, approved unit cost > 0 and tax code (Commitment SpecField1, e.g. ''V2-...'') are required.'
            UNION ALL
            SELECT 7, CASE WHEN @max_po_item IS NULL AND EXISTS (
                        SELECT 1 FROM dbo.xx_changeorder_line_stg_tbl_ob
                        WHERE hdr_record_id = @hdr_record_id AND line_action = 'ADD')
                      THEN 'The SAP item numbers of the PO are not known (no rows in xx_sap_po_line_ref_tbl), so no item can be added.' END
        ) x
        WHERE x.Msg IS NOT NULL
        ORDER BY x.Ord;

        IF @bad_lines IS NOT NULL
        BEGIN
            SET @ERROR_DESC = @bad_lines;

            UPDATE dbo.xx_changeorder_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_changeorder_line_stg_tbl_ob
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
            RETURN -5;
        END

        ----------Account Assignment Validation---------
        ---- Same rule as PO Create, for every line that sends an account row: WBS element only, or
        ---- Network + Activity only; a WBSId with children (a Network or WBS group node) is rejected.

        SET @acct_error = NULL;

        IF EXISTS (
            SELECT 1
            FROM dbo.xx_changeorder_line_stg_tbl_ob l
            JOIN dbo.CostManagement_CommitmentCODetails d ON d.Id = l.change_order_detail_id
            WHERE l.hdr_record_id = @hdr_record_id
              AND l.serial_no IS NOT NULL
              AND NULLIF(d.WBSId, 0) IS NOT NULL
              AND EXISTS (SELECT 1 FROM dbo.WBS c WHERE c.ParentId = d.WBSId)
        )
            SET @acct_error = 'PO can be created either at WBS level or at Activity level. Please select correct activity';

        SET @bad_lines = STUFF((
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
            FROM dbo.xx_changeorder_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id
              AND l.serial_no IS NOT NULL
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

        IF @acct_error IS NULL AND @bad_lines IS NOT NULL
            SET @acct_error = 'Invalid account assignment on item(s): ' + @bad_lines
                + '. Each line needs either a Cost Code whose Notes holds the SAP WBS element (WBS left blank),'
                + ' or a WBS selection that is an Activity under a Network.';

        IF @acct_error IS NOT NULL
        BEGIN
            SET @ERROR_DESC = @acct_error;

            UPDATE dbo.xx_changeorder_hdr_stg_tbl_ob
            SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
            WHERE record_id = @hdr_record_id;

            UPDATE dbo.xx_changeorder_line_stg_tbl_ob
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
        FROM dbo.xx_changeorder_hdr_stg_tbl_ob
        WHERE record_id = @hdr_record_id;

        IF @API_STATUS = 'S' AND @sap_po_id IS NOT NULL
        BEGIN
            UPDATE dbo.xx_integration_tbl
            SET status = 'S', error_msg = 'Change Order sent successfully, SAP PO ' + @sap_po_id + ' changed', last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            -- Items added: SAP item numbers kept in the register (as ROSHN xx_erp_po_line_num_tbl)
            INSERT INTO dbo.xx_sap_po_line_ref_tbl
                (commitment_id, po_number, po_item, change_order_id, change_order_detail_id, creation_date)
            SELECT @commitment_id, @po_number, l.po_item, @TRAN_ID, l.change_order_detail_id, GETDATE()
            FROM dbo.xx_changeorder_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id AND l.line_action = 'ADD';

            --  SAP PO number on the VO header, SAP item on each VO line
            UPDATE dbo.CostManagement_CommitmentCOs
            SET Reference = @sap_po_id
            WHERE Id = @TRAN_ID;

            UPDATE d
            SET d.Field10 = l.po_item
            FROM dbo.CostManagement_CommitmentCODetails d
            JOIN dbo.xx_changeorder_line_stg_tbl_ob l ON l.change_order_detail_id = d.Id
            WHERE l.hdr_record_id = @hdr_record_id
              AND d.CommitmentCOId = @TRAN_ID;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 7
                    ,@DeliveredToStepId = 0
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = 'Change Order sent to SAP successfully'
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = 0;
                EXEC dbo.Workflow_UpdateWorkflowDocumentStatus @DocumentId = @DocumentId, @ActionTypeId = 7, @StepId = @CurrStepId, @UserId = 5, @ChangeLastAction = 0;
            END

            SELECT 'Change Order sent successfully' AS Message, @sap_po_id AS SapPoId, @hdr_record_id AS HdrRecordId;
        END
        ELSE
        BEGIN
            SET @ERROR_DESC = ISNULL(@con_error, 'Change Order API call did not return a success status.')
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
        SET @ErrorDesc = 'Unexpected exception in Change Order procedure';
        SET @ERROR_DESC = @ErrorDesc + ': ' + @ErrorMessage;

        INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
        VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, CAST(@TRAN_ID AS VARCHAR(100)), GETDATE(), @ErrorDesc);

        -- Re-read from staging: the error may have happened after SAP accepted the change
        IF @hdr_record_id > 0
            SELECT @sap_po_id = NULLIF(LTRIM(RTRIM(sap_po_id)), '')
            FROM dbo.xx_changeorder_hdr_stg_tbl_ob
            WHERE record_id = @hdr_record_id;

        IF @sap_po_id IS NULL
        BEGIN
            -- SAP did not accept it: same handling as the other errors, back to the submitter
            IF @hdr_record_id > 0
            BEGIN
                UPDATE dbo.xx_changeorder_hdr_stg_tbl_ob
                SET process_status = 'E', error_msg = LEFT(@ERROR_DESC, 2000), last_update_date = GETDATE()
                WHERE record_id = @hdr_record_id;

                UPDATE dbo.xx_changeorder_line_stg_tbl_ob
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

        -- SAP already accepted the change: finish the success steps that the error interrupted
        -- (never send it back - a resubmit would add the differences a second time)
        BEGIN TRY
            UPDATE dbo.xx_integration_tbl
            SET status = 'S', error_msg = 'Change Order sent successfully, SAP PO ' + @sap_po_id
                + ' changed (completed after error: ' + @ErrorMessage + ')', last_update_date = GETDATE()
            WHERE tran_id = @TRAN_ID AND tran_type = @txn_type;

            INSERT INTO dbo.xx_sap_po_line_ref_tbl
                (commitment_id, po_number, po_item, change_order_id, change_order_detail_id, creation_date)
            SELECT @commitment_id, @po_number, l.po_item, @TRAN_ID, l.change_order_detail_id, GETDATE()
            FROM dbo.xx_changeorder_line_stg_tbl_ob l
            WHERE l.hdr_record_id = @hdr_record_id AND l.line_action = 'ADD'
              AND NOT EXISTS (SELECT 1 FROM dbo.xx_sap_po_line_ref_tbl r
                              WHERE r.commitment_id = @commitment_id AND r.po_item = l.po_item);

            UPDATE dbo.CostManagement_CommitmentCOs
            SET Reference = @sap_po_id
            WHERE Id = @TRAN_ID;

            UPDATE d
            SET d.Field10 = l.po_item
            FROM dbo.CostManagement_CommitmentCODetails d
            JOIN dbo.xx_changeorder_line_stg_tbl_ob l ON l.change_order_detail_id = d.Id
            WHERE l.hdr_record_id = @hdr_record_id
              AND d.CommitmentCOId = @TRAN_ID;

            IF @DocumentId IS NOT NULL
            BEGIN
                EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 7
                    ,@DeliveredToStepId = 0
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = 'Change Order sent to SAP successfully'
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

                EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId = @DocumentId;
                EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId = @DocumentId, @CurrentPendingStepId = 0;
                EXEC dbo.Workflow_UpdateWorkflowDocumentStatus @DocumentId = @DocumentId, @ActionTypeId = 7, @StepId = @CurrStepId, @UserId = 5, @ChangeLastAction = 0;
            END

            SELECT 'Change Order sent successfully (completed after error: ' + @ErrorMessage + ')' AS Message,
                   @sap_po_id AS SapPoId, @hdr_record_id AS HdrRecordId;
            RETURN -9;  -- same code for every unexpected error ; the message tells the cases apart
        END TRY
        BEGIN CATCH
            -- Completion failed : Do NOT re-run this Change Order; the duplicate guard blocks it anyway
            -- because the staging header keeps the sap_po_id. The register may now be behind SAP.
            SET @ErrorMessage = ERROR_MESSAGE();
            SET @ErrorDesc = 'Change Order accepted by SAP (PO ' + @sap_po_id + ') but completion failed - complete manually (incl. xx_sap_po_line_ref_tbl), do not re-send';

            INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber, ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate, ErrorDesc)
            VALUES (ERROR_NUMBER(), ERROR_PROCEDURE(), ERROR_LINE(), @ErrorMessage, CAST(@TRAN_ID AS VARCHAR(100)), GETDATE(), @ErrorDesc);

            -- status stays 'S' (SAP holds the change); the message shows it still needs completing
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
