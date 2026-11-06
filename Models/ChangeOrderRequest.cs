using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class ChangeOrderRequest
{
    [JsonPropertyName("PoNumber")] public string PoNumber { get; set; } = string.Empty;
    [JsonPropertyName("POITEMSet")] public List<ChangeOrderItemSetItem> PoItemSet { get; set; } = [];
    [JsonPropertyName("POSCHEDSet")] public List<ChangeOrderSchedSetItem>? PoSchedSet { get; set; }
    [JsonPropertyName("POACCOUNTSet")] public List<ChangeOrderAccountSetItem>? PoAccountSet { get; set; }
}

public sealed class ChangeOrderItemSetItem
{
    [JsonPropertyName("PoItem")] public string PoItem { get; set; } = string.Empty;
    [JsonPropertyName("DeleteInd")] public string? DeleteInd { get; set; }
    [JsonPropertyName("ShortText")] public string? ShortText { get; set; }
    [JsonPropertyName("Plant")] public string? Plant { get; set; }
    [JsonPropertyName("MatlGroup")] public string? MatlGroup { get; set; }
    [JsonPropertyName("Quantity")] public string? Quantity { get; set; }
    [JsonPropertyName("PoUnit")] public string? PoUnit { get; set; }
    [JsonPropertyName("NetPrice")] public string? NetPrice { get; set; }
    [JsonPropertyName("PriceUnit")] public string? PriceUnit { get; set; }
    [JsonPropertyName("TaxCode")] public string? TaxCode { get; set; }
    [JsonPropertyName("Acctasscat")] public string? AcctAssCat { get; set; }
}

public sealed class ChangeOrderSchedSetItem
{
    [JsonPropertyName("PoItem")] public string PoItem { get; set; } = string.Empty;
    [JsonPropertyName("SchedLine")] public string SchedLine { get; set; } = string.Empty;
    [JsonPropertyName("DeliveryDate")] public string? DeliveryDate { get; set; }
    [JsonPropertyName("Quantity")] public string? Quantity { get; set; }
}

public sealed class ChangeOrderAccountSetItem
{
    [JsonPropertyName("PoItem")] public string PoItem { get; set; } = string.Empty;
    [JsonPropertyName("SerialNo")] public string SerialNo { get; set; } = string.Empty;
    [JsonPropertyName("GlAccount")] public string? GlAccount { get; set; }
    [JsonPropertyName("WbsElement")] public string? WbsElement { get; set; }
    [JsonPropertyName("Network")] public string? Network { get; set; }
    [JsonPropertyName("Activity")] public string? Activity { get; set; }
}

public sealed record ChangeOrderResult(bool Success, string? PoNumber, string? ErrorMessage);
