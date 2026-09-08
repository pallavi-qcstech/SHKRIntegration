using System.Net;
using System.Net.Http.Headers;
using System.Text;

using Microsoft.Extensions.Options;
using SHKRIntegration.Handlers;
using SHKRIntegration.Options;

namespace SHKRIntegration.Extensions;


public static class ShkrSapIntegrationExtensions
{
    public static IServiceCollection AddShkrSapApiOptions(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<ShkrSapApiOptions>(configuration.GetSection(ShkrSapApiOptions.SectionName));
        services.AddTransient<ShkrSapCsrfTokenHandler>();
        return services;
    }

   
    public static IHttpClientBuilder AddShkrSapHttpClient(this IServiceCollection services, string clientName)
    {
        var builder = services.AddHttpClient(clientName, ConfigureShkrSapClient)
            .ConfigurePrimaryHttpMessageHandler(CreateShkrSapHandler)
            .AddHttpMessageHandler<ShkrSapCsrfTokenHandler>();

        builder.AddStandardResilienceHandler();

        return builder;
    }

    private static void ConfigureShkrSapClient(IServiceProvider sp, HttpClient client)
    {
        var options = sp.GetRequiredService<IOptions<ShkrSapApiOptions>>().Value;

        client.BaseAddress = new Uri(options.BaseUrl);

        client.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));

        if (!string.IsNullOrWhiteSpace(options.Username))
        {
            var credentials = Convert.ToBase64String(
                Encoding.ASCII.GetBytes($"{options.Username}:{options.Password}"));

            client.DefaultRequestHeaders.Authorization =
                new AuthenticationHeaderValue("Basic", credentials);
        }
    }

    private static HttpClientHandler CreateShkrSapHandler() => new()
    {
        UseCookies = true,
        CookieContainer = new CookieContainer()
    };
}
