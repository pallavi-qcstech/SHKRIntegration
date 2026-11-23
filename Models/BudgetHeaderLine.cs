namespace SHKRIntegration.Models;
public sealed class BudgetHeader
{
    public long RecordId { get; set; }
    public string? ProjectCode { get; set; }
    public long ProjectId { get; set; }
    public string? SapNetwork { get; set; }
    public string? ProcessStatus { get; set; }
}

public sealed class BudgetLine
{
    public long RecordId { get; set; }
    public long HdrRecordId { get; set; }
    public long PmWebBudgetLineId { get; set; }
    public string? SapActivity { get; set; }
    public string? SapActivityDescription { get; set; }
    public string? SapControlKey { get; set; }
    public string? SapPlant { get; set; }
    public string? SapWbsElement { get; set; }
    public long PriceUnit { get; set; }
    public decimal Price { get; set; }
    public string? ProcessStatus { get; set; }
}