namespace SHKRIntegration.Options;


/// Settings for the daily Vendor staging load (SAP Z_VEND_DETAILS_SRV -> PMWeb staging tables
/// xx_vendor_stg_tbl_ib / xx_vendor_address_stg_tbl_ib / xx_vendor_contacts_stg_tbl_ib /
/// xx_vendor_company_map_stg_tl_ib). Bind from configuration section "Vendor".
///
/// The SQL connection string used to be here, but moved to the shared ShkrDatabaseOptions
/// (section "Database") on 2026-09-04, once ShkrProjectService became a second consumer of the
/// same PMWeb connection string - see ShkrDatabaseOptions for why.

public sealed class ShkrVendorOptions
{
    public const string SectionName = "Vendor";

    /// <summary>Time of day (UTC) the daily background sync should run, e.g. "02:00:00".</summary>
    public TimeSpan DailyRunTimeUtc { get; set; } = TimeSpan.FromHours(2);
}
