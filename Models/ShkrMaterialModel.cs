using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class MaterialRequest
{
    public string MaterialNumber { get; set; } = string.Empty;

    public object[] ItemSet { get; set; } = [];
}

public sealed class MaterialHeader
{
    [JsonPropertyName("MaterialNumber")]
    public string? MaterialNumber { get; set; }

    [JsonPropertyName("ItemSet")]
    public ODataResultSet<MaterialItem>? ItemSet { get; set; }
}

public sealed class MaterialItem
{
    [JsonPropertyName("MaterialNumber")]
    public string? MaterialNumber { get; set; }

    [JsonPropertyName("MaterialName")]
    public string? MaterialName { get; set; }

    [JsonPropertyName("Description")]
    public string? Description { get; set; }

    [JsonPropertyName("CompanyCode")]
    public string? CompanyCode { get; set; }

    [JsonPropertyName("MaterialGroup")]
    public string? MaterialGroup { get; set; }

    [JsonPropertyName("MaterialGroupDescr")]
    public string? MaterialGroupDescr { get; set; }

    [JsonPropertyName("MaterialType")]
    public string? MaterialType { get; set; }

    [JsonPropertyName("Industry")]
    public string? Industry { get; set; }

    [JsonPropertyName("BaseUnitofMeasure")]
    public string? BaseUnitOfMeasure { get; set; }

    [JsonPropertyName("PurchaseOrderUnitofMeasure")]
    public string? PurchaseOrderUnitOfMeasure { get; set; }

    [JsonPropertyName("DEPARMENT")]
    public string? Department { get; set; }

    [JsonPropertyName("Division")]
    public string? Division { get; set; }

    [JsonPropertyName("ProductHierarchy")]
    public string? ProductHierarchy { get; set; }

    [JsonPropertyName("LabOffice")]
    public string? LabOffice { get; set; }
}
