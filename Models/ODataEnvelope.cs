using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

/// Every SAP Gateway OData v2 JSON response wraps its payload in a "d" property.
public sealed class ODataEnvelope<T>
{
    [JsonPropertyName("d")]
    public required T D { get; set; }
}

/// Every OData v2 navigation/collection property is wrapped as { "results": [...] }.
public sealed class ODataResultSet<T>
{
    [JsonPropertyName("results")]
    public List<T> Results { get; set; } = [];
}
