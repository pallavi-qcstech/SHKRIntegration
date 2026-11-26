using System.Data;
using System.Net;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public abstract class ShkrGetPrPoStatusServiceBase(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptionsMonitor<ShkrGetPrPoStatusOptions> prPoStatusOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger logger)
{
    public const string ShkrSapClientName = "ShkrSapGetPrPoStatus";

    private const string QueueRowSql = """
        SELECT tran_id, tran_type
        FROM dbo.xx_integration_tbl
        WHERE record_id = @RecordId
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

    private static volatile bool _stoppedBy401;

    private readonly ShkrSapApiOptions _shkrSapOptions = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    protected abstract string DocumentKind { get; }

    protected abstract string ExpectedTranType { get; }

    protected abstract string EntitySet { get; }

    protected abstract string? FilterField { get; }

    protected abstract string NumberSql { get; }

    protected abstract SapStatusRead Parse(int httpStatus, string body, string sapNumber);

    public static string BuildRequestUri(string servicePath, string entitySet, string? filterField, string sapNumber, string sapClient)
    {
        var basePath = $"{servicePath.TrimEnd('/')}/{entitySet}";
        if (filterField is null)
        {
            return $"{basePath}('{sapNumber}')?sap-client={sapClient}&$format=json";
        }

        var filter = Uri.EscapeDataString($"{filterField} eq '{sapNumber}'");
        return $"{basePath}?sap-client={sapClient}&$filter={filter}&$format=json";
    }

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

    public static string? ReadSapErrorValue(string body) => SapErrorMessageExtensions.TryReadSapErrorMessage(body);

    private static StatusReadResult Fail(long recordId, int replyStatusCode, string error, string? sapNumber = null) =>
        new(recordId, sapNumber, null, null, null, null, false, error, replyStatusCode);

    protected async Task<StatusReadResult> ReadAsync(long recordId, CancellationToken cancellationToken)
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

        if (!string.Equals(tranType, ExpectedTranType, StringComparison.OrdinalIgnoreCase))
        {
            return Fail(recordId, StatusCodes.Status400BadRequest,
                $"xx_integration_tbl record_id {recordId} has tran_type '{tranType}', not '{ExpectedTranType}'; SAP was not called.");
        }

        if (tranId is null)
        {
            return Fail(recordId, StatusCodes.Status400BadRequest,
                $"xx_integration_tbl record_id {recordId} has no tran_id; SAP was not called.");
        }

        string? rawNumber;
        await using (var command = new SqlCommand(NumberSql, connection))
        {
            command.Parameters.Add("@TranId", SqlDbType.BigInt).Value = tranId.Value;
            var value = await command.ExecuteScalarAsync(cancellationToken);
            rawNumber = value is null or DBNull ? null : Convert.ToString(value);
        }

        var sapNumber = NormalizeDocumentNumber(rawNumber);
        if (sapNumber is null)
        {
            return Fail(recordId, StatusCodes.Status400BadRequest,
                $"{DocumentKind} number '{rawNumber}' of tran_id {tranId} is not a 1-10 digit SAP number; SAP was not called.");
        }

        var requestUri = BuildRequestUri(prPoStatusOptions.CurrentValue.ServicePath, EntitySet, FilterField, sapNumber,
            _shkrSapOptions.ShkrSapClient);

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
                    DocumentKind, sapNumber, recordId);
                return Fail(recordId, StatusCodes.Status502BadGateway, "SAP returned 401 - stopped, no retry.", sapNumber);
            }

            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            read = Parse((int)response.StatusCode, body, sapNumber);
        }
        catch (Exception ex) when (ex is HttpRequestException || (ex is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            logger.LogError(ex, "{DocumentKind} status read failed for {SapNumber} (record_id {RecordId}).", DocumentKind, sapNumber, recordId);
            return Fail(recordId, StatusCodes.Status504GatewayTimeout, $"No answer from SAP: {ex.Message}", sapNumber);
        }

        if (read.ReadError is not null)
        {
            logger.LogWarning("{DocumentKind} {SapNumber} (record_id {RecordId}): {ReadError}",
                DocumentKind, sapNumber, recordId, read.ReadError);
            return Fail(recordId, StatusCodes.Status502BadGateway, read.ReadError, sapNumber);
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
                DocumentKind, sapNumber, recordId);
        }
        else if (read.HttpStatus is >= 200 and < 300)
        {
            logger.LogInformation("{DocumentKind} {SapNumber} (record_id {RecordId}): SAP status '{SapStatus}', approval status '{ApprovalStatus}'.",
                DocumentKind, sapNumber, recordId, read.Status, approvalStatus);
        }
        else
        {
            logger.LogWarning("{DocumentKind} {SapNumber} (record_id {RecordId}): SAP returned {HttpStatus}: {SapMessage}",
                DocumentKind, sapNumber, recordId, read.HttpStatus, read.SapMessage);
        }

        return new StatusReadResult(recordId, sapNumber, read.HttpStatus, read.Status, approvalStatus, read.SapMessage, true, null,
            StatusCodes.Status200OK);
    }
}
