USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_START_INTEGRATION]    Script Date: 10/28/2026 8:13:53 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE   PROCEDURE [dbo].[SHK_INT_START_INTEGRATION]

AS 
BEGIN
	SET NOCOUNT ON;
	
	---Delete records stuck in I status
	DELETE xx_integration_tbl 
	FROM xx_integration_tbl a
	where status='I'
	and exists (select 1 from xx_integration_tbl x
				where tran_id=a.tran_id and tran_type_id=a.tran_type_id
				and status in ('S','E')
				)

	DELETE xx_integration_tbl
	WHERE status = 'E'
	AND wf_document_id IN (
							Select wd.Id 
							From  dbo.Workflow_Documents wd
									,dbo.Workflow_DocumentStepRoles wdsr
							where wd.CurrentPendingStepId = wdsr.DocumentStepId
							and wdsr.RoleName IN ( 'Integration User', 'Integration Admin')
							)
	
	INSERT INTO xx_integration_tbl 
						(wf_document_id,
						wf_curr_step_id,
						wf_prev_step_id,
						tran_id ,
						tran_type_id,
						tran_type,
						procedure_name,
						status,
						create_date) 
	(
	Select wd.Id 
		, wd.CurrentPendingStepId
		, wdsa.DocumentStepId 
		, wd.RecordId
		, wrt.Id 
		, wrt.RecordName
		,CASE WHEN wrt.RecordName = 'Budgets' THEN 'ALF_SAP_INT_BUDGET'
		 WHEN wrt.RecordName = 'BudgetRequests' THEN 'ALF_SAP_INT_BUDGET_TRF'
		 WHEN wrt.RecordName = 'PREBID' THEN 'SHK_INT_PROJECTREQUISITION_OB_PRC'
		 WHEN wrt.RecordName = 'Commitments' THEN 'SHK_INT_PURCHASEORDER_OB_PRC'
		 WHEN wrt.RecordName = 'CommitmentCOs' THEN 'SHK_INT_CHANGEORDER_OB_PRC'
		 WHEN wrt.RecordName = 'ONLINECHANGEREQUESTS' THEN 'ALF_SAP_INT_RFC'
		 WHEN wrt.RecordName = 'ProgressInvoices' THEN 'ALF_SAP_INT_GRN'
		 END 
		,'N'
		,GETDATE()
		From  dbo.Workflow_Documents wd
			 ,dbo.Workflow_DocumentStepRoles wdsr
			 ,dbo.Workflow_RecordTypes wrt
			 ,dbo.Workflow_DocumentStepActions wdsa
		where wd.CurrentPendingStepId = wdsr.DocumentStepId
		and wd.RecordTypeId = wrt.Id
		and wdsa.DeliveredToStepId = wd.CurrentPendingStepId 
		and wdsr.RoleName IN ( 'Integration User', 'Integration Admin')
		and wrt.RecordName in ('Budgets','BudgetRequests','PREBID','Commitments','CommitmentCOs','ONLINECHANGEREQUESTS' ,'ProgressInvoices')
		and not exists (select 1
						from  xx_integration_tbl x
						where wf_document_id = wd.Id
						and status IN ('N','I')
						and cast(x.create_date as date) = cast(GETDATE() as date)
						)
	)

	SET NOCOUNT OFF;
END
GO


