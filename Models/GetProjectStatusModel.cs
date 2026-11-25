using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class GetProjectStatusEntry
{
    [JsonPropertyName("ProjectNumber")] public string? ProjectNumber { get; set; }
    [JsonPropertyName("ProjectType")] public string? ProjectType { get; set; }

    [JsonPropertyName("CreatedOn")]
    [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? CreatedOn { get; set; }

    [JsonPropertyName("Status")] public string? Status { get; set; }
}

public sealed record GetProjectStatusResult(
    string? ProjectNumber,
    string? SapProjectNumber,
    string? ProjectType,
    string? CreatedOn,
    string? Status,
    bool Approved,
    int? SapHttpStatus,
    string? Error,
    [property: JsonIgnore] int ReplyStatusCode);
