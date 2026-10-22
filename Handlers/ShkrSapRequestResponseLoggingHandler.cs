using System.Text;

namespace SHKRIntegration.Handlers;

public sealed class ShkrSapRequestResponseLoggingHandler(ILogger<ShkrSapRequestResponseLoggingHandler> logger) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var requestBody = request.Content is null
            ? "(none)"
            : await request.Content.ReadAsStringAsync(cancellationToken);

        logger.LogDebug(
            "SAP request: {Method} {Uri}{NewLine}{RequestBody}",
            request.Method, request.RequestUri, Environment.NewLine, requestBody);

        var response = await base.SendAsync(request, cancellationToken);

        var responseBytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        var responseBody = responseBytes.Length > 0 ? Encoding.UTF8.GetString(responseBytes) : "(empty)";

        logger.LogDebug(
            "SAP response: {StatusCode} for {Method} {Uri}{NewLine}{ResponseBody}",
            (int)response.StatusCode, request.Method, request.RequestUri, Environment.NewLine, responseBody);

        var replacementContent = new ByteArrayContent(responseBytes);
        foreach (var header in response.Content.Headers)
        {
            replacementContent.Headers.TryAddWithoutValidation(header.Key, header.Value);
        }

        response.Content = replacementContent;

        return response;
    }
}
