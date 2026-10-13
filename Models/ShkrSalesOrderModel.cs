using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;

public sealed class SalesOrderHeader
{
    [JsonPropertyName("CreationDateTime")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? CreationDateTime { get; set; }

    [JsonPropertyName("DocumentDate")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? DocumentDate { get; set; }

    [JsonPropertyName("IsReturnOrder")] public bool IsReturnOrder { get; set; }
    [JsonPropertyName("IsSaleOrder")] public bool IsSaleOrder { get; set; }

    [JsonPropertyName("ItemChangeDate")] public string ItemChangeDate { get; set; } = string.Empty;

    [JsonPropertyName("LastUpdateDateTime")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? LastUpdateDateTime { get; set; }

    [JsonPropertyName("SalesDocumentNumber")] public string SalesDocumentNumber { get; set; } = string.Empty;
    [JsonPropertyName("SalesOrg")] public string SalesOrg { get; set; } = string.Empty;
    [JsonPropertyName("SoldToPartyNumber")] public string SoldToPartyNumber { get; set; } = string.Empty;
    [JsonPropertyName("AdvanceAmt")] public decimal? AdvanceAmt { get; set; }
    [JsonPropertyName("AdvancePercentage")] public decimal? AdvancePercentage { get; set; }
    [JsonPropertyName("C4CProjectName")] public string C4CProjectName { get; set; } = string.Empty;
    [JsonPropertyName("C4CProjectNumber")] public string C4CProjectNumber { get; set; } = string.Empty;
    [JsonPropertyName("CreatedByName")] public string CreatedByName { get; set; } = string.Empty;
    [JsonPropertyName("Currency")] public string Currency { get; set; } = string.Empty;
    [JsonPropertyName("CustomerName")] public string CustomerName { get; set; } = string.Empty;

    [JsonPropertyName("Date_from")] public string DateFrom { get; set; } = string.Empty;
    [JsonPropertyName("Date_to")] public string DateTo { get; set; } = string.Empty;

    [JsonPropertyName("DiscountAmount")] public decimal? DiscountAmount { get; set; }
    [JsonPropertyName("DistributionChannel")] public string DistributionChannel { get; set; } = string.Empty;
    [JsonPropertyName("Division")] public string Division { get; set; } = string.Empty;
    [JsonPropertyName("DocumentStatus")] public string DocumentStatus { get; set; } = string.Empty;
    [JsonPropertyName("DownPaymentCharges")] public decimal? DownPaymentCharges { get; set; }
    [JsonPropertyName("DownPaymentPercentage")] public decimal? DownPaymentPercentage { get; set; }
    [JsonPropertyName("ExchangeRate")] public decimal? ExchangeRate { get; set; }

    [JsonPropertyName("ExpectedAwardDate")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? ExpectedAwardDate { get; set; }

    [JsonPropertyName("ExpectedDeliveryDate")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? ExpectedDeliveryDate { get; set; }

    [JsonPropertyName("GrossPrice")] public decimal? GrossPrice { get; set; }
    [JsonPropertyName("InstallationCharges")] public decimal? InstallationCharges { get; set; }
    [JsonPropertyName("Message")] public string Message { get; set; } = string.Empty;
    [JsonPropertyName("NetValueWithoutTax")] public decimal? NetValueWithoutTax { get; set; }
    [JsonPropertyName("NetValueWithTax")] public decimal? NetValueWithTax { get; set; }
    [JsonPropertyName("OrderReason")] public string OrderReason { get; set; } = string.Empty;
    [JsonPropertyName("OrderType")] public string OrderType { get; set; } = string.Empty;
    [JsonPropertyName("OrderTypeDesc")] public string OrderTypeDesc { get; set; } = string.Empty;
    [JsonPropertyName("PaymentTerms")] public string PaymentTerms { get; set; } = string.Empty;

    [JsonPropertyName("ProgressUpdateDate")] [JsonConverter(typeof(ODataDateTimeConverter))]
    public DateTime? ProgressUpdateDate { get; set; }

    [JsonPropertyName("RetentionAmt")] public decimal? RetentionAmt { get; set; }
    [JsonPropertyName("RetentionPercentage")] public decimal? RetentionPercentage { get; set; }
    [JsonPropertyName("SalesGroup")] public string SalesGroup { get; set; } = string.Empty;
    [JsonPropertyName("SalesOffice")] public string SalesOffice { get; set; } = string.Empty;
    [JsonPropertyName("SalesPersonCommission")] public decimal? SalesPersonCommission { get; set; }
    [JsonPropertyName("SalesPersonName")] public string SalesPersonName { get; set; } = string.Empty;
    [JsonPropertyName("SalesPersonNumber")] public string SalesPersonNumber { get; set; } = string.Empty;
    [JsonPropertyName("ShipToPartyNumber")] public string ShipToPartyNumber { get; set; } = string.Empty;
    [JsonPropertyName("VatAmount")] public decimal? VatAmount { get; set; }
    [JsonPropertyName("VatPercentage")] public decimal? VatPercentage { get; set; }
    [JsonPropertyName("Version")] public string Version { get; set; } = string.Empty;

    [JsonPropertyName("Lines")] public ODataResultSet<SalesOrderLine> Lines { get; set; } = new();
}

public sealed class SalesOrderLine
{
    [JsonPropertyName("ItemChangeDate")] public string ItemChangeDate { get; set; } = string.Empty;

    [JsonPropertyName("SalesDocumentNumber")] public string SalesDocumentNumber { get; set; } = string.Empty;
    [JsonPropertyName("LineNumber")] public string LineNumber { get; set; } = string.Empty;
    [JsonPropertyName("Material")] public string Material { get; set; } = string.Empty;
    [JsonPropertyName("ItemDescription")] public string ItemDescription { get; set; } = string.Empty;
    [JsonPropertyName("WbsElement")] public string WbsElement { get; set; } = string.Empty;
    [JsonPropertyName("WbsDescription")] public string WbsDescription { get; set; } = string.Empty;
    [JsonPropertyName("ProjectCode")] public string ProjectCode { get; set; } = string.Empty;
    [JsonPropertyName("ProjectDescription")] public string ProjectDescription { get; set; } = string.Empty;
    [JsonPropertyName("Quantity")] public decimal? Quantity { get; set; }
    [JsonPropertyName("Uom")] public string Uom { get; set; } = string.Empty;
    [JsonPropertyName("Plant")] public string Plant { get; set; } = string.Empty;
    [JsonPropertyName("StorageLocation")] public string StorageLocation { get; set; } = string.Empty;
    [JsonPropertyName("GrossUnitPrice")] public decimal? GrossUnitPrice { get; set; }
    [JsonPropertyName("TotalGrossAmount")] public decimal? TotalGrossAmount { get; set; }
    [JsonPropertyName("DiscPercentage")] public decimal? DiscPercentage { get; set; }
    [JsonPropertyName("DiscAmount")] public decimal? DiscAmount { get; set; }
    [JsonPropertyName("TotalDiscAmount")] public decimal? TotalDiscAmount { get; set; }
    [JsonPropertyName("VatPercentage")] public decimal? VatPercentage { get; set; }
    [JsonPropertyName("TotalVatAmount")] public decimal? TotalVatAmount { get; set; }
    [JsonPropertyName("NetValueWithTax")] public decimal? NetValueWithTax { get; set; }
    [JsonPropertyName("AdvancePercentage")] public decimal? AdvancePercentage { get; set; }
    [JsonPropertyName("AdvanceAmt")] public decimal? AdvanceAmt { get; set; }
    [JsonPropertyName("InstallationCharges")] public decimal? InstallationCharges { get; set; }
    [JsonPropertyName("DownPaymentPercentage")] public decimal? DownPaymentPercentage { get; set; }
    [JsonPropertyName("DownPaymentCharges")] public decimal? DownPaymentCharges { get; set; }
    [JsonPropertyName("ReferenceDocument")] public string ReferenceDocument { get; set; } = string.Empty;
    [JsonPropertyName("ReferenceDocumentItem")] public string ReferenceDocumentItem { get; set; } = string.Empty;
    [JsonPropertyName("ReferenceDocumentCategory")] public string ReferenceDocumentCategory { get; set; } = string.Empty;
    [JsonPropertyName("OriginalSalesOrder")] public string OriginalSalesOrder { get; set; } = string.Empty;
    [JsonPropertyName("OriginalSalesOrderItem")] public string OriginalSalesOrderItem { get; set; } = string.Empty;
    [JsonPropertyName("RejectionReason")] public string RejectionReason { get; set; } = string.Empty;
    [JsonPropertyName("QuotationNumber")] public string QuotationNumber { get; set; } = string.Empty;
    [JsonPropertyName("QuotationItem")] public string QuotationItem { get; set; } = string.Empty;
}
