using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class WBSServiceExtensions
{
    public static IServiceCollection AddWBS(this IServiceCollection services)
    {
        services.AddScoped<ShkrWBSService>();

        return services;
    }
}
