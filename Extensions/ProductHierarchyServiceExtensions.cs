using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class ProductHierarchyServiceExtensions
{
    private static readonly TimeSpan ProductHierarchyReadTimeout = TimeSpan.FromMinutes(2);

    public static IServiceCollection AddProductHierarchy(this IServiceCollection services)
    {
        services.AddShkrSapHttpClientLargeRead(ShkrProductHierarchyService.ShkrSapClientName, ProductHierarchyReadTimeout);
        services.AddScoped<ShkrProductHierarchyService>();

        return services;
    }
}
