using SHKRIntegration.Options;
using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class NetworkActivityServiceExtensions
{
    public static IServiceCollection AddNetworkActivities(this IServiceCollection services, IConfiguration configuration)
    {
        // No-retry client: a retried POST could create the activities in SAP twice.
        services.AddShkrSapHttpClientNoRetry(ShkrNetworkActivityService.ShkrSapClientName);

        services.Configure<ShkrNetworkActivityOptions>(configuration.GetSection(ShkrNetworkActivityOptions.SectionName));
        services.AddScoped<ShkrNetworkActivityService>();

        return services;
    }
}
