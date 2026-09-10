namespace SHKRIntegration.Options;

public sealed class ShkrDatabaseOptions
{
    public const string SectionName = "Database";

    public string ConnectionString { get; set; } = string.Empty;
}
