using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class CostCodeServiceExtensions
{
    public static IServiceCollection AddCostCodes(this IServiceCollection services)
    {
        services.AddScoped<ShkrCostCodeService>();

        return services;
    }
}
