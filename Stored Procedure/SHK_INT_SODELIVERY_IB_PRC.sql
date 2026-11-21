USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_SODELIVERY_IB_PRC]    Script Date: 11/21/2026 6:30:50 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



CREATE     PROC [dbo].[SHK_INT_SODELIVERY_IB_PRC] 
AS

SET XACT_ABORT ON
DECLARE @ERROR_DESC VARCHAR(MAX);  
DECLARE @ERROR_STATUS INT;


BEGIN
/* 
Procedure which is called from SO Delivery scheduled service
It picks all new data from staging table (process_status=N) and creates/updates production and production details in PMWeb

1. Check the delivery number (Reference field), if it does not exist , create a new record. If its forst delivery use AddProduction, if not then use AddNextProduction
2. If delivery number exists in PMWeb, update production lines. If delivered qty = total scheduled qty then mark as done
3. If the delivery status is pending, deliveredqty and pickedqty=0, hen ignore the record and mark the process status as X
4. Deliverylinenumber is stored in Field1. Delivery line is linked to contract/contractCO line based on SaleOdrerItem

Change Log
7/9/26 - Roopal C - New procedure
				
*/
SET NOCOUNT ON
BEGIN TRY  
--BEGIN TRAN
--Error variables  

DECLARE  
@record_id bigint,
@PmwebProjectId bigint,
@PmwebCompanyId bigint,
@ItemChangeDate nvarchar(8) ,
@LastUpdateDateTime datetime2(7) ,
@SalesDocumentNumber nvarchar(10) ,
@Currency nvarchar(5) ,
@CurrencyId bigint,
@DocumentStatus nvarchar(20) ,
@DeliveryNumber nvarchar(20) ,
@deliveryexists bigint,
@operation_flag nvarchar(1),
@DocumentDate date,
@pmweb_hdr_id bigint,
@pmweb_contract_id bigint,
@pmweb_contract_line_id bigint,
@pmweb_contractco_id bigint,
@pmweb_contractco_line_id bigint,
@lastproductonid bigint,
@pmweb_project_id bigint ,
@pmweb_existingproduction_id bigint ,
@beforeMaxId bigint

,@ErrorNumber     BIGINT
,@ErrorProcedure  NVARCHAR(200)
,@ErrorLine       INT
,@ErrorMessage    NVARCHAR(4000)
,@ErrorDesc		NVARCHAR(4000)

SET @ERROR_DESC = 0
SET @ERROR_DESC=' '
SET @ErrorDesc = ''
SET @ErrorMessage = ''
SET @ERROR_STATUS=0

DECLARE @Result TABLE (ID BIGINT);

---Delete 6 months old data
DELETE xx_delivery_line_stg_tbl_ib 
WHERE creation_date < GETDATE()-180

DELETE xx_delivery_hdr_stg_tbl_ib
WHERE creation_date < GETDATE()-180

DELETE xx_delivery_line_stg_tbl_ib
FROM xx_delivery_line_stg_tbl_ib a
WHERE process_status IN ('E','X')
AND exists (select 1 from xx_delivery_line_stg_tbl_ib b 
			where b.DeliveryNumber=a.DeliveryNumber and b.LineNumber=a.LineNumber and b.process_status = 'N')

DELETE xx_delivery_hdr_stg_tbl_ib
FROM xx_delivery_hdr_stg_tbl_ib a
WHERE process_status IN ('E','X')
AND exists (select 1 from xx_delivery_hdr_stg_tbl_ib b 
			where b.DeliveryNumber=a.DeliveryNumber and b.process_status = 'N')


---Update contract and contract line reference
UPDATE xx_delivery_hdr_stg_tbl_ib SET pmweb_contract_id=c.id, pmweb_project_id=c.ProjectId, operation_flag='I'
FROM xx_delivery_hdr_stg_tbl_ib h, xx_delivery_line_stg_tbl_ib l, dbo.CostManagement_Contracts c
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND l.SalesOrderNumber = c.Reference

UPDATE xx_delivery_line_stg_tbl_ib SET pmweb_contract_line_id = cl.Id, operation_flag='I'
FROM xx_delivery_hdr_stg_tbl_ib h, xx_delivery_line_stg_tbl_ib l, dbo.CostManagement_ContractDetails cl
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND cl.ContractId = h.pmweb_contract_id
AND l.SalesOrderItem = cl.Field3

---Update contractCO and contractCO line reference
UPDATE xx_delivery_hdr_stg_tbl_ib SET pmweb_contractco_id=c.id, pmweb_project_id=c.ProjectId, operation_flag='I'
FROM xx_delivery_hdr_stg_tbl_ib h, xx_delivery_line_stg_tbl_ib l, dbo.CostManagement_ContractCOs c
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND l.SalesOrderNumber = c.Reference

UPDATE xx_delivery_line_stg_tbl_ib SET pmweb_contractco_line_id = cl.Id, operation_flag='I'
FROM xx_delivery_hdr_stg_tbl_ib h, xx_delivery_line_stg_tbl_ib l, dbo.CostManagement_ContractCODetails cl
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND cl.ContractCOId = h.pmweb_contractco_id
AND l.SalesOrderItem = cl.Field3

----If no contract or contract line reference found then update the process status as E
UPDATE xx_delivery_line_stg_tbl_ib SET process_status = 'E', error_msg = 'No contract or conttract CO line found in PMWeb', last_update_date=getdate()
WHERE process_status = 'N' 
AND (ISNULL(pmweb_contract_line_id,0) = 0 OR pmweb_contract_line_id='') AND (ISNULL(pmweb_contractco_line_id,0)=0 OR pmweb_contractco_line_id='')

UPDATE xx_delivery_hdr_stg_tbl_ib SET process_status = 'E', error_msg = 'No contract or conttract CO line found in PMWeb', last_update_date=getdate()
FROM xx_delivery_hdr_stg_tbl_ib h, xx_delivery_line_stg_tbl_ib l
WHERE h.process_status = 'N'
AND h.record_id = l.hdr_record_id
AND l.process_status = 'E'


--update existing production id if the delivery number already exists 
UPDATE xx_delivery_hdr_stg_tbl_ib
SET pmweb_existingproduction_id = p.Id, operation_flag='U', pmweb_hdr_id=@pmweb_hdr_id
FROM xx_delivery_hdr_stg_tbl_ib h, dbo.CostManagement_Productions p
WHERE h.DeliveryNumber = p.Reference
AND h.process_status = 'N'

UPDATE xx_delivery_line_stg_tbl_ib
SET pmweb_line_id = d.Id, operation_flag='U'
FROM xx_delivery_hdr_stg_tbl_ib h, dbo.CostManagement_ProductionDetails d, xx_delivery_line_stg_tbl_ib l
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND h.pmweb_existingproduction_id = d.ProductionId
AND ((l.pmweb_contract_line_id = d.ContractDetailId) 
	OR
	(l.pmweb_contractco_line_id = d.ContractCODetailId)
	)


IF CURSOR_STATUS('global','hdr_cursor')>=-1  
	BEGIN  
	 DEALLOCATE hdr_cursor 
	END 

DECLARE hdr_cursor CURSOR FOR 
SELECT record_id
	,DeliveryNumber
	,pmweb_contract_id
	,pmweb_contractco_id
	,pmweb_project_id
	,pmweb_existingproduction_id
	,operation_flag
	,DocumentDate
FROM xx_delivery_hdr_stg_tbl_ib
WHERE process_status = 'N'
ORDER BY record_id

OPEN hdr_cursor

FETCH NEXT FROM hdr_cursor INTO @record_id
							,@DeliveryNumber
							,@pmweb_contract_id
							,@pmweb_contractco_id
							,@pmweb_project_id
							,@pmweb_existingproduction_id
							,@operation_flag
							,@DocumentDate

WHILE @@FETCH_STATUS = 0
BEGIN
	print 'start of processing delivery for record id = ' print @record_id
	print 'operation flag = ' + @operation_flag
--###################     New delivery     #########################################
IF @operation_flag = 'I'
BEGIN TRY
	
	
	SET @lastproductonid=0
	SET @pmweb_hdr_id = 0

	SELECT @PmwebProjectId=projectid, @PmwebCompanyId=companyid, @CurrencyId = CurrencyId
	from dbo.costmanagement_contracts where id = @pmweb_contract_id


	--Check if there are any deliveries for this contract
	SET @lastproductonid = ISNULL((select TOP 1 ID from dbo.CostManagement_Productions 
									where PrimeContractId = @pmweb_contract_id and IsActive=1 order by id desc),0)

print '@lastproductonid = ' + cast(@lastproductonid as varchar)

	DELETE FROM @Result;
    IF @lastproductonid = 0 ---No delivery exists
		BEGIN
		INSERT INTO @Result (ID)
        EXEC dbo.APIC_CostManagement_AddProduction 
			@RecordNumber = N'',@ProjectId = @PmwebProjectId,@TypeId = 0,@FromDate = @DocumentDate,@ToDate = @DocumentDate,@DocStatusId= 5
			,@PeriodId = 0,@IsActive = 1,@PrimeContractId = @pmweb_contract_id,@CommitmentId = 0,@CompanyId = @PmwebCompanyId
			,@IsPostToCostLedger = 1,@CreatedBy =5,@RevisionNumber = 0,@CategoryId = 0,@Reference = @DeliveryNumber,@Description = N''
			,@CurrencyId = @CurrencyId,@wbsid = 0
		
		SELECT @pmweb_hdr_id = ID FROM @Result;
		END
    ELSE
        BEGIN
		SET @beforeMaxId = ISNULL((SELECT MAX(Id) FROM dbo.CostManagement_Productions WHERE PrimeContractId = @pmweb_contract_id), 0);
        EXEC dbo.CostManagement_AddNextProduction @ProductionId=@lastproductonid,
                @ProjectId=@PmwebProjectId, @TypeId=0, @CreatedBy=5;

		SELECT @pmweb_hdr_id = ISNULL(MIN(Id), 0)
		FROM dbo.CostManagement_Productions
		WHERE Id > @beforeMaxId AND PrimeContractId = @pmweb_contract_id;

		UPDATE dbo.CostManagement_Productions SET Reference = @DeliveryNumber WHERE Id = @pmweb_hdr_id;
		END

	print '@pmweb_hdr_id = ' + cast(@pmweb_hdr_id as varchar)

	IF @pmweb_hdr_id = 0
		UPDATE xx_delivery_hdr_stg_tbl_ib set process_status='E',error_msg = 'Error in creating delivery header', last_update_date=getdate()
		WHERE record_id = @record_id
	ELSE
		----Add all change orders which are not added to the invoice
		/*
		exec [dbo].[CostManagement_AddChangeOrdersToProductionContract] 
					@ProductionId=@pmweb_hdr_id,
					@ContractCODetailIds=N'35,36,37',
					@ChangeEventDetailIds=N'',
					@UserId=5,@Revised=0,@Merge=0
		*/
		BEGIN
			---update for contract lines
			update CostManagement_ProductionDetails 
			set Quantity= case when l.DeliveredQuantity = 0 then l.PickedQuantity else l.DeliveredQuantity end, 
				Total = d.Rate * case when l.DeliveredQuantity = 0 then l.PickedQuantity else l.DeliveredQuantity end,
				lastupdatedate = getdate()
			from dbo.CostManagement_ProductionDetails d, xx_delivery_line_stg_tbl_ib l
			where d.ProductionId=@pmweb_hdr_id 
			and l.hdr_record_id = @record_id
			and l.pmweb_contract_line_id = d.ContractDetailId

			print 'after update of productiondetails for CO' print @@rowcount

			---update for contract CO lines
			update CostManagement_ProductionDetails 
			set Quantity= case when l.DeliveredQuantity = 0 then l.PickedQuantity else l.DeliveredQuantity end, 
				Total = d.Rate * case when l.DeliveredQuantity = 0 then l.PickedQuantity else l.DeliveredQuantity end,
				lastupdatedate = getdate()
			from dbo.CostManagement_ProductionDetails d, xx_delivery_line_stg_tbl_ib l
			where d.ProductionId=@pmweb_hdr_id 
			and l.hdr_record_id = @record_id
			and l.pmweb_contractco_line_id = d.ContractCODetailId

			print 'after update of productiondetails for change co' print @@rowcount

			UPDATE CostManagement_ProductionDetails 
			SET IsDone = case when ScheduledQuantity-Quantity=0 then 1 else 0 end
			where ProductionId=@pmweb_hdr_id 
		END;

	--Update the success in staging table
	IF @pmweb_hdr_id > 0
	BEGIN
		UPDATE xx_delivery_hdr_stg_tbl_ib set process_status='S',error_msg = null,last_update_date=getdate(), pmweb_hdr_id=@pmweb_hdr_id
		WHERE record_id = @record_id and process_status = 'N'

		UPDATE xx_delivery_line_stg_tbl_ib
		SET process_status='S',error_msg=null,last_update_date=GETDATE(),pmweb_line_id=d.Id
		from dbo.CostManagement_ProductionDetails d, xx_delivery_line_stg_tbl_ib l
		where d.ProductionId=@pmweb_hdr_id 
		and l.hdr_record_id = @record_id
		and l.pmweb_contract_line_id = d.ContractDetailId

		UPDATE xx_delivery_line_stg_tbl_ib
		SET process_status='S',error_msg=null,last_update_date=GETDATE(),pmweb_line_id=d.Id
		from dbo.CostManagement_ProductionDetails d, xx_delivery_line_stg_tbl_ib l
		where d.ProductionId=@pmweb_hdr_id 
		and l.hdr_record_id = @record_id
		and l.pmweb_contractco_line_id = d.ContractCODetailId
	END
	
END TRY--End of IF @operation_flag = 'I'
BEGIN CATCH
	IF @@TRANCOUNT > 0
	ROLLBACK TRAN; 

	print 'Error in sales order creation'+ERROR_MESSAGE()
	UPDATE xx_delivery_line_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in delivery creation. '+ERROR_MESSAGE(),operation_flag='I'
	WHERE hdr_record_id = @record_id

	UPDATE xx_delivery_hdr_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in sales order creation. '+ERROR_MESSAGE(),operation_flag='I'
	WHERE record_id = @record_id


END CATCH
--###################     END OF NEW delivery     #########################################

--###################     UPDATE OF delivery     #########################################
IF @operation_flag = 'U'
BEGIN TRY

	SET @lastproductonid=0
	SET @pmweb_hdr_id = 0

	print 'for update of existing delivery = ' +cast (@pmweb_existingproduction_id as varchar)

	---update for contract lines
	update CostManagement_ProductionDetails 
	set Quantity= case when l.DeliveredQuantity = 0 then l.PickedQuantity else l.DeliveredQuantity end, 
		Total = d.Rate * case when l.DeliveredQuantity = 0 then l.PickedQuantity else l.DeliveredQuantity end,
		lastupdatedate = getdate()
	from dbo.CostManagement_ProductionDetails d, xx_delivery_line_stg_tbl_ib l
	where d.ProductionId=@pmweb_existingproduction_id 
	and d.Id = l.pmweb_line_id

	UPDATE CostManagement_ProductionDetails 
	SET IsDone = case when ScheduledQuantity-Quantity=0 then 1 else 0 end
	where ProductionId=@pmweb_existingproduction_id 

	UPDATE xx_delivery_line_stg_tbl_ib
	SET process_status='S',error_msg=null,last_update_date=GETDATE()
	WHERE hdr_record_id = @record_id

	UPDATE xx_delivery_hdr_stg_tbl_ib 
	SET process_status='S',error_msg=null,last_update_date=GETDATE()
	WHERE record_id = @record_id



END TRY
BEGIN CATCH
	IF @@TRANCOUNT > 0
	ROLLBACK TRAN; 

	print 'Error in sales order creation'+ERROR_MESSAGE()
	UPDATE xx_delivery_line_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in delivery update. '+ERROR_MESSAGE(),operation_flag='U'
	WHERE hdr_record_id = @record_id

	UPDATE xx_delivery_hdr_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in sales order update. '+ERROR_MESSAGE(),operation_flag='U'
	WHERE record_id = @record_id

END CATCH

FETCH NEXT FROM hdr_cursor INTO @record_id
							,@DeliveryNumber
							,@pmweb_contract_id
							,@pmweb_contractco_id
							,@pmweb_project_id
							,@pmweb_existingproduction_id
							,@operation_flag
							,@DocumentDate

END

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


