using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class ProductHierarchyNode
{
    [JsonPropertyName("ProductHierarchy")]
    public string? ProductHierarchy { get; set; }

    [JsonPropertyName("ParentHierarchy")]
    public string? ParentHierarchy { get; set; }

    [JsonPropertyName("HierarchyLevel")]
    public string? HierarchyLevel { get; set; }

    [JsonPropertyName("NodeCode")]
    public string? NodeCode { get; set; }

    [JsonPropertyName("Description")]
    public string? Description { get; set; }

    [JsonPropertyName("HasChildren")]
    public string? HasChildren { get; set; }
}
