USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_SALEORDER_IB_PRC]    Script Date: 11/19/2026 2:08:36 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE   PROC [dbo].[SHK_INT_SALEORDER_IB_PRC]
AS

SET XACT_ABORT ON

BEGIN
/*
Procedure which is called from Sales Order scheduled service
It picks all new data from staging table (process_status=N) and creates/updates contract order or contract order changes in PMWeb

1. Check the sale order number, if it does not exist , create a new contract order
2. If sale order exists, and there is production request, update the contract order
3. If the sale order exists and there is a production request, if the change is only in the material then update the contract order
4. If the sale order exists and there is a production request, and change in qty create a change order

Change Log
7/9/26   - Roopal C - New procedure

*/
SET NOCOUNT ON
BEGIN TRY

DECLARE
 @record_id                  bigint
,@PmwebProjectId             bigint
,@PmwebCompanyId             bigint
,@IsReturnOrder              bit
,@SalesDocumentNumber        nvarchar(10)
,@CurrencyId                 bigint
,@DocumentDate               date
,@operation_flag             nvarchar(1)
,@pmweb_hdr_id               bigint
,@pmweb_contractco_id        bigint
,@pmweb_original_contract_id bigint
,@sameproject                bigint
,@deliveryexists             bigint
,@onlyitemchange             bigint
,@newlineaddedinso           bigint

DECLARE @Result TABLE (ID BIGINT);

---Delete 6 months old data
DELETE xx_salesorder_line_stg_tbl_ib
WHERE creation_date < GETDATE()-180

DELETE xx_salesorder_hdr_stg_tbl_ib
WHERE creation_date < GETDATE()-180

--------------------------------------------------------------------------------------------
-- Resolve PMWeb ids on the staging tables
--------------------------------------------------------------------------------------------

--update pmweb cost code id (wbs element is stored in Notes when cost codes are created in pmweb)
UPDATE l SET l.PmwebCostCodeId = c.Id
FROM xx_salesorder_line_stg_tbl_ib l
JOIN dbo.CostCodes c ON c.Notes = l.WbsElement
WHERE l.process_status = 'N'

--update pmweb project id
UPDATE l SET l.PmwebProjectId = p.Id
FROM xx_salesorder_line_stg_tbl_ib l
JOIN dbo.projects p ON p.ProjectNumber = l.ProjectCode
WHERE l.process_status = 'N'

--update pmweb project id in header
UPDATE h SET h.PmwebProjectId = l.PmwebProjectId
FROM xx_salesorder_hdr_stg_tbl_ib h
JOIN xx_salesorder_line_stg_tbl_ib l ON l.hdr_record_id = h.record_id
WHERE h.process_status = 'N'
AND l.PmwebProjectId IS NOT NULL

--update pmweb item id
UPDATE l SET l.PmwebItemId = i.Id
FROM xx_salesorder_line_stg_tbl_ib l
JOIN dbo.Items i ON i.ManufacturerNumber = l.Material
WHERE l.process_status = 'N'

--Update pmweb company id
UPDATE h SET h.PmwebCompanyId = c.Id
FROM xx_salesorder_hdr_stg_tbl_ib h
JOIN dbo.Companies c ON c.CompanyCode = h.SoldToPartyNumber
WHERE h.process_status = 'N'


--------------------------------------------------------------------------------------------
-- Existing sales documents (not return orders: contract)
--------------------------------------------------------------------------------------------
UPDATE h SET h.pmweb_hdr_id = c.Id, h.operation_flag = 'U'
FROM xx_salesorder_hdr_stg_tbl_ib h
JOIN dbo.CostManagement_Contracts c ON c.Code = h.SalesDocumentNumber
WHERE h.process_status = 'N'
AND h.IsReturnOrder = 0 ---exclude return order, return orders are created as contract change order


UPDATE xx_salesorder_line_stg_tbl_ib
SET pmweb_line_id = d.Id, operation_flag = 'U'
FROM xx_salesorder_line_stg_tbl_ib l, dbo.CostManagement_ContractDetails d, dbo.CostManagement_Contracts c
WHERE c.Code = l.SalesDocumentNumber
AND c.Id = d.ContractId
AND d.Field3 = l.LineNumber
AND l.process_status = 'N'
and (l.OriginalSalesOrder is null or l.OriginalSalesOrder = '') ---exclude return order, return orders are created as contract change order


--------------------------------------------------------------------------------------------
-- Existing return orders (contract change order)
--------------------------------------------------------------------------------------------
UPDATE h SET h.pmweb_hdr_id = c.Id, h.operation_flag = 'U'
FROM xx_salesorder_hdr_stg_tbl_ib h
JOIN dbo.CostManagement_ContractCOs c ON c.Reference = h.SalesDocumentNumber
WHERE h.process_status = 'N'
AND h.IsReturnOrder = 1 ---only return order, return orders are created as contract change order

UPDATE xx_salesorder_line_stg_tbl_ib
SET pmweb_line_id = d.Id, operation_flag = 'U'
FROM xx_salesorder_line_stg_tbl_ib l, dbo.CostManagement_ContractCODetails d, dbo.CostManagement_ContractCOs c
WHERE c.Reference = l.SalesDocumentNumber
AND c.Id = d.ContractCOId
AND d.Field3 = l.LineNumber
AND l.process_status = 'N'
and (l.OriginalSalesOrder is not null or l.OriginalSalesOrder <> '') ---only return order, return orders are created as contract change order


--------------------------------------------------------------------------------------------
-- Mark as E where PMWeb ids are not found
--------------------------------------------------------------------------------------------
UPDATE xx_salesorder_line_stg_tbl_ib
SET process_status = 'E',
    error_msg = isnull(error_msg,'') +
                CASE WHEN isnull(PmwebProjectId,0) = 0 THEN 'Project not setup in PMWeb. '
                     WHEN isnull(PmwebItemId,0)    = 0 THEN 'Item not setup in PMWeb. '
                     ELSE                                    'Cost Code not setup in PMWeb. '
                END
WHERE process_status = 'N'
AND (isnull(PmwebProjectId,0) = 0 OR isnull(PmwebItemId,0) = 0 OR isnull(PmwebCostCodeId,0) = 0)

UPDATE xx_salesorder_hdr_stg_tbl_ib
SET process_status = 'E', error_msg = isnull(error_msg,'')+'Customer not setup in PMWeb. '
WHERE process_status = 'N'
AND isnull(PmwebCompanyId,0) = 0

UPDATE h SET h.process_status = 'E', h.error_msg = l.error_msg
FROM xx_salesorder_hdr_stg_tbl_ib h
JOIN xx_salesorder_line_stg_tbl_ib l ON l.hdr_record_id = h.record_id
WHERE h.process_status = 'N'
AND l.process_status = 'E'


--------------------------------------------------------------------------------------------
-- Return orders: original sales order / original contract references
--------------------------------------------------------------------------------------------

---Mark as error if there are multiple original sales order reference against a given return order, or if there is no original order reference
UPDATE h SET h.process_status = 'E', h.error_msg = 'No original sales order or multiple original sales order reference'
FROM xx_salesorder_hdr_stg_tbl_ib h
WHERE h.IsReturnOrder = 1
AND NOT EXISTS (select count(distinct l.OriginalSalesOrder)
			from xx_salesorder_line_stg_tbl_ib l
			where l.hdr_record_id = h.record_id
			and (l.OriginalSalesOrder is not null and l.OriginalSalesOrder <> '')
			and (l.OriginalSalesOrderItem is not null and l.OriginalSalesOrderItem <> '')
			having count(distinct l.OriginalSalesOrder) = 1
			)

---Update the original pmweb contract id for the return orders
UPDATE h SET h.pmweb_original_contract_id = c.Id
FROM xx_salesorder_hdr_stg_tbl_ib h
JOIN xx_salesorder_line_stg_tbl_ib l ON l.hdr_record_id = h.record_id
JOIN dbo.CostManagement_Contracts c ON c.Code = l.OriginalSalesOrder
WHERE h.process_status = 'N'
AND h.IsReturnOrder = 1

--Update the original pmweb contract line id for return order lines based on original sales order line item
UPDATE l SET l.pmweb_original_contract_line_id = cl.Id
FROM xx_salesorder_line_stg_tbl_ib l
JOIN xx_salesorder_hdr_stg_tbl_ib h ON h.record_id = l.hdr_record_id
JOIN dbo.CostManagement_ContractDetails cl ON cl.ContractId = h.pmweb_original_contract_id
                                           AND cl.Field3 = l.OriginalSalesOrderItem
WHERE h.IsReturnOrder = 1
AND h.process_status = 'N'

---Update the return order as E if original pmweb contract order is not found
UPDATE xx_salesorder_hdr_stg_tbl_ib
SET process_status = 'E', error_msg = 'Original contract reference not found in PMWeb, cannot create return order', last_update_date=GETDATE()
FROM xx_salesorder_hdr_stg_tbl_ib h
WHERE h.IsReturnOrder = 1
AND h.process_status = 'N'
and (isnull(pmweb_original_contract_id,0) = 0 OR pmweb_original_contract_id='')

UPDATE h SET h.process_status = 'E', h.error_msg = 'Original contract reference not found in PMWeb, cannot create return order', h.last_update_date = GETDATE()
FROM xx_salesorder_hdr_stg_tbl_ib h
WHERE h.IsReturnOrder = 1
AND h.process_status = 'N'
AND EXISTS (select 1
			from xx_salesorder_line_stg_tbl_ib l
			where l.hdr_record_id = h.record_id
			and l.process_status = 'E'
			)


--------------------------------------------------------------------------------------------
-- Process each sales order header
--------------------------------------------------------------------------------------------
IF CURSOR_STATUS('global','hdr_cursor') >= -1
	DEALLOCATE hdr_cursor

DECLARE hdr_cursor CURSOR FOR
SELECT record_id
	,PmwebProjectId
	,PmwebCompanyId
	,IsReturnOrder
	,SalesDocumentNumber
	,isnull((select id from dbo.Currencies where code = isnull(Currency,'SAR')),38)
	,isnull(operation_flag,'I')
	,DocumentDate
	,pmweb_hdr_id
	,pmweb_original_contract_id
FROM xx_salesorder_hdr_stg_tbl_ib
WHERE process_status = 'N'

OPEN hdr_cursor

FETCH NEXT FROM hdr_cursor INTO @record_id, @PmwebProjectId, @PmwebCompanyId, @IsReturnOrder, @SalesDocumentNumber
							,@CurrencyId, @operation_flag, @DocumentDate, @pmweb_hdr_id, @pmweb_original_contract_id

WHILE @@FETCH_STATUS = 0
BEGIN TRY

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
---#########################################################################################################
-- NEW CONTRACT ORDER CREATION FLOW, EXCLUDING RETURN ORDER
---#########################################################################################################
IF @operation_flag = 'I' AND @IsReturnOrder = 0
	BEGIN TRY
		BEGIN TRAN;
		PRINT CONCAT('inserting header for ', @SalesDocumentNumber)

		INSERT INTO dbo.CostManagement_Contracts
			(ProjectId,CompanyId,Code,RevisionNumber,RevisionDate,DocStatusId,CurrencyId,
			IsActive,IsUseUnit,CreatedBy,CreateDate,Reference,EffectiveDate,
			AllowOverBilling,MaxBilling,MaxLineBilling,IsLineOverBilling,IsTotalOverbilling,PaidInFull,UseRevisedUnit)
		VALUES (@PmwebProjectId,@PmwebCompanyId,@SalesDocumentNumber,0,GETDATE(),5,@CurrencyId,
				1,1,5,GETDATE(),@SalesDocumentNumber,@DocumentDate,
				0,0,0,0,0,0,0)

		SET @pmweb_hdr_id = SCOPE_IDENTITY()
		PRINT CONCAT('@pmweb_hdr_id = ', @pmweb_hdr_id)

		---Insert lines
		INSERT INTO dbo.CostManagement_ContractDetails
			(ContractId,Linenumber,ItemId,Description,Quantity,CurrencyId,
			UOMId,UnitCost,TotalCost,TotalPrice,
			CostCodeId,Field1,Field2,Field3)
		SELECT @pmweb_hdr_id, cast(l.linenumber as bigint),l.pmwebitemid,l.ItemDescription,l.Quantity,@CurrencyId,
			u.Id,cast(l.NetValueWithTax/l.Quantity as decimal(32,5)),l.NetValueWithTax,l.NetValueWithTax,
			l.pmwebcostcodeid,l.QuotationNumber,l.QuotationItem,l.LineNumber
		FROM xx_salesorder_line_stg_tbl_ib l
		JOIN dbo.UOM u ON u.UOM = l.Uom
		WHERE l.hdr_record_id = @record_id

		PRINT CONCAT('After contract lines insert, rows = ', @@ROWCOUNT)

		UPDATE xx_salesorder_hdr_stg_tbl_ib
		SET process_status = 'S', pmweb_hdr_id = @pmweb_hdr_id, last_update_date=GETDATE(), error_msg=null, operation_flag='I'
		WHERE record_id = @record_id

		UPDATE l
		SET l.pmweb_line_id = d.id, l.process_status = 'S', l.last_update_date = GETDATE(), l.error_msg = NULL, l.operation_flag = 'I'
		FROM xx_salesorder_line_stg_tbl_ib l
		JOIN dbo.CostManagement_ContractDetails d ON d.Linenumber = cast(l.linenumber as bigint)
		WHERE d.ContractId = @pmweb_hdr_id
		AND l.hdr_record_id = @record_id

		COMMIT TRAN;
	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0
			ROLLBACK TRAN;

		PRINT 'Error in sales order creation' + ERROR_MESSAGE()
		UPDATE xx_salesorder_line_stg_tbl_ib
		SET process_status = 'E', error_msg = 'Error in sales order creation. '+ERROR_MESSAGE(), operation_flag='I'
		WHERE hdr_record_id = @record_id

		UPDATE xx_salesorder_hdr_stg_tbl_ib
		SET process_status = 'E', error_msg = 'Error in sales order creation. '+ERROR_MESSAGE(), operation_flag='I'
		WHERE record_id = @record_id

		
	END CATCH

---#########################################################################################################
-- NEW CONTRACT CHANGE ORDER CREATION FOR RETURN ORDER
---#########################################################################################################
IF @operation_flag = 'I' AND @IsReturnOrder = 1
	BEGIN TRY
		BEGIN TRAN;
		PRINT CONCAT('Return order, create change order ', @SalesDocumentNumber)

		DELETE FROM @Result;

		INSERT INTO @Result (ID)
		exec dbo.APIC_CostManagement_AddContractCO
			@ProjectId=@PmwebProjectId,@RecordNumber=N'',@ContractId=@pmweb_original_contract_id,@CODate=@DocumentDate
			,@Description=N'',@DocStatusId=5,@Days=0,@EffectiveDate=@DocumentDate
			,@IsActive=1,@RevisionNumber=0,@DefaultMarkup=0,@Reference=@SalesDocumentNumber
			,@CategoryId=0,@CreatedBy=5,@CurrencyId=@CurrencyId
			,@WBSId=0
		
		SELECT @pmweb_contractco_id = ID FROM @Result;
		PRINT CONCAT('After return order creation, @pmweb_contractco_id = ', @pmweb_contractco_id)

		INSERT INTO dbo.CostManagement_ContractCODetails
				(LineNumber
				,Description,UOMId,Quantity,UnitPrice
				,OwnerBudget,MarkupPct,Markup,TotalPrice
				,CostCodeId,ContractCOId,ItemCode,CurrencyId
				,Field1,Field2,Field3
				,ContractLineId,Modifier,ModifiedOn)
		SELECT cast(l.linenumber as bigint),
				l.ItemDescription,(select id from dbo.uom where uom=l.uom), l.Quantity,
				cast(l.NetValueWithTax/l.Quantity as decimal(32,5)),
				l.NetValueWithTax,0,0,l.NetValueWithTax,
				l.pmwebcostcodeid,@pmweb_contractco_id,l.pmwebitemid,@CurrencyId,
				l.QuotationNumber,l.QuotationItem,l.LineNumber
				,l.pmweb_original_contract_line_id,5,GETDATE()
		FROM xx_salesorder_line_stg_tbl_ib l
		WHERE l.hdr_record_id = @record_id

		PRINT CONCAT('After return order CO line insert, rows = ', @@ROWCOUNT)

		UPDATE xx_salesorder_hdr_stg_tbl_ib
		SET process_status = 'S', pmweb_contractco_id = @pmweb_contractco_id, last_update_date=GETDATE(), error_msg=null, operation_flag='I'
		WHERE record_id = @record_id

		UPDATE l
		SET l.pmweb_contractco_line_id = d.id, l.process_status = 'S', l.last_update_date = GETDATE(), l.error_msg = NULL, l.operation_flag = 'I'
		FROM xx_salesorder_line_stg_tbl_ib l
		JOIN dbo.CostManagement_ContractCODetails d ON d.Linenumber = cast(l.linenumber as bigint)
		WHERE d.ContractCOId = @pmweb_contractco_id
		AND l.hdr_record_id = @record_id

		COMMIT TRAN;
	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0
			ROLLBACK TRAN;

		PRINT 'Error in return order CO creation' + ERROR_MESSAGE()
		UPDATE xx_salesorder_line_stg_tbl_ib
		SET process_status = 'E', error_msg = 'Error in return order CO creation. '+ERROR_MESSAGE(), operation_flag='I'
		WHERE hdr_record_id = @record_id

		UPDATE xx_salesorder_hdr_stg_tbl_ib
		SET process_status = 'E', error_msg = 'Error in return order CO creation. '+ERROR_MESSAGE(), operation_flag='I'
		WHERE record_id = @record_id

		
	END CATCH

---#########################################################################################################
-- CONTRACT ORDER ALREADY EXISTS, EITHER UPDATE OR CREATE A CHANGE ORDER
-- REVIEW LATER:  branch for operation_flag = 'U' with IsReturnOrder = 1 (existing return order),
---#########################################################################################################
IF @operation_flag = 'U' AND @IsReturnOrder = 0
	BEGIN TRY
		PRINT CONCAT('in update of record id = ', @record_id)
		BEGIN TRAN;

		SET @deliveryexists = (select count(*) from dbo.CostManagement_Productions where PrimeContractId = @pmweb_hdr_id)

		---Check if there is only item change and no qty/price change
		SET @onlyitemchange = (SELECT count(d.id)
								FROM xx_salesorder_line_stg_tbl_ib l
								JOIN dbo.CostManagement_ContractDetails d ON d.field3 = l.LineNumber
								WHERE d.ContractId = @pmweb_hdr_id
								AND l.hdr_record_id = @record_id
								AND l.Quantity = d.Quantity AND l.NetValueWithTax = d.TotalPrice
								AND l.PmwebItemId <> d.ItemId
								)

		---Check if there are any new lines added to SO
		SET @newlineaddedinso = (SELECT count(l.record_id)
								FROM xx_salesorder_line_stg_tbl_ib l
								WHERE l.hdr_record_id = @record_id
								AND l.process_status = 'N'
								AND NOT EXISTS (Select 1 From dbo.CostManagement_ContractDetails d
												Where d.ContractId = @pmweb_hdr_id
												And d.field3 = l.LineNumber
												)
								)

		PRINT CONCAT('@deliveryexists = ', @deliveryexists, ', @onlyitemchange = ', @onlyitemchange, ', @newlineaddedinso = ', @newlineaddedinso)

---#########################################################################################################
-- CONTRACT ORDER UPDATE FLOW
---#########################################################################################################

		---No delivery exists OR if delivery exists and Only item change and no new line, update the sales order
		IF @deliveryexists = 0 OR (@deliveryexists = 1 AND @onlyitemchange > 0 AND @newlineaddedinso = 0)
		BEGIN
			PRINT CONCAT('Updating sales order for ', @SalesDocumentNumber)

			MERGE INTO dbo.CostManagement_ContractDetails tgt
			USING (SELECT @pmweb_hdr_id contract_id
						,l.linenumber
						,l.pmwebitemid
						,l.ItemDescription
						,l.Quantity
						,@CurrencyId currencyid
						,u.Id uomid
						,cast(l.NetValueWithTax/l.Quantity as decimal(32,5)) unitcost
						,l.NetValueWithTax TotalCost
						,l.pmwebcostcodeid
						,l.QuotationNumber
						,l.QuotationItem
					FROM xx_salesorder_line_stg_tbl_ib l
					JOIN xx_salesorder_hdr_stg_tbl_ib h ON h.record_id = l.hdr_record_id
					JOIN dbo.UOM u ON u.UOM = l.Uom
					WHERE l.hdr_record_id = @record_id
					AND h.pmweb_hdr_id IS NOT NULL
				) src
			ON (tgt.ContractId = src.contract_id AND tgt.Field3 = src.LineNumber)
			WHEN MATCHED THEN
				UPDATE SET tgt.ItemId = src.pmwebitemid
					,tgt.Description = src.ItemDescription
					,tgt.Quantity = src.Quantity
					,tgt.UnitCost = src.UnitCost
					,tgt.TotalCost = src.TotalCost
					,tgt.TotalPrice = src.TotalCost
					,tgt.CostCodeId = src.pmwebcostcodeid
					,tgt.Field1 = src.QuotationNumber
					,tgt.Field2 = src.QuotationItem
					,tgt.modifier = 5
					,tgt.modifiedOn = getdate()
			WHEN NOT MATCHED THEN
				INSERT
					(ContractId,Linenumber,ItemId,Description,Quantity,CurrencyId,
					UOMId,UnitCost,TotalCost,TotalPrice,CostCodeId,Field1,Field2,Field3)
				VALUES
					(src.contract_id,src.linenumber,src.pmwebitemid,src.ItemDescription,src.Quantity,src.currencyid,
					src.uomId,src.UnitCost,src.TotalCost,src.TotalCost,src.pmwebcostcodeid,src.QuotationNumber,src.QuotationItem,src.LineNumber);

			PRINT CONCAT('after merge, rows = ', @@ROWCOUNT)

			UPDATE xx_salesorder_hdr_stg_tbl_ib
			SET process_status = 'S', pmweb_hdr_id = @pmweb_hdr_id, last_update_date=GETDATE(), error_msg=null, operation_flag='U'
			WHERE record_id = @record_id

			UPDATE l
			SET l.pmweb_line_id = d.id, l.process_status = 'S', l.last_update_date = GETDATE(), l.error_msg = NULL, l.operation_flag = 'U'
			FROM xx_salesorder_line_stg_tbl_ib l
			JOIN dbo.CostManagement_ContractDetails d ON d.field3 = l.linenumber
			WHERE d.ContractId = @pmweb_hdr_id
			AND l.hdr_record_id = @record_id
		END --End of sale order update

---#########################################################################################################
-- CHANGE ORDER CREATION FLOW WHEN DELIVERY EXISTS FOR NORMAL ORDERS, WHEN NEW LINE IS ADDED OR QTY IS CHANGED
---#########################################################################################################
		IF @deliveryexists > 0 AND (@onlyitemchange <> 0 OR @newlineaddedinso > 0)
		BEGIN TRY
			PRINT CONCAT('delivery exists, creating CO for contract id = ', @pmweb_hdr_id)

			DELETE FROM @Result;

			INSERT INTO @Result (ID)
			exec dbo.APIC_CostManagement_AddContractCO
				@ProjectId=@PmwebProjectId,@RecordNumber=N'',@ContractId=@pmweb_hdr_id,@CODate=@DocumentDate
				,@Description=N'',@DocStatusId=5,@Days=0,@EffectiveDate=@DocumentDate
				,@IsActive=1,@RevisionNumber=0,@DefaultMarkup=0,@Reference=@SalesDocumentNumber
				,@CategoryId=0,@CreatedBy=5,@CurrencyId=@CurrencyId
				,@WBSId=0

			SELECT @pmweb_contractco_id = ID FROM @Result;
			PRINT CONCAT('After CO creation, @pmweb_contractco_id = ', @pmweb_contractco_id)

			INSERT INTO dbo.CostManagement_ContractCODetails
				(LineNumber
				,Description,UOMId,Quantity,UnitPrice
				,OwnerBudget,MarkupPct,Markup,TotalPrice
				,CostCodeId,ContractCOId,ItemCode,CurrencyId
				,Field1,Field2,Field3
				,ContractLineId,Modifier,ModifiedOn)
			SELECT cast(l.linenumber as bigint),
					l.ItemDescription,(select id from dbo.uom where uom=l.uom), l.Quantity,
					cast(l.NetValueWithTax/l.Quantity as decimal(32,5)),
					l.NetValueWithTax,0,0,l.NetValueWithTax,
					l.pmwebcostcodeid,@pmweb_contractco_id,l.pmwebitemid,@CurrencyId,
					l.QuotationNumber,l.QuotationItem,l.LineNumber
					,l.pmweb_line_id,5,GETDATE()
			FROM xx_salesorder_line_stg_tbl_ib l
			WHERE l.hdr_record_id = @record_id

			PRINT CONCAT('after CO line insert, rows = ', @@ROWCOUNT)

			UPDATE xx_salesorder_hdr_stg_tbl_ib
			SET process_status = 'S', pmweb_contractco_id = @pmweb_contractco_id, last_update_date=GETDATE(), error_msg=null, operation_flag='I'
			WHERE record_id = @record_id

			UPDATE l
			SET l.pmweb_contractco_line_id = d.id, l.process_status = 'S', l.last_update_date = GETDATE(), l.error_msg = NULL, l.operation_flag = 'I'
			FROM xx_salesorder_line_stg_tbl_ib l
			JOIN dbo.CostManagement_ContractCODetails d ON d.Linenumber = cast(l.linenumber as bigint)
			WHERE d.ContractCOId = @pmweb_contractco_id
			AND l.hdr_record_id = @record_id
		END TRY
		BEGIN CATCH
			IF @@TRANCOUNT > 0
			ROLLBACK TRAN;

			PRINT 'Error in change order creation' + ERROR_MESSAGE()
			UPDATE xx_salesorder_line_stg_tbl_ib
			SET process_status = 'E', error_msg = 'Error in change order creation. '+ERROR_MESSAGE(), operation_flag='I'
			WHERE hdr_record_id = @record_id

			UPDATE xx_salesorder_hdr_stg_tbl_ib
			SET process_status = 'E', error_msg = 'Error in change order creation. '+ERROR_MESSAGE(), operation_flag='I'
			WHERE record_id = @record_id
		END CATCH

		COMMIT TRAN;

	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0
			ROLLBACK TRAN;

		PRINT 'Error in sales order creation' + ERROR_MESSAGE()
		UPDATE xx_salesorder_line_stg_tbl_ib
		SET process_status = 'E', error_msg = 'Error in sales order creation. '+ERROR_MESSAGE()
		WHERE hdr_record_id = @record_id

		UPDATE xx_salesorder_hdr_stg_tbl_ib
		SET process_status = 'E', error_msg = 'Error in sales order creation. '+ERROR_MESSAGE()
		WHERE record_id = @record_id

		
	END CATCH

END --IF @sameproject > 1

FETCH NEXT FROM hdr_cursor INTO @record_id, @PmwebProjectId, @PmwebCompanyId, @IsReturnOrder, @SalesDocumentNumber
							,@CurrencyId, @operation_flag, @DocumentDate, @pmweb_hdr_id, @pmweb_original_contract_id
END TRY
BEGIN CATCH
	
	PRINT 'Error in sales order creation' + ERROR_MESSAGE()
	UPDATE xx_salesorder_line_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in sales order creation'+ERROR_MESSAGE()
	WHERE hdr_record_id = @record_id

	UPDATE xx_salesorder_hdr_stg_tbl_ib
	SET process_status = 'E', error_msg = 'Error in sales order creation'+ERROR_MESSAGE()
	WHERE record_id = @record_id

	FETCH NEXT FROM hdr_cursor INTO @record_id, @PmwebProjectId, @PmwebCompanyId, @IsReturnOrder, @SalesDocumentNumber
								,@CurrencyId, @operation_flag, @DocumentDate, @pmweb_hdr_id, @pmweb_original_contract_id
END CATCH

CLOSE hdr_cursor
DEALLOCATE hdr_cursor

END TRY

BEGIN CATCH
	IF @@TRANCOUNT > 0
		ROLLBACK TRAN;

	SELECT ERROR_MESSAGE() AS 'Message'
END CATCH

SET NOCOUNT OFF
END
GO

