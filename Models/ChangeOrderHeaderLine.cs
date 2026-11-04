namespace SHKRIntegration.Models;

public sealed class ChangeOrderHeader
{
    public long RecordId { get; set; }
    public string? PoNumber { get; set; }
}

public sealed class ChangeOrderLine
{
    public long RecordId { get; set; }
    public long HdrRecordId { get; set; }

    public string? LineAction { get; set; }
    public string? PoItem { get; set; }
    public string? DeleteInd { get; set; }
    public string? ShortText { get; set; }
    public string? MatGrp { get; set; }
    public string? Plant { get; set; }
    public decimal? Quantity { get; set; }
    public string? PoUnit { get; set; }
    public decimal? NetPrice { get; set; }
    public string? PriceUnit { get; set; }
    public string? TaxCode { get; set; }
    public string? AcctAssCat { get; set; }
    public string? SchedLine { get; set; }
    public string? DeliveryDate { get; set; }
    public string? SerialNo { get; set; }
    public string? WbsElement { get; set; }
    public string? GlAccount { get; set; }
    public string? Network { get; set; }
    public string? Activity { get; set; }
    public string? PreqNo { get; set; }
    public string? PreqItem { get; set; }
}
