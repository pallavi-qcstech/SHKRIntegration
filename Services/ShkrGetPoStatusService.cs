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
        ParsePoResponse(httpStatus, body);

    public static SapStatusRead ParsePoResponse(int httpStatus, string body)
    {
        if (httpStatus is >= 200 and < 300)
        {
            var entry = TryDeserialize<GetPoStatusEntry>(body);
            return new SapStatusRead(httpStatus, entry?.PoType, entry?.Status, null, body);
        }

        return new SapStatusRead(httpStatus, null, null, ReadSapErrorValue(body), body);
    }

    private static T? TryDeserialize<T>(string body) where T : class
    {
        try
        {
            return JsonSerializer.Deserialize<ODataEnvelope<T>>(body)?.D;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
