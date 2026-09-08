namespace SHKRIntegration.Options;


/// Connection settings for the SAP OData Gateway services (Z_VEND_DETAILS_SRV today; any
/// future SAP Z_*_SRV service this project adds) established during live testing against
/// devfiroi.ghs.hec.ondemand.com (Aug 2026).
///
/// Bind from configuration section "ShkrSap". Username/Password should come from User Secrets
/// (dotnet user-secrets) or environment variables in every environment except local dev 
/// - never commit real credentials to appsettings.json.

public sealed class ShkrSapApiOptions
{
    public const string SectionName = "ShkrSap";

    /// <summary>SAP Gateway host, e.g. https://devfiroi.ghs.hec.ondemand.com</summary>
    public required string BaseUrl { get; set; }

    /// <summary>sap-client query parameter, e.g. "140"</summary>
    public required string ShkrSapClient { get; set; }

    /// <summary>sap-language query parameter, e.g. "EN"</summary>
    public string ShkrSapLanguage { get; set; } = "EN";

    /// <summary>Basic auth username for the SAP Gateway (set via User Secrets/environment).</summary>
    public string Username { get; set; } = string.Empty;

    /// <summary>Basic auth password for the SAP Gateway (set via User Secrets/environment).</summary>
    public string Password { get; set; } = string.Empty;
}
