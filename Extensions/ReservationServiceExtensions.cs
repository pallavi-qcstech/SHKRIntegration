using SHKRIntegration.Services;

namespace SHKRIntegration.Extensions;

public static class ReservationServiceExtensions
{
    public static IServiceCollection AddReservations(this IServiceCollection services)
    {
        services.AddShkrSapHttpClient(ShkrReservationService.ShkrSapClientName);
        services.AddScoped<ShkrReservationService>();

        return services;
    }
}
