using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class PurchaseOrderServiceExtensions
{
    public static IServiceCollection AddPurchaseOrder(this IServiceCollection services)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrPurchaseOrderService.ShkrSapClientName);
        services.AddScoped<ShkrPurchaseOrderService>();

        return services;
    }
}
