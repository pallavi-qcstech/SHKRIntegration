using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class CreatePurchaseOrderRequest
{
    [JsonPropertyName("PoNumber")] public string PoNumber { get; set; } = string.Empty;
    [JsonPropertyName("CompCode")] public string CompCode { get; set; } = string.Empty;
    [JsonPropertyName("DocType")] public string DocType { get; set; } = string.Empty;
    [JsonPropertyName("Vendor")] public string Vendor { get; set; } = string.Empty;
    [JsonPropertyName("PurchOrg")] public string PurchOrg { get; set; } = string.Empty;
    [JsonPropertyName("PurGroup")] public string PurGroup { get; set; } = string.Empty;
    [JsonPropertyName("Currency")] public string Currency { get; set; } = string.Empty;
    [JsonPropertyName("DocDate")] public string DocDate { get; set; } = string.Empty;
    [JsonPropertyName("POITEMSet")] public List<PoItemSetItem> PoItemSet { get; set; } = [];
    [JsonPropertyName("POSCHEDSet")] public List<object> PoSchedSet { get; set; } = [];
    [JsonPropertyName("POACCOUNTSet")] public List<PoAccountSetItem> PoAccountSet { get; set; } = [];
    [JsonPropertyName("POSRVSet")] public List<object> PoSrvSet { get; set; } = [];
    [JsonPropertyName("POSRVVALSet")] public List<object> PoSrvValSet { get; set; } = [];
}

public sealed class PoItemSetItem
{
    [JsonPropertyName("PoItem")] public string PoItem { get; set; } = string.Empty;
    [JsonPropertyName("ShortText")] public string ShortText { get; set; } = string.Empty;
    [JsonPropertyName("Plant")] public string Plant { get; set; } = string.Empty;
    [JsonPropertyName("MatlGroup")] public string MatlGroup { get; set; } = string.Empty;
    [JsonPropertyName("Quantity")] public string Quantity { get; set; } = string.Empty;
    [JsonPropertyName("PoUnit")] public string PoUnit { get; set; } = string.Empty;
    [JsonPropertyName("NetPrice")] public string NetPrice { get; set; } = string.Empty;
    [JsonPropertyName("PriceUnit")] public string PriceUnit { get; set; } = string.Empty;
    [JsonPropertyName("TaxCode")] public string TaxCode { get; set; } = string.Empty;
    [JsonPropertyName("Acctasscat")] public string AcctAssCat { get; set; } = string.Empty;
    [JsonPropertyName("ItemCat")] public string ItemCat { get; set; } = string.Empty;
}

public sealed class PoAccountSetItem
{
    [JsonPropertyName("PoItem")] public string PoItem { get; set; } = string.Empty;
    [JsonPropertyName("SerialNo")] public string SerialNo { get; set; } = string.Empty;
    [JsonPropertyName("GlAccount")] public string GlAccount { get; set; } = string.Empty;
    [JsonPropertyName("WbsElement")] public string WbsElement { get; set; } = string.Empty;
    [JsonPropertyName("Network")] public string Network { get; set; } = string.Empty;
    [JsonPropertyName("Activity")] public string Activity { get; set; } = string.Empty;
    [JsonPropertyName("CoArea")] public string CoArea { get; set; } = string.Empty;
}
