USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_SALEORDER_IB_PRC]    Script Date: 10/16/2026 3:15:39 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE   PROC [dbo].[SHK_INT_SALEORDER_IB_PRC] 
AS

SET XACT_ABORT ON
DECLARE @ERROR_DESC VARCHAR(MAX);  
DECLARE @ERROR_STATUS INT;


BEGIN
/* 
Procedure which is called from Sales Order scheduled service
It picks all new data from staging table (process_status=N) and creates/updates contract order or contract order changes in PMWeb

1. Check the sale order number, if it does not exist , create a new contract order
2. If sale order exists, and there is production request, update the contract order
3. If the sale order exists and there is a production request, if the change is only in the material then update the contract order
4. If the sale order exists and there is a production request, and change in qty create a change order

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
@IsReturnOrder bit ,
@IsSaleOrder bit ,
@ItemChangeDate nvarchar(8) ,
@LastUpdateDateTime datetime2(7) ,
@SalesDocumentNumber nvarchar(10) ,
@SalesOrg nvarchar(4) ,
@SoldToPartyNumber nvarchar(10) ,
@AdvanceAmt decimal(16, 3) ,
@AdvancePercentage decimal(5, 2) ,
@C4CProjectName nvarchar(40) ,
@C4CProjectNumber nvarchar(24) ,
@CreatedByName nvarchar(12) ,
@Currency nvarchar(5) ,
@CustomerName nvarchar(35) ,
@Date_from nvarchar(10) ,
@Date_to nvarchar(10) ,
@DiscountAmount decimal(16, 3) ,
@DistributionChannel nvarchar(2) ,
@Division nvarchar(2) ,
@DocumentStatus nvarchar(20) ,
@DownPaymentCharges decimal(16, 3) ,
@DownPaymentPercentage decimal(5, 2) ,
@ExchangeRate decimal(9, 5) ,
@ExpectedAwardDate datetime2(7) ,
@ExpectedDeliveryDate datetime2(7) ,
@GrossPrice decimal(16, 3) ,
@InstallationCharges decimal(16, 3) ,
@Message nvarchar(220) ,
@NetValueWithoutTax decimal(16, 3) ,
@NetValueWithTax decimal(16, 3) ,
@OrderReason nvarchar(3) ,
@OrderType nvarchar(4) ,
@OrderTypeDesc nvarchar(20) ,
@PaymentTerms nvarchar(4) ,
@ProgressUpdateDate datetime2(7) ,
@RetentionAmt decimal(16, 3) ,
@RetentionPercentage decimal(5, 2) ,
@SalesGroup nvarchar(3) ,
@SalesOffice nvarchar(4) ,
@SalesPersonCommission decimal(5, 2) ,
@SalesPersonName nvarchar(35) ,
@SalesPersonNumber nvarchar(8) ,
@ShipToPartyNumber nvarchar(10) ,
@VatAmount decimal(16, 3) ,
@VatPercentage decimal(5, 2) ,
@Version nvarchar(10),
@sameproject bigint,
@deliveryexists bigint,
@operation_flag nvarchar(1),
@DocumentDate date,
@pmweb_hdr_id bigint,
@onlyitemchange bigint,
@newlineaddedinso bigint

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


---Delete 6 months old data
DELETE xx_salesorder_line_stg_tbl_ib
WHERE creation_date < GETDATE()-180

DELETE xx_salesorder_line_stg_tbl_ib 
WHERE creation_date < GETDATE()-180

--update pmweb cost code id
UPDATE xx_salesorder_line_stg_tbl_ib
SET PmwebCostCodeId = c.Id
FROM xx_salesorder_line_stg_tbl_ib l, dbo.CostCodes c
WHERE l.WbsElement+'-0-0' = c.StuffedCodes
AND l.process_status = 'N'

--update pmweb project id
UPDATE xx_salesorder_line_stg_tbl_ib
SET PmwebProjectId = p.Id
FROM xx_salesorder_line_stg_tbl_ib l, dbo.projects p
WHERE l.ProjectCode = p.ProjectNumber
AND l.process_status = 'N'

--update pmweb project id in header
UPDATE xx_salesorder_hdr_stg_tbl_ib
SET PmwebProjectId = l.PmwebProjectId
FROM xx_salesorder_hdr_stg_tbl_ib h, xx_salesorder_line_stg_tbl_ib l
WHERE h.record_id = l.hdr_record_id
AND h.process_status = 'N'
AND l.PmwebProjectId is not null

--update pmweb item id
UPDATE xx_salesorder_line_stg_tbl_ib
SET PmwebItemId = i.Id
FROM xx_salesorder_line_stg_tbl_ib l, dbo.Items i
WHERE l.Material = i.ManufacturerNumber
AND l.process_status = 'N'

--Update pmweb company id
UPDATE xx_salesorder_hdr_stg_tbl_ib
SET PmwebCompanyId = c.Id
FROM xx_salesorder_hdr_stg_tbl_ib h, dbo.Companies c
WHERE h.SoldToPartyNumber = c.CompanyCode
AND h.process_status = 'N'

--Update pmweb_hdr_id if sales documet number already exists
UPDATE xx_salesorder_hdr_stg_tbl_ib
SET pmweb_hdr_id = c.Id, operation_flag = 'U'
FROM xx_salesorder_hdr_stg_tbl_ib h, dbo.CostManagement_Contracts c
WHERE c.Code = h.SalesDocumentNumber
AND h.process_status = 'N'

UPDATE xx_salesorder_line_stg_tbl_ib
SET pmweb_line_id = d.Id, operation_flag = 'U'
FROM xx_salesorder_line_stg_tbl_ib l, dbo.CostManagement_ContractDetails d, dbo.CostManagement_Contracts c
WHERE c.Code = l.SalesDocumentNumber
AND c.Id = d.ContractId
AND d.Field1 = l.QuotationNumber
AND d.Field2 = l.QuotationItem
AND l.process_status = 'N'

--Update to E where PMWeb ids are not found
UPDATE xx_salesorder_line_stg_tbl_ib 
SET process_status = 'E', error_msg = isnull(error_msg,'')+'Project not setup in PMWeb. '
WHERE process_status = 'N'
AND isnull(PmwebProjectId,0) = 0

UPDATE xx_salesorder_line_stg_tbl_ib 
SET process_status = 'E', error_msg = isnull(error_msg,'')+'Item not setup in PMWeb. '
WHERE process_status = 'N'
AND isnull(PmwebItemId,0) = 0

UPDATE xx_salesorder_line_stg_tbl_ib 
SET process_status = 'E', error_msg = isnull(error_msg,'')+'Cost Code not setup in PMWeb. '
WHERE process_status = 'N'
AND isnull(PmwebCostCodeId,0) = 0


UPDATE xx_salesorder_line_stg_tbl_ib 
SET process_status = 'E', error_msg = isnull(error_msg,'')+'Quotation details ar reuired. '
WHERE process_status = 'N'
AND QuotationNumber is null or QuotationNumber ='' or QuotationItem is null or QuotationItem=''

UPDATE xx_salesorder_hdr_stg_tbl_ib 
SET process_status = 'E', error_msg = isnull(error_msg,'')+'Customer not setup in PMWeb. '
WHERE process_status = 'N'
AND isnull(PmwebCompanyId,0) = 0

UPDATE xx_salesorder_hdr_stg_tbl_ib 
SET process_status = 'E', error_msg = l.error_msg
FROM xx_salesorder_hdr_stg_tbl_ib h, xx_salesorder_line_stg_tbl_ib l
WHERE h.process_status = 'N'
AND h.record_id = l.hdr_record_id
AND l.process_status = 'E'

IF CURSOR_STATUS('global','hdr_cursor')>=-1  
	BEGIN  
	 DEALLOCATE hdr_cursor 
	END 

DECLARE hdr_cursor CURSOR FOR 
SELECT record_id
	,PmwebProjectId
	,PmwebCompanyId
	,IsReturnOrder
	,SalesDocumentNumber
	,AdvancePercentage
	,C4CProjectNumber
	,Currency
	,ExchangeRate
	,CustomerName
	,DownPaymentPercentage
	,InstallationCharges
	,RetentionPercentage
	,SalesPersonName
	,SalesPersonNumber
	,VatPercentage
	,isnull(operation_flag,'I')
	,DocumentDate
	,pmweb_hdr_id
FROM xx_salesorder_hdr_stg_tbl_ib
WHERE process_status = 'N'

OPEN hdr_cursor

FETCH NEXT FROM hdr_cursor INTO @record_id
							,@PmwebProjectId
							,@PmwebCompanyId
							,@IsReturnOrder
							,@SalesDocumentNumber
							,@AdvancePercentage
							,@C4CProjectNumber
							,@Currency
							,@ExchangeRate
							,@CustomerName
							,@DownPaymentPercentage
							,@InstallationCharges
							,@RetentionPercentage
							,@SalesPersonName
							,@SalesPersonNumber
							,@VatPercentage
							,@operation_flag
							,@DocumentDate
							,@pmweb_hdr_id
WHILE @@FETCH_STATUS = 0
BEGIN TRY
SET @deliveryexists=0

--Check if there are any sales order with multiple project in sale order
SET @sameproject = (select count(distinct projectcode) from xx_salesorder_line_stg_tbl_ib where hdr_record_id = @record_id)

IF @sameproject > 1
	BEGIN
		UPDATE xx_salesorder_line_stg_tbl_ib
		SET process_status = 'E', error_msg = 'This sales order has multiple project code'
		WHERE hdr_record_id = @record_id

		UPDATE xx_salesorder_hdr_stg_tbl_ib
		SET process_status = 'E', error_msg = 'This sales order has multiple project code'
		WHERE record_id = @record_id
	END
ELSE
BEGIN
	IF @operation_flag = 'I'
		BEGIN TRY
			BEGIN TRAN;
			print 'inserrting header for ' print @SalesDocumentNumber
			INSERT INTO dbo.CostManagement_Contracts
				(ProjectId,CompanyId,Code,RevisionNumber,RevisionDate,DocStatusId,CurrencyId,
				IsActive,IsUseUnit,CreatedBy,CreateDate,Reference,EffectiveDate,
				AllowOverBilling,MaxBilling,MaxLineBilling,IsLineOverBilling,IsTotalOverbilling,PaidInFull,UseRevisedUnit
				)
			VALUES (@PmwebProjectId,@PmwebCompanyId,@SalesDocumentNumber,0,GETDATE(),5,
					isnull((select id from dbo.Currencies where code = isnull(@Currency,'SAR')),38),
					1,1,5,GETDATE(),@SalesDocumentNumber,@DocumentDate,
					0,0,0,0,0,0,0
					)

			SET @pmweb_hdr_id = SCOPE_IDENTITY()
			print '@pmweb_hdr_id=' print @pmweb_hdr_id
				
			print 'Inserring lines'
			---Insert lines
			INSERT INTO dbo.CostManagement_ContractDetails
				(ContractId,Linenumber,ItemId,Description,Quantity,CurrencyId,
				UOMId,UnitCost, TotalCost, TotalPrice,CostCodeId,Field1,Field2
				)
			SELECT @pmweb_hdr_id, cast(l.linenumber as bigint),l.pmwebitemid,l.ItemDescription,l.Quantity,c.Id,
				u.Id,cast(l.NetValueWithTax/l.Quantity as decimal(32,5)),l.NetValueWithTax,l.NetValueWithTax,pmwebcostcodeid,l.QuotationNumber,l.QuotationItem
			FROM xx_salesorder_line_stg_tbl_ib l, xx_salesorder_hdr_stg_tbl_ib h, dbo.Currencies c, dbo.UOM u
			WHERE l.hdr_record_id = @record_id
			AND l.hdr_record_id = h.record_id
			AND h.Currency = c.Code
			AND l.Uom = u.UOM

			UPDATE xx_salesorder_hdr_stg_tbl_ib
			SET process_status = 'S', pmweb_hdr_id = @pmweb_hdr_id, last_update_date=GETDATE(), error_msg=null,operation_flag='I'
			WHERE record_id = @record_id

			UPDATE xx_salesorder_line_stg_tbl_ib
			SET pmweb_line_id = d.id, process_status='S', last_update_date=GETDATE(), error_msg=null,operation_flag='I'
			FROM xx_salesorder_line_stg_tbl_ib l, dbo.CostManagement_ContractDetails d
			WHERE d.ContractId = @pmweb_hdr_id
			AND l.hdr_record_id = @record_id
			AND cast(l.linenumber as bigint) = d.Linenumber

			COMMIT TRAN;

		END TRY
		BEGIN CATCH
			print 'Error in sales order creation'+ERROR_MESSAGE()
			UPDATE xx_salesorder_line_stg_tbl_ib
			SET process_status = 'E', error_msg = 'Error in sales order creation. '+ERROR_MESSAGE(),operation_flag='I'
			WHERE hdr_record_id = @record_id

			UPDATE xx_salesorder_hdr_stg_tbl_ib
			SET process_status = 'E', error_msg = 'Error in sales order creation. '+ERROR_MESSAGE(),operation_flag='I'
			WHERE record_id = @record_id

			IF @@TRANCOUNT > 0
			ROLLBACK TRAN; 
		END CATCH

	
IF @operation_flag = 'U'
	BEGIN TRY
			print 'in update of record id=' print @record_id
			BEGIN TRAN;
			SET @deliveryexists = (select count(*) from dbo.CostManagement_Productions where PrimeContractId=@pmweb_hdr_id)
			

			---Check if there is only item change and no qty/price change
			SET @onlyitemchange = (SELECT count(d.id)
									FROM xx_salesorder_line_stg_tbl_ib l, dbo.CostManagement_ContractDetails d
									WHERE d.ContractId = @pmweb_hdr_id
									AND l.hdr_record_id = @record_id
									AND l.QuotationNumber = d.field1
									AND l.QuotationItem = d.Field2
									AND l.Quantity = d.Quantity AND l.NetValueWithTax = d.TotalPrice
									AND l.PmwebItemId <> d.ItemId
									)
			---Check if there are any new lines added to SO
			SET @newlineaddedinso = (SELECT count(l.record_id)
									FROM xx_salesorder_line_stg_tbl_ib l 
									WHERE l.hdr_record_id = @record_id
									AND process_status = 'N'
									AND NOT EXISTS (Select 1 From dbo.CostManagement_ContractDetails d
													Where d.ContractId = @pmweb_hdr_id
													And d.Field1 = l.QuotationNumber
													And d.Field2 = l.QuotationItem
													)
									)

			print '@deliveryexists=' print @deliveryexists
			print '@onlyitemchange=' print @onlyitemchange
			print '@newlineaddedinso=' print @newlineaddedinso
			
			---No delivery exists OR if delivery exists and Only item change and no new line, update the sales order
			IF @deliveryexists=0 OR (@onlyitemchange > 0 AND @newlineaddedinso = 0)
			BEGIN
			print 'Updating sales order for ' print @SalesDocumentNumber
			
			MERGE INTO dbo.CostManagement_ContractDetails tgt
			USING (SELECT @pmweb_hdr_id contract_id
						, cast(l.linenumber as bigint) linenumber
						,l.pmwebitemid
						,l.ItemDescription
						,l.Quantity
						,c.Id currencyid
						,u.Id uomid
						,cast(l.NetValueWithTax/l.Quantity as decimal(32,5)) unitcost
						,l.NetValueWithTax TotalCost
						,l.pmwebcostcodeid
						,l.QuotationNumber
						,l.QuotationItem
					FROM xx_salesorder_line_stg_tbl_ib l, xx_salesorder_hdr_stg_tbl_ib h, dbo.Currencies c, dbo.UOM u
					WHERE l.hdr_record_id = @record_id
					AND l.hdr_record_id = h.record_id
					AND h.Currency = c.Code
					AND l.Uom = u.UOM
					AND h.pmweb_hdr_id is not null
				) src
			ON (tgt.ContractId = src.contract_id AND tgt.Field1 = src.QuotationNumber AND tgt.Field2=src.QuotationItem)
			WHEN MATCHED THEN
            UPDATE SET tgt.ItemId = src.pmwebitemid
					,tgt.Description = src.ItemDescription
					,tgt.Quantity = src.Quantity
					,tgt.UnitCost = src.UnitCost
					,tgt.TotalCost = src.TotalCost
					,tgt.TotalPrice = src.TotalCost 
					,tgt.linenumber= src.linenumber
					,tgt.CostCodeId = src.pmwebcostcodeid
					,tgt.modifier = 5
					,tgt.modifiedOn = getdate()
			WHEN NOT MATCHED THEN
			INSERT 
				(ContractId,Linenumber,ItemId,Description,Quantity,CurrencyId,
				UOMId,UnitCost, TotalCost, TotalPrice,CostCodeId,Field1,Field2
				)
			VALUES
				(src.contract_id, src.linenumber,src.pmwebitemid,src.ItemDescription,src.Quantity,src.currencyid,
				src.uomId,src.UnitCost,src.TotalCost,src.TotalCost,src.pmwebcostcodeid,src.QuotationNumber,src.QuotationItem
			);

			print 'after merge ' print @@ROWCOUNT

			UPDATE xx_salesorder_hdr_stg_tbl_ib
			SET process_status = 'S', pmweb_hdr_id = @pmweb_hdr_id, last_update_date=GETDATE(), error_msg=null,operation_flag='U'
			WHERE record_id = @record_id

			UPDATE xx_salesorder_line_stg_tbl_ib
			SET pmweb_line_id = d.id, process_status='S', last_update_date=GETDATE(), error_msg=null,operation_flag='U'
			FROM xx_salesorder_line_stg_tbl_ib l, dbo.CostManagement_ContractDetails d
			WHERE d.ContractId = @pmweb_hdr_id
			AND l.hdr_record_id = @record_id
			AND l.QuotationNumber = d.field1
			AND l.QuotationItem = d.Field2

			END --End of sale order update
			ELSE
			BEGIN
				print 'Change Order flow'
			END ----End of change order flow
			---end of IF @deliveryexists=0 OR (@onlyitemchange > 0 AND @newlineaddedinso = 0)
			COMMIT TRAN;

		END TRY
		BEGIN CATCH
			print 'Error in sales order creation'+ERROR_MESSAGE()
			UPDATE xx_salesorder_line_stg_tbl_ib
			SET process_status = 'E', error_msg = 'Error in sales order creation. '+ERROR_MESSAGE()
			WHERE hdr_record_id = @record_id

			UPDATE xx_salesorder_hdr_stg_tbl_ib
			SET process_status = 'E', error_msg = 'Error in sales order creation. '+ERROR_MESSAGE()
			WHERE record_id = @record_id

			IF @@TRANCOUNT > 0
			ROLLBACK TRAN; 
		END CATCH
	
END --IF @sameproject > 1

FETCH NEXT FROM hdr_cursor INTO @record_id
							,@PmwebProjectId
							,@PmwebCompanyId
							,@IsReturnOrder
							,@SalesDocumentNumber
							,@AdvancePercentage
							,@C4CProjectNumber
							,@Currency
							,@ExchangeRate
							,@CustomerName
							,@DownPaymentPercentage
							,@InstallationCharges
							,@RetentionPercentage
							,@SalesPersonName
							,@SalesPersonNumber
							,@VatPercentage
							,@operation_flag
							,@DocumentDate
							,@pmweb_hdr_id
END TRY
BEGIN CATCH
	print 'Error in sales order creation'+ERROR_MESSAGE()
	UPDATE xx_salesorder_line_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in sales order creation'+ERROR_MESSAGE()
	WHERE hdr_record_id = @record_id

	UPDATE xx_salesorder_hdr_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in sales order creation'+ERROR_MESSAGE()
	WHERE record_id = @record_id

	FETCH NEXT FROM hdr_cursor INTO @record_id
							,@PmwebProjectId
							,@PmwebCompanyId
							,@IsReturnOrder
							,@SalesDocumentNumber
							,@AdvancePercentage
							,@C4CProjectNumber
							,@Currency
							,@ExchangeRate
							,@CustomerName
							,@DownPaymentPercentage
							,@InstallationCharges
							,@RetentionPercentage
							,@SalesPersonName
							,@SalesPersonNumber
							,@VatPercentage
							,@operation_flag
							,@DocumentDate
							,@pmweb_hdr_id
END CATCH

	
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


