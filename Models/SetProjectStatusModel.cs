using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class SetProjectStatusRequest
{
    [JsonPropertyName("ProjectDefinition")] public string ProjectDefinition { get; set; } = string.Empty;
    [JsonPropertyName("SetUserStatus")] public string SetUserStatus { get; set; } = string.Empty;
}

public sealed class SetProjectStatusResponse
{
    [JsonPropertyName("ProjectDefinition")] public string? ProjectDefinition { get; set; }
    [JsonPropertyName("SetUserStatus")] public string? SetUserStatus { get; set; }
    [JsonPropertyName("Success")] public bool? Success { get; set; }
    [JsonPropertyName("MessageType")] public string? MessageType { get; set; }
    [JsonPropertyName("MessageId")] public string? MessageId { get; set; }
    [JsonPropertyName("MessageNumber")] public string? MessageNumber { get; set; }
    [JsonPropertyName("Message")] public string? Message { get; set; }
    [JsonPropertyName("ResultLog")] public string? ResultLog { get; set; }
    [JsonPropertyName("ActiveUserStatuses")] public string? ActiveUserStatuses { get; set; }
}

public sealed record SetProjectStatusResult(
    string? ProjectDefinition,
    string? UserStatus,
    bool Success,
    int? SapHttpStatus,
    string? ActiveUserStatuses,
    string? SapMessage,
    string? ResultLog,
    string? Error,
    [property: JsonIgnore] int ReplyStatusCode);
