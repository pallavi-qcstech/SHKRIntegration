USE [PMWeb]
GO

/*
Staging table for SAP reservation items, filled daily by the SHKRIntegration Reservation API
(ZMM_RESV_DETAIL_SRV/ReservationSet). One row per Reservation + Item: an existing row is updated, a new one inserted.

Data columns follow the Reservation Layout sheet, named as the SAP service returns them, plus Currency,
IsDeleted and ReservationType, which the service adds to the layout.

The four pmweb_* columns are derived by dbo.SHK_INT_RESERVATION_IB_PRC, which the API runs after staging:
  pmweb_project_id  - dbo.Projects.Id where ProjectNumber = ProjectDefinition (active projects only)
  pmweb_material_id - dbo.Items.Id where ManufacturerNumber = Material
  pmweb_costcode_id - dbo.CostCodes.Id where StuffedCodes = WbsElement + '-0-0' (same rule as the sales order)
  pmweb_wbs_id      - dbo.WBS.Id of the Activity row under the Network row in the project's WBS configuration

Change Log
21/10/2026 - New table
*/

CREATE TABLE dbo.xx_sap_reservation_details_stg_tbl_ib
(
    record_id               BIGINT IDENTITY(1,1) NOT NULL,

    OrderCategory           NVARCHAR(2)     NULL,
    Reservation             NVARCHAR(10)    NOT NULL,
    Item                    NVARCHAR(4)     NOT NULL,
    ReservationType         NVARCHAR(1)     NULL,
    RequirementsDate        DATE            NULL,
    ProjectDefinition       NVARCHAR(24)    NULL,
    WbsElement              NVARCHAR(24)    NULL,
    Network                 NVARCHAR(12)    NULL,
    Activity                NVARCHAR(4)     NULL,
    Material                NVARCHAR(40)    NULL,
    MaterialText            NVARCHAR(40)    NULL,
    Plant                   NVARCHAR(4)     NULL,
    StorageLocation         NVARCHAR(4)     NULL,
    RequirementQuantity     DECIMAL(13,3)   NULL,
    UnitOfEntry             NVARCHAR(3)     NULL,
    ItemCategory            NVARCHAR(1)     NULL,
    PriceUnit               DECIMAL(5,0)    NULL,
    Price                   DECIMAL(15,2)   NULL,
    Currency                NVARCHAR(5)     NULL,
    GlAccount               NVARCHAR(10)    NULL,
    ProfitCenter            NVARCHAR(10)    NULL,
    MovementAllowed         NVARCHAR(1)     NULL,
    QuantityWithdrawn       DECIMAL(13,3)   NULL,
    IsDeleted               BIT             NOT NULL CONSTRAINT DF_xx_sap_reservation_IsDeleted DEFAULT (0),

    pmweb_project_id        BIGINT          NULL,
    pmweb_material_id       BIGINT          NULL,
    pmweb_costcode_id       BIGINT          NULL,
    pmweb_wbs_id            BIGINT          NULL,

    operation_flag          VARCHAR(1)      NULL,
    process_status          VARCHAR(1)      NULL,
    error_msg               NVARCHAR(4000)  NULL,
    creation_date           DATETIME        NULL,
    last_update_date        DATETIME        NULL,

    CONSTRAINT PK_xx_sap_reservation_details_stg_tbl_ib PRIMARY KEY (record_id),
    CONSTRAINT UQ_xx_sap_reservation_details_stg_tbl_ib UNIQUE (Reservation, Item)
);
GO
