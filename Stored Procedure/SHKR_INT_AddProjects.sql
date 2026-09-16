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
            @ProjectProfile VARCHAR(250),
            @Projectcode    VARCHAR(250),
            @Projectname    VARCHAR(250),
            @Startdate      DATETIME2,
            @CreatedOn      DATETIME2,
            @Companycode    VARCHAR(250),
            @Id             BIGINT

        DECLARE project_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT ProjectProfile, Projectcode, Projectname, Startdate, CreatedOn, Companycode
            FROM dbo.xx_project_stg_tbl_ib
            WHERE ProcessStatus = 'N'

        OPEN project_cursor
        FETCH NEXT FROM project_cursor INTO
            @ProjectProfile, @Projectcode, @Projectname, @Startdate, @CreatedOn, @Companycode

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ErrorStatus = 0
            SET @ErrorDesc = ''
            SET @Id = NULL

            IF EXISTS (SELECT 1 FROM dbo.Projects WHERE ProjectNumber = @Projectcode)
                SELECT @ErrorStatus = 1, @ErrorDesc = 'Duplicate ProjectNumber - a project with this ProjectNumber already exists in dbo.Projects. '

            IF @ErrorStatus = 0
            BEGIN
                INSERT INTO dbo.Projects
                    (ProjectNumber, ProjectName, TargetStart, CreateDate, CreatedBy, IsRequireMasterGroup, IsInitiative)
                VALUES
                    (@Projectcode, @Projectname, @Startdate, ISNULL(@CreatedOn, @Now), 5, 0, 0)

                SET @Id = SCOPE_IDENTITY()

                EXEC dbo.Log_AddAuditTrail 'Insert', 'dbo.Projects', 'PROJECT', @Id, 5, -1, 'Header', '', 'SAP_INTEGRATION'

                INSERT INTO dbo.FileManager_Folders
                            (FolderName, ObjectTypeId, ObjectId, ParentId, CreatedBy, CreatedDate)
                    VALUES
                            (NULL, 1, @Id, NULL, 5, @Now)

                DECLARE @Project_TypeId AS TINYINT
                SELECT @Project_TypeId = Id FROM dbo.ObjectTypes WHERE [TYPE] LIKE 'PROJECT'

                IF NOT EXISTS (SELECT * FROM dbo.UserEntities WHERE UserId = 5 AND EntityTypeId = @Project_TypeId AND EntityId IN (-1, 0))
                BEGIN
                    INSERT INTO dbo.UserEntities ([UserId], [EntityTypeId], [EntityId])
                    VALUES (5, @Project_TypeId, @Id)
                END

                EXEC dbo.Workflow_AddEntityWithoutTransaction 1, @Id, 5

                UPDATE dbo.xx_project_stg_tbl_ib
                SET ProcessStatus = 'S', ProcessError = 'Project processed successfully', DestProjectId = @Id, LastUpdateDate = @Now
                WHERE Projectcode = @Projectcode AND ProcessStatus = 'N'
            END
            ELSE
            BEGIN
                UPDATE dbo.xx_project_stg_tbl_ib
                SET ProcessStatus = 'E', ProcessError = @ErrorDesc, LastUpdateDate = @Now
                WHERE Projectcode = @Projectcode AND ProcessStatus = 'N'
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
