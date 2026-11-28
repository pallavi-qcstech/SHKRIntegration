USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_APPROVE_PO_IB_PRC]    Script Date: 11/26/2026 8:51:54 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO





CREATE   PROC [dbo].[SHK_INT_APPROVE_PO_IB_PRC]
AS

SET XACT_ABORT ON
DECLARE @ERROR_DESC VARCHAR(MAX);
DECLARE @ERROR_STATUS INT;


BEGIN
SET NOCOUNT ON
BEGIN TRY
--BEGIN TRAN
--Error variables
SELECT @ERROR_STATUS=0,@ERROR_DESC=''

DECLARE
@erp_req_number nvarchar(250),
@pmweb_id bigint,
@approved nvarchar(250),
@approved_by nvarchar(250),
@approval_comment nvarchar(max),
@approved_date date,
@record_id bigint,
@erp_approval_status nvarchar(250),
@erp_approval_comments nvarchar(2000)

---workflow variable
,@PrevStepId BIGINT
,@CurrStepId BIGINT
,@DocumentId BIGINT
,@tran_id BIGINT

,@hdr_record_id BIGINT = 0
,@URL NVARCHAR(500)
,@MSG VARCHAR(MAX)
,@BASE_URL NVARCHAR(200) = 'http://Shaker.pmweb.local:8080/SHKRIntegration/api/Inbound/postatus' ---26/11/26 host Shaker.pmweb.local (was localhost), the same as the PR/PO/CO outbound procedures
,@last_action_id BIGINT ---28/11/26 last workflow action before the Reject, to check PMWeb recorded it

SET @ERROR_DESC=''
SET @ERROR_STATUS=0


IF CURSOR_STATUS('global','bid_cursor')>=-1
    BEGIN
     DEALLOCATE bid_cursor
    END


DECLARE bid_cursor CURSOR FOR
    select record_id,wf_document_id,wf_curr_step_id,wf_prev_step_id,tran_id
        from xx_integration_tbl
        where tran_type = 'Commitments'
        and status = 'P' ---pending for erp approval status
        and (erp_txn_number is not null and erp_txn_number <> '')
        and exists (select 1 from dbo.Workflow_Documents wd 
                    where wd.Id = xx_integration_tbl.wf_document_id
                    and wd.CurrentPendingStepId = xx_integration_tbl.wf_curr_step_id)

open bid_cursor

FETCH NEXT FROM bid_cursor INTO @record_id,@DocumentId, @CurrStepId,@PrevStepId,@tran_id

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ERROR_STATUS=0
    SET @ERROR_DESC=''

    SELECT @URL = CONCAT(@BASE_URL, '?recordId=', @record_id);
    EXEC dbo.SHK_INT_APICALL_PRC @URL = @URL, @MSG = @MSG OUTPUT;

    SELECT @erp_approval_status = erp_approval_status, @erp_approval_comments = erp_approval_comments
    FROM dbo.xx_integration_tbl
    WHERE record_id = @record_id;

    IF @erp_approval_status = 'Approved'
        BEGIN
            UPDATE xx_integration_tbl
            SET status = 'S', error_msg = 'PO Approved'
            WHERE record_id = @record_id

            --Complete workflow
            EXEC [dbo].[Workflow_ExecuteDocumentAction]
                        @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                        ,@ActionTypeId = 7
                        ,@DeliveredToStepId = 0
                        ,@DelegateToIds =N'0'
                        ,@TeamInputIds =N'0'
                        ,@DocumentId = @DocumentId
                        ,@ActionComment = @erp_approval_comments
                        ,@UserId = 5
                        ,@TeamInputCanEditRecord = 0
                        ,@TeamInputCanEditNotes = 0
                        ,@TeamInputCanEditAttachments =0
                        ,@ActionSource = N'Website'


            EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId=@DocumentId
            EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId=@DocumentId,@CurrentPendingStepId=0
            EXEC dbo.Workflow_UpdateWorkflowDocumentStatus @DocumentId=@DocumentId,@ActionTypeId=7,@StepId=@CurrStepId,@UserId=5,@ChangeLastAction=0

        END
    ELSE IF @erp_approval_status = 'Rejected'
        BEGIN
            ---28/11/26 PO rejected in SAP = Reject the workflow (ActionTypeId 5), same as PR - no longer returned to the previous approver (ActionTypeId 3)
            SET @last_action_id = ISNULL((SELECT MAX(a.Id)
                                          FROM dbo.Workflow_DocumentStepActions a
                                          INNER JOIN dbo.Workflow_DocumentSteps s ON s.Id = a.DocumentStepId
                                          WHERE s.DocumentId = @DocumentId), 0)

            EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 5
                    ,@DeliveredToStepId = 0
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @erp_approval_comments
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

            ---28/11/26 only when PMWeb recorded the Reject (it writes nothing if Reject is not allowed on the step for user 5)
            IF EXISTS (SELECT 1
                       FROM dbo.Workflow_DocumentStepActions a
                       INNER JOIN dbo.Workflow_DocumentSteps s ON s.Id = a.DocumentStepId
                       WHERE s.DocumentId = @DocumentId
                       AND a.Id > @last_action_id
                       AND a.ActionTypeId = 5)
                BEGIN
                    UPDATE xx_integration_tbl
                    SET status = 'E', error_msg = 'PO Rejected'
                    WHERE record_id = @record_id

                    EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId=@DocumentId
                    EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId=@DocumentId,@CurrentPendingStepId=0
                    EXEC dbo.Workflow_UpdateWorkflowDocumentStatus @DocumentId=@DocumentId,@ActionTypeId=5,@StepId=@CurrStepId,@UserId=5,@ChangeLastAction=0
                END
            ELSE
                BEGIN
                    ---28/11/26 workflow not changed; row stays P
                    UPDATE xx_integration_tbl
                    SET error_msg = 'PO Rejected in SAP, but PMWeb did not record the Reject action (Reject not allowed on this step for user 5?). Workflow not changed.'
                    WHERE record_id = @record_id
                END
        END


FETCH NEXT FROM bid_cursor INTO @record_id,@DocumentId, @CurrStepId,@PrevStepId,@tran_id

END

CLOSE bid_cursor;
DEALLOCATE bid_cursor;


END TRY

BEGIN CATCH

    IF @@TRANCOUNT>0
        ROLLBACK TRAN;

    IF(LEN(@ERROR_DESC)>0)
        BEGIN
        SELECT @ERROR_DESC
        END
    ELSE
        BEGIN
        SELECT ERROR_MESSAGE() as 'Message'
        END
END CATCH

SET NOCOUNT OFF
END

GO

