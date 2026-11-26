using System.Text.Json;

namespace SHKRIntegration.Extensions;

public static class SapErrorMessageExtensions
{
    private static readonly string[] GenericSapTexts =
    [
        "An exception was raised",
        "Errors occurred during processing",
        "Exception raised without specific error",
    ];

    public static async Task<string> ReadSapErrorMessageAsync(this HttpResponseMessage response, CancellationToken cancellationToken = default)
    {
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        return ExtractSapErrorMessage(body, (int)response.StatusCode);
    }

    public static string ExtractSapErrorMessage(string? body, int statusCode)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return $"HTTP {statusCode} (no response body)";
        }

        var message = TryReadSapErrorMessage(body);
        return message ?? body.Trim();
    }

    public static string? TryReadSapErrorMessage(string? body)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !document.RootElement.TryGetProperty("error", out var error) ||
                error.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            var real = new List<string>();
            var generic = new List<string>();

            if (error.TryGetProperty("innererror", out var innerError) &&
                innerError.ValueKind == JsonValueKind.Object &&
                innerError.TryGetProperty("errordetails", out var errorDetails) &&
                errorDetails.ValueKind == JsonValueKind.Array)
            {
                foreach (var detail in errorDetails.EnumerateArray())
                {
                    if (detail.ValueKind == JsonValueKind.Object &&
                        detail.TryGetProperty("message", out var detailMessage) &&
                        detailMessage.ValueKind == JsonValueKind.String)
                    {
                        Add(detailMessage.GetString(), real, generic);
                    }
                }
            }

            if (real.Count == 0 &&
                error.TryGetProperty("message", out var topMessage))
            {
                if (topMessage.ValueKind == JsonValueKind.Object &&
                    topMessage.TryGetProperty("value", out var value) &&
                    value.ValueKind == JsonValueKind.String)
                {
                    Add(value.GetString(), real, generic);
                }
                else if (topMessage.ValueKind == JsonValueKind.String)
                {
                    Add(topMessage.GetString(), real, generic);
                }
            }

            if (real.Count == 0)
            {
                CollectMessages(error, real, generic);
            }

            var texts = real.Count > 0 ? real : generic;
            return texts.Count == 0 ? null : string.Join("; ", texts.Distinct(StringComparer.Ordinal));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static bool IsGenericSapText(string text) =>
        GenericSapTexts.Any(g => text.StartsWith(g, StringComparison.OrdinalIgnoreCase));

    private static void Add(string? raw, List<string> real, List<string> generic)
    {
        var text = raw?.Trim();
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        (IsGenericSapText(text) ? generic : real).Add(text);
    }

    private static void CollectMessages(JsonElement element, List<string> real, List<string> generic)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    if (property.NameEquals("message"))
                    {
                        if (property.Value.ValueKind == JsonValueKind.String)
                        {
                            Add(property.Value.GetString(), real, generic);
                            continue;
                        }

                        if (property.Value.ValueKind == JsonValueKind.Object &&
                            property.Value.TryGetProperty("value", out var value) &&
                            value.ValueKind == JsonValueKind.String)
                        {
                            Add(value.GetString(), real, generic);
                            continue;
                        }
                    }

                    CollectMessages(property.Value, real, generic);
                }
                break;
            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    CollectMessages(item, real, generic);
                }
                break;
        }
    }
}
