using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;
using SHKRIntegration.Options;

namespace SHKRIntegration.HealthChecks;


/// Confirms the PMWeb SQL Server database is reachable - opens and immediately closes a
/// connection, no query executed. Uses ShkrDatabaseOptions.ConnectionString - the shared
/// connection string used by every SQL consumer in this project (Vendor, Project, this check).

public sealed class SqlServerHealthCheck(IOptions<ShkrDatabaseOptions> databaseOptions) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        var connectionString = databaseOptions.Value.ConnectionString;

        if (string.IsNullOrWhiteSpace(connectionString))
        {
            return HealthCheckResult.Unhealthy("Database:ConnectionString is not configured.");
        }

        try
        {
            await using var connection = new SqlConnection(connectionString);
            await connection.OpenAsync(cancellationToken);
            return HealthCheckResult.Healthy("SQL Server reachable.");
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("SQL Server unreachable.", ex);
        }
    }
}
