USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_SOINVOICE_IB_PRC]    Script Date: 11/25/2026 4:37:22 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO





CREATE       PROC [dbo].[SHK_INT_SOINVOICE_IB_PRC] 
AS

SET XACT_ABORT ON
DECLARE @ERROR_DESC VARCHAR(MAX);  
DECLARE @ERROR_STATUS INT;


BEGIN
/* 
Procedure which is called from SO Invoice scheduled service
It picks all new data from staging table (process_status=N) and creates/updates requisitions in PMWeb

1. Check the delivery number (Reference field), if it does not exist , create a new record. If its forst delivery use AddProduction, if not then use AddNextProduction
2. If delivery number exists in PMWeb, update production lines. If delivered qty = total scheduled qty then mark as done
3. If the delivery status is pending, deliveredqty and pickedqty=0, hen ignore the record and mark the process status as X
4. Deliverylinenumber is stored in Field1. Delivery line is linked to contract/contractCO line based on SaleOdrerItem

Change Log
22/11/26 - Roopal C - New procedure
				
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
@InvoiceNumber nvarchar(20) ,
@deliveryexists bigint,
@operation_flag nvarchar(1),
@DocumentDate date,
@pmweb_hdr_id bigint,
@pmweb_contract_id bigint,
@pmweb_contract_line_id bigint,
@pmweb_contractco_id bigint,
@pmweb_contractco_line_id bigint,
@lastinvoiceid bigint,
@pmweb_project_id bigint ,
@pmweb_production_id bigint ,
@pmweb_existinginvoice_id bigint,
@beforeMaxId bigint,
@nextrecordnumber NVARCHAR(30),
@codetailids varchar(250),
@InvoiceDescription varchar(255),
@IsReturnInvoice int,
@IsCancelled int,
@billingtermid bigint,
@line_record_id bigint,
@Qty decimal(32,5),
@totalamt decimal(32,5),
@TaxAmount decimal(32,5), 
@pmweblineid bigint,
@ScheduledQuantity decimal(32,5), 
@ScheduledValue decimal(32,5), 
@UnitCost decimal(32,5), 
@UOMId bigint,
@pmweb_contractdetail_id bigint,
@pmweb_contractcodetail_id bigint,
@pmweb_productiondetail_id bigint,
@sap_soline_ref varchar(250),
@sap_del_ref varchar(250),
@pmweb_contract_reflineid bigint,
@ItemDescrition nvarchar(250),
@costcodeid bigint,
@reqcodeid bigint,
@reqcode varchar(10)

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
DELETE xx_invoice_line_stg_tbl_ib 
WHERE creation_date < GETDATE()-180

DELETE xx_invoice_hdr_stg_tbl_ib
WHERE creation_date < GETDATE()-180

DELETE xx_invoice_line_stg_tbl_ib
FROM xx_invoice_line_stg_tbl_ib a
WHERE process_status IN ('E','X')
AND exists (select 1 from xx_invoice_line_stg_tbl_ib b 
			where b.InvoiceNumber=a.InvoiceNumber and b.LineNumber=a.LineNumber and b.process_status = 'N')

DELETE xx_invoice_hdr_stg_tbl_ib
FROM xx_invoice_hdr_stg_tbl_ib a
WHERE process_status IN ('E','X')
AND exists (select 1 from xx_invoice_hdr_stg_tbl_ib b 
			where b.InvoiceNumber=a.InvoiceNumber and b.process_status = 'N')

---Mark as error if there are multiple sales order/return order reference against a given return order
UPDATE h SET h.process_status = 'E', h.error_msg = 'Multiple sales/return order reference found in lines table against this invoice number'
FROM xx_invoice_hdr_stg_tbl_ib h
WHERE h.process_status = 'N'
AND h.IsReturnInvoice = 0
AND EXISTS (select count(distinct l.SalesOrderNumber)
			from xx_invoice_line_stg_tbl_ib l
			where l.hdr_record_id = h.record_id
			and (l.SalesOrderNumber is not null and l.SalesOrderNumber <> '')
			and (l.SalesOrderItem is not null and l.SalesOrderItem <> '')
			having count(distinct l.SalesOrderNumber) > 1
			)

UPDATE h SET h.process_status = 'E', h.error_msg = 'Multiple sales/return order reference found in lines table against this invoice number'
FROM xx_invoice_hdr_stg_tbl_ib h
WHERE h.process_status = 'N'
AND h.IsReturnInvoice = 1
AND EXISTS (select count(distinct l.ReturnOrderNumber)
			from xx_invoice_line_stg_tbl_ib l
			where l.hdr_record_id = h.record_id
			and (l.ReturnOrderNumber is not null and l.ReturnOrderNumber <> '')
			and (l.ReturnOrderItem is not null and l.ReturnOrderItem <> '')
			having count(distinct l.ReturnOrderNumber) > 1
			)


---Mark as error if there no delivery number is there in the lines. Each invoice line must have a delivery number and delivery line reference
UPDATE h SET h.process_status = 'E', h.error_msg = 'Delivery reference not found in lines table against this invoice number'
FROM xx_invoice_hdr_stg_tbl_ib h
WHERE h.process_status = 'N'
AND EXISTS (select count(l.record_id)
			from xx_invoice_line_stg_tbl_ib l
			where l.hdr_record_id = h.record_id
			and( (l.DeliveryNumber is null or l.DeliveryNumber = '')
					or  
					(l.DeliveryItem is null or l.DeliveryItem = '')
				)
			having count(l.record_id) > 0
			)

---Update contract and contract line reference for sales order
UPDATE xx_invoice_hdr_stg_tbl_ib SET pmweb_contract_id=c.id, pmweb_project_id=c.ProjectId, operation_flag='I'
FROM xx_invoice_hdr_stg_tbl_ib h, dbo.CostManagement_Contracts c, xx_invoice_line_stg_tbl_ib l 
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND l.SalesOrderNumber = c.Reference
AND (l.SalesOrderNumber is not null and l.SalesOrderNumber <> '')

UPDATE xx_invoice_line_stg_tbl_ib SET pmweb_contractdetail_id = cl.Id, operation_flag='I'
FROM xx_invoice_hdr_stg_tbl_ib h, xx_invoice_line_stg_tbl_ib l, dbo.CostManagement_ContractDetails cl
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND cl.ContractId = h.pmweb_contract_id
AND l.SalesOrderItem = cl.Field3

---Update contractCO and contractCO line reference for Return Orders
UPDATE xx_invoice_hdr_stg_tbl_ib SET pmweb_contractco_id=c.id, pmweb_project_id=c.ProjectId, operation_flag='I',
	pmweb_contract_id = c.ContractId
FROM xx_invoice_hdr_stg_tbl_ib h, dbo.CostManagement_ContractCOs c, xx_invoice_line_stg_tbl_ib l 
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND h.IsReturnInvoice = 1
AND l.ReturnOrderNumber = c.Reference
AND (l.ReturnOrderNumber is not null and l.ReturnOrderNumber <> '')

UPDATE xx_invoice_line_stg_tbl_ib SET pmweb_contractcodetail_id = cl.Id, operation_flag='I'
FROM xx_invoice_hdr_stg_tbl_ib h, xx_invoice_line_stg_tbl_ib l, dbo.CostManagement_ContractCODetails cl
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND cl.ContractCOId = h.pmweb_contractco_id
AND l.ReturnOrderItem = cl.Field3

----If no contract or contract line reference found then update the process status as E
UPDATE h SET process_status = 'E', error_msg = 'No contract or conttract CO line found in PMWeb', last_update_date=getdate()
FROM xx_invoice_hdr_stg_tbl_ib h, xx_invoice_line_stg_tbl_ib l
WHERE h.process_status = 'N' 
AND  l.hdr_record_id=  h.record_id
AND  (isnull(l.pmweb_contractdetail_id,0)=0 and isnull(l.pmweb_contractcodetail_id,0)=0 )

UPDATE h SET process_status = 'E', error_msg = 'No contract or conttract CO line found in PMWeb', last_update_date=getdate()
FROM xx_invoice_hdr_stg_tbl_ib h
WHERE process_status = 'N' 
AND ISNULL(pmweb_contract_id,0) = 0 AND ISNULL(pmweb_contractco_id,0)=0


UPDATE xx_invoice_line_stg_tbl_ib SET process_status = h.process_status, error_msg = h.error_msg, last_update_date=getdate()
FROM xx_invoice_hdr_stg_tbl_ib h, xx_invoice_line_stg_tbl_ib l
WHERE h.process_status = 'E'
AND h.record_id = l.hdr_record_id
AND l.process_status = 'N'


--update existing production id if the delivery number already exists 
UPDATE xx_invoice_hdr_stg_tbl_ib
SET pmweb_existinginvoice_id = p.Id, operation_flag='U', pmweb_hdr_id=@pmweb_hdr_id
FROM xx_invoice_hdr_stg_tbl_ib h, dbo.CostManagement_Requisitions p
WHERE h.InvoiceNumber = p.Reference
AND h.pmweb_contract_id = p.ContractId
AND h.process_status = 'N'

UPDATE xx_invoice_line_stg_tbl_ib
SET pmweb_line_id = d.Id, operation_flag='U'
FROM xx_invoice_hdr_stg_tbl_ib h, dbo.CostManagement_RequisitionDetails d, xx_invoice_line_stg_tbl_ib l
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND h.pmweb_existinginvoice_id = d.RequisitionId
AND ((l.pmweb_contractdetail_id = d.ContractDetailId) 
	OR
	(l.pmweb_contractcodetail_id = d.ContractCODetailId)
	)

---Update the productionid and productiondetailsid (SAP deliveries)
---No error is raised if this is not found, link the requisitiondetail (invoice lines) to productiondetail (delivery lines) if found
UPDATE xx_invoice_hdr_stg_tbl_ib SET pmweb_production_id = p.Id
FROM xx_invoice_hdr_stg_tbl_ib h, dbo.CostManagement_Productions p, xx_invoice_line_stg_tbl_ib l 
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND h.pmweb_contract_id = p.PrimeContractId
AND l.DeliveryNumber = p.Reference
AND p.IsActive = 1
AND (l.DeliveryNumber is not null and l.DeliveryNumber <> '')

UPDATE xx_invoice_line_stg_tbl_ib SET pmweb_productiondetail_id = pl.Id
FROM xx_invoice_hdr_stg_tbl_ib h, xx_invoice_line_stg_tbl_ib l, dbo.CostManagement_ProductionDetails pl
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND pl.ProductionId = h.pmweb_production_id
AND ((l.pmweb_contractdetail_id = pl.ContractDetailId) 
	OR
	(l.pmweb_contractcodetail_id = pl.ContractCODetailId)
	)


IF CURSOR_STATUS('global','hdr_cursor')>=-1  
	BEGIN  
	 DEALLOCATE hdr_cursor 
	END 

DECLARE hdr_cursor CURSOR FOR 
SELECT record_id
	,InvoiceNumber
	,pmweb_contract_id
	,pmweb_contractco_id
	,pmweb_project_id
	,pmweb_existinginvoice_id
	,pmweb_production_id
	,operation_flag
	,BillingDate
	,InvoiceDescription
	,IsReturnInvoice
	,IsCancelled
	,(select id from dbo.PMWeb_AdvancedListBillingTerms where substring(Terms,1,4) = PaymentTerms) BillingTermId
FROM xx_invoice_hdr_stg_tbl_ib
WHERE process_status = 'N'
AND IsPostedToAccounting = 1
AND IsCancellation = 0 --Ignore the separate cancellation invoices as in PMWeb we are cancelling the existing invoice on basis of IsCancelled=1
ORDER BY record_id

OPEN hdr_cursor

FETCH NEXT FROM hdr_cursor INTO @record_id
							,@InvoiceNumber
							,@pmweb_contract_id
							,@pmweb_contractco_id
							,@pmweb_project_id
							,@pmweb_existinginvoice_id
							,@pmweb_production_id
							,@operation_flag
							,@DocumentDate
							,@InvoiceDescription
							,@IsReturnInvoice
							,@IsCancelled
							,@billingtermid

WHILE @@FETCH_STATUS = 0
BEGIN
	print 'start of processing delivery for record id = ' print @record_id
	print 'operation flag = ' + @operation_flag
--###################     New Invoice     #########################################
IF @operation_flag = 'I' AND @IsCancelled = 0
BEGIN TRY
	
	
	SET @lastinvoiceid=0
	SET @pmweb_hdr_id = 0

	SELECT @PmwebProjectId=projectid, @PmwebCompanyId=companyid, @CurrencyId = CurrencyId
	from dbo.costmanagement_contracts where id = @pmweb_contract_id

print '@pmweb_contract_id = ' print @pmweb_contract_id
	--Check if there are any deliveries for this contract
	SET @lastinvoiceid = ISNULL((select TOP 1 ID from dbo.CostManagement_Requisitions 
								where ContractId = @pmweb_contract_id 
								and DocstatusId NOT IN (6,7)
								order by id desc),0)

print '@@lastinvoiceid = ' + cast(@lastinvoiceid as varchar)

	DELETE FROM @Result;
    IF @lastinvoiceid = 0 ---No invoice exists
		BEGIN
		--INSERT INTO @Result (ID)
        exec dbo.APIC_CostManagement_AddFirstRequisition 
		@RecordNumber=N'001',@CostPeriodId=-1,@ProjectId=@PmwebProjectId,@ContractId=@pmweb_contract_id,@InvoiceDate=@documentdate,
		@DocStatusId=5,@Inactive=0,@IsVoided=0,@InvoiceDue=NULL,@CopyDetails=1,@UserId=5,
		@RevisionNumber=0,@CategoryId=0,@CurrencyId=@CurrencyId,@Reference=@InvoiceNumber,@PaidInFull=0,
		@Description=@InvoiceDescription,@BillingTermId=@billingtermid,@WBSId=0

		SELECT @pmweb_hdr_id = ISNULL(MAX(Id),0)
		FROM dbo.CostManagement_Requisitions
		WHERE ContractId = @pmweb_contract_id
		AND Reference = @InvoiceNumber
		AND ISNULL(IsVoided,0) = 0
		
		print 'PMWeb header id after first invoice = '+cast(@pmweb_hdr_id as varchar);
		END
    ELSE
        BEGIN
		SET @beforeMaxId = ISNULL((SELECT MAX(Id) FROM dbo.CostManagement_Requisitions 
									WHERE ContractId = @pmweb_contract_id and DocstatusId NOT IN (6,7) AND ISNULL(IsVoided,0) = 0), 0);
        SELECT @nextrecordnumber = ISNULL(RecordNumber, 1) FROM dbo.CostManagement_Requisitions WHERE Id = @beforeMaxId
		
		print 'adding next invoice after invoice id ' print @beforeMaxId
		EXEC dbo.CostManagement_AddNextRequisition @RequisitionId=@beforeMaxId,@ContractId=@pmweb_contract_id,@UserId=5;

		SELECT @pmweb_hdr_id = ISNULL(MIN(Id), 0)
		FROM dbo.CostManagement_Requisitions
		WHERE Id > @beforeMaxId AND ContractId = @pmweb_contract_id AND ISNULL(IsVoided,0) = 0;

		print 'PMWeb header id after next invoice = '+cast(@pmweb_hdr_id as varchar);

		UPDATE dbo.CostManagement_Requisitions SET Reference = @InvoiceNumber,DocStatusId=5--, recordnumber=@nextrecordnumber+1 
		WHERE Id = @pmweb_hdr_id;
		END

	IF @pmweb_hdr_id = 0
		UPDATE xx_invoice_hdr_stg_tbl_ib set process_status='E',error_msg = 'Error in creating invoice header', last_update_date=getdate()
		WHERE record_id = @record_id
	ELSE
		----Add all change orders which are not added to the invoice
		SET @codetailids=''
		SET @codetailids = ISNULL((SELECT STRING_AGG(CAST(col.id AS VARCHAR(MAX)), ',')-- WITHIN GROUP (ORDER BY id) AS line_ids
									from dbo.CostManagement_ContractCODetails col, dbo.CostManagement_ContractCOs coh
									where col.ContractCOId = coh.Id
									and coh.ContractId = @pmweb_contract_id
									and coh.DocStatusId = 5
									and not exists (select 1 from dbo.CostManagement_RequisitionDetails pl, dbo.CostManagement_Requisitions ph
													where ph.Id = pl.RequisitionId
													and ph.ContractId = @pmweb_contract_id
													and pl.ContractCODetailId = col.Id
													)
									),'')
		
		
		print concat('Before adding COs = ',@codetailids)
		IF @codetailids <> ''
		exec dbo.CostManagement_AddChangeOrdersToRequisition
				@RequisitionId=@pmweb_hdr_id,@ContractCODetailIds=@codetailids,
				@ChangeEventDetailIds=N'',@UserId=5,
				@Revised=0,@Merge=0,@CostCodeId=NULL
		
		print 'after add change order to production'
		
		-----------------------------------------------------------------------------
		---- Invoice Line Processing
		------------------------------------------------------------------------------
		IF CURSOR_STATUS('global','line_cursor')>=-1  
		BEGIN  
		 DEALLOCATE line_cursor 
		END 

		DECLARE line_cursor CURSOR FOR 
		SELECT DISTINCT l.record_id
			,l.BilledQuantity Qty
			,l.NetValueWithTax totalamt
			,l.TaxAmount 
			,d.id pmweblineid
			,d.ScheduledQuantity
			,d.ScheduledValue
			,d.UnitCost
			,d.UOMId
			,l.pmweb_contractdetail_id
			,l.pmweb_contractcodetail_id
			,l.pmweb_productiondetail_id
			,case when h.IsReturnInvoice=1 
				then l.ReturnOrderNumber+'-'+l.ReturnOrderItem
			else l.SalesOrderNumber+'-'+l.SalesOrderItem
			end sap_soline_ref
			,l.DeliveryNumber+'-'+l.DeliveryItem sap_del_ref
			,l.ItemDescription
			,d.costcodeid
			,case when h.IsReturnInvoice=0 then l.pmweb_contractdetail_id else 0 end reqcodeid
			,case when h.IsReturnInvoice=0 then 'Contract' else '' end reqcode
		FROM xx_invoice_hdr_stg_tbl_ib h
			 ,xx_invoice_line_stg_tbl_ib l
			 ,dbo.CostManagement_RequisitionDetails d
		WHERE l.hdr_record_id = h.record_id 
		AND l.hdr_record_id = @record_id
		AND d.RequisitionId = @pmweb_hdr_id
		AND   ((l.pmweb_contractdetail_id = d.ContractDetailId and h.IsReturnInvoice=0)
				OR (l.pmweb_contractcodetail_id = d.ContractCODetailId and h.IsReturnInvoice=1)
				)
		ORDER BY record_id

		OPEN line_cursor

		FETCH NEXT FROM line_cursor INTO @line_record_id,
										@Qty,
										@totalamt,
										@TaxAmount, 
										@pmweblineid,
										@ScheduledQuantity, 
										@ScheduledValue, 
										@UnitCost,
										@UOMId,
										@pmweb_contractdetail_id ,
										@pmweb_contractcodetail_id ,
										@pmweb_productiondetail_id ,
										@sap_soline_ref,
										@sap_del_ref,
										@ItemDescrition,
										@costcodeid,
										@reqcodeid,
										@reqcode
		
		WHILE @@FETCH_STATUS = 0 AND @pmweb_hdr_id > 0
		BEGIN
			print 'In line update for sap line ' +@sap_soline_ref
			---update for contract lines
			exec dbo.CostManagement_UpdateRequisitionDetails
			@Id=@pmweblineid,@CurrentQuantity=@Qty,@TotalQuantity=@Qty,@PctComplete=0,@CurrentInvoice=@totalamt,
			@StoredMaterial=0,@TotalThisInvoice=@totalamt,@TotalInvoiced=@totalamt,@BalanceToInvoice=0,
			@PctServicesRetain=0,@ServicesRetainAmount=0,@PctMaterialsRetain=0,@MaterialsRetainAmount=0,
			@TotalRetained=0,@Notes=N'',@ReqCodeId=@reqcodeid,@ReqCodeType=@reqcode,@TaskId=0,
			@Field1=NULL,@Field2=NULL,@Field3=NULL,@Field4=NULL,@Field5=NULL,@Field6=NULL,
			@Field7=NULL,@Field8=NULL,@Field9=@sap_soline_ref,@Field10=@sap_del_ref,@CostTypeId=0,
			@UserId=5,@CurrencyId=@currencyid,@Description=@ItemDescrition,
			@UOMId=@uomid,@ScheduledQuantity=@ScheduledQuantity,@UnitCost=@UnitCost,@ScheduledValue=@ScheduledValue,@CostCodeId=@costcodeid

			UPDATE CostManagement_RequisitionDetails SET productiondetailid = @pmweb_productiondetail_id where id=@pmweblineid
			
			print 'after update of invoicedetails for CO' print @@rowcount

			UPDATE xx_invoice_line_stg_tbl_ib SET process_status='S',error_msg = null, pmweb_line_id=@pmweblineid, last_update_date=GETDATE()
			WHERE record_id = @line_record_id

			FETCH NEXT FROM line_cursor INTO @line_record_id,
										@Qty,
										@totalamt,
										@TaxAmount, 
										@pmweblineid,
										@ScheduledQuantity, 
										@ScheduledValue, 
										@UnitCost,
										@UOMId,
										@pmweb_contractdetail_id ,
										@pmweb_contractcodetail_id ,
										@pmweb_productiondetail_id ,
										@sap_soline_ref,
										@sap_del_ref,
										@ItemDescrition,
										@costcodeid,
										@reqcodeid,
										@reqcode
 
		END
	
		CLOSE line_cursor;     
		DEALLOCATE line_cursor;

	--Update the success in staging table
	IF @pmweb_hdr_id > 0
	BEGIN
		UPDATE xx_invoice_hdr_stg_tbl_ib set process_status='S',error_msg = null,last_update_date=getdate(), pmweb_hdr_id=@pmweb_hdr_id
		WHERE record_id = @record_id and process_status = 'N'
	END
	
END TRY--End of IF @operation_flag = 'I'
BEGIN CATCH
	IF @@TRANCOUNT > 0
	ROLLBACK TRAN; 

	print 'in Try block Error in invoice creation'+ERROR_MESSAGE()
	UPDATE xx_invoice_line_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in invoice creation. '+ERROR_MESSAGE(),operation_flag='I'
	WHERE hdr_record_id = @record_id

	UPDATE xx_invoice_hdr_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in invoice creation. '+ERROR_MESSAGE(),operation_flag='I'
	WHERE record_id = @record_id


END CATCH
--###################     END OF NEW Invoice     #########################################

--###################     UPDATE OF invoice - cancellation     #########################################
IF @IsCancelled = 1 AND ISNULL(@pmweb_existinginvoice_id,0) > 0
BEGIN TRY

	SET @lastinvoiceid=0
	SET @pmweb_hdr_id = 0

	print 'cancellation for invoice id = ' +cast (@pmweb_existinginvoice_id as varchar)
	print 'invoicenumber = '+ @InvoiceNumber

	exec [dbo].[CostManagement_VoidRequisition] @RequisitionId=@pmweb_existinginvoice_id,@UserId=5

	UPDATE xx_invoice_line_stg_tbl_ib
	SET process_status='S',error_msg=null,last_update_date=GETDATE()
	WHERE hdr_record_id = @record_id

	UPDATE xx_invoice_hdr_stg_tbl_ib 
	SET process_status='S',error_msg=null,last_update_date=GETDATE()
	WHERE record_id = @record_id
END TRY
BEGIN CATCH
	IF @@TRANCOUNT > 0
	ROLLBACK TRAN; 

	print 'Try block of cancellation, Error in invoice cancellation'+ERROR_MESSAGE()
	UPDATE xx_invoice_line_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in invoice cancellation. '+ERROR_MESSAGE(),operation_flag='U'
	WHERE hdr_record_id = @record_id

	UPDATE xx_invoice_hdr_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in invoice cancellation. '+ERROR_MESSAGE(),operation_flag='U'
	WHERE record_id = @record_id

END CATCH

FETCH NEXT FROM hdr_cursor INTO @record_id
							,@InvoiceNumber
							,@pmweb_contract_id
							,@pmweb_contractco_id
							,@pmweb_project_id
							,@pmweb_existinginvoice_id
							,@pmweb_production_id
							,@operation_flag
							,@DocumentDate
							,@InvoiceDescription
							,@IsReturnInvoice
							,@IsCancelled
							,@billingtermid
END

CLOSE hdr_cursor;     
DEALLOCATE hdr_cursor;

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

