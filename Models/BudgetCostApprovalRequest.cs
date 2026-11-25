using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class BudgetCostNetworkCreateRequest
{
    [JsonPropertyName("Network")] public string Network { get; set; } = string.Empty;
    [JsonPropertyName("ACTIVITYSet")] public List<BudgetCostNetworkActivityItem> ActivitySet { get; set; } = [];
    [JsonPropertyName("RELATIONSet")] public List<object> RelationSet { get; set; } = [];
    [JsonPropertyName("ELEMENTSet")] public List<object> ElementSet { get; set; } = [];
    [JsonPropertyName("RETURNSet")] public List<object> ReturnSet { get; set; } = [];
}

// DurationNormal and WorkActivity are deliberately not part of it.
public sealed class BudgetCostNetworkActivityItem
{
    [JsonPropertyName("Activity")] public string Activity { get; set; } = string.Empty;
    [JsonPropertyName("Description")] public string Description { get; set; } = string.Empty;
    [JsonPropertyName("ControlKey")] public string ControlKey { get; set; } = string.Empty;
    [JsonPropertyName("Plant")] public string Plant { get; set; } = string.Empty;
    [JsonPropertyName("WorkCntr")] public string WorkCntr { get; set; } = string.Empty;
    [JsonPropertyName("DurationNormalUnit")] public string DurationNormalUnit { get; set; } = string.Empty;
    [JsonPropertyName("UnWork")] public string UnWork { get; set; } = string.Empty;
    [JsonPropertyName("WbsElement")] public string WbsElement { get; set; } = string.Empty;
    [JsonPropertyName("Price")] public string Price { get; set; } = string.Empty;
    [JsonPropertyName("PriceUnit")] public string PriceUnit { get; set; } = string.Empty;
    [JsonPropertyName("OperationQty")] public string OperationQty { get; set; } = string.Empty;
    [JsonPropertyName("Currency")] public string Currency { get; set; } = string.Empty;
}
