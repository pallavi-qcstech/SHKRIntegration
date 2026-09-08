using SHKRIntegration.Options;

namespace SHKRIntegration.Extensions;

public static class ShkrDatabaseExtensions
{
    public static IServiceCollection AddShkrDatabaseOptions(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<ShkrDatabaseOptions>(configuration.GetSection(ShkrDatabaseOptions.SectionName));
        return services;
    }
}
