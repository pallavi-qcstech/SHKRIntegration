using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class ShkrBudgetCostPlanServiceExtension
{
    public static IServiceCollection AddBudgetCostPlan(this IServiceCollection services)
    {
        services.AddShkrSapHttpClientNoRetry(ShkrBudgetCostPlanService.ShkrSapClientName);
        services.AddScoped<ShkrBudgetCostPlanService>();

        return services;
    }
}
