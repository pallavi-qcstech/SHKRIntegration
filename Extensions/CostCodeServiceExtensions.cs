using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class CostCodeServiceExtensions
{
    // Reuses the "ShkrSapProject" HttpClient registered by AddProjects() - hierarchySet lives on
    // the same ZPS_PROJ_SRV SAP service as PROJSet. AddProjects() must be called before this.
    public static IServiceCollection AddCostCodes(this IServiceCollection services)
    {
        services.AddScoped<ShkrCostCodeService>();

        return services;
    }
}
