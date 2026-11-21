using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class InvoiceServiceExtensions
{
    public static IServiceCollection AddInvoices(this IServiceCollection services)
    {
        services.AddShkrSapHttpClient(ShkrInvoiceService.ShkrSapClientName);
        services.AddScoped<ShkrInvoiceService>();

        return services;
    }
}
