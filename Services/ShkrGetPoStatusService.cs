using System.Text.Json;
using Microsoft.Extensions.Options;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrGetPoStatusService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptionsMonitor<ShkrGetPrPoStatusOptions> prPoStatusOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrGetPoStatusService> logger)
    : ShkrGetPrPoStatusServiceBase(httpClientFactory, shkrSapOptions, prPoStatusOptions, databaseOptions, logger)
{
    private const string PoNumberSql = """
        SELECT Reference
        FROM dbo.CostManagement_Commitments
        WHERE Id = @TranId
        """;

    protected override string DocumentKind => "PO";

    protected override string ExpectedTranType => "Commitments";

    protected override string EntitySet => "POSet";

    protected override string? FilterField => null;

    protected override string NumberSql => PoNumberSql;

    public Task<StatusReadResult> ReadPoAsync(long recordId, CancellationToken cancellationToken = default) =>
        ReadAsync(recordId, cancellationToken);

    protected override SapStatusRead Parse(int httpStatus, string body, string sapNumber) =>
        ParsePoListResponse(httpStatus, body, sapNumber);

    public static SapStatusRead ParsePoListResponse(int httpStatus, string body, string sapNumber)
    {
        if (httpStatus is < 200 or >= 300)
        {
            return new SapStatusRead(httpStatus, null, null, ReadSapErrorValue(body), body);
        }

        List<GetPoStatusEntry>? entries = null;
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("d", out var d) &&
                d.ValueKind == JsonValueKind.Object &&
                d.TryGetProperty("results", out var results) &&
                results.ValueKind == JsonValueKind.Array)
            {
                entries = results.Deserialize<List<GetPoStatusEntry>>();
            }
        }
        catch (JsonException)
        {
            entries = null;
        }

        if (entries is null)
        {
            return new SapStatusRead(httpStatus, null, null, null, body,
                $"SAP reply for PO {sapNumber} is not an OData result list; nothing was written.");
        }

        var matches = entries
            .Where(e => NormalizeDocumentNumber(e.PurchaseOrder) == sapNumber)
            .ToList();

        if (matches.Count > 1)
        {
            return new SapStatusRead(httpStatus, null, null, null, body,
                $"SAP returned {matches.Count} entries for PO {sapNumber}; nothing was written.");
        }

        if (matches.Count == 0)
        {
            return new SapStatusRead(httpStatus, null, null, null, body);
        }

        return new SapStatusRead(httpStatus, matches[0].PoType, matches[0].Status, null, body);
    }
}
