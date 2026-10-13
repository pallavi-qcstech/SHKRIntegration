using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class DeliveryServiceExtensions
{
    public static IServiceCollection AddDeliveries(this IServiceCollection services)
    {
        services.AddShkrSapHttpClient(ShkrDeliveryService.ShkrSapClientName);
        services.AddScoped<ShkrDeliveryService>();

        return services;
    }
}
