namespace SHKRIntegration.Options;



public sealed class ShkrVendorOptions
{
    public const string SectionName = "Vendor";

    public TimeSpan DailyRunTimeUtc { get; set; } = TimeSpan.FromHours(2);
}
