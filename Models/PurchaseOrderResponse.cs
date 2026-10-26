using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class CreatePurchaseOrderResponseBody
{
    [JsonPropertyName("PoNumber")] public string PoNumber { get; set; } = string.Empty;
}

public sealed record PurchaseOrderCreateResult(bool Success, string? PoNumber, string? ErrorMessage);
