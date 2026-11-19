using SHKRIntegration.Options;
using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class VendorServiceExtensions
{
    public static IServiceCollection AddVendors(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddShkrSapHttpClient(ShkrVendorService.ShkrSapClientName);

        services.Configure<ShkrVendorOptions>(configuration.GetSection(ShkrVendorOptions.SectionName));
        services.AddSingleton<ShkrVendorService>();
        services.AddHostedService(sp => sp.GetRequiredService<ShkrVendorService>());

        return services;
    }
}
