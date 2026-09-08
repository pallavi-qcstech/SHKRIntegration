using SHKRIntegration.Middleware;

namespace SHKRIntegration.Extensions;

public static class MiddlewareServiceExtensions
{
    public static IServiceCollection AddGlobalExceptionHandling(this IServiceCollection services)
    {
        services.AddExceptionHandler<GlobalExceptionHandler>();
        services.AddProblemDetails();
        return services;
    }
}
