using SHKRIntegration.Options;
using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class GetPrPoStatusServiceExtensions
{
    public static IServiceCollection AddGetPrPoStatus(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrGetPrPoStatusServiceBase.ShkrSapClientName);

        services.Configure<ShkrGetPrPoStatusOptions>(configuration.GetSection(ShkrGetPrPoStatusOptions.SectionName));
        services.AddSingleton<ShkrGetPrStatusService>();
        services.AddSingleton<ShkrGetPoStatusService>();

        return services;
    }
}
