using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class ProjectServiceExtensions
{
    public static IServiceCollection AddProjects(this IServiceCollection services)
    {
        services.AddShkrSapHttpClient(ShkrProjectService.ShkrSapClientName);
        services.AddScoped<ShkrProjectService>();

        return services;
    }
}
