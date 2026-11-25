using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class GetPrStatusEntry
{
    [JsonPropertyName("purchase_requsition")]
    public string? PurchaseRequisition { get; set; }

    [JsonPropertyName("pr_type")]
    public string? PrType { get; set; }

    [JsonPropertyName("status")]
    public string? Status { get; set; }
}

public sealed class GetPoStatusEntry
{
    [JsonPropertyName("purchase_order")]
    public string? PurchaseOrder { get; set; }

    [JsonPropertyName("po_type")]
    public string? PoType { get; set; }

    [JsonPropertyName("status")]
    public string? Status { get; set; }
}

public sealed record SapStatusRead(
    int HttpStatus,
    string? DocumentType,
    string? Status,
    string? SapMessage,
    string RawResponse,
    string? ReadError = null);

public sealed record StatusReadResult(
    long RecordId,
    string? SapNumber,
    int? SapHttpStatus,
    string? SapStatus,
    string? ApprovalStatus,
    string? SapMessage,
    bool Updated,
    string? Error,
    [property: JsonIgnore] int ReplyStatusCode);
