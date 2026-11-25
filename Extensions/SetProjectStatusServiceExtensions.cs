using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class SetProjectStatusServiceExtensions
{
    public static IServiceCollection AddSetProjectStatus(this IServiceCollection services)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrSetProjectStatusService.ShkrSapClientName);
        services.AddScoped<ShkrSetProjectStatusService>();

        return services;
    }
}
