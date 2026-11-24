USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_BUDGETREQUEST_OB_PRC]    Script Date: 11/24/2026 6:13:53 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE PROC [dbo].[SHK_INT_BUDGETREQUEST_OB_PRC] @TRAN_ID BIGINT
AS

SET XACT_ABORT ON
DECLARE @ERROR_DESC VARCHAR(MAX);  
DECLARE @ERROR_STATUS INT;


BEGIN
SET NOCOUNT ON
 
--BEGIN TRAN
--Error variables  
SELECT @ERROR_STATUS=0,@ERROR_DESC=''

DECLARE   
@Id AS BIGINT
,@recordid AS BIGINT
,@budget_id BIGINT
,@budget_line_id BIGINT
,@budget_name NVARCHAR(250)
,@project_name NVARCHAR(250)
,@project_unit NVARCHAR(250)
,@organization NVARCHAR(250)
,@Active_flag NVARCHAR(1)
,@operation_flag NVARCHAR(1)
,@IsActive INT
,@ProjectId bigint
,@erp_project varchar(10)
,@approve_wf int
,@reject_wf int
,@cnt_hdr int
,@cnt_line int
,@cnt_api_error int

---workflow variable
,@PrevStepId BIGINT
,@CurrStepId BIGINT
,@DocumentId BIGINT
,@TranType NVARCHAR(250) = 'BudgetRequests'

---Delete duplicate records and keep only latest record
DELETE xx_budget_line_stg_tbl_ob
WHERE hdr_record_id IN (SELECT record_id  
						FROM xx_budget_hdr_stg_tbl_ob a
						WHERE a.pmweb_budget_id = @TRAN_ID
						and attribute1 = @TranType
						AND a.process_status <> 'S')

DELETE xx_budget_hdr_stg_tbl_ob 
FROM xx_budget_hdr_stg_tbl_ob a
WHERE a.process_status <> 'S'
AND a.pmweb_budget_id = @TRAN_ID
and attribute1 = @TranType

--get workflow document id
SELECT @PrevStepId = wf_prev_step_id, @CurrStepId = wf_curr_step_id, @DocumentId = wf_document_id
FROM xx_integration_tbl
WHERE tran_id = @TRAN_ID
AND tran_type = @TranType


print 'inserting  header ' 
BEGIN TRY
INSERT INTO xx_budget_hdr_stg_tbl_ob (pmweb_budget_id, project_code, project_id, sap_network, creation_date, process_status,attribute1)
(
select distinct @TRAN_ID, p.ProjectNumber,p.Id,n.Code,GETDATE(),'N',@TranType
from dbo.CostManagement_BudgetDetails l
	,dbo.CostManagement_Budgets h
	,dbo.Projects p
	,dbo.WBS n
	,dbo.WBS a
	,dbo.WBSConfiguration wc
where 1=1
and h.Id = @TRAN_ID
and l.BudgetId = h.Id
and h.ProjectId = p.Id
and p.Id = wc.ProjectId
and n.ConfigurationId = wc.Id
and l.WBSId = a.Id
and a.ParentId = n.Id
and a.Description like '%(A)%'
and n.Description like '%(N)%'
)

set @cnt_hdr = @@rowcount
print 'record inserted after hdr'
print @cnt_hdr

IF @cnt_hdr=0
	BEGIN
		SET @ERROR_DESC = 'Error in inserting in budget header staging table in PMWeb'
		
		--return the workflow
		UPDATE xx_integration_tbl
		SET status = 'E', error_msg = @ERROR_DESC
		WHERE tran_id = @TRAN_ID
		AND tran_type = @TranType

		--Return workflow to previous approver 
		EXEC [dbo].[Workflow_ExecuteDocumentAction]
					@StepActionGUID = '00000000-0000-0000-0000-000000000000'
					,@ActionTypeId = 3
					,@DeliveredToStepId = @PrevStepId
					,@DelegateToIds =N'0'
					,@TeamInputIds =N'0'
					,@DocumentId = @DocumentId
					,@ActionComment = @ERROR_DESC
					,@UserId = 5
					,@TeamInputCanEditRecord = 0
					,@TeamInputCanEditNotes = 0
					,@TeamInputCanEditAttachments =0
					,@ActionSource = N'Website'

		EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId=@DocumentId
		EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId=@DocumentId,@CurrentPendingStepId=@PrevStepId
		EXEC dbo.Workflow_RecalculateDueDate @DocumentId=@DocumentId
		RETURN -1
	END


INSERT INTO xx_budget_line_stg_tbl_ob (hdr_record_id,pmweb_budget_id, sap_activity
		,sap_activity_desc,sap_control_key,sap_plant,sap_wbs_element,price_unit,price
		,creation_date, process_status,attribute1)
	(
	select x.record_id,@tran_id, a.Code --activity_code
		,SUBSTRING(a.Description,1,CHARINDEX('(', a.Description)-1)-- activity_desc
		,SUBSTRING(n.Description,CHARINDEX('|', n.Description) + 1, 4) --control_key
		,'1010' --plant
		,wbs_ele.Code --wbs_element
		,1 --priceunit
		,sum(l.ExtCost)-- price
		,GETDATE(),'N',@TranType
	from dbo.CostManagement_BudgetDetails l
		,dbo.CostManagement_Budgets h
		,dbo.Projects p
		,dbo.WBS n
		,dbo.WBS a
		,dbo.WBS wbs_ele
		,dbo.WBSConfiguration wc
		,xx_budget_hdr_tbl_ib x
	where 1=1
	and h.Id = @TRAN_ID
	and l.BudgetId = h.Id
	and h.ProjectId = p.Id
	and p.Id = wc.ProjectId
	and n.ConfigurationId = wc.Id
	and l.WBSId = a.Id
	and a.ParentId = n.Id
	and n.ParentId = wbs_ele.Id
	and a.Description like '%(A)%'
	and n.Description like '%(N)%'
	and x.pmweb_budget_id = @TRAN_ID
	and x.sap_network = n.Code
	and x.process_status = 'N'
	group by n.Code 
		, a.Code 
		,SUBSTRING(n.Description,1,CHARINDEX('(', n.Description)-1) 
		,wbs_ele.Code 
		,SUBSTRING(n.Description,CHARINDEX('|', n.Description) + 1, 4) 
	)

SET @cnt_line = @@ROWCOUNT
IF  @cnt_line > 0
	SET @ERROR_STATUS = 0
ELSE
	SET @ERROR_STATUS=1

END TRY
BEGIN CATCH
	SET @ERROR_DESC = ERROR_MESSAGE()+'Error in inserting data in staging tables.'
	SET @ERROR_STATUS = 1
END CATCH

print 'After line insert, cnt = ' print @cnt_line
IF @ERROR_STATUS = 0
	BEGIN
		DECLARE @MSG VARCHAR(MAX), @URL NVARCHAR(250),@API_STATUS VARCHAR(10), @ERP_REF_ID VARCHAR(10)
		SET @MSG=''
		print 'Calling API'
		
		SELECT @URL=CONCAT('http://10.12.36.5:8036/ERPIntegration/api/Outbound/BudgetCreate?headerId=',@recordid) --New Prod
		EXEC SHK_INT_APICALL_PRC @URL,@MSG OUTPUT
					
		SET @cnt_api_error = (select count(*) from xx_budget_hdr_stg_tbl_ob where pmweb_budget_id=@recordid
								and process_status in ('E','N')
								)

		IF @cnt_api_error=0
			BEGIN
				UPDATE dbo.CostManagement_Budgets SET SpecField1 = 'S' WHERE Id = @tran_id
				UPDATE dbo.CostManagement_BudgetDetails SET Field10 = 'S' WHERE BudgetId = @tran_id
			END
		ELSE
			BEGIN
				SET @ERROR_DESC = @ERROR_DESC+@MSG
				SET @reject_wf = 1
			END
	END
ELSE
	BEGIN
		SET @ERROR_DESC = @ERROR_DESC+'.No lines inserted for this budget in staging table '+@erp_project
		SET @reject_wf = 1
	END

print @ERROR_DESC

END

print '@reject_wf=' print @reject_wf

IF @reject_wf = 1
BEGIN
	--return the workflow
	UPDATE xx_integration_tbl
	SET status = 'E', error_msg = @ERROR_DESC
	WHERE tran_id = @TRAN_ID
	AND tran_type = @TranType

	--Return workflow to previous approver 
	EXEC [dbo].[Workflow_ExecuteDocumentAction]
				@StepActionGUID = '00000000-0000-0000-0000-000000000000'
				,@ActionTypeId = 3
				,@DeliveredToStepId = @PrevStepId
				,@DelegateToIds =N'0'
				,@TeamInputIds =N'0'
				,@DocumentId = @DocumentId
				,@ActionComment = @ERROR_DESC
				,@UserId = 5
				,@TeamInputCanEditRecord = 0
				,@TeamInputCanEditNotes = 0
				,@TeamInputCanEditAttachments =0
				,@ActionSource = N'Website'

	EXEC dbo.Workflow_CalculateCurrentPendingStepId @DocumentId=@DocumentId
	EXEC dbo.Workflow_UpdateDocumentCurrentPendingStepId @DocumentId=@DocumentId,@CurrentPendingStepId=@PrevStepId
	EXEC dbo.Workflow_RecalculateDueDate @DocumentId=@DocumentId
END

ELSE
---approve the workflow
BEGIN
	print 'Budget integration successful'
	UPDATE xx_integration_tbl
	SET status = 'P', error_msg = 'Budget integration successful, awaiting approval from SAP'
	WHERE tran_id = @TRAN_ID
	AND tran_type = @TranType

END

SET NOCOUNT OFF

GO

