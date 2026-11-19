namespace SHKRIntegration.Options;

public sealed class ShkrPrStatusOptions
{
    public const string SectionName = "PrStatus";

    public string ServicePath { get; set; } = "/sap/opu/odata/sap/Z_PR_STATUS_SRV";
}
