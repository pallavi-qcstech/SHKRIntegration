using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class BudgetCostNetworkCreateResponse
{
    [JsonPropertyName("Network")] public string Network { get; set; } = string.Empty;
    //[JsonPropertyName("RETURNSet")] public ODataResultSet<SapReturnMessage>? ReturnSet { get; set; }
}

public sealed record BudgetCostNetworkCreateResult(bool Success, string? Network, string? ErrorMessage);

public sealed record BudgetCostHeaderResult(long HdrRecordId, string? Network, bool Success, string? ErrorMessage);

public sealed record BudgetCostCreateResult(
    long PmWebBudgetId, bool Success, int Networks, int Succeeded, int Failed, IReadOnlyList<BudgetCostHeaderResult> Results);