using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class GetProjectStatusServiceExtensions
{
    public static IServiceCollection AddGetProjectStatus(this IServiceCollection services)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrGetProjectStatusService.ShkrSapClientName);
        services.AddSingleton<ShkrGetProjectStatusService>();

        return services;
    }
}
