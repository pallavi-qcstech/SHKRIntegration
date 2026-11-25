using System.Text.Json;
using Microsoft.Extensions.Options;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrGetPrStatusService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptionsMonitor<ShkrGetPrPoStatusOptions> prPoStatusOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrGetPrStatusService> logger)
    : ShkrGetPrPoStatusServiceBase(httpClientFactory, shkrSapOptions, prPoStatusOptions, databaseOptions, logger)
{
    public const string PrFilterField = "purchase_requsition";

    private const string PrNumberSql = """
        SELECT SpecField4
        FROM dbo.Estimate_PreBids
        WHERE Id = @TranId
        """;

    protected override string DocumentKind => "PR";

    protected override string ExpectedTranType => "PREBID";

    protected override string EntitySet => "PRSet";

    protected override string? FilterField => PrFilterField;

    protected override string NumberSql => PrNumberSql;

    public Task<StatusReadResult> ReadPrAsync(long recordId, CancellationToken cancellationToken = default) =>
        ReadAsync(recordId, cancellationToken);

    protected override SapStatusRead Parse(int httpStatus, string body, string sapNumber) =>
        ParsePrFilterResponse(httpStatus, body, sapNumber);

    public static SapStatusRead ParsePrFilterResponse(int httpStatus, string body, string sapNumber)
    {
        if (httpStatus is < 200 or >= 300)
        {
            return new SapStatusRead(httpStatus, null, null, ReadSapErrorValue(body), body);
        }

        List<GetPrStatusEntry>? entries = null;
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("d", out var d) &&
                d.ValueKind == JsonValueKind.Object &&
                d.TryGetProperty("results", out var results) &&
                results.ValueKind == JsonValueKind.Array)
            {
                entries = results.Deserialize<List<GetPrStatusEntry>>();
            }
        }
        catch (JsonException)
        {
            entries = null;
        }

        if (entries is null)
        {
            return new SapStatusRead(httpStatus, null, null, null, body,
                $"SAP reply for PR {sapNumber} is not an OData result list; nothing was written.");
        }

        var matches = entries
            .Where(e => NormalizeDocumentNumber(e.PurchaseRequisition) == sapNumber)
            .ToList();

        if (matches.Count > 1)
        {
            return new SapStatusRead(httpStatus, null, null, null, body,
                $"SAP returned {matches.Count} entries for PR {sapNumber}; nothing was written.");
        }

        if (matches.Count == 0)
        {
            return new SapStatusRead(httpStatus, null, null, null, body);
        }

        return new SapStatusRead(httpStatus, matches[0].PrType, matches[0].Status, null, body);
    }
}
