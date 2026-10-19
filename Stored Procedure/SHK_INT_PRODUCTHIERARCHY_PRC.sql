USE [PMWeb]
GO

/****** Object:  StoredProcedure [dbo].[SHK_INT_PRODUCTHIERARCHY_PRC]    Script Date: 10/16/2026 3:12:19 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/* =====================================================================================
   Procedure   : dbo.SHK_INT_PRODUCTHIERARCHY_PRC
   Purpose     : Reads unprocessed rows from staging table xx_producthierarchy_stg_tbl_ib
                 and syncs them into dbo.ItemGroups, level by level (parents before
                 children), writing the resolved ItemGroups.Id, I/U flag and a
                 success/error status back onto the staging rows.

   SOURCE      : xx_producthierarchy_stg_tbl_ib
                 (record_id, product_hierarchy, parent_hierarchy, hierarchy_level,
                  node_code, description, has_children, operation_flag,
                  process_status, error_msg, creation_date, last_update_date,
                  pmweb_node_id)

   TARGET      : dbo.ItemGroups
                 (Id, GroupName, ParentId, IsDeleted, CreatedBy, CreatedDate,
                  LastModifiedBy, LastModificationDate)

   KEY DESIGN DECISIONS (confirmed with business / inferred from data profiling)
   ---------------------------------------------------------------------------
   1. GroupName = node_code, taken directly from staging - NO string
      manipulation/stripping of product_hierarchy is done anymore. node_code
      is the source system's own pre-computed "this node's segment" value.

   2. node_code is only unique WITHIN a parent (not globally - same collision
      pattern we saw when we derived it ourselves by stripping: e.g. '01',
      'AC', 'MV' repeat across different branches), so the match/exists check
      for I vs U is the composite key (ParentId, GroupName), never GroupName
      alone.
      >> Recommend a unique index on ItemGroups(ParentId, GroupName) WHERE IsDeleted = 0.

   3. dbo.ItemGroups has no column holding the original source code
      (product_hierarchy), so parent resolution for existing rows is done by
      reconstructing each node's full source-style code: walk the ParentId
      chain from the fixed root ('1000') down, concatenating GroupName
      (= node_code) segments in order. This reproduces product_hierarchy as
      long as node_code values are correct and consistently padded, which is
      now the source system's responsibility rather than ours. Rows created
      earlier in the SAME run use their real product_hierarchy value directly
      (no reconstruction needed / no risk of drift).

   4. Processing is level-by-level (1 -> max level present), because a child's
      parent may be a brand-new node being created in this very run.

   5. Only staging rows with process_status = 'N' are considered (already
      processed rows, i.e. process_status IN ('S','E') from a prior run, are
      skipped - confirmed).

   6. No soft-deletes are performed for ItemGroups rows missing from the payload
      (confirmed: payload is not treated as authoritative for removals).

   7. Duplicate product_hierarchy values WITHIN one incoming batch are defended
      against: the newest row (by last_update_date, then record_id) is kept and
      processed; the rest are marked process_status = 'E' with an explanatory
      error_msg and are not sent to ItemGroups.

   8. process_status is set to:
         'S' - inserted or updated successfully in ItemGroups
         'E' - could not be processed (see error_msg for reason)
      operation_flag is OVERWRITTEN with our own computed value ('I' or 'U'),
      replacing whatever the source system sent.

   9. CreatedBy / LastModifiedBy are hardcoded to 5 (system/job account), per
      the same convention used in the existing seed row for GroupName = 1000.

   10. This procedure does NOT wrap the whole run in one explicit transaction.
       Each level's MERGE commits as it goes, so a failure on level N does not
       roll back levels < N (already-created parents are needed by children
       processed in later runs). Failures are captured per-row via
       process_status = 'E' instead. If you need strict all-or-nothing
       semantics instead, wrap the level loop in BEGIN TRAN / COMMIT and
       remove the per-level CATCH handling.

   ===================================================================================== */
CREATE   PROCEDURE [dbo].[SHK_INT_PRODUCTHIERARCHY_PRC]
    
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RootId       INT;
    DECLARE @Lvl          INT;
    DECLARE @MaxLvl       INT;
    DECLARE @RunStartTime DATETIME2 = SYSDATETIME();
	DECLARE @SystemUserId INT = 5;

    /* -----------------------------------------------------------------
       Step 0: Confirm the fixed top-level anchor (GroupName = 1000) exists.
       Nothing can be processed without it.
       ----------------------------------------------------------------- */
    SELECT @RootId = Id
    FROM dbo.ItemGroups
    WHERE GroupName = '1000'
      AND ParentId IS NULL
      AND IsDeleted = 0;

    IF @RootId IS NULL
    BEGIN
        RAISERROR('Fixed root node (GroupName = 1000) not found in dbo.ItemGroups. Aborting run.', 16, 1);
        RETURN;
    END;

    /* -----------------------------------------------------------------
       Step 1: Pull the unprocessed batch and stage it in a working temp
       table. GroupName = node_code, straight from staging - no derivation.
       ----------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#Staging') IS NOT NULL DROP TABLE #Staging;

    SELECT
        stg.record_id,
        stg.product_hierarchy,
        NULLIF(stg.parent_hierarchy, 'NULL')  AS parent_hierarchy,   -- normalize literal 'NULL' string
        stg.hierarchy_level,
        stg.node_code                          AS GroupName,
        stg.description
    INTO #Staging
    FROM dbo.xx_producthierarchy_stg_tbl_ib stg
    WHERE stg.process_status = 'N';

    -- Basic sanity check: node_code must actually be populated to become GroupName.
    UPDATE realstg
    SET process_status = 'E',
        error_msg       = 'node_code is missing/blank - cannot derive GroupName.',
        last_update_date = SYSDATETIME()
    FROM dbo.xx_producthierarchy_stg_tbl_ib realstg
    JOIN #Staging s ON s.record_id = realstg.record_id
    WHERE s.GroupName IS NULL OR LTRIM(RTRIM(s.GroupName)) = '' OR s.GroupName = 'NULL';

    DELETE FROM #Staging WHERE GroupName IS NULL OR LTRIM(RTRIM(GroupName)) = '' OR GroupName = 'NULL';

    /* -----------------------------------------------------------------
       Step 2: Defend against duplicate product_hierarchy values inside the
       same incoming batch. Keep the newest (by last_update_date, then
       record_id); park the rest as errors.
       ----------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#Dupes') IS NOT NULL DROP TABLE #Dupes;

    SELECT record_id,
           ROW_NUMBER() OVER (
               PARTITION BY product_hierarchy
               ORDER BY (SELECT last_update_date FROM dbo.xx_producthierarchy_stg_tbl_ib r WHERE r.record_id = s.record_id) DESC,
                        record_id DESC
           ) AS rn
    INTO #Dupes
    FROM #Staging s;

    UPDATE realstg
    SET process_status = 'E',
        error_msg       = 'Duplicate product_hierarchy within incoming batch - superseded by a newer row in the same load.',
        last_update_date = SYSDATETIME()
    FROM dbo.xx_producthierarchy_stg_tbl_ib realstg
    JOIN #Dupes d ON d.record_id = realstg.record_id
    WHERE d.rn > 1;

    DELETE s
    FROM #Staging s
    JOIN #Dupes d ON d.record_id = s.record_id
    WHERE d.rn > 1;

    /* -----------------------------------------------------------------
       Step 3: Bootstrap the source-code lookup for nodes that ALREADY
       exist in ItemGroups (from prior runs), by walking the ParentId
       chain from the root and concatenating GroupName top-down.
       FullCode = '' for the root itself (parent_hierarchy is NULL for
       level-1 rows, normalized to '' below to match on the join).
       ----------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#ItemGroupPath') IS NOT NULL DROP TABLE #ItemGroupPath;

    CREATE TABLE #ItemGroupPath
    (
        Id        INT           NOT NULL PRIMARY KEY,
        ParentId  INT           NULL,
        GroupName VARCHAR(200)  NOT NULL,
        FullCode  VARCHAR(4000) NOT NULL
    );

    ;WITH ExistingPath AS
    (
        SELECT ig.Id, ig.ParentId, ig.GroupName, CAST('' AS VARCHAR(4000)) AS FullCode
        FROM dbo.ItemGroups ig
        WHERE ig.Id = @RootId

        UNION ALL

        SELECT c.Id, c.ParentId, c.GroupName, CAST(p.FullCode + c.GroupName AS VARCHAR(4000))
        FROM dbo.ItemGroups c
        JOIN ExistingPath p ON p.Id = c.ParentId
        WHERE c.IsDeleted = 0
    )
    INSERT INTO #ItemGroupPath (Id, ParentId, GroupName, FullCode)
    SELECT Id, ParentId, GroupName, FullCode
    FROM ExistingPath
    OPTION (MAXRECURSION 100);

    /* -----------------------------------------------------------------
       Step 4: Process level by level (parents before children).
       ----------------------------------------------------------------- */
    SELECT @Lvl = MIN(hierarchy_level), @MaxLvl = MAX(hierarchy_level) FROM #Staging;

    IF OBJECT_ID('tempdb..#MergeOutput') IS NOT NULL DROP TABLE #MergeOutput;
    CREATE TABLE #MergeOutput
    (
        record_id       INT,
        product_hierarchy VARCHAR(200),
        ItemGroupId     INT,
        ParentId        INT,
        GroupName       VARCHAR(200),
        Action          VARCHAR(10)
    );

    WHILE @Lvl IS NOT NULL AND @Lvl <= @MaxLvl
    BEGIN
        DELETE FROM #MergeOutput;

        BEGIN TRY
            MERGE dbo.ItemGroups AS tgt
            USING (
                SELECT
                    s.record_id,
                    s.product_hierarchy,
                    s.GroupName,
                    p.Id AS ResolvedParentId
                FROM #Staging s
                JOIN #ItemGroupPath p
                     ON p.FullCode = ISNULL(s.parent_hierarchy, '')
                WHERE s.hierarchy_level = @Lvl
            ) AS src
            ON  tgt.ParentId  = src.ResolvedParentId
            AND tgt.GroupName = src.GroupName
            AND tgt.IsDeleted = 0
            WHEN MATCHED THEN
                UPDATE SET LastModifiedBy = @SystemUserId,
                           LastModificationDate = SYSDATETIME()
            WHEN NOT MATCHED THEN
                INSERT (GroupName, ParentId, IsDeleted, CreatedBy, CreatedDate, LastModifiedBy, LastModificationDate)
                VALUES (src.GroupName, src.ResolvedParentId, 0, @SystemUserId, SYSDATETIME(), @SystemUserId, SYSDATETIME())
            OUTPUT
                src.record_id,
                src.product_hierarchy,
                INSERTED.Id,
                INSERTED.ParentId,
                INSERTED.GroupName,
                $action
            INTO #MergeOutput (record_id, product_hierarchy, ItemGroupId, ParentId, GroupName, Action);

            -- Write results back to the real staging table.
            UPDATE realstg
            SET pmweb_node_id     = mo.ItemGroupId,
                operation_flag    = CASE WHEN mo.Action = 'INSERT' THEN 'I' ELSE 'U' END,
                process_status    = 'S',
                error_msg         = NULL,
                last_update_date  = SYSDATETIME()
            FROM dbo.xx_producthierarchy_stg_tbl_ib realstg
            JOIN #MergeOutput mo ON mo.record_id = realstg.record_id;

            -- Extend the path lookup so level (@Lvl + 1) can resolve these as parents.
            -- Uses the REAL product_hierarchy value directly - no reconstruction needed.
            INSERT INTO #ItemGroupPath (Id, ParentId, GroupName, FullCode)
            SELECT mo.ItemGroupId, mo.ParentId, mo.GroupName, mo.product_hierarchy
            FROM #MergeOutput mo;

            -- Any row at this level that did NOT come back in #MergeOutput failed to
            -- resolve a parent (its parent_hierarchy wasn't found - e.g. the parent
            -- row itself errored out earlier, or is genuinely missing from the payload).
            UPDATE realstg
            SET process_status   = 'E',
                error_msg        = 'Parent hierarchy code not found (parent may have failed to process, or is missing from this payload).',
                last_update_date = SYSDATETIME()
            FROM dbo.xx_producthierarchy_stg_tbl_ib realstg
            JOIN #Staging s ON s.record_id = realstg.record_id
            WHERE s.hierarchy_level = @Lvl
              AND NOT EXISTS (SELECT 1 FROM #MergeOutput mo WHERE mo.record_id = s.record_id);

        END TRY
        BEGIN CATCH
            -- Anything not already marked 'S' in this level is flagged with the caught error.
            DECLARE @ErrMsg NVARCHAR(2000) = ERROR_MESSAGE();

            UPDATE realstg
            SET process_status   = 'E',
                error_msg        = LEFT(@ErrMsg, 2000),
                last_update_date = SYSDATETIME()
            FROM dbo.xx_producthierarchy_stg_tbl_ib realstg
            JOIN #Staging s ON s.record_id = realstg.record_id
            WHERE s.hierarchy_level = @Lvl
              AND realstg.process_status = 'N';
        END CATCH;

        SET @Lvl = @Lvl + 1;

        -- advance to the next level actually present, in case of gaps
        SELECT @Lvl = MIN(hierarchy_level)
        FROM #Staging
        WHERE hierarchy_level >= @Lvl;
    END;

    /* -----------------------------------------------------------------
       Step 5: Run summary.
       ----------------------------------------------------------------- */
    SELECT
        SUM(CASE WHEN process_status = 'S' THEN 1 ELSE 0 END) AS SuccessCount,
        SUM(CASE WHEN process_status = 'E' THEN 1 ELSE 0 END) AS ErrorCount,
        COUNT(*)                                               AS TotalInBatch,
        @RunStartTime                                          AS RunStartTime,
        SYSDATETIME()                                          AS RunEndTime
    FROM #Staging;

END;
GO


