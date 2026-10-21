USE [PMWeb]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE   PROC [dbo].[SHK_INT_RESERVATION_IB_PRC]
AS

SET XACT_ABORT ON
DECLARE @ERROR_DESC VARCHAR(MAX);
DECLARE @ERROR_STATUS INT;


BEGIN
/*
Procedure which is called from the Reservation scheduled service, after it has saved the day's SAP
reservations into dbo.xx_sap_reservation_details_stg_tbl_ib (one row per Reservation + Item).
It picks all new data from the staging table (process_status = N), derives the PMWeb ids and validates them.

1. pmweb_project_id  - dbo.Projects.Id where ProjectNumber = ProjectDefinition (active projects only)
2. pmweb_material_id - dbo.Items.Id where ManufacturerNumber = Material
3. pmweb_costcode_id - dbo.CostCodes.Id where StuffedCodes = WbsElement + '-0-0' (same rule as the sales order)
4. pmweb_wbs_id      - dbo.WBS.Id of the Activity row under the Network row in the project's WBS configuration.
                       dbo.WBS keeps "<SAP id>|<description>" in Description.
5. A row without project, material or cost code is set to E with the reason in error_msg.
   A missing WBS id is not an error - the network/activity mapping in dbo.WBS is still to be confirmed.
6. Every other row is set to S.

The load of validated reservations into the PMWeb base tables is not part of this version - the target is
still to be agreed.

Change Log
21/10/2026 - New procedure
*/
SET NOCOUNT ON
BEGIN TRY

SET @ERROR_DESC = ''
SET @ERROR_STATUS = 0

--update pmweb project id
UPDATE s
SET pmweb_project_id = p.Id
FROM dbo.xx_sap_reservation_details_stg_tbl_ib s, dbo.Projects p
WHERE s.ProjectDefinition = p.ProjectNumber
AND p.IsActive = 1
AND s.process_status = 'N'

--update pmweb material id
UPDATE s
SET pmweb_material_id = i.Id
FROM dbo.xx_sap_reservation_details_stg_tbl_ib s, dbo.Items i
WHERE s.Material = i.ManufacturerNumber
AND s.process_status = 'N'

--update pmweb cost code id
UPDATE s
SET pmweb_costcode_id = c.Id
FROM dbo.xx_sap_reservation_details_stg_tbl_ib s, dbo.CostCodes c
WHERE s.WbsElement + '-0-0' = c.StuffedCodes
AND s.process_status = 'N'

--update pmweb wbs id - the activity row under the network row, inside the project's WBS configuration
UPDATE s
SET pmweb_wbs_id = act.Id
FROM dbo.xx_sap_reservation_details_stg_tbl_ib s
JOIN dbo.WBSConfiguration wc ON wc.ProjectId = s.pmweb_project_id
JOIN dbo.WBS net ON net.ConfigurationId = wc.Id
	AND LEFT(net.Description, CHARINDEX('|', net.Description + '|') - 1) = s.Network
JOIN dbo.WBS act ON act.ParentId = net.Id
	AND LEFT(act.Description, CHARINDEX('|', act.Description + '|') - 1) = s.Activity
WHERE s.process_status = 'N'

--Update to E where PMWeb ids are not found
UPDATE dbo.xx_sap_reservation_details_stg_tbl_ib
SET error_msg = ISNULL(error_msg, '') + 'Project not setup in PMWeb. '
WHERE process_status = 'N'
AND ISNULL(pmweb_project_id, 0) = 0

UPDATE dbo.xx_sap_reservation_details_stg_tbl_ib
SET error_msg = ISNULL(error_msg, '') + 'Item not setup in PMWeb. '
WHERE process_status = 'N'
AND ISNULL(pmweb_material_id, 0) = 0

UPDATE dbo.xx_sap_reservation_details_stg_tbl_ib
SET error_msg = ISNULL(error_msg, '') + 'Cost Code not setup in PMWeb. '
WHERE process_status = 'N'
AND ISNULL(pmweb_costcode_id, 0) = 0

UPDATE dbo.xx_sap_reservation_details_stg_tbl_ib
SET process_status = 'E', last_update_date = GETDATE()
WHERE process_status = 'N'
AND ISNULL(error_msg, '') <> ''

--Everything left has its ids
UPDATE dbo.xx_sap_reservation_details_stg_tbl_ib
SET process_status = 'S', error_msg = NULL, last_update_date = GETDATE()
WHERE process_status = 'N'

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
