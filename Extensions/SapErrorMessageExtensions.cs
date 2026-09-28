using System.Text.Json;

namespace SHKRIntegration.Extensions;

public static class SapErrorMessageExtensions
{
    public static async Task<string> ReadSapErrorMessageAsync(this HttpResponseMessage response, CancellationToken cancellationToken = default)
    {
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (string.IsNullOrWhiteSpace(body))
        {
            return $"{(int)response.StatusCode} {response.StatusCode} (no response body)";
        }

        try
        {
            using var document = JsonDocument.Parse(body);

            if (document.RootElement.TryGetProperty("error", out var error) &&
                error.TryGetProperty("message", out var message) &&
                message.TryGetProperty("value", out var value) &&
                value.ValueKind == JsonValueKind.String)
            {
                var text = value.GetString()!;

                if (error.TryGetProperty("innererror", out var innerError) &&
                    innerError.TryGetProperty("transactionid", out var transactionId) &&
                    transactionId.ValueKind == JsonValueKind.String)
                {
                    text += $" (SAP transaction {transactionId.GetString()})";
                }

                return text;
            }
        }
        catch (JsonException)
        {
        }

        return body;
    }
}
