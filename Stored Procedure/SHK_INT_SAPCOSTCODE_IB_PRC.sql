USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_SAPCOSTCODE_IB_PRC]    Script Date: 10/16/2026 3:16:42 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE   PROC [dbo].[SHK_INT_SAPCOSTCODE_IB_PRC]
AS

SET XACT_ABORT ON
DECLARE @ERROR_DESC VARCHAR(MAX);  
DECLARE @ERROR_STATUS INT;


BEGIN
/* 
Procedure which is called by the scheduled dot net API, which extracts new/updated cost codes from SAP for a given time period
The procedure validates the data and creates/updates cost codes in PMWeb

AMC/ SCECO/ ESCO  Project Template - Has 3 levels
Installation Flow 2 & 3 (Supply  + Apply) Project Template - Has 2 levels

Rules for mapping in PMWeb
1. Level1 = project code
2. For level2 and level3 (for amc), the wbs type will be WBS Element. If parent wbs = project code, then level1
3. If parent wbs <> project code, and wbs type = WBS element, then level 3 for AMC project
4. Max number of code code levels for a project will be defined in program - dbo.Programs.SpecField4

Change Log
7/9/26 - Roopal C - New procedure
				
*/
SET NOCOUNT ON
BEGIN TRY  
--BEGIN TRAN
--Error variables  
SELECT @ERROR_STATUS=0,@ERROR_DESC=''

DECLARE
@project_id bigint
,@project_code varchar(150)
,@project_name varchar(250)
,@sap_wbs varchar(150)
,@sap_wbs_desc varchar(150)
,@parent_wbs varchar(150)
,@sap_stripped_wbs varchar(150)
,@wbs_type varchar(150)
,@pmweb_level bigint
,@pmweb_costcode_id bigint
,@operation_flag varchar(1)
,@record_id bigint
,@systemdate datetime
,@pmweb_group_id bigint
,@pmweb_costcodegroupid bigint
,@pmweb_costcodegroupdetailid bigint
,@pmweb_max_level int
,@pmweb_group_number bigint

,@wbs_config_id bigint
,@wbs_id bigint
,@parent_wbs_id bigint
,@NewLineNumber bigint
,@L1_costcodegoupdetid bigint
,@L2_costcodegoupdetid bigint
,@L3_costcodegoupdetid bigint
,@L2_detailnumber nvarchar(10)

,@ErrorNumber     BIGINT
,@ErrorProcedure  NVARCHAR(200)
,@ErrorLine       INT
,@ErrorMessage    NVARCHAR(4000)
,@ErrorDesc		NVARCHAR(4000)



SET @ERROR_DESC=''
SET @ERROR_STATUS=0
SET @systemdate = GETDATE()

--update all records as E where project code is not valid
UPDATE a
SET a.project_id = b.id, 
	pmweb_max_level=ISNULL((Select cast(p.SpecField4 AS INT) from dbo.Programs p
							where p.id = b.ProgramId),0)
FROM dbo.xx_sap_costcode_stg_tbl_ib a, dbo.projects b
WHERE (a.process_status IN ('N') OR a.process_status_wbs IN ('N'))
AND b.ProjectNumber = a.project_code and b.IsActive=1

UPDATE  a
SET a.process_status     = 'E'
	,a.error_msg = 'Invalid project code'
    ,a.last_update_date   = @systemdate
FROM dbo.xx_sap_costcode_stg_tbl_ib a
WHERE (a.process_status IN ('N') OR a.process_status_wbs IN ('N')) AND ISNULL(project_id,0) = 0

--Update the costcode ids existing ids of root level/level1
UPDATE a
SET a.process_status     = 'S'
	,a.error_msg = null
    ,a.last_update_date   = @systemdate
	,a.pmweb_costcodegroupid = g.Id
	,a.pmweb_costcodegroupdetailid = d.Id
	,a.operation_flag='U'
FROM dbo.xx_sap_costcode_stg_tbl_ib a, dbo.CostCodeGroups g, dbo.CostCodeGroupDetails d
WHERE a.process_status IN ('N')  
AND ISNULL(parent_wbs,'X') = 'X'
AND a.project_id = g.ProjectId
AND g.GroupNumber = 1
AND g.id = d.CostCodeGroupId
AND d.DetailNumber = a.project_code

--Update the costcode ids existing ids of Level2, where parent wbs = project code
UPDATE a
SET a.process_status     = 'S'
	,a.error_msg = null
    ,a.last_update_date   = @systemdate
	,a.pmweb_costcodegroupid = g.Id
	,a.pmweb_costcodegroupdetailid = d.Id
	,a.operation_flag='U'
FROM dbo.xx_sap_costcode_stg_tbl_ib a, dbo.CostCodeGroups g, dbo.CostCodeGroupDetails d
WHERE a.process_status IN ('N')  
AND ISNULL(parent_wbs,'X') <> 'X'
AND parent_wbs = project_code
AND a.project_id = g.ProjectId
AND g.GroupNumber = 2
AND g.id = d.CostCodeGroupId
AND d.DetailNumber = a.sap_stripped_wbs

--Update the costcode ids existing ids of Level2, where parent wbs = project code
UPDATE a
SET a.process_status     = 'S'
	,a.error_msg = null
    ,a.last_update_date   = @systemdate
	,a.pmweb_costcodegroupid = g.Id
	,a.pmweb_costcodegroupdetailid = d.Id
	,a.operation_flag='U'
FROM dbo.xx_sap_costcode_stg_tbl_ib a, dbo.CostCodeGroups g, dbo.CostCodeGroupDetails d
WHERE a.process_status IN ('N')  
AND ISNULL(parent_wbs,'X') <> 'X'
AND parent_wbs <> project_code
AND wbs_type = 'WBS Element'
AND a.project_id = g.ProjectId
AND g.GroupNumber = 3
AND g.id = d.CostCodeGroupId
AND d.DetailNumber = a.sap_stripped_wbs

print 'Start processing for all root level where there is no parent WBS, this means PMWeb level=project code'
----------------------------------------------------------------------------------------
--Start processing for all root level where there is no parent WBS, this means PMWeb level=project code
--For AMC projects (max 3 levels) - After adding 

IF CURSOR_STATUS('global','cc_cursor')>=-1  
	BEGIN  
	 DEALLOCATE cc_cursor 
	END  


DECLARE cc_cursor CURSOR FOR 
select 	record_id,project_id,project_code,project_name,pmweb_max_level
	,sap_wbs
	,sap_wbs_name
	,isnull(parent_wbs,'X')
	,sap_stripped_wbs
	,wbs_type
from xx_sap_costcode_stg_tbl_ib a
where process_status in ('N') 
AND wbs_type = 'WBS Element'
AND isnull(parent_wbs,'X') = 'X'

OPEN cc_cursor

FETCH NEXT FROM cc_cursor INTO @record_id
					,@project_id,@project_code,@project_name,@pmweb_max_level
					,@sap_wbs
					,@sap_wbs_desc
					,@parent_wbs
					,@sap_stripped_wbs
					,@wbs_type


WHILE @@FETCH_STATUS = 0
BEGIN TRY
	print 'Start for sap_wbs = ' print @sap_wbs
	SET @ERROR_STATUS=0
	SET @ERROR_DESC=''
	SET @pmweb_costcode_id = 0
	SET @pmweb_costcodegroupdetailid = 0
	SET @pmweb_costcodegroupid = 0
	SET @pmweb_group_id = 0
	SET @pmweb_group_number = 0
	SET @pmweb_level = 0
	
	IF @pmweb_max_level is null or @pmweb_max_level = '' or @pmweb_max_level = 0 
		SET @pmweb_max_level = 3 --Set default max level as 3

	--Check if the levels have been created for the project, if not then create all levels as per max level 
	IF (select count(*) from dbo.CostCodeGroups where ProjectId = @project_id) = 0
		BEGIN
			DECLARE @level INT
			SET @level = 1

			WHILE @level <= @pmweb_max_level
			BEGIN
				print 'In insert cost code group level = ' print @level

				INSERT INTO dbo.CostCodeGroups(GroupNumber,Description,ProjectId,NumberofCharacters)
				VALUES (@level, 
						case when @level = 1 then 'Project'
						when @level = 2 then 'Parent WBSE'
						when @level = 3 then 'Sub-Level WBSE'
						end,
						@project_id,
						case when @level = 1 then 30
						when @level = 2 then 2
						when @level = 3 then 10
						end)
				SET @level = @level + 1
			END --WHILE @level <= @pmweb_max_level

			--Enter the first level as the project code
			SET @pmweb_costcodegroupid = isnull((SELECT id from dbo.CostCodeGroups where projectid=@project_id and GroupNumber =1),0)
			print 'L1 id = ' print @pmweb_costcodegroupid

			IF @pmweb_costcodegroupid > 0 
				BEGIN
					INSERT INTO dbo.CostCodeGroupDetails(costcodegroupid,detailnumber,Description)
					VALUES (@pmweb_costcodegroupid,@project_code,@project_name)

					SET @L1_costcodegoupdetid = SCOPE_IDENTITY()
				END
			ELSE
				print 'Error in creating group level 1 for this project' 

			--Enter the second level default value as 0
			SET @pmweb_costcodegroupid = isnull((SELECT id from dbo.CostCodeGroups where projectid=@project_id and GroupNumber =2),0)
			print 'L2 id = ' print @pmweb_costcodegroupid

			IF @pmweb_costcodegroupid > 0 
				BEGIN
					INSERT INTO dbo.CostCodeGroupDetails(costcodegroupid,detailnumber,Description)
					VALUES (@pmweb_costcodegroupid,'0','Default')

					SET @L2_costcodegoupdetid = SCOPE_IDENTITY()
				END
			ELSE
				print 'Error in creating group level 2 for this project' 

			--Enter the second level default value as 3
			IF @pmweb_max_level = 3
			BEGIN
				SET @pmweb_costcodegroupid = isnull((SELECT id from dbo.CostCodeGroups where projectid=@project_id and GroupNumber =3),0)
				print 'L3 id = ' print @pmweb_costcodegroupid

				IF @pmweb_costcodegroupid > 0 
					BEGIN
					INSERT INTO dbo.CostCodeGroupDetails(costcodegroupid,detailnumber,Description)
					VALUES (@pmweb_costcodegroupid,'0','Default')

					SET @L3_costcodegoupdetid = SCOPE_IDENTITY()
					END
				ELSE
					print 'Error in creating group level 3 for this project' 
			END

			---Add the default value cost codes
			INSERT INTO dbo.CostCodes(ProjectId,Description,GLAccountId,Inactive)
			VALUES (@project_id,@project_name,0,0)

			SET @pmweb_costcode_id = SCOPE_IDENTITY()

			INSERT INTO dbo.CostCodeDetails(CostCodeGroupDetailId,CostCodeId)
			VALUES (@L1_costcodegoupdetid,@pmweb_costcode_id)

			INSERT INTO dbo.CostCodeDetails(CostCodeGroupDetailId,CostCodeId)
			VALUES (@L2_costcodegoupdetid,@pmweb_costcode_id)

			IF @pmweb_max_level = 3
			INSERT INTO dbo.CostCodeDetails(CostCodeGroupDetailId,CostCodeId)
			VALUES (@L3_costcodegoupdetid,@pmweb_costcode_id)

		END ----Check if the levels have been created for the project, if not then create all levels 

		--Update process status of level 1
		UPDATE xx_sap_costcode_stg_tbl_ib
		SET process_status = 'S', last_update_date = @systemdate,
			pmweb_level = 1, pmweb_costcodegroupid = (SELECT id from dbo.CostCodeGroups where projectid=@project_id and GroupNumber =1),
			pmweb_costcodegroupdetailid = @L1_costcodegoupdetid,
			pmweb_costcode_id=@pmweb_costcode_id
		WHERE record_id = @record_id 

		FETCH NEXT FROM cc_cursor INTO @record_id
					,@project_id,@project_code,@project_name,@pmweb_max_level
					,@sap_wbs
					,@sap_wbs_desc
					,@parent_wbs
					,@sap_stripped_wbs
					,@wbs_type

END TRY
		
BEGIN CATCH
	SET @ERROR_STATUS = 1
	SET @ErrorNumber  = ERROR_NUMBER()
	SET @ErrorProcedure  = ERROR_PROCEDURE()
	SET @ErrorLine   = ERROR_LINE()
	SET @ErrorMessage = ERROR_MESSAGE()
	SET @ErrorDesc = 'Exception in inserting costcode.'
	SET @ERROR_DESC= 'Exception in inserting costcode.' + @ErrorMessage

	print 'insert exception cost code' print @ERROR_DESC

	INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber,  ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate,ErrorDesc)
	VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, @record_id, GETDATE(),@ErrorDesc);

	IF ISNULL(@L1_costcodegoupdetid,0) = 0 ---If L1 is not created, mark all records for that project as E
		UPDATE dbo.xx_sap_costcode_stg_tbl_ib
		SET process_status     = 'E',
			error_msg = 'Error adding root level in PMWeb'+ERROR_MESSAGE(),
			last_update_date   = @systemdate,
			operation_flag     = 'I'
		WHERE project_code = @project_code
		AND process_status = 'N'

	
END CATCH

CLOSE cc_cursor;     
DEALLOCATE cc_cursor;


----------------------------------------------------------------------------------------
--Start processing for Level 2 codes
------------------------------------------------------------------------------------------
print 'Start processing for Level 2 codes'
IF CURSOR_STATUS('global','cc_cursor')>=-1  
	BEGIN  
	 DEALLOCATE cc_cursor 
	END  


DECLARE cc_cursor CURSOR FOR 
select 	record_id,project_id,project_code,project_name,pmweb_max_level
	,sap_wbs
	,sap_wbs_name
	,isnull(parent_wbs,'X')
	,sap_stripped_wbs
	,wbs_type
	,(select id from dbo.CostCodeGroupDetails where detailnumber=project_code)
from xx_sap_costcode_stg_tbl_ib a
where process_status in ('N') 
AND wbs_type = 'WBS Element'
AND isnull(parent_wbs,'X') <> 'X'
AND parent_wbs = project_code ---Where parent WBS = Project code it means L1 WBS
AND exists ((select 1 from dbo.CostCodeGroupDetails where detailnumber=project_code)) ---L1 code shiuld be there

OPEN cc_cursor

FETCH NEXT FROM cc_cursor INTO @record_id
					,@project_id,@project_code,@project_name,@pmweb_max_level
					,@sap_wbs
					,@sap_wbs_desc
					,@parent_wbs
					,@sap_stripped_wbs
					,@wbs_type
					,@L1_costcodegoupdetid

WHILE @@FETCH_STATUS = 0
BEGIN TRY
	SET @ERROR_STATUS=0
	SET @ERROR_DESC=''
	SET @pmweb_costcode_id = 0
	SET @pmweb_costcodegroupdetailid = 0
	SET @pmweb_costcodegroupid = 0
	SET @pmweb_group_id = 0
	SET @pmweb_group_number = 0
	SET @pmweb_level = 0
	SET @pmweb_group_number = 2

	print '@L1_costcodegoupdetid=' print @L1_costcodegoupdetid

	IF @pmweb_max_level is null or @pmweb_max_level = '' or @pmweb_max_level = 0 
		SET @pmweb_max_level = 3 --Set default max level as 3

	SET @pmweb_costcodegroupid = (select id from dbo.CostCodeGroups where ProjectId=@project_id and GroupNumber=@pmweb_group_number)
	--Find if level value already exists
	SET @pmweb_costcodegroupdetailid = ISNULL((select id from dbo.CostCodeGroupDetails 
										where CostCodeGroupId=@pmweb_costcodegroupid and DetailNumber=@sap_stripped_wbs),0)
	
	print 'existing @pmweb_costcodegroupdetailid = ' print @pmweb_costcodegroupdetailid
	IF @pmweb_costcodegroupdetailid > 0 -- Level value already exists, update description
		BEGIN
			UPDATE dbo.CostCodeGroupDetails SET Description = @sap_wbs_desc WHERE id = @pmweb_costcodegroupdetailid

			UPDATE dbo.xx_sap_costcode_stg_tbl_ib
			SET process_status     = 'S',
				last_update_date   = @systemdate,
				operation_flag     = 'U',
				pmweb_level = @pmweb_group_number,
				pmweb_costcodegroupid = @pmweb_costcodegroupid,
				pmweb_costcodegroupdetailid = @pmweb_costcodegroupdetailid
			WHERE record_id = @record_id

		END ----Cost code level already exists, update the description
	ELSE
	--Level value does not exist, add level  value
		BEGIN
			print 'Inserting L2 for sap_wbs = ' print @sap_wbs	
			INSERT INTO dbo.CostCodeGroupDetails(costcodegroupid,detailnumber,Description)
			VALUES (@pmweb_costcodegroupid,@sap_stripped_wbs,@sap_wbs_desc)

			SET @L2_costcodegoupdetid = (SELECT SCOPE_IDENTITY()) --Get the id of the new level 3 cost code inserted 
			print '@L2_costcodegoupdetid=' print @L2_costcodegoupdetid

			---Insert the L1 and L2 combination in cost code table
			INSERT INTO dbo.CostCodes(ProjectId,Description,GLAccountId,Inactive)
			VALUES (@project_id,@sap_wbs_desc,0,0)

			SET @pmweb_costcode_id = SCOPE_IDENTITY()
			print '@pmweb_costcode_id=' print @pmweb_costcode_id

			INSERT INTO dbo.CostCodeDetails(CostCodeGroupDetailId,CostCodeId)
			VALUES (@L1_costcodegoupdetid,@pmweb_costcode_id) ---Level 1 group detail

			INSERT INTO dbo.CostCodeDetails(CostCodeGroupDetailId,CostCodeId)
			VALUES (@L2_costcodegoupdetid,@pmweb_costcode_id) ---Level 2 group detail

			---For AMC project, the max level is 3. Hence a third level of default also need to be added
			IF @pmweb_max_level=3
				BEGIN
					print 'insert default for level 3'

					SET @L3_costcodegoupdetid = (select d.id from dbo.CostCodeGroupDetails d,dbo.CostCodeGroups c
										where d.CostCodeGroupId = c.id 
										and c.ProjectId=@project_id and c.GroupNumber=3
										and detailnumber='0'
										) 
					print '@L3_costcodegoupdetid=' print @L3_costcodegoupdetid		

					INSERT INTO dbo.CostCodeDetails(CostCodeGroupDetailId,CostCodeId)
					VALUES (@L3_costcodegoupdetid,@pmweb_costcode_id) ---Level 3 group detail

				END

			UPDATE dbo.xx_sap_costcode_stg_tbl_ib
			SET process_status     = 'S',
				last_update_date   = @systemdate,
				operation_flag     = 'I',
				pmweb_level = @pmweb_group_number,
				pmweb_costcodegroupid = @pmweb_costcodegroupid,
				pmweb_costcodegroupdetailid = @L2_costcodegoupdetid,
				pmweb_costcode_id = @pmweb_costcode_id
			WHERE record_id = @record_id

		END --Level2 does not exist, add level value

		FETCH NEXT FROM cc_cursor INTO @record_id
					,@project_id,@project_code,@project_name,@pmweb_max_level
					,@sap_wbs
					,@sap_wbs_desc
					,@parent_wbs
					,@sap_stripped_wbs
					,@wbs_type
					,@L1_costcodegoupdetid

END TRY
		
BEGIN CATCH
	SET @ERROR_STATUS = 1
	SET @ErrorNumber  = ERROR_NUMBER()
	SET @ErrorProcedure  = ERROR_PROCEDURE()
	SET @ErrorLine   = ERROR_LINE()
	SET @ErrorMessage = ERROR_MESSAGE()
	SET @ErrorDesc = 'Exception in inserting L2 costcode.'
	SET @ERROR_DESC= 'Exception in inserting L2 costcode.' + @ErrorMessage

	print 'insert exception L2 cost code' print @ERROR_DESC

	INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber,  ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate,ErrorDesc)
	VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, @record_id, GETDATE(),@ErrorDesc);

	UPDATE dbo.xx_sap_costcode_stg_tbl_ib
	SET process_status     = 'E',
		error_msg = 'Exception in inserting L2 costcode.'+ERROR_MESSAGE(),
		last_update_date   = @systemdate,
		operation_flag     = 'I'
	WHERE project_code = @project_code
	AND record_id = @record_id

	
END CATCH

CLOSE cc_cursor;     
DEALLOCATE cc_cursor;		
		


----------------------------------------------------------------------------------------
--Start processing for Level 3 codes, where L2 codes have been added successfully
------------------------------------------------------------------------------------------
print 'Start processing for Level 3 codes, where L2 codes have been added successfully'
IF CURSOR_STATUS('global','cc_cursor')>=-1  
	BEGIN  
	 DEALLOCATE cc_cursor 
	END  


DECLARE cc_cursor CURSOR FOR 
select 	record_id,project_id,project_code,project_name,pmweb_max_level
	,sap_wbs
	,sap_wbs_name
	,isnull(parent_wbs,'X')
	,sap_stripped_wbs
	,wbs_type
	,(select id from dbo.CostCodeGroupDetails where detailnumber=project_code) L1_detail_id
	,(select d.id from dbo.CostCodeGroupDetails d, dbo.CostCodeGroups c
	where d.CostCodeGroupId = c.Id and c.ProjectId=project_id and c.GroupNumber=2
	and LTRIM(RTRIM(detailnumber))=CASE
									WHEN LEFT(RIGHT(parent_wbs, LEN(parent_wbs) - LEN(project_code)), 1) = '-'
											THEN STUFF(RIGHT(parent_wbs, LEN(parent_wbs) - LEN(project_code)), 1, 1, '')
									ELSE RIGHT(parent_wbs, LEN(parent_wbs) - LEN(project_code))
									END
	) L2_detail_id
from xx_sap_costcode_stg_tbl_ib a
where process_status in ('N') 
AND wbs_type = 'WBS Element'
AND isnull(parent_wbs,'X') <> 'X'
AND parent_wbs <> project_code ---Where parent WBS <> Project code it means L2 WBS
AND exists (select 1 from dbo.CostCodeGroupDetails where detailnumber=project_code) --L1_detail_id should exists 
AND exists (select 1 from dbo.CostCodeGroupDetails d, dbo.CostCodeGroups c
			where d.CostCodeGroupId = c.Id and c.ProjectId=project_id and c.GroupNumber=2
			and LTRIM(RTRIM(detailnumber))=CASE
											WHEN LEFT(RIGHT(parent_wbs, LEN(parent_wbs) - LEN(project_code)), 1) = '-'
													THEN STUFF(RIGHT(parent_wbs, LEN(parent_wbs) - LEN(project_code)), 1, 1, '')
											ELSE RIGHT(parent_wbs, LEN(parent_wbs) - LEN(project_code))
											END
			) --L2_detail_id should exists 


OPEN cc_cursor

FETCH NEXT FROM cc_cursor INTO @record_id
					,@project_id,@project_code,@project_name,@pmweb_max_level
					,@sap_wbs
					,@sap_wbs_desc
					,@parent_wbs
					,@sap_stripped_wbs
					,@wbs_type
					,@L1_costcodegoupdetid
					,@L2_costcodegoupdetid

WHILE @@FETCH_STATUS = 0
BEGIN TRY
	SET @ERROR_STATUS=0
	SET @ERROR_DESC=''
	SET @pmweb_costcode_id = 0
	SET @pmweb_costcodegroupdetailid = 0
	SET @pmweb_costcodegroupid = 0
	SET @pmweb_group_id = 0
	SET @pmweb_group_number = 0
	SET @pmweb_level = 0
	SET @pmweb_group_number = 3

	IF @pmweb_max_level is null or @pmweb_max_level = '' or @pmweb_max_level = 0 
		SET @pmweb_max_level = 3 --Set default max level as 3

	SET @pmweb_costcodegroupid = (select id from dbo.CostCodeGroups where ProjectId=@project_id and GroupNumber=@pmweb_group_number)
	
	--Find if level value already exists
	SET @pmweb_costcodegroupdetailid = ISNULL((select id from dbo.CostCodeGroupDetails 
										where CostCodeGroupId=@pmweb_costcodegroupid and DetailNumber=@sap_stripped_wbs),0)
	print 'exising @pmweb_costcodegroupdetailid = ' print @pmweb_costcodegroupdetailid
	IF @pmweb_costcodegroupdetailid > 0 -- Level value already exists, update description
		BEGIN
			UPDATE dbo.CostCodeGroupDetails SET Description = @sap_wbs_desc WHERE id = @pmweb_costcodegroupdetailid

			UPDATE dbo.xx_sap_costcode_stg_tbl_ib
			SET process_status     = 'S',
				last_update_date   = @systemdate,
				operation_flag     = 'U',
				pmweb_level = @pmweb_group_number,
				pmweb_costcodegroupid = @pmweb_costcodegroupid,
				pmweb_costcodegroupdetailid = @pmweb_costcodegroupdetailid
			WHERE record_id = @record_id

		END ----Cost code level already exists, update the description
	ELSE
	--Level value does not exist, add level  value
		BEGIN
			print 'insertinf L3 for sap_wbs = ' print @sap_wbs	
			INSERT INTO dbo.CostCodeGroupDetails(costcodegroupid,detailnumber,Description)
			VALUES (@pmweb_costcodegroupid,@sap_stripped_wbs,@sap_wbs_desc)

			SET @L3_costcodegoupdetid = (SELECT SCOPE_IDENTITY()) --Get the id of the new level 3 cost code inserted 
			print '@L3_costcodegoupdetid' print @L3_costcodegoupdetid
			print '@L1_costcodegoupdetid' print @L1_costcodegoupdetid
			print '@L2_costcodegoupdetid' print @L2_costcodegoupdetid

			---Insert the L1 and L2 combination in cost code table
			INSERT INTO dbo.CostCodes(ProjectId,Description,GLAccountId,Inactive)
			VALUES (@project_id,@sap_wbs_desc,0,0)

			SET @pmweb_costcode_id = SCOPE_IDENTITY()
			print '@@pmweb_costcode_id' print @pmweb_costcode_id

			INSERT INTO dbo.CostCodeDetails(CostCodeGroupDetailId,CostCodeId)
			VALUES (@L1_costcodegoupdetid,@pmweb_costcode_id) ---Level 1 group detail

			INSERT INTO dbo.CostCodeDetails(CostCodeGroupDetailId,CostCodeId)
			VALUES (@L2_costcodegoupdetid,@pmweb_costcode_id) ---Level 2 group detail

			INSERT INTO dbo.CostCodeDetails(CostCodeGroupDetailId,CostCodeId)
			VALUES (@L3_costcodegoupdetid,@pmweb_costcode_id) ---Level 3 group detail

			UPDATE dbo.xx_sap_costcode_stg_tbl_ib
			SET process_status     = 'S',
				last_update_date   = @systemdate,
				operation_flag     = 'I',
				pmweb_level = @pmweb_group_number,
				pmweb_costcodegroupid = @pmweb_costcodegroupid,
				pmweb_costcodegroupdetailid = @L3_costcodegoupdetid,
				pmweb_costcode_id = @pmweb_costcode_id
			WHERE record_id = @record_id

		END --Level3 does not exist, add level value

		FETCH NEXT FROM cc_cursor INTO @record_id
					,@project_id,@project_code,@project_name,@pmweb_max_level
					,@sap_wbs
					,@sap_wbs_desc
					,@parent_wbs
					,@sap_stripped_wbs
					,@wbs_type
					,@L1_costcodegoupdetid
					,@L2_costcodegoupdetid

END TRY
		
BEGIN CATCH
	SET @ERROR_STATUS = 1
	SET @ErrorNumber  = ERROR_NUMBER()
	SET @ErrorProcedure  = ERROR_PROCEDURE()
	SET @ErrorLine   = ERROR_LINE()
	SET @ErrorMessage = ERROR_MESSAGE()
	SET @ErrorDesc = 'Exception in inserting L3 costcode.'
	SET @ERROR_DESC= 'Exception in inserting L3 costcode.' + @ErrorMessage

	print 'insert exception L3 cost code' print @ERROR_DESC

	INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber,  ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate,ErrorDesc)
	VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, @record_id, GETDATE(),@ErrorDesc);

	UPDATE dbo.xx_sap_costcode_stg_tbl_ib
	SET process_status     = 'E',
		error_msg = 'Exception in inserting L3 costcode.'+ERROR_MESSAGE(),
		last_update_date   = @systemdate,
		operation_flag     = 'I'
	WHERE project_code = @project_code
	AND record_id = @record_id

	
END CATCH

CLOSE cc_cursor;     
DEALLOCATE cc_cursor;		



print 'start of wbs processig'
----------------------START OF WBS CREATE/UPDATE--------------------------------------------
BEGIN TRY
---If the config id does not exist for a project, create config
INSERT INTO dbo.WBSConfiguration (ProjectId, CustomWBS,ProgramId,UseProgram,UsePortfolio)
    SELECT DISTINCT s.project_id, 1,0,0,0
    FROM dbo.xx_sap_costcode_stg_tbl_ib s
    WHERE s.process_status_wbs = 'N'
        AND NOT EXISTS (SELECT 1 FROM dbo.WBSConfiguration wc WHERE wc.ProjectId = s.project_id);

print 'After wbs config insert'

---update WBS config id if already exists
UPDATE s SET pmweb_wbs_config_id = wc.id
FROM dbo.xx_sap_costcode_stg_tbl_ib s
JOIN dbo.WBSConfiguration wc ON wc.ProjectId = s.project_id
WHERE s.process_status_wbs = 'N'

print 'After wbs config update in staging'

----Update E if the WBS config id cannot be resolved
UPDATE s SET 
        s.process_status_wbs   = 'E',
        s.error_msg_wbs        = 'Cannot resolve WBS configuration id for this project id',
        s.last_update_date = SYSDATETIME()
FROM dbo.xx_sap_costcode_stg_tbl_ib s
WHERE s.process_status_wbs = 'N'
AND ISNULL(pmweb_wbs_config_id,0) = 0


----Insert all the parent root level WBS if not already exists, rows where parent_wbs is null
INSERT INTO dbo.WBS(Code,Description,ConfigurationId,LineNumber)
SELECT DISTINCT 1,sap_wbs + N'|' + sap_wbs_name,pmweb_wbs_config_id,1
FROM dbo.xx_sap_costcode_stg_tbl_ib s
WHERE s.process_status_wbs = 'N'
AND ISNULL(s.parent_wbs, 'X') = 'X'
AND not exists (select 1 from dbo.WBS w
				WHERE w.ConfigurationId = s.pmweb_wbs_config_id
				AND LEFT(w.Description, CHARINDEX('|', w.Description + '|') - 1) = s.sap_wbs
				)

print 'After parent wbs insert'

--Update the pmweb id if the WBS already exists
UPDATE s
SET s.pmweb_wbs_id     = w.Id,
    s.operation_flag_wbs   = 'U',
    s.process_status_wbs   = 'S',
    s.error_msg_wbs        = NULL,
    s.last_update_date = SYSDATETIME()
FROM dbo.xx_sap_costcode_stg_tbl_ib s
JOIN dbo.wbs w ON w.ConfigurationId = s.pmweb_wbs_config_id 
			   AND LEFT(w.Description, CHARINDEX('|', w.Description + '|') - 1) = s.sap_wbs
WHERE s.process_status_wbs = 'N'

----Update status as E for records where parent_wbs is null, since it was already inserted in above steps.
UPDATE s
SET s.process_status_wbs   = 'E',
    s.error_msg_wbs        = 'Error inserting parent wbs in pmweb',
    s.last_update_date = SYSDATETIME()
FROM dbo.xx_sap_costcode_stg_tbl_ib s
WHERE s.process_status_wbs = 'N'
AND ISNULL(s.parent_wbs, 'X') = 'X'
AND ISNULL(s.pmweb_wbs_id,0) = 0

--Update the pmweb id if the WBS already exists
UPDATE s
    SET s.pmweb_wbs_id     = mw.Id,
        s.operation_flag_wbs   = 'U',
        s.process_status_wbs   = 'S',
        s.error_msg_wbs        = NULL,
        s.last_update_date = SYSDATETIME()
    FROM dbo.xx_sap_costcode_stg_tbl_ib s
    JOIN dbo.WBSConfiguration wc ON wc.ProjectId = s.project_id
    OUTER APPLY (
        SELECT TOP 1 realstg.pmweb_wbs_id
        FROM dbo.xx_sap_costcode_stg_tbl_ib realstg
        WHERE realstg.project_id = s.project_id
          AND realstg.sap_wbs    = NULLIF(s.parent_wbs, 'NULL')
          AND realstg.process_status_wbs = 'S'
        ORDER BY realstg.last_update_date DESC
    ) ph
    CROSS APPLY (
        SELECT TOP 1 w.Id
        FROM dbo.WBS w
        WHERE w.ConfigurationId = wc.Id
          AND ((w.ParentId IS NULL AND (CASE WHEN NULLIF(s.parent_wbs, 'NULL') IS NULL THEN NULL ELSE ph.pmweb_wbs_id END) IS NULL)
               OR w.ParentId = (CASE WHEN NULLIF(s.parent_wbs, 'NULL') IS NULL THEN NULL ELSE ph.pmweb_wbs_id END))
          AND LEFT(w.Description, CHARINDEX('|', w.Description + '|') - 1) = s.sap_wbs
    ) mw
    WHERE s.process_status_wbs = 'N'
      AND (NULLIF(s.parent_wbs, 'NULL') IS NULL OR ph.pmweb_wbs_id IS NOT NULL);

		

IF CURSOR_STATUS('global','wbs_cursor')>=-1  
	BEGIN  
	 DEALLOCATE wbs_cursor 
	END  

---Start cursor for creating new WBS since update has already happened above
DECLARE wbs_cursor CURSOR FOR 
select 	record_id,project_id
	,sap_wbs
	,sap_wbs_name
	,parent_wbs
	,pmweb_wbs_config_id
from xx_sap_costcode_stg_tbl_ib a
where process_status_wbs in ('N') 
and isnull(parent_wbs,'X') <> 'X'
AND ISNULL(pmweb_wbs_id,0) = 0
order by project_id,record_id

OPEN wbs_cursor

FETCH NEXT FROM wbs_cursor INTO @record_id
					,@project_id
					,@sap_wbs
					,@sap_wbs_desc
					,@parent_wbs
					,@wbs_config_id

WHILE @@FETCH_STATUS = 0
BEGIN
	SET @ERROR_STATUS=0
	SET @ERROR_DESC=''
	SET @parent_wbs_id = 0
	SET @NewLineNumber = 0
	SET @wbs_id = 0
	print 'processing insert for WBS ' print @sap_wbs

	SELECT TOP 1 @parent_wbs_id = id
    FROM dbo.WBS w
    WHERE ConfigurationId = @wbs_config_id
	AND LEFT(w.Description, CHARINDEX('|', w.Description + '|') - 1) = @parent_wbs; --assuming it is an ordered list and project hierarchy is inserted in table with parent before the child


	print 'parent wbs id = ' print @parent_wbs_id 

	SELECT @NewLineNumber = ISNULL(MAX(LineNumber), 0) + 1
    FROM dbo.WBS
    WHERE ConfigurationId = @wbs_config_id
    AND ParentId = @parent_wbs_id;

	print '@NewLineNumber' print @NewLineNumber
 
    INSERT INTO dbo.WBS (Code, Description, ParentId, LineNumber, ConfigurationId)
    VALUES (
        CAST(@NewLineNumber AS NVARCHAR(50)),
        @sap_wbs + N'|' + @sap_wbs_desc,
        @parent_wbs_id,
        @NewLineNumber,
        @wbs_config_id
    );
 
    SET @wbs_id = SCOPE_IDENTITY();

	print '@wbs_id=' print @wbs_id

	UPDATE dbo.xx_sap_costcode_stg_tbl_ib
	SET pmweb_wbs_id     = @wbs_id,
		operation_flag_wbs   = 'I',
		process_status_wbs   = 'S',
		error_msg_wbs        = NULL,
		last_update_date = SYSDATETIME()
	WHERE record_id = @record_id;


FETCH NEXT FROM wbs_cursor INTO @record_id
					,@project_id
					,@sap_wbs
					,@sap_wbs_desc
					,@parent_wbs
					,@wbs_config_id
END

CLOSE wbs_cursor;     
DEALLOCATE wbs_cursor;

END TRY
BEGIN CATCH
	SET @ERROR_STATUS = 1
	SET @ErrorNumber  = ERROR_NUMBER()
	SET @ErrorProcedure  = ERROR_PROCEDURE()
	SET @ErrorLine   = ERROR_LINE()
	SET @ErrorMessage = ERROR_MESSAGE()
	SET @ErrorDesc = 'Exception in inserting wbs.'
	SET @ERROR_DESC= 'Exception in inserting wbs.' + @ErrorMessage

	print 'insert exception wbs' print @ERROR_DESC

	UPDATE dbo.xx_sap_costcode_stg_tbl_ib
	SET process_status_wbs     = 'E',
		error_msg_wbs = 'Exception in inserting wbs.'+ERROR_MESSAGE(),
		last_update_date   = @systemdate,
		operation_flag_wbs     = 'I'
	WHERE record_id = @record_id

	INSERT INTO dbo.xx_int_ErrorLog (ErrorNumber,  ErrorProcedure, ErrorLine, ErrorMessage, TranId, ErrorDate,ErrorDesc)
	VALUES (@ErrorNumber, @ErrorProcedure, @ErrorLine, @ErrorMessage, @record_id, GETDATE(),@ErrorDesc);
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


