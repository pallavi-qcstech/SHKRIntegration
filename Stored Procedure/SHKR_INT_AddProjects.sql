USE [PMWeb]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE OR ALTER PROC [dbo].[SHKR_INT_AddProjects]
AS
SET NOCOUNT ON
SET XACT_ABORT ON

BEGIN
    DECLARE @Now DATETIME2 = GETDATE()
    DECLARE @ErrorDesc VARCHAR(MAX)
    DECLARE @ErrorStatus INT

    BEGIN TRY

        DECLARE
            @ProjectProfile VARCHAR(30),
            @Projectcode    VARCHAR(150),
            @Projectname    VARCHAR(150),
            @Startdate      DATE,
            @CreatedOn      DATE,
            @Companycode    VARCHAR(30),
            @Id             BIGINT,
            @ProgramId      BIGINT,
            @CommitmentCompanyId BIGINT

        DECLARE project_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT project_profile, project_code, project_name, Start_Date, creation_date, company_code
            FROM [PMWEB\roopal.chauhan].[xx_project_stg_tbl_ib]
            WHERE process_status = 'N'

        OPEN project_cursor
        FETCH NEXT FROM project_cursor INTO
            @ProjectProfile, @Projectcode, @Projectname, @Startdate, @CreatedOn, @Companycode

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ErrorStatus = 0
            SET @ErrorDesc = ''
            SET @Id = NULL
            SET @ProgramId = NULL
            SET @CommitmentCompanyId = NULL

            IF EXISTS (SELECT 1 FROM dbo.Projects WHERE ProjectNumber = @Projectcode)
                SELECT @ErrorStatus = 1, @ErrorDesc = 'Duplicate ProjectNumber - a project with this ProjectNumber already exists in dbo.Projects. '

            -- ProjectProfile (SAP) is matched against dbo.Programs.ProgramCode
            -- ProgramId has a FK constraint (FK_Projects_Programs), so for an
            -- unresolved match - reject the row
            
            IF @ErrorStatus = 0
            BEGIN
                SET @ProgramId = (SELECT TOP 1 Id FROM dbo.Programs WHERE ProgramCode = @ProjectProfile)
                IF @ProgramId IS NULL
                    SELECT @ErrorStatus = 1, @ErrorDesc = @ErrorDesc + 'Invalid ProjectProfile - no matching ProgramCode in dbo.Programs. '
            END

            -- Companycode (SAP) is matched against dbo.Companies.CompanyCode and stored into
            -- dbo.Projects.CommitmentCompanyId 
            -- An unresolved match is rejected for consistency with ProgramId.
            IF @ErrorStatus = 0
            BEGIN
                SET @CommitmentCompanyId = (SELECT TOP 1 Id FROM dbo.Companies WHERE CompanyCode = @Companycode)
                IF @CommitmentCompanyId IS NULL
                    SELECT @ErrorStatus = 1, @ErrorDesc = @ErrorDesc + 'Invalid Companycode - no matching CompanyCode in dbo.Companies. '
            END

            IF @ErrorStatus = 0
            BEGIN
                INSERT INTO dbo.Projects
                    (ProjectNumber, ProjectName, TargetStart, CreateDate, CreatedBy, IsRequireMasterGroup, IsInitiative, ProgramId, CommitmentCompanyId)
                VALUES
                    (@Projectcode, @Projectname, @Startdate, ISNULL(@CreatedOn, @Now), 5, 0, 0, @ProgramId, @CommitmentCompanyId)

                SET @Id = SCOPE_IDENTITY()

                UPDATE [PMWEB\roopal.chauhan].[xx_project_stg_tbl_ib]
                SET process_status = 'S', error_msg = 'Project processed successfully', pmweb_project_id = @Id, last_update_date = @Now
                WHERE project_code = @Projectcode AND process_status = 'N'
            END
            ELSE
            BEGIN
                UPDATE [PMWEB\roopal.chauhan].[xx_project_stg_tbl_ib]
                SET process_status = 'E', error_msg = @ErrorDesc, last_update_date = @Now
                WHERE project_code = @Projectcode AND process_status = 'N'
            END

            FETCH NEXT FROM project_cursor INTO
                @ProjectProfile, @Projectcode, @Projectname, @Startdate, @CreatedOn, @Companycode
        END

        CLOSE project_cursor
        DEALLOCATE project_cursor
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION

        THROW
    END CATCH
END
GO
