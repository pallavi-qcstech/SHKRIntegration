namespace SHKRIntegration.Options;



public sealed class ShkrSapApiOptions
{
    public const string SectionName = "ShkrSap";

    public required string BaseUrl { get; set; }

    public required string ShkrSapClient { get; set; }

    public string ShkrSapLanguage { get; set; } = "EN";

    public string Username { get; set; } = string.Empty;

    public string Password { get; set; } = string.Empty;
}
