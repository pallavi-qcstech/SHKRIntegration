USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_PROJECT_IB_PRC]    Script Date: 10/16/2026 3:14:12 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE   PROC [dbo].[SHK_INT_PROJECT_IB_PRC]
AS

SET XACT_ABORT ON
DECLARE @ERROR_DESC VARCHAR(MAX);  
DECLARE @ERROR_STATUS INT;


BEGIN
/* 
Procedure which is called by the scheduled dot net API, which extracts new/updated projects from SAP for a given time period
The procedure validates the data and creates/updates projects in PMWeb

Change Log
7/9/26 - Roopal C - New procedure
				
*/
SET NOCOUNT ON
BEGIN TRY  
--BEGIN TRAN
--Error variables  
SELECT @ERROR_STATUS=0,@ERROR_DESC=''

DECLARE
@project_code	varchar(150)
,@project_name	varchar(150)
,@project_profile	varchar(30)
,@company_code	varchar(30)
,@Start_Date	date
,@End_Date	date
,@operation_flag varchar(1)
,@pmweb_project_id bigint
,@program_id bigint
,@record_id bigint
,@systemdate datetime

---workflow variable
,@PrevStepId BIGINT
,@CurrStepId BIGINT
,@DocumentId BIGINT

,@ErrorNumber     BIGINT
,@ErrorProcedure  NVARCHAR(200)
,@ErrorLine       INT
,@ErrorMessage    NVARCHAR(4000)
,@ErrorDesc		NVARCHAR(4000)



SET @ERROR_DESC=''
SET @ERROR_STATUS=0
SET @systemdate = GETDATE()

--update all records as E where project profile is not a valid PMWeb program code
UPDATE  a
SET a.process_status     = 'E'
	,a.error_msg = 'No active program exists in PMWeb for this project profile'
    ,a.last_update_date   = @systemdate
FROM dbo.xx_project_stg_tbl_ib a
WHERE a.process_status IN ('N')
AND NOT EXISTS (Select 1 from dbo.programs where Name =  a.project_profile and IsActive=1)


--Update data for all the existing projects
BEGIN
 IF OBJECT_ID('tempdb..#MatchedProjects') IS NOT NULL DROP TABLE #MatchedProjects;
 
    SELECT
        a.project_code,
        a.project_name,
        a.Start_Date,
        a.End_Date,
        b.Id AS ProjectId
    INTO #MatchedProjects
    FROM dbo.xx_project_stg_tbl_ib a
    INNER JOIN dbo.Projects b
        ON a.project_code = b.ProjectNumber
    WHERE b.IsActive = 1
      AND a.process_status IN ('N');
 
    -- Supports the join below (project_code lookups against the captured set)
    CREATE UNIQUE CLUSTERED INDEX IX_MatchedProjects_ProjectCode
        ON #MatchedProjects (project_code);
 
    -- Update 1: dbo.Projects, driven by the pre-matched set
    UPDATE b
    SET b.ProjectName     = m.project_name,
        b.TargetStart     = m.Start_Date,
        b.TargetFinish    = m.End_Date,
        b.LastUpdateDate  = @systemdate,
        b.LastUpdatedBy   = 5
    FROM dbo.Projects b
    INNER JOIN #MatchedProjects m
        ON m.project_code = b.ProjectNumber;
 
    -- Update 2: xx_project_stg_tbl_ib, driven by the same pre-matched set
    UPDATE a
    SET a.process_status     = 'S',
        a.last_update_date   = @systemdate,
        a.operation_flag     = 'U',
        a.pmweb_project_id   = m.ProjectId
    FROM dbo.xx_project_stg_tbl_ib a
    INNER JOIN #MatchedProjects m
        ON m.project_code = a.project_code;
 
    DROP TABLE #MatchedProjects;
END


--Process new projects
IF CURSOR_STATUS('global','prj_cursor')>=-1  
	BEGIN  
	 DEALLOCATE prj_cursor 
	END  


DECLARE prj_cursor CURSOR FOR 
select 	record_id,project_code
	,project_name
	,project_profile
	,Start_Date
	,End_Date
	,(select id from dbo.Programs where Name = a.project_profile and IsActive=1) programid
from xx_project_stg_tbl_ib a
where process_status in ('N','E') and isnull(operation_flag,'I')='I'

OPEN prj_cursor

FETCH NEXT FROM prj_cursor INTO @record_id
					,@project_code
					,@project_name
					,@project_profile
					,@Start_Date
					,@End_Date
					,@program_id


WHILE @@FETCH_STATUS = 0
BEGIN
	SET @ERROR_STATUS=0
	SET @ERROR_DESC=''

	EXEC [dbo].[API_AddProject]
	@ProgramId = @program_id
	,@ProjectName= @project_name
	,@ProjectNumber = @project_code
	,@Description = @project_name
	,@CurrencyId = null
	,@DocStatusId = 5
	,@IsActive = 1
	,@PropertyId = 0
	,@Address1 = null
	,@Address2 = null
	,@GoogleAddress = null
	,@City = null
	,@StateId = null
	,@Zip = null
	,@CountryId = null
	,@Phone = null
	,@Fax = null
	,@TypeId = null
	,@CategoryId = null
	,@StatusId = null
	,@UserId = 5
	,@ClientId = null
	,@GCId = null
	,@ArchitectId = null
	,@Executive = null
	,@Manager = null
	,@Superintendents = null
    ,@CommitmentCompanyId = null
    ,@OwnerId = null
    ,@TargetBudget = null
	,@LogoFileName = null
    ,@WBSId = null
    ,@TargetRevenue = null
    ,@TargetDuration = null
    ,@TargetStart = @Start_Date
    ,@TargetFinish = @End_Date
    ,@UOMId = null
    ,@PercentComplete = null
    ,@Scope = null
    ,@Longitude = null
    ,@Latitude = null
    ,@Elevation = null
    ,@PBSId = null
    ,@APIKey =''


SET @pmweb_project_id = isnull((select id from dbo.projects where ProjectNumber = @project_code and IsActive=1),0)

IF @pmweb_project_id = 0 OR @pmweb_project_id='' 
	UPDATE a
    SET a.process_status     = 'E',
        a.last_update_date   = @systemdate,
        a.operation_flag     = 'I',
        a.error_msg   = 'Error in creating project in PMWeb'
    FROM dbo.xx_project_stg_tbl_ib a
	WHERE record_id = @record_id
ELSE
	UPDATE a
    SET a.process_status     = 'S',
        a.last_update_date   = @systemdate,
        a.operation_flag     = 'I',
        a.pmweb_project_id   = @pmweb_project_id
    FROM dbo.xx_project_stg_tbl_ib a
	WHERE record_id = @record_id

FETCH NEXT FROM prj_cursor INTO @record_id,@project_code
					,@project_name
					,@project_profile
					,@Start_Date
					,@End_Date
					,@program_id
END

CLOSE prj_cursor;     
DEALLOCATE prj_cursor;

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


