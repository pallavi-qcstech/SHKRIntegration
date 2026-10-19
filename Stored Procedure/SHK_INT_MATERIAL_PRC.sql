USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_MATERIAL_PRC]    Script Date: 10/16/2026 3:08:47 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/* =====================================================================================
   Procedure   : dbo.SHK_INT_MATERIAL_PRC
   Purpose     : Reads unprocessed rows (process_status = 'N') from staging table
                 xx_material_stg_tbl_ib, resolves the derived foreign keys
                 (Category, Type, UOM x2, ItemGroup/ProductHierarchy), and syncs
                 them into dbo.Items - matching on Material_Number (ManufacturerNumber).

   SOURCE      : xx_material_stg_tbl_ib
                 (record_id, material_number, material_name, description,
                  company_code, material_group, material_group_descr, material_type,
                  industry, base_unit_of_measure, purchase_order_unit_of_measure,
                  department, division, product_hierarchy, lab_office,
                  operation_flag, process_status, error_msg, creation_date,
                  last_update_date, pmweb_material_id)

   TARGET      : dbo.Items  (only the 10 mapped columns are ever written by this
                 procedure - every other column is left to its table default/NULL,
                 per your confirmation. If any of those unmapped columns are
                 NOT NULL with no default in the real DDL, the INSERT will fail
                 and be caught below, landing the row in process_status = 'E'
                 rather than failing silently.)

   MAPPING (per mapping rules tab)
   ---------------------------------------------------------------------------
     material_number                 -> Items.ManufacturerNumber   (match key)
     material_name                   -> Items.ForeignKey
     description                     -> Items.Description
     material_group + '-' +
       material_group_descr          -> Portfolio_ItemCategories.Category
                                         (auto-create if missing)          -> Items.CategoryId
     material_type                   -> Portfolio_ItemTypes.Type
                                         (auto-create if missing)          -> Items.TypeId
     industry                        -> Items.SpecField4
     base_unit_of_measure            -> UOM.uom (auto-create if missing)  -> Items.InventoryUOMId
     purchase_order_unit_of_measure  -> UOM.uom (auto-create if missing)  -> Items.PurchasingUOMId
     department                      -> Items.SpecField1
     division                        -> Items.SpecField2
     product_hierarchy               -> ItemGroups full path under the root whose
                                         GroupName = company_code (dynamic, per row) -> Items.ItemGroupId
                                         NOT auto-created - error to staging if not found.
     lab_office                      -> Items.SpecField3


   ===================================================================================== */
CREATE   PROCEDURE [dbo].[SHK_INT_MATERIAL_PRC]
    
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunStartTime DATETIME2 = SYSDATETIME();
    DECLARE @ErrMsg NVARCHAR(2000);
	DECLARE @SystemUserId INT = 5

    /* -----------------------------------------------------------------
       Step 1: Pull the unprocessed batch into a working temp table.
       ----------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#Staging') IS NOT NULL DROP TABLE #Staging;

    SELECT
        stg.record_id,
        stg.material_number,
        stg.material_name,
        stg.description,
        stg.company_code,
        stg.material_group,
        NULLIF(stg.material_group_descr, 'NULL')  AS material_group_descr,
        stg.material_type,
        NULLIF(stg.industry, 'NULL')              AS industry,
        stg.base_unit_of_measure,
        stg.purchase_order_unit_of_measure,
        NULLIF(stg.department, 'NULL')            AS department,
        NULLIF(stg.division, 'NULL')              AS division,
        stg.product_hierarchy,
        NULLIF(stg.lab_office, 'NULL')            AS lab_office,
        CAST(NULL AS INT) AS CategoryId,
        CAST(NULL AS INT) AS TypeId,
        CAST(NULL AS INT) AS InventoryUOMId,
        CAST(NULL AS INT) AS PurchasingUOMId,
        CAST(NULL AS INT) AS ItemGroupId
    INTO #Staging
    FROM dbo.xx_material_stg_tbl_ib stg
    WHERE stg.process_status = 'N';

    /* -----------------------------------------------------------------
       Step 2: Defend against duplicate material_number within this batch.
       Keep the newest (by last_update_date, then record_id); park the rest.
       ----------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#Dupes') IS NOT NULL DROP TABLE #Dupes;

    SELECT record_id,
           ROW_NUMBER() OVER (
               PARTITION BY material_number
               ORDER BY (SELECT last_update_date FROM dbo.xx_material_stg_tbl_ib r WHERE r.record_id = s.record_id) DESC,
                        record_id DESC
           ) AS rn
    INTO #Dupes
    FROM #Staging s;

    UPDATE realstg
    SET process_status    = 'E',
        error_msg         = 'Duplicate material_number within incoming batch - superseded by a newer row in the same load.',
        last_update_date  = SYSDATETIME()
    FROM dbo.xx_material_stg_tbl_ib realstg
    JOIN #Dupes d ON d.record_id = realstg.record_id
    WHERE d.rn > 1;

    DELETE s FROM #Staging s JOIN #Dupes d ON d.record_id = s.record_id WHERE d.rn > 1;

    /* -----------------------------------------------------------------
       Step 3: Resolve / auto-create Material_Group -> Portfolio_ItemCategories.
       Category = material_group + '-' + material_group_descr
       ----------------------------------------------------------------- */
    BEGIN TRY
        IF OBJECT_ID('tempdb..#DistinctCategories') IS NOT NULL DROP TABLE #DistinctCategories;

        SELECT DISTINCT
            material_group,
            material_group_descr,
            CAST(material_group + N'-' + ISNULL(material_group_descr, N'') AS NVARCHAR(500)) AS CategoryText
        INTO #DistinctCategories
        FROM #Staging;

        INSERT INTO dbo.Portfolio_ItemCategories (Category, Inactive)
        SELECT dc.CategoryText, 0
        FROM #DistinctCategories dc
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.Portfolio_ItemCategories pc WHERE pc.Category = dc.CategoryText
        );

        UPDATE s
        SET s.CategoryId = pc.ID
        FROM #Staging s
        JOIN dbo.Portfolio_ItemCategories pc
             ON pc.Category = s.material_group + N'-' + ISNULL(s.material_group_descr, N'');
    END TRY
    BEGIN CATCH
        SET @ErrMsg = ERROR_MESSAGE();

        UPDATE realstg
        SET process_status    = 'E',
            error_msg         = LEFT('Failed to resolve/create Material_Group in Portfolio_ItemCategories: ' + @ErrMsg, 2000),
            last_update_date  = SYSDATETIME()
        FROM dbo.xx_material_stg_tbl_ib realstg
        JOIN #Staging s ON s.record_id = realstg.record_id;

        DELETE FROM #Staging;   -- whole batch failed this shared step; nothing left to process
    END CATCH;

    -- Any row that still didn't resolve a CategoryId (e.g. lookup insert partially failed) also errors out.
    UPDATE realstg
    SET process_status    = 'E',
        error_msg         = 'Material_Group could not be resolved to a Portfolio_ItemCategories.ID.',
        last_update_date  = SYSDATETIME()
    FROM dbo.xx_material_stg_tbl_ib realstg
    JOIN #Staging s ON s.record_id = realstg.record_id
    WHERE s.CategoryId IS NULL;

    DELETE FROM #Staging WHERE CategoryId IS NULL;

    /* -----------------------------------------------------------------
       Step 4: Resolve / auto-create Material_Type -> Portfolio_ItemTypes.
       ----------------------------------------------------------------- */
    BEGIN TRY
        INSERT INTO dbo.Portfolio_ItemTypes (Type, Inactive)
        SELECT DISTINCT s.material_type, 0
        FROM #Staging s
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.Portfolio_ItemTypes pt WHERE pt.Type = s.material_type
        );

        UPDATE s
        SET s.TypeId = pt.ID
        FROM #Staging s
        JOIN dbo.Portfolio_ItemTypes pt ON pt.Type = s.material_type;
    END TRY
    BEGIN CATCH
        SET @ErrMsg = ERROR_MESSAGE();

        UPDATE realstg
        SET process_status    = 'E',
            error_msg         = LEFT('Failed to resolve/create Material_Type in Portfolio_ItemTypes: ' + @ErrMsg, 2000),
            last_update_date  = SYSDATETIME()
        FROM dbo.xx_material_stg_tbl_ib realstg
        JOIN #Staging s ON s.record_id = realstg.record_id;

        DELETE FROM #Staging;
    END CATCH;

    UPDATE realstg
    SET process_status    = 'E',
        error_msg         = 'Material_Type could not be resolved to a Portfolio_ItemTypes.ID.',
        last_update_date  = SYSDATETIME()
    FROM dbo.xx_material_stg_tbl_ib realstg
    JOIN #Staging s ON s.record_id = realstg.record_id
    WHERE s.TypeId IS NULL;

    DELETE FROM #Staging WHERE TypeId IS NULL;

    /* -----------------------------------------------------------------
       Step 5: Resolve / auto-create both UOMs -> dbo.UOM.
       ----------------------------------------------------------------- */
    BEGIN TRY
        IF OBJECT_ID('tempdb..#DistinctUOM') IS NOT NULL DROP TABLE #DistinctUOM;

        SELECT DISTINCT uom_code
        INTO #DistinctUOM
        FROM (
            SELECT base_unit_of_measure AS uom_code FROM #Staging
            UNION
            SELECT purchase_order_unit_of_measure FROM #Staging
        ) x;

        INSERT INTO dbo.UOM (uom, createdate,Inactive)
        SELECT du.uom_code, SYSDATETIME(),0
        FROM #DistinctUOM du
        WHERE NOT EXISTS (SELECT 1 FROM dbo.UOM u WHERE u.uom = du.uom_code);

        UPDATE s
        SET s.InventoryUOMId = u1.ID
        FROM #Staging s
        JOIN dbo.UOM u1 ON u1.uom = s.base_unit_of_measure;

        UPDATE s
        SET s.PurchasingUOMId = u2.ID
        FROM #Staging s
        JOIN dbo.UOM u2 ON u2.uom = s.purchase_order_unit_of_measure;
    END TRY
    BEGIN CATCH
        SET @ErrMsg = ERROR_MESSAGE();

        UPDATE realstg
        SET process_status    = 'E',
            error_msg         = LEFT('Failed to resolve/create Base/Purchase UOM in dbo.UOM: ' + @ErrMsg, 2000),
            last_update_date  = SYSDATETIME()
        FROM dbo.xx_material_stg_tbl_ib realstg
        JOIN #Staging s ON s.record_id = realstg.record_id;

        DELETE FROM #Staging;
    END CATCH;

    UPDATE realstg
    SET process_status    = 'E',
        error_msg         = 'Base_Unit_of_Measure or Purchase_Order_Unit_of_Measure could not be resolved to a UOM.ID.',
        last_update_date  = SYSDATETIME()
    FROM dbo.xx_material_stg_tbl_ib realstg
    JOIN #Staging s ON s.record_id = realstg.record_id
    WHERE s.InventoryUOMId IS NULL OR s.PurchasingUOMId IS NULL;

    DELETE FROM #Staging WHERE InventoryUOMId IS NULL OR PurchasingUOMId IS NULL;

    /* -----------------------------------------------------------------
       Step 6: Resolve Product_Hierarchy -> ItemGroups.ItemGroupId.
       Root = the ItemGroups row whose GroupName = stg.company_code
       (dynamic per row). Full path is reconstructed by walking the
       ParentId chain from each root and concatenating GroupName
       top-down (same technique used in the ProductHierarchy load),
       carried out for ALL roots at once, disambiguated by RootId.
       NOT auto-created - a miss here is a hard error per requirement #4.
       ----------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#ItemGroupPath') IS NOT NULL DROP TABLE #ItemGroupPath;

    CREATE TABLE #ItemGroupPath
    (
        Id        INT           NOT NULL PRIMARY KEY,
        RootId    INT           NOT NULL,
        GroupName VARCHAR(200)  NOT NULL,
        FullCode  VARCHAR(4000) NOT NULL
    );

    ;WITH AllPaths AS
    (
        SELECT ig.Id, ig.Id AS RootId, ig.GroupName, CAST('' AS VARCHAR(4000)) AS FullCode
        FROM dbo.ItemGroups ig
        WHERE ig.ParentId IS NULL AND ig.IsDeleted = 0

        UNION ALL

        SELECT c.Id, p.RootId, c.GroupName, CAST(p.FullCode + c.GroupName AS VARCHAR(4000))
        FROM dbo.ItemGroups c
        JOIN AllPaths p ON p.Id = c.ParentId
        WHERE c.IsDeleted = 0
    )
    INSERT INTO #ItemGroupPath (Id, RootId, GroupName, FullCode)
    SELECT Id, RootId, GroupName, FullCode
    FROM AllPaths
    OPTION (MAXRECURSION 100);

    -- Resolve each row's root by company_code, then match product_hierarchy to a FullCode under that root.
    UPDATE s
    SET s.ItemGroupId = p.Id
    FROM #Staging s
    JOIN #ItemGroupPath rootp
         ON rootp.RootId = rootp.Id
        AND rootp.GroupName = CAST(s.company_code AS VARCHAR(50))
    JOIN #ItemGroupPath p
         ON p.RootId = rootp.Id
        AND p.FullCode = s.product_hierarchy;

    -- Company code root not found at all under any ItemGroups top level.
    UPDATE realstg
    SET process_status    = 'E',
        error_msg         = 'Company_Code has no matching top-level GroupName in dbo.ItemGroups.',
        last_update_date  = SYSDATETIME()
    FROM dbo.xx_material_stg_tbl_ib realstg
    JOIN #Staging s ON s.record_id = realstg.record_id
    WHERE s.ItemGroupId IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM #ItemGroupPath rootp
          WHERE rootp.RootId = rootp.Id AND rootp.GroupName = CAST(s.company_code AS VARCHAR(50))
      );

    -- Root found, but product_hierarchy doesn't match any node under it -> required error path (requirement #4).
    UPDATE realstg
    SET process_status    = 'E',
        error_msg         = 'Product_Hierarchy not found under the ItemGroups top level for this Company_Code.',
        last_update_date  = SYSDATETIME()
    FROM dbo.xx_material_stg_tbl_ib realstg
    JOIN #Staging s ON s.record_id = realstg.record_id
    WHERE s.ItemGroupId IS NULL
      AND EXISTS (
          SELECT 1 FROM #ItemGroupPath rootp
          WHERE rootp.RootId = rootp.Id AND rootp.GroupName = CAST(s.company_code AS VARCHAR(50))
      );

    DELETE FROM #Staging WHERE ItemGroupId IS NULL;

    /* -----------------------------------------------------------------
       Step 7: Final MERGE into dbo.Items - match on ManufacturerNumber.
       ----------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#MergeOutput') IS NOT NULL DROP TABLE #MergeOutput;
    CREATE TABLE #MergeOutput
    (
        record_id   INT,
        ItemId      INT,
        Action      VARCHAR(10)
    );

    BEGIN TRY
        MERGE dbo.Items AS tgt
        USING #Staging AS src
        ON tgt.ManufacturerNumber = src.material_number
        WHEN MATCHED THEN
            UPDATE SET
                tgt.Description      = src.description,
                tgt.ForeignKey        = src.material_name,
                tgt.CategoryId        = src.CategoryId,
                tgt.TypeId            = src.TypeId,
                tgt.SpecField4        = src.industry,
                tgt.InventoryUOMId    = src.InventoryUOMId,
                tgt.PurchasingUOMId   = src.PurchasingUOMId,
                tgt.SpecField1        = src.department,
                tgt.SpecField2        = src.division,
                tgt.ItemGroupId       = src.ItemGroupId,
                tgt.SpecField3        = src.lab_office,
                tgt.UpdatedDate       = SYSDATETIME(),
                tgt.UpdatedBy         = @SystemUserId
        WHEN NOT MATCHED THEN
            INSERT (ManufacturerNumber, ForeignKey, Description, CategoryId, TypeId, SpecField4,
                    InventoryUOMId, PurchasingUOMId, SpecField1, SpecField2, ItemGroupId, SpecField3,
                    IsActive, CreatedDate, CreatedBy, UpdatedDate, UpdatedBy)
            VALUES (src.material_number, src.material_name, src.description, src.CategoryId, src.TypeId, src.industry,
                    src.InventoryUOMId, src.PurchasingUOMId, src.department, src.division, src.ItemGroupId, src.lab_office,
                    1, SYSDATETIME(), @SystemUserId, SYSDATETIME(), @SystemUserId)
        OUTPUT src.record_id, INSERTED.Id, $action
        INTO #MergeOutput (record_id, ItemId, Action);

        UPDATE realstg
        SET pmweb_material_id = mo.ItemId,
            operation_flag    = CASE WHEN mo.Action = 'INSERT' THEN 'I' ELSE 'U' END,
            process_status    = 'S',
            error_msg         = NULL,
            last_update_date  = SYSDATETIME()
        FROM dbo.xx_material_stg_tbl_ib realstg
        JOIN #MergeOutput mo ON mo.record_id = realstg.record_id;

    END TRY
    BEGIN CATCH
        SET @ErrMsg = ERROR_MESSAGE();

        UPDATE realstg
        SET process_status    = 'E',
            error_msg         = LEFT('Failed to insert/update dbo.Items: ' + @ErrMsg, 2000),
            last_update_date  = SYSDATETIME()
        FROM dbo.xx_material_stg_tbl_ib realstg
        JOIN #Staging s ON s.record_id = realstg.record_id
        WHERE realstg.process_status = 'N';
    END CATCH;

    /* -----------------------------------------------------------------
       Step 8: Run summary.
       ----------------------------------------------------------------- */
    SELECT
        SUM(CASE WHEN realstg.process_status = 'S' THEN 1 ELSE 0 END) AS SuccessCount,
        SUM(CASE WHEN realstg.process_status = 'E' THEN 1 ELSE 0 END) AS ErrorCount,
        COUNT(*)                                                       AS TotalInOriginalBatch,
        @RunStartTime                                                  AS RunStartTime,
        SYSDATETIME()                                                  AS RunEndTime
    FROM dbo.xx_material_stg_tbl_ib realstg
    WHERE realstg.last_update_date >= @RunStartTime;

END;
GO


