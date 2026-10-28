namespace SHKRIntegration.Models;

public sealed class PurchaseOrderHeader
{
    public long RecordId { get; set; }
    public string? CompCode { get; set; }
    public string? DocType { get; set; }
    public string? Vendor { get; set; }
    public string? PurchOrg { get; set; }
    public string? PurGroup { get; set; }
    public string? Currency { get; set; }
    public string? DocDate { get; set; }
}

public sealed class PurchaseOrderLine
{
    public long RecordId { get; set; }
    public long HdrRecordId { get; set; }

    public string? PoItem { get; set; }
    public string? ShortText { get; set; }
    public string? MatGrp { get; set; }
    public string? Plant { get; set; }
    public decimal? Quantity { get; set; }
    public string? PoUnit { get; set; }
    public decimal? NetPrice { get; set; }
    public string? PriceUnit { get; set; }
    public string? TaxCode { get; set; }
    public string? AcctAssCat { get; set; }
    public string? WbsElement { get; set; }
    public string? GlAccount { get; set; }
    public string? CoArea { get; set; }
    public string? Network { get; set; }
    public string? Activity { get; set; }
    public string? ItemCat { get; set; }
    public string? PreqNo { get; set; }
    public string? PreqItem { get; set; }
    public string? DeliveryDate { get; set; }
}
