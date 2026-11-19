using SHKRIntegration.Options;
using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class PrStatusServiceExtensions
{
    public static IServiceCollection AddPrStatus(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrPrStatusService.ShkrSapClientName);

        services.Configure<ShkrPrStatusOptions>(configuration.GetSection(ShkrPrStatusOptions.SectionName));
        services.AddSingleton<ShkrPrStatusService>();

        return services;
    }
}
