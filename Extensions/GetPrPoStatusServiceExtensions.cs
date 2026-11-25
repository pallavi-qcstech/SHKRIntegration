using SHKRIntegration.Options;
using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class GetPrPoStatusServiceExtensions
{
    public static IServiceCollection AddGetPrPoStatus(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrGetPrPoStatusService.ShkrSapClientName);

        services.Configure<ShkrGetPrPoStatusOptions>(configuration.GetSection(ShkrGetPrPoStatusOptions.SectionName));
        services.AddSingleton<ShkrGetPrPoStatusService>();

        return services;
    }
}
