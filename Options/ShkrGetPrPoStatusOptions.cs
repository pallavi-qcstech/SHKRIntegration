namespace SHKRIntegration.Options;

public sealed class ShkrGetPrPoStatusOptions
{
    public const string SectionName = "PrStatus";

    public string ServicePath { get; set; } = "/sap/opu/odata/sap/Z_PR_STATUS_SRV";
}
