using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class CreateProjectRequisitionRequest
{
    [JsonPropertyName("BANFN")] public string Banfn { get; set; } = string.Empty;
    [JsonPropertyName("BSART")] public string Bsart { get; set; } = string.Empty;
    [JsonPropertyName("PRHEADERSet")] public List<PrHeaderSetItem> PrHeaderSet { get; set; } = [];
    [JsonPropertyName("ZSRVSet")] public List<object> ZSrvSet { get; set; } = [];
    [JsonPropertyName("ACCOUNTSet")] public List<PrAccountSetItem> AccountSet { get; set; } = [];
    [JsonPropertyName("SRVACCSet")] public List<object> SrvAccSet { get; set; } = [];
}

public sealed class PrHeaderSetItem
{
    [JsonPropertyName("TRACKINGNO")] public string TrackingNo { get; set; } = string.Empty;
    [JsonPropertyName("PREQ_ITEM")] public string PreqItem { get; set; } = string.Empty;
    [JsonPropertyName("DOC_TYPE")] public string DocType { get; set; } = string.Empty;
    [JsonPropertyName("SHORT_TEXT")] public string ShortText { get; set; } = string.Empty;
    [JsonPropertyName("MATERIAL")] public string Material { get; set; } = string.Empty;
    [JsonPropertyName("MAT_GRP")] public string MatGrp { get; set; } = string.Empty;
    [JsonPropertyName("PLANT")] public string Plant { get; set; } = string.Empty;
    [JsonPropertyName("PUR_GROUP")] public string PurGroup { get; set; } = string.Empty;
    [JsonPropertyName("QUANTITY")] public string Quantity { get; set; } = string.Empty;
    [JsonPropertyName("UNIT")] public string Unit { get; set; } = string.Empty;
    [JsonPropertyName("PREQ_DATE")] public string PreqDate { get; set; } = string.Empty;
    [JsonPropertyName("REL_DATE")] public string RelDate { get; set; } = string.Empty;
    [JsonPropertyName("DELIV_DATE")] public string DelivDate { get; set; } = string.Empty;
    [JsonPropertyName("ITEM_CAT")] public string ItemCat { get; set; } = string.Empty;
    [JsonPropertyName("ACCTASSCAT")] public string AcctAssCat { get; set; } = string.Empty;
    [JsonPropertyName("C_AMT_BAPI")] public string CAmtBapi { get; set; } = string.Empty;
    [JsonPropertyName("PRICE_UNIT")] public string PriceUnit { get; set; } = string.Empty;
    [JsonPropertyName("CURRENCY")] public string Currency { get; set; } = string.Empty;
}

public sealed class PrAccountSetItem
{
    [JsonPropertyName("PreqNo")] public string PreqNo { get; set; } = string.Empty;
    [JsonPropertyName("PreqItem")] public string PreqItem { get; set; } = string.Empty;
    [JsonPropertyName("SerialNo")] public string SerialNo { get; set; } = string.Empty;
    [JsonPropertyName("WbsElemE")] public string WbsElemE { get; set; } = string.Empty;
    [JsonPropertyName("Network")] public string Network { get; set; } = string.Empty;
    [JsonPropertyName("Activity")] public string Activity { get; set; } = string.Empty;
    [JsonPropertyName("ProjExt")] public string ProjExt { get; set; } = string.Empty;
    [JsonPropertyName("GLAcct")] public string GlAcct { get; set; } = string.Empty;
    [JsonPropertyName("CoArea")] public string CoArea { get; set; } = string.Empty;
}
