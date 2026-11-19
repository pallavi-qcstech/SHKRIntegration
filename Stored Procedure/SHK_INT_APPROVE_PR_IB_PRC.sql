USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_APPROVE_PR_IB_PRC]    Script Date: 11/19/2026 2:04:17 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO







CREATE   PROC [dbo].[SHK_INT_APPROVE_PR_IB_PRC]
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
,@BASE_URL NVARCHAR(200) = 'http://localhost:8080/SHKRIntegration/api/Inbound/prstatus'

SET @ERROR_DESC=''
SET @ERROR_STATUS=0


IF CURSOR_STATUS('global','bid_cursor')>=-1  
	BEGIN  
	 DEALLOCATE bid_cursor 
	END  


DECLARE bid_cursor CURSOR FOR 
	select record_id,wf_document_id,wf_curr_step_id,wf_prev_step_id,tran_id
		from xx_integration_tbl
		where tran_type = 'PREBID'
		and status = 'P' ---pending for erp approval status
		and (erp_txn_number is not null and erp_txn_number <> '')

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
			SET status = 'S', error_msg = 'PR Approved'
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
	ELSE
		BEGIN 
			UPDATE xx_integration_tbl
			SET status = 'E', error_msg = @ERROR_DESC
			WHERE record_id = @record_id
				
			--Return workflow to previous approver 
			EXEC dbo.Workflow_ExecuteDocumentAction
                    @StepActionGUID = '00000000-0000-0000-0000-000000000000'
                    ,@ActionTypeId = 3
                    ,@DeliveredToStepId = @PrevStepId
                    ,@DelegateToIds = N'0'
                    ,@TeamInputIds = N'0'
                    ,@DocumentId = @DocumentId
                    ,@ActionComment = @erp_approval_comments
                    ,@UserId = 5
                    ,@TeamInputCanEditRecord = 0
                    ,@TeamInputCanEditNotes = 0
                    ,@TeamInputCanEditAttachments = 0
                    ,@ActionSource = N'Website';

			EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId=@DocumentId
			EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId=@DocumentId,@CurrentPendingStepId=@PrevStepId
			EXEC dbo.Workflow_RecalculateDueDate @DocumentId=@DocumentId
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

