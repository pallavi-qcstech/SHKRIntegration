namespace SHKRIntegration.Options;



public sealed class ShkrVendorOptions
{
    public const string SectionName = "Vendor";

    public TimeSpan DailyRunTimeUtc { get; set; } = TimeSpan.FromHours(2);

    // Only used on the very first run ever, before any row exists in xx_vendor_sync_run_tbl_ib.
    public int InitialLookbackDays { get; set; } = 7;
}
