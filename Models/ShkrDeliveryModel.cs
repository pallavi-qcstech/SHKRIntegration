using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class DeliveryHeader
{
    [JsonPropertyName("DeliveryNumber")] public string DeliveryNumber { get; set; } = string.Empty;

    [JsonPropertyName("CreationDateTime")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? CreationDateTime { get; set; }

    [JsonPropertyName("LastUpdateDateTime")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? LastUpdateDateTime { get; set; }

    [JsonPropertyName("CreatedByName")] public string CreatedByName { get; set; } = string.Empty;

    [JsonPropertyName("DocumentDate")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? DocumentDate { get; set; }

    [JsonPropertyName("DocumentStatus")] public string DocumentStatus { get; set; } = string.Empty;
    [JsonPropertyName("ShipToPartyNumber")] public string ShipToPartyNumber { get; set; } = string.Empty;
    [JsonPropertyName("ShippingPoint")] public string ShippingPoint { get; set; } = string.Empty;
    [JsonPropertyName("ShippingPointName")] public string ShippingPointName { get; set; } = string.Empty;
    [JsonPropertyName("Date_to")] public string DateTo { get; set; } = string.Empty;
    [JsonPropertyName("Date_from")] public string DateFrom { get; set; } = string.Empty;
    [JsonPropertyName("DeliveryType")] public string DeliveryType { get; set; } = string.Empty;
    [JsonPropertyName("DeliveryTypeDesc")] public string DeliveryTypeDesc { get; set; } = string.Empty;
    [JsonPropertyName("IsSaleDelivery")] public bool IsSaleDelivery { get; set; }
    [JsonPropertyName("IsReturnDelivery")] public bool IsReturnDelivery { get; set; }
    [JsonPropertyName("IsFullyInvoiced")] public bool IsFullyInvoiced { get; set; }
    [JsonPropertyName("BillingStatus")] public string BillingStatus { get; set; } = string.Empty;
    [JsonPropertyName("ItemChangeDate")] public string ItemChangeDate { get; set; } = string.Empty;
    [JsonPropertyName("GoodsMovementStatus")] public string GoodsMovementStatus { get; set; } = string.Empty;
    [JsonPropertyName("GoodsMovementStatusDesc")] public string GoodsMovementStatusDesc { get; set; } = string.Empty;
    [JsonPropertyName("OverallPickingStatus")] public string OverallPickingStatus { get; set; } = string.Empty;
    [JsonPropertyName("OverallPickingStatusDesc")] public string OverallPickingStatusDesc { get; set; } = string.Empty;
    [JsonPropertyName("WarehouseActivityStatus")] public string WarehouseActivityStatus { get; set; } = string.Empty;
    [JsonPropertyName("WarehouseActivityStatusDesc")] public string WarehouseActivityStatusDesc { get; set; } = string.Empty;
    [JsonPropertyName("BillingStatusDesc")] public string BillingStatusDesc { get; set; } = string.Empty;

    [JsonPropertyName("Lines")] public ODataResultSet<DeliveryLine> Lines { get; set; } = new();
}

public sealed class DeliveryLine
{
    [JsonPropertyName("DeliveryNumber")] public string DeliveryNumber { get; set; } = string.Empty;
    [JsonPropertyName("LineNumber")] public string LineNumber { get; set; } = string.Empty;
    [JsonPropertyName("SalesOrderNumber")] public string SalesOrderNumber { get; set; } = string.Empty;
    [JsonPropertyName("Material")] public string Material { get; set; } = string.Empty;
    [JsonPropertyName("ItemDescription")] public string ItemDescription { get; set; } = string.Empty;
    [JsonPropertyName("DeliveredQuantity")] public decimal? DeliveredQuantity { get; set; }
    [JsonPropertyName("PickedQuantity")] public decimal? PickedQuantity { get; set; }
    [JsonPropertyName("Uom")] public string Uom { get; set; } = string.Empty;
    [JsonPropertyName("Plant")] public string Plant { get; set; } = string.Empty;
    [JsonPropertyName("WarehouseNo")] public string WarehouseNo { get; set; } = string.Empty;
    [JsonPropertyName("Quantity")] public decimal? Quantity { get; set; }
    [JsonPropertyName("Status")] public string Status { get; set; } = string.Empty;
    [JsonPropertyName("WbsElement")] public string WbsElement { get; set; } = string.Empty;
    [JsonPropertyName("SalesOrderItem")] public string SalesOrderItem { get; set; } = string.Empty;
    [JsonPropertyName("OriginalDeliveryNumber")] public string OriginalDeliveryNumber { get; set; } = string.Empty;
    [JsonPropertyName("OriginalDeliveryItem")] public string OriginalDeliveryItem { get; set; } = string.Empty;
    [JsonPropertyName("ItemChangeDate")] public string ItemChangeDate { get; set; } = string.Empty;
    [JsonPropertyName("PickingStatus")] public string PickingStatus { get; set; } = string.Empty;
    [JsonPropertyName("PickingStatusDesc")] public string PickingStatusDesc { get; set; } = string.Empty;
    [JsonPropertyName("WarehouseActivityStatus")] public string WarehouseActivityStatus { get; set; } = string.Empty;
    [JsonPropertyName("WarehouseActivityStatusDesc")] public string WarehouseActivityStatusDesc { get; set; } = string.Empty;
    [JsonPropertyName("GoodsMovementStatus")] public string GoodsMovementStatus { get; set; } = string.Empty;
    [JsonPropertyName("GoodsMovementStatusDesc")] public string GoodsMovementStatusDesc { get; set; } = string.Empty;
    [JsonPropertyName("BillingStatus")] public string BillingStatus { get; set; } = string.Empty;
    [JsonPropertyName("BillingStatusDesc")] public string BillingStatusDesc { get; set; } = string.Empty;
}
