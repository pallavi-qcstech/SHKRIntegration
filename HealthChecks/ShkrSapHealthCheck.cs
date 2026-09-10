using System.Net.Http.Headers;
using System.Text;

using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;
using SHKRIntegration.Options;

namespace SHKRIntegration.HealthChecks;



public sealed class ShkrSapHealthCheck(IHttpClientFactory httpClientFactory, IOptions<ShkrSapApiOptions> shkrSapOptions) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        var options = shkrSapOptions.Value;

        if (string.IsNullOrWhiteSpace(options.BaseUrl))
        {
            return HealthCheckResult.Unhealthy("ShkrSap:BaseUrl is not configured.");
        }

        try
        {
            using var client = httpClientFactory.CreateClient();
            client.Timeout = TimeSpan.FromSeconds(5);

            var requestUri = $"{options.BaseUrl}/sap/opu/odata/SAP/Z_VEND_DETAILS_SRV/$metadata?sap-client={options.ShkrSapClient}";
            using var request = new HttpRequestMessage(HttpMethod.Get, requestUri);

            if (!string.IsNullOrWhiteSpace(options.Username))
            {
                var credentials = Convert.ToBase64String(
                    Encoding.ASCII.GetBytes($"{options.Username}:{options.Password}"));
                request.Headers.Authorization = new AuthenticationHeaderValue("Basic", credentials);
            }

            using var response = await client.SendAsync(request, cancellationToken);

            return response.IsSuccessStatusCode
                ? HealthCheckResult.Healthy($"SAP Gateway reachable ({(int)response.StatusCode}).")
                : HealthCheckResult.Unhealthy($"SAP Gateway returned {(int)response.StatusCode}.");
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("SAP Gateway unreachable.", ex);
        }
    }
}
