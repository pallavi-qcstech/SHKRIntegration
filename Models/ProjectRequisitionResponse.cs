using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class CreateProjectRequisitionResponseBody
{
    [JsonPropertyName("BANFN")] public string Banfn { get; set; } = string.Empty;
}

public sealed record ProjectRequisitionCreateResult(bool Success, string? Banfn, string? ErrorMessage);
