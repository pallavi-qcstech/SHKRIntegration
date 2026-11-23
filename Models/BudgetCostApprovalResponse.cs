using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class BudgetCostNetworkCreateResponse
{
    [JsonPropertyName("Network")] public string Network { get; set; } = string.Empty;
    //[JsonPropertyName("RETURNSet")] public ODataResultSet<SapReturnMessage>? ReturnSet { get; set; }
}

public sealed record BudgetCostNetworkCreateResult(bool Success, string? Network, string? ErrorMessage);