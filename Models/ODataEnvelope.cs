using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class ODataEnvelope<T>
{
    [JsonPropertyName("d")]
    public required T D { get; set; }
}

public sealed class ODataResultSet<T>
{
    [JsonPropertyName("results")]
    public List<T> Results { get; set; } = [];
}
