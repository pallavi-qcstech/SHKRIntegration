using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class MaterialServiceExtensions
{
    private static readonly TimeSpan MaterialReadTimeout = TimeSpan.FromMinutes(5);

    public static IServiceCollection AddMaterials(this IServiceCollection services)
    {
        services.AddShkrSapHttpClientLargeRead(ShkrMaterialService.ShkrSapClientName, MaterialReadTimeout);
        services.AddScoped<ShkrMaterialService>();

        return services;
    }
}
