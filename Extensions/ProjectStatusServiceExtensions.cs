using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class ProjectStatusServiceExtensions
{
    public static IServiceCollection AddProjectStatus(this IServiceCollection services)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrProjectStatusService.ShkrSapClientName);
        services.AddScoped<ShkrProjectStatusService>();

        return services;
    }
}
