using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class WbsHierarchy
{
    [JsonPropertyName("PROJECTCODE")] public string ProjectCode { get; set; } = string.Empty;
    [JsonPropertyName("PROJECTNAME")] public string ProjectName { get; set; } = string.Empty;
    [JsonPropertyName("WBS")] public string Wbs { get; set; } = string.Empty;
    [JsonPropertyName("NAME")] public string Name { get; set; } = string.Empty;
    [JsonPropertyName("UP_WBS")] public string UpWbs { get; set; } = string.Empty;
    [JsonPropertyName("DETAIL")] public string Detail { get; set; } = string.Empty;
    [JsonPropertyName("PLANT")] public string Plant { get; set; } = string.Empty;
    [JsonPropertyName("CON_KEY")] public string ConKey { get; set; } = string.Empty;
    [JsonPropertyName("FUNC_AREA")] public string FuncArea { get; set; } = string.Empty;
    [JsonPropertyName("CREATEDON")] public string CreatedOn { get; set; } = string.Empty;
}
