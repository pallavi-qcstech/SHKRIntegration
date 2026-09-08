namespace SHKRIntegration.Options;

/// SQL Server connection string for the PMWeb database - shared by every consumer that needs
/// direct SQL access (ShkrVendorService, ShkrProjectService, SqlServerHealthCheck). Not owned by
/// any one of them, so it lives here rather than in ShkrVendorOptions, even though today every
/// consumer happens to point at the same PMWeb database - a new consumer just injects
/// IOptions&lt;ShkrDatabaseOptions&gt; instead of coupling to Vendor's own options class.
/// Bind from configuration section "Database".
///
/// ConnectionString should come from User Secrets/environment, not appsettings.json, in every
/// environment except local dev with a throwaway system.
public sealed class ShkrDatabaseOptions
{
    public const string SectionName = "Database";

    /// <summary>SQL Server connection string for the PMWeb database.</summary>
    public string ConnectionString { get; set; } = string.Empty;
}
