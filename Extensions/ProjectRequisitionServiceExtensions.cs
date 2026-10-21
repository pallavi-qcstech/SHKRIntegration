using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class ProjectRequisitionServiceExtensions
{
    public static IServiceCollection AddProjectRequisition(this IServiceCollection services)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrProjectRequisitionService.ShkrSapClientName);
        services.AddScoped<ShkrProjectRequisitionService>();

        return services;
    }
}
