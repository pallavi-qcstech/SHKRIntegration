using System.Data;
using System.Net;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrPrStatusService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptionsMonitor<ShkrPrStatusOptions> prStatusOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrPrStatusService> logger)
{
    public const string ShkrSapClientName = "ShkrSapPrStatus";

    private const string QueueRowSql = """
        SELECT tran_id, tran_type
        FROM dbo.xx_integration_tbl
        WHERE record_id = @RecordId
        """;

    private const string PrNumberSql = """
        SELECT SpecField4
        FROM dbo.Estimate_PreBids
        WHERE Id = @TranId
        """;

    private const string PoNumberSql = """
        SELECT Reference
        FROM dbo.CostManagement_Commitments
        WHERE Id = @TranId
        """;

    private const string UpdateQueueRowSql = """
        UPDATE dbo.xx_integration_tbl
        SET erp_txn_number = @SapNumber,
            erp_approval_status = @SapStatus,
            erp_approval_comments = @SapMessage,
            last_update_date = GETDATE()
        WHERE record_id = @RecordId
        """;

    private const string TouchQueueRowSql = """
        UPDATE dbo.xx_integration_tbl
        SET last_update_date = GETDATE()
        WHERE record_id = @RecordId
        """;

    private readonly ShkrSapApiOptions _shkrSapOptions = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;
    private volatile bool _stoppedBy401;

    public Task<StatusReadResult> ReadPrAsync(long recordId, CancellationToken cancellationToken = default) =>
        ReadAsync("PR", "PREBID", "PRSet", PrNumberSql, ParsePrResponse, recordId, cancellationToken);

    public Task<StatusReadResult> ReadPoAsync(long recordId, CancellationToken cancellationToken = default) =>
        ReadAsync("PO", "Commitments", "POSet", PoNumberSql, ParsePoResponse, recordId, cancellationToken);

    public static string? NormalizeDocumentNumber(string? value)
    {
        var trimmed = value?.Trim() ?? string.Empty;
        if (trimmed.Length == 0 || trimmed.Length > 10 || !trimmed.All(char.IsAsciiDigit))
        {
            return null;
        }

        return trimmed.PadLeft(10, '0');
    }

    public const string Approved = "Approved";
    public const string Rejected = "Rejected";

    public static string? MapApprovalStatus(string? sapStatus)
    {
        var status = sapStatus?.Trim();
        if (string.IsNullOrEmpty(status))
        {
            return null;
        }

        if (status.StartsWith("Rejected", StringComparison.OrdinalIgnoreCase) ||
            status.StartsWith("Deleted", StringComparison.OrdinalIgnoreCase) ||
            status.StartsWith("Pending", StringComparison.OrdinalIgnoreCase))
        {
            return Rejected;
        }

        return Approved;
    }

    public static bool IsNoStatus(SapStatusRead read) =>
        read.HttpStatus is >= 200 and < 300 && MapApprovalStatus(read.Status) is null;

    public static string? BuildApprovalComment(SapStatusRead read)
    {
        if (read.HttpStatus is >= 200 and < 300)
        {
            return read.Status is null ? null : $"SAP status: {read.Status}";
        }

        return read.SapMessage;
    }

    public static SapStatusRead ParsePrResponse(int httpStatus, string body)
    {
        if (httpStatus is >= 200 and < 300)
        {
            var entry = TryDeserialize<PrStatusEntry>(body);
            return new SapStatusRead(httpStatus, entry?.PrType, entry?.Status, null, body);
        }

        return new SapStatusRead(httpStatus, null, null, ReadSapErrorValue(body), body);
    }

    public static SapStatusRead ParsePoResponse(int httpStatus, string body)
    {
        if (httpStatus is >= 200 and < 300)
        {
            var entry = TryDeserialize<PoStatusEntry>(body);
            return new SapStatusRead(httpStatus, entry?.PoType, entry?.Status, null, body);
        }

        return new SapStatusRead(httpStatus, null, null, ReadSapErrorValue(body), body);
    }

    public static string? ReadSapErrorValue(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("error", out var error) &&
                error.TryGetProperty("message", out var message) &&
                message.TryGetProperty("value", out var value) &&
                value.ValueKind == JsonValueKind.String)
            {
                return value.GetString();
            }
        }
        catch (JsonException)
        {
        }

        return null;
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

    private static StatusReadResult Fail(long recordId, int replyStatusCode, string error, string? sapNumber = null) =>
        new(recordId, sapNumber, null, null, null, null, false, error, replyStatusCode);

    private async Task<StatusReadResult> ReadAsync(
        string documentKind,
        string expectedTranType,
        string entitySet,
        string numberSql,
        Func<int, string, SapStatusRead> parse,
        long recordId,
        CancellationToken cancellationToken)
    {
        if (recordId <= 0 || recordId > int.MaxValue)
        {
            return Fail(recordId, StatusCodes.Status400BadRequest, "recordId must be an xx_integration_tbl record_id.");
        }

        if (_stoppedBy401)
        {
            return Fail(recordId, StatusCodes.Status503ServiceUnavailable,
                "SAP returned 401 earlier. Fix the SAP account, then restart the application.");
        }

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        long? tranId;
        string? tranType;
        await using (var command = new SqlCommand(QueueRowSql, connection))
        {
            command.Parameters.Add("@RecordId", SqlDbType.Int).Value = (int)recordId;
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
            {
                return Fail(recordId, StatusCodes.Status404NotFound, $"No xx_integration_tbl row with record_id {recordId}.");
            }

            tranId = reader.IsDBNull(0) ? null : reader.GetInt64(0);
            tranType = reader.IsDBNull(1) ? null : reader.GetString(1);
        }

        if (!string.Equals(tranType, expectedTranType, StringComparison.OrdinalIgnoreCase))
        {
            return Fail(recordId, StatusCodes.Status400BadRequest,
                $"xx_integration_tbl record_id {recordId} has tran_type '{tranType}', not '{expectedTranType}'; SAP was not called.");
        }

        if (tranId is null)
        {
            return Fail(recordId, StatusCodes.Status400BadRequest,
                $"xx_integration_tbl record_id {recordId} has no tran_id; SAP was not called.");
        }

        string? rawNumber;
        await using (var command = new SqlCommand(numberSql, connection))
        {
            command.Parameters.Add("@TranId", SqlDbType.BigInt).Value = tranId.Value;
            var value = await command.ExecuteScalarAsync(cancellationToken);
            rawNumber = value is null or DBNull ? null : Convert.ToString(value);
        }

        var sapNumber = NormalizeDocumentNumber(rawNumber);
        if (sapNumber is null)
        {
            return Fail(recordId, StatusCodes.Status400BadRequest,
                $"{documentKind} number '{rawNumber}' of tran_id {tranId} is not a 1-10 digit SAP number; SAP was not called.");
        }

        var requestUri =
            $"{prStatusOptions.CurrentValue.ServicePath.TrimEnd('/')}/{entitySet}('{sapNumber}')?sap-client={_shkrSapOptions.ShkrSapClient}&$format=json";

        SapStatusRead read;
        try
        {
            var client = httpClientFactory.CreateClient(ShkrSapClientName);
            using var response = await client.GetAsync(requestUri, cancellationToken);

            if (response.StatusCode == HttpStatusCode.Unauthorized)
            {
                _stoppedBy401 = true;
                logger.LogCritical(
                    "SAP returned 401 for {DocumentKind} {SapNumber} (record_id {RecordId}). Status reads are stopped until the application is restarted (no retry, to avoid locking the SAP account).",
                    documentKind, sapNumber, recordId);
                return Fail(recordId, StatusCodes.Status502BadGateway, "SAP returned 401 - stopped, no retry.", sapNumber);
            }

            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            read = parse((int)response.StatusCode, body);
        }
        catch (Exception ex) when (ex is HttpRequestException || (ex is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            logger.LogError(ex, "{DocumentKind} status read failed for {SapNumber} (record_id {RecordId}).", documentKind, sapNumber, recordId);
            return Fail(recordId, StatusCodes.Status504GatewayTimeout, $"No answer from SAP: {ex.Message}", sapNumber);
        }

        var approvalStatus = read.HttpStatus is >= 200 and < 300 ? MapApprovalStatus(read.Status) : null;
        var noStatus = IsNoStatus(read);

        await using (var command = new SqlCommand(noStatus ? TouchQueueRowSql : UpdateQueueRowSql, connection))
        {
            command.Parameters.Add("@RecordId", SqlDbType.Int).Value = (int)recordId;
            if (!noStatus)
            {
                command.Parameters.Add("@SapNumber", SqlDbType.VarChar, -1).Value = sapNumber;
                command.Parameters.Add("@SapStatus", SqlDbType.VarChar, -1).Value = (object?)approvalStatus ?? DBNull.Value;
                command.Parameters.Add("@SapMessage", SqlDbType.VarChar, -1).Value = (object?)BuildApprovalComment(read) ?? DBNull.Value;
            }

            var rows = await command.ExecuteNonQueryAsync(cancellationToken);
            if (rows == 0)
            {
                return Fail(recordId, StatusCodes.Status404NotFound, $"xx_integration_tbl row {recordId} no longer exists.", sapNumber);
            }
        }

        if (noStatus)
        {
            logger.LogInformation("{DocumentKind} {SapNumber} (record_id {RecordId}): no status from SAP (pending); only last_update_date set.",
                documentKind, sapNumber, recordId);
        }
        else if (read.HttpStatus is >= 200 and < 300)
        {
            logger.LogInformation("{DocumentKind} {SapNumber} (record_id {RecordId}): SAP status '{SapStatus}', approval status '{ApprovalStatus}'.",
                documentKind, sapNumber, recordId, read.Status, approvalStatus);
        }
        else
        {
            logger.LogWarning("{DocumentKind} {SapNumber} (record_id {RecordId}): SAP returned {HttpStatus}: {SapMessage}",
                documentKind, sapNumber, recordId, read.HttpStatus, read.SapMessage);
        }

        return new StatusReadResult(recordId, sapNumber, read.HttpStatus, read.Status, approvalStatus, read.SapMessage, true, null,
            StatusCodes.Status200OK);
    }
}
