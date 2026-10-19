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

    // Deliberately NO AddStandardResilienceHandler() here. The standard resilience handler retries
    // transient failures (timeouts, 5xx) for any HTTP method by default, which is safe for every
    // other SHKRIntegration client (all read-only GETs) but NOT safe for a non-idempotent SAP create
    // call. The PR Create/Change API spec (v1.2, section 16) says so explicitly: "No duplicate
    // protection on create. Sending the same body twice creates two requisitions." A retried timeout
    // here could silently create a second real PR in SAP with no way to detect it. Decided
    // 17.10.2026 - use this for any future genuinely non-idempotent outbound create/change call.
    public static IHttpClientBuilder AddShkrSapHttpClientNoRetry(this IServiceCollection services, string clientName)
    {
        return services.AddHttpClient(clientName, ConfigureShkrSapClient)
            .ConfigurePrimaryHttpMessageHandler(CreateShkrSapHandler)
            .AddHttpMessageHandler<ShkrSapCsrfTokenHandler>();
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
