using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;



public sealed class VendorHeaderData
{
    [JsonPropertyName("VendorID")]
    public string VendorId { get; set; } = string.Empty;

    [JsonPropertyName("VendorDetailsSet")]
    public ODataResultSet<VendorDetail> VendorDetailsSet { get; set; } = new();
}

/// VendorAddressSet/VendorContactSet/VendorCompanySet moved here (2026-09-07) - SAP's service
/// contract changed to nest them under each VendorDetailsSet entry instead of as siblings of it
/// on VendorHeaderData. See "Pallavi Develpment docs/Modified APIS/Z_VEND_DETAILS.docx" (the
/// spec this change is based on) and "important points/Z_VEND_DETAILS_SRV API Contract Change -
/// Nested Child Sets 07.09.2026.md" for the full investigation, evidence, and open items -
/// notably, this nesting is only content-verified for single-vendor mode (GetVendor); whether
/// bulk mode (GetAllVendors) now also links each vendor to its own children, rather than
/// returning them unlinked, is NOT verified - see ShkrVendorService.GetAllVendors's doc comment.
public sealed class VendorDetail
{
    [JsonPropertyName("VendorID")] public string VendorId { get; set; } = string.Empty;
    [JsonPropertyName("VendorCode")] public string VendorCode { get; set; } = string.Empty;
    [JsonPropertyName("VendorName")] public string VendorName { get; set; } = string.Empty;
    [JsonPropertyName("VendorType")] public string VendorType { get; set; } = string.Empty;
    [JsonPropertyName("Country")] public string Country { get; set; } = string.Empty;
    [JsonPropertyName("City")] public string City { get; set; } = string.Empty;
    [JsonPropertyName("POBox")] public string PoBox { get; set; } = string.Empty;
    [JsonPropertyName("PostalCode")] public string PostalCode { get; set; } = string.Empty;
    [JsonPropertyName("AddressLine1")] public string AddressLine1 { get; set; } = string.Empty;
    [JsonPropertyName("AddressLine2")] public string AddressLine2 { get; set; } = string.Empty;
    [JsonPropertyName("Street")] public string Street { get; set; } = string.Empty;
    [JsonPropertyName("Telephone1")] public string Telephone1 { get; set; } = string.Empty;
    [JsonPropertyName("Telephone2")] public string Telephone2 { get; set; } = string.Empty;
    [JsonPropertyName("Fax")] public string Fax { get; set; } = string.Empty;
    [JsonPropertyName("EmailAddress")] public string EmailAddress { get; set; } = string.Empty;
    [JsonPropertyName("ActiveFlag")] public string ActiveFlag { get; set; } = string.Empty;

    [JsonPropertyName("VendorAddressSet")]
    public ODataResultSet<VendorAddress> VendorAddressSet { get; set; } = new();

    [JsonPropertyName("VendorContactSet")]
    public ODataResultSet<VendorContact> VendorContactSet { get; set; } = new();

    [JsonPropertyName("VendorCompanySet")]
    public ODataResultSet<VendorCompany> VendorCompanySet { get; set; } = new();
}

public sealed class VendorAddress
{
    [JsonPropertyName("AddressId")] public string AddressId { get; set; } = string.Empty;
    [JsonPropertyName("AddressLine1")] public string AddressLine1 { get; set; } = string.Empty;
    [JsonPropertyName("AddressLine2")] public string AddressLine2 { get; set; } = string.Empty;
    [JsonPropertyName("Street")] public string Street { get; set; } = string.Empty;
    [JsonPropertyName("City")] public string City { get; set; } = string.Empty;
    [JsonPropertyName("POBox")] public string PoBox { get; set; } = string.Empty;
    [JsonPropertyName("PostalCode")] public string PostalCode { get; set; } = string.Empty;
    [JsonPropertyName("Country")] public string Country { get; set; } = string.Empty;
    [JsonPropertyName("ActiveFlag")] public string ActiveFlag { get; set; } = string.Empty;
}

public sealed class VendorContact
{
    [JsonPropertyName("ContactId")] public string ContactId { get; set; } = string.Empty;
    [JsonPropertyName("FirstName")] public string FirstName { get; set; } = string.Empty;
    [JsonPropertyName("LastName")] public string LastName { get; set; } = string.Empty;
    [JsonPropertyName("Title")] public string Title { get; set; } = string.Empty;
    [JsonPropertyName("Telephone1")] public string Telephone1 { get; set; } = string.Empty;
    [JsonPropertyName("Telephone2")] public string Telephone2 { get; set; } = string.Empty;
    [JsonPropertyName("Fax")] public string Fax { get; set; } = string.Empty;
    [JsonPropertyName("EmailAddress")] public string EmailAddress { get; set; } = string.Empty;
    [JsonPropertyName("ActiveFlag")] public string ActiveFlag { get; set; } = string.Empty;
}


/// NOTE: PaymentTerms is NOT added here - that Z_VEND_DETAILS_SRV's VendorCompany entity only
/// defines CompanyCode and ActiveFlag. If PaymentTerms is required, then change needs to be done.

public sealed class VendorCompany
{
    [JsonPropertyName("CompanyCode")] public string CompanyCode { get; set; } = string.Empty;
    [JsonPropertyName("ActiveFlag")] public string ActiveFlag { get; set; } = string.Empty;
}
