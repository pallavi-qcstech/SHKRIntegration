using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class ReservationItem
{
    [JsonPropertyName("OrderCategory")] public string OrderCategory { get; set; } = string.Empty;
    [JsonPropertyName("Reservation")] public string Reservation { get; set; } = string.Empty;
    [JsonPropertyName("Item")] public string Item { get; set; } = string.Empty;
    [JsonPropertyName("ReservationType")] public string ReservationType { get; set; } = string.Empty;

    [JsonPropertyName("RequirementsDate")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? RequirementsDate { get; set; }

    [JsonPropertyName("ProjectDefinition")] public string ProjectDefinition { get; set; } = string.Empty;
    [JsonPropertyName("WbsElement")] public string WbsElement { get; set; } = string.Empty;
    [JsonPropertyName("Network")] public string Network { get; set; } = string.Empty;
    [JsonPropertyName("Activity")] public string Activity { get; set; } = string.Empty;
    [JsonPropertyName("Material")] public string Material { get; set; } = string.Empty;
    [JsonPropertyName("MaterialText")] public string MaterialText { get; set; } = string.Empty;
    [JsonPropertyName("Plant")] public string Plant { get; set; } = string.Empty;
    [JsonPropertyName("StorageLocation")] public string StorageLocation { get; set; } = string.Empty;
    [JsonPropertyName("RequirementQuantity")] public decimal? RequirementQuantity { get; set; }
    [JsonPropertyName("UnitOfEntry")] public string UnitOfEntry { get; set; } = string.Empty;
    [JsonPropertyName("ItemCategory")] public string ItemCategory { get; set; } = string.Empty;
    [JsonPropertyName("PriceUnit")] public decimal? PriceUnit { get; set; }
    [JsonPropertyName("Price")] public decimal? Price { get; set; }
    [JsonPropertyName("Currency")] public string Currency { get; set; } = string.Empty;
    [JsonPropertyName("GlAccount")] public string GlAccount { get; set; } = string.Empty;
    [JsonPropertyName("ProfitCenter")] public string ProfitCenter { get; set; } = string.Empty;
    [JsonPropertyName("MovementAllowed")] public string MovementAllowed { get; set; } = string.Empty;
    [JsonPropertyName("QuantityWithdrawn")] public decimal? QuantityWithdrawn { get; set; }
    [JsonPropertyName("IsDeleted")] public bool IsDeleted { get; set; }
}
