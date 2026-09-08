using SHKRIntegration.Options;
using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class VendorServiceExtensions
{
    public static IServiceCollection AddVendors(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddShkrSapHttpClient(ShkrVendorService.ShkrSapClientName);

        services.Configure<ShkrVendorOptions>(configuration.GetSection(ShkrVendorOptions.SectionName));
        services.AddHostedService<ShkrVendorService>();

        return services;
    }
}
