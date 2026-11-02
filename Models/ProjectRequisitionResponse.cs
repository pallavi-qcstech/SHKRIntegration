using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class CreateProjectRequisitionResponseBody
{
    [JsonPropertyName("BANFN")] public string Banfn { get; set; } = string.Empty;

    [JsonPropertyName("PRHEADERSet")] public PrHeaderSetResponseWrapper PrHeaderSet { get; set; } = new();
}

public sealed class PrHeaderSetResponseWrapper
{
    [JsonPropertyName("results")] public List<PrHeaderSetResponseItem> Results { get; set; } = [];
}

public sealed class PrHeaderSetResponseItem
{
    [JsonPropertyName("PREQ_ITEM")] public string PreqItem { get; set; } = string.Empty;
}

public sealed record ProjectRequisitionCreateResult(
    bool Success, string? Banfn, string? ErrorMessage, IReadOnlyList<string>? ConfirmedLineItems = null);
