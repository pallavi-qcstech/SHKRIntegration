using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class InvoiceHeader
{
    [JsonPropertyName("InvoiceNumber")] public string InvoiceNumber { get; set; } = string.Empty;
    [JsonPropertyName("InvoiceDescription")] public string InvoiceDescription { get; set; } = string.Empty;
    [JsonPropertyName("BillingType")] public string BillingType { get; set; } = string.Empty;
    [JsonPropertyName("BillingTypeDesc")] public string BillingTypeDesc { get; set; } = string.Empty;
    [JsonPropertyName("DocumentCategory")] public string DocumentCategory { get; set; } = string.Empty;
    [JsonPropertyName("IsCreditMemo")] public bool? IsCreditMemo { get; set; }
    [JsonPropertyName("IsSaleInvoice")] public bool? IsSaleInvoice { get; set; }
    [JsonPropertyName("IsReturnInvoice")] public bool? IsReturnInvoice { get; set; }
    [JsonPropertyName("IsCancellation")] public bool? IsCancellation { get; set; }
    [JsonPropertyName("IsCancelled")] public bool? IsCancelled { get; set; }
    [JsonPropertyName("CancelledInvoice")] public string CancelledInvoice { get; set; } = string.Empty;
    [JsonPropertyName("CustomerReference")] public string CustomerReference { get; set; } = string.Empty;
    [JsonPropertyName("Assignment")] public string Assignment { get; set; } = string.Empty;

    [JsonPropertyName("BillingDate")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? BillingDate { get; set; }

    [JsonPropertyName("CreationDateTime")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? CreationDateTime { get; set; }

    [JsonPropertyName("LastUpdateDateTime")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? LastUpdateDateTime { get; set; }

    [JsonPropertyName("CreatedByName")] public string CreatedByName { get; set; } = string.Empty;
    [JsonPropertyName("PayerNumber")] public string PayerNumber { get; set; } = string.Empty;
    [JsonPropertyName("PayerName")] public string PayerName { get; set; } = string.Empty;
    [JsonPropertyName("SoldToPartyNumber")] public string SoldToPartyNumber { get; set; } = string.Empty;
    [JsonPropertyName("ShipToPartyNumber")] public string ShipToPartyNumber { get; set; } = string.Empty;
    [JsonPropertyName("BillToPartyNumber")] public string BillToPartyNumber { get; set; } = string.Empty;
    [JsonPropertyName("CustomerVatNumber")] public string CustomerVatNumber { get; set; } = string.Empty;
    [JsonPropertyName("CustomerTaxNumber")] public string CustomerTaxNumber { get; set; } = string.Empty;
    [JsonPropertyName("DestinationCountry")] public string DestinationCountry { get; set; } = string.Empty;
    [JsonPropertyName("SalesOrg")] public string SalesOrg { get; set; } = string.Empty;
    [JsonPropertyName("DistributionChannel")] public string DistributionChannel { get; set; } = string.Empty;
    [JsonPropertyName("Division")] public string Division { get; set; } = string.Empty;
    [JsonPropertyName("SalesDistrict")] public string SalesDistrict { get; set; } = string.Empty;
    [JsonPropertyName("CompanyCode")] public string CompanyCode { get; set; } = string.Empty;
    [JsonPropertyName("FiscalYear")] public string FiscalYear { get; set; } = string.Empty;
    [JsonPropertyName("Currency")] public string Currency { get; set; } = string.Empty;
    [JsonPropertyName("ExchangeRate")] public decimal? ExchangeRate { get; set; }
    [JsonPropertyName("PaymentTerms")] public string PaymentTerms { get; set; } = string.Empty;
    [JsonPropertyName("PaymentTermsDesc")] public string PaymentTermsDesc { get; set; } = string.Empty;
    [JsonPropertyName("PaymentMethod")] public string PaymentMethod { get; set; } = string.Empty;
    [JsonPropertyName("Incoterms1")] public string Incoterms1 { get; set; } = string.Empty;
    [JsonPropertyName("Incoterms2")] public string Incoterms2 { get; set; } = string.Empty;
    [JsonPropertyName("ShippingConditions")] public string ShippingConditions { get; set; } = string.Empty;
    [JsonPropertyName("NetValue")] public decimal? NetValue { get; set; }
    [JsonPropertyName("TaxAmount")] public decimal? TaxAmount { get; set; }
    [JsonPropertyName("GrossValue")] public decimal? GrossValue { get; set; }
    [JsonPropertyName("GrossPrice")] public decimal? GrossPrice { get; set; }
    [JsonPropertyName("DiscountAmount")] public decimal? DiscountAmount { get; set; }
    [JsonPropertyName("VatPercentage")] public decimal? VatPercentage { get; set; }
    [JsonPropertyName("ItemCount")] public int? ItemCount { get; set; }
    [JsonPropertyName("AccountingStatus")] public string AccountingStatus { get; set; } = string.Empty;
    [JsonPropertyName("IsPostedToAccounting")] public bool? IsPostedToAccounting { get; set; }
    [JsonPropertyName("AccountingDocument")] public string AccountingDocument { get; set; } = string.Empty;

    [JsonPropertyName("Lines")] public ODataResultSet<InvoiceLine> Lines { get; set; } = new();
}

public sealed class InvoiceLine
{
    [JsonPropertyName("InvoiceNumber")] public string InvoiceNumber { get; set; } = string.Empty;
    [JsonPropertyName("LineNumber")] public string LineNumber { get; set; } = string.Empty;
    [JsonPropertyName("ItemCategory")] public string ItemCategory { get; set; } = string.Empty;
    [JsonPropertyName("Material")] public string Material { get; set; } = string.Empty;
    [JsonPropertyName("ItemDescription")] public string ItemDescription { get; set; } = string.Empty;
    [JsonPropertyName("MaterialGroup")] public string MaterialGroup { get; set; } = string.Empty;
    [JsonPropertyName("ProductHierarchy")] public string ProductHierarchy { get; set; } = string.Empty;
    [JsonPropertyName("Batch")] public string Batch { get; set; } = string.Empty;
    [JsonPropertyName("BilledQuantity")] public decimal? BilledQuantity { get; set; }
    [JsonPropertyName("Uom")] public string Uom { get; set; } = string.Empty;
    [JsonPropertyName("BilledQuantityInBaseUnit")] public decimal? BilledQuantityInBaseUnit { get; set; }
    [JsonPropertyName("BaseUnit")] public string BaseUnit { get; set; } = string.Empty;
    [JsonPropertyName("Plant")] public string Plant { get; set; } = string.Empty;
    [JsonPropertyName("StorageLocation")] public string StorageLocation { get; set; } = string.Empty;
    [JsonPropertyName("ProfitCenter")] public string ProfitCenter { get; set; } = string.Empty;
    [JsonPropertyName("NetAmount")] public decimal? NetAmount { get; set; }
    [JsonPropertyName("TaxAmount")] public decimal? TaxAmount { get; set; }
    [JsonPropertyName("NetValueWithTax")] public decimal? NetValueWithTax { get; set; }
    [JsonPropertyName("Cost")] public decimal? Cost { get; set; }
    [JsonPropertyName("TaxCode")] public string TaxCode { get; set; } = string.Empty;
    [JsonPropertyName("GrossUnitPrice")] public decimal? GrossUnitPrice { get; set; }
    [JsonPropertyName("TotalGrossAmount")] public decimal? TotalGrossAmount { get; set; }
    [JsonPropertyName("DiscPercentage")] public decimal? DiscPercentage { get; set; }
    [JsonPropertyName("DiscAmount")] public decimal? DiscAmount { get; set; }
    [JsonPropertyName("TotalDiscAmount")] public decimal? TotalDiscAmount { get; set; }
    [JsonPropertyName("VatPercentage")] public decimal? VatPercentage { get; set; }
    [JsonPropertyName("TotalVatAmount")] public decimal? TotalVatAmount { get; set; }
    [JsonPropertyName("NetWeight")] public decimal? NetWeight { get; set; }
    [JsonPropertyName("GrossWeight")] public decimal? GrossWeight { get; set; }
    [JsonPropertyName("WeightUnit")] public string WeightUnit { get; set; } = string.Empty;
    [JsonPropertyName("Volume")] public decimal? Volume { get; set; }
    [JsonPropertyName("VolumeUnit")] public string VolumeUnit { get; set; } = string.Empty;
    [JsonPropertyName("DeliveryNumber")] public string DeliveryNumber { get; set; } = string.Empty;
    [JsonPropertyName("DeliveryItem")] public string DeliveryItem { get; set; } = string.Empty;
    [JsonPropertyName("SalesOrderNumber")] public string SalesOrderNumber { get; set; } = string.Empty;
    [JsonPropertyName("SalesOrderItem")] public string SalesOrderItem { get; set; } = string.Empty;
    [JsonPropertyName("ReturnOrderNumber")] public string ReturnOrderNumber { get; set; } = string.Empty;
    [JsonPropertyName("ReturnOrderItem")] public string ReturnOrderItem { get; set; } = string.Empty;
    [JsonPropertyName("WbsElement")] public string WbsElement { get; set; } = string.Empty;
    [JsonPropertyName("WbsDescription")] public string WbsDescription { get; set; } = string.Empty;
    [JsonPropertyName("ProjectCode")] public string ProjectCode { get; set; } = string.Empty;
    [JsonPropertyName("ProjectDescription")] public string ProjectDescription { get; set; } = string.Empty;
}
