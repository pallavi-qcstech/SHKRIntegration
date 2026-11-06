using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class ChangeOrderServiceExtensions
{
    public static IServiceCollection AddChangeOrder(this IServiceCollection services)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrChangeOrderService.ShkrSapClientName);
        services.AddScoped<ShkrChangeOrderService>();

        return services;
    }
}
