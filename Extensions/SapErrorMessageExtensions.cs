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

            if (document.RootElement.TryGetProperty("error", out var error))
            {
                string? transactionId = null;

                if (error.TryGetProperty("innererror", out var innerError))
                {
                    if (innerError.TryGetProperty("transactionid", out var transactionIdElement) &&
                        transactionIdElement.ValueKind == JsonValueKind.String)
                    {
                        transactionId = transactionIdElement.GetString();
                    }

                    if (innerError.TryGetProperty("errordetails", out var errorDetails) &&
                        errorDetails.ValueKind == JsonValueKind.Array &&
                        errorDetails.GetArrayLength() > 0 &&
                        errorDetails[0].TryGetProperty("message", out var detailMessage) &&
                        detailMessage.ValueKind == JsonValueKind.String)
                    {
                        var detailText = detailMessage.GetString()!;
                        return transactionId is null ? detailText : $"{detailText} (SAP transaction {transactionId})";
                    }
                }

                if (error.TryGetProperty("message", out var message) &&
                    message.TryGetProperty("value", out var value) &&
                    value.ValueKind == JsonValueKind.String)
                {
                    var text = value.GetString()!;
                    return transactionId is null ? text : $"{text} (SAP transaction {transactionId})";
                }
            }
        }
        catch (JsonException)
        {
        }

        return body;
    }
}
