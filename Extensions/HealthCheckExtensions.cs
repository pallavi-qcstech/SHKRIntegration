using SHKRIntegration.HealthChecks;

namespace SHKRIntegration.Extensions;

public static class HealthCheckExtensions
{
    public static IServiceCollection AddIntegrationHealthChecks(this IServiceCollection services)
    {
        services.AddHealthChecks()
            .AddCheck<ShkrSapHealthCheck>("shkrsap")
            .AddCheck<SqlServerHealthCheck>("sql-server");

        return services;
    }
}
