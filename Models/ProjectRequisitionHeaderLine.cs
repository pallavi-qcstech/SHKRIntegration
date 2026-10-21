namespace SHKRIntegration.Models;

public sealed class ProjectRequisitionHeader
{
    public long RecordId { get; set; }
    public string? DocType { get; set; }
}

public sealed class ProjectRequisitionLine
{
    public long RecordId { get; set; }
    public long HdrRecordId { get; set; }

    public string? TrackingNo { get; set; }
    public string? PrebidLineNo { get; set; }
    public string? DocType { get; set; }
    public string? ShortText { get; set; }
    public string? Material { get; set; }
    public string? MatGrp { get; set; }
    public string? Plant { get; set; }
    public string? PurGroup { get; set; }
    public decimal? Quantity { get; set; }
    public string? Uom { get; set; }
    public string? PrebidDate { get; set; }
    public string? RelDate { get; set; }
    public string? DelivDate { get; set; }
    public string? ItemCat { get; set; }
    public string? AcctAssCat { get; set; }
    public decimal? PrebidAmount { get; set; }
    public string? PriceUnit { get; set; }
    public string? Currency { get; set; }

    public string? PrebidNo { get; set; }
    public string? SerialNo { get; set; }
    public string? WbsElement { get; set; }
    public string? Network { get; set; }
    public string? Activity { get; set; }
    public string? ProjExt { get; set; }
    public string? GlAcct { get; set; }
    public string? CoArea { get; set; }
}
