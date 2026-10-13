using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class SalesOrderServiceExtensions
{
    public static IServiceCollection AddSalesOrders(this IServiceCollection services)
    {
        services.AddShkrSapHttpClient(ShkrSalesOrderService.ShkrSapClientName);
        services.AddScoped<ShkrSalesOrderService>();

        return services;
    }
}
