using System.Text.Json.Serialization;

namespace SHKRIntegration.Models;



public sealed class VendorHeaderData
{
    [JsonPropertyName("VendorID")]
    public string VendorId { get; set; } = string.Empty;

    [JsonPropertyName("VendorDetailsSet")]
    public ODataResultSet<VendorDetail> VendorDetailsSet { get; set; } = new();
}

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



public sealed class VendorCompany
{
    [JsonPropertyName("CompanyCode")] public string CompanyCode { get; set; } = string.Empty;
    [JsonPropertyName("ActiveFlag")] public string ActiveFlag { get; set; } = string.Empty;
}
