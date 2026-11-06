using System.Globalization;
using System.Net.Http.Json;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrChangeOrderService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrChangeOrderService> logger)
{
    public const string ShkrSapClientName = "ShkrSapChangeOrder";

    private const string StatusSuccess = "S";
    private const string StatusError = "E";

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    private static readonly JsonSerializerOptions RequestSerializerOptions = new(JsonSerializerDefaults.General)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public async Task<ChangeOrderResult> ChangeAsync(long recordId, CancellationToken cancellationToken = default)
    {
        var header = await GetHeaderAsync(recordId, cancellationToken)
            ?? throw new ArgumentException(
                $"No Change Order header found for record_id {recordId} with process_status = 'N'.");

        var lines = await GetLinesAsync(header.RecordId, cancellationToken);
        if (lines.Count == 0)
        {
            throw new ArgumentException($"Change Order header {header.RecordId} has no lines.");
        }

        try
        {
            var request = BuildRequest(header, lines);

            var result = await SendToSapAsync(request, cancellationToken);

            await PersistResultAsync(header.RecordId, result, cancellationToken);

            logger.LogInformation(
                "Change Order (header record_id={RecordId}) completed: Success={Success}, PoNumber={PoNumber}.",
                header.RecordId, result.Success, result.PoNumber);

            return result;
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            logger.LogError(ex, "Change Order failed for header record_id {RecordId}.", header.RecordId);
            await PersistResultAsync(header.RecordId, new ChangeOrderResult(false, null, ex.Message), cancellationToken);
            throw;
        }
    }

    private static ChangeOrderRequest BuildRequest(ChangeOrderHeader header, List<ChangeOrderLine> lines)
    {
        var request = new ChangeOrderRequest
        {
            PoNumber = header.PoNumber ?? string.Empty,
        };

        var schedules = new List<ChangeOrderSchedSetItem>();
        var accounts = new List<ChangeOrderAccountSetItem>();

        foreach (var line in lines)
        {
            var poItem = line.PoItem ?? string.Empty;
            var quantity = FormatDecimal(line.Quantity, "0.000");

            var item = new ChangeOrderItemSetItem
            {
                PoItem = poItem,
                DeleteInd = NullIfBlank(line.DeleteInd),
                ShortText = NullIfBlank(line.ShortText),
                Plant = NullIfBlank(line.Plant),
                MatlGroup = NullIfBlank(line.MatGrp),
                Quantity = quantity,
                PoUnit = NullIfBlank(line.PoUnit),
                NetPrice = FormatDecimal(line.NetPrice, "0.00"),
                PriceUnit = NullIfBlank(line.PriceUnit),
                TaxCode = NullIfBlank(line.TaxCode),
                AcctAssCat = NullIfBlank(line.AcctAssCat),
            };

            if (line.LineAction == "ADD" || HasItemChange(item))
            {
                request.PoItemSet.Add(item);
            }

            if (!string.IsNullOrWhiteSpace(line.SchedLine))
            {
                schedules.Add(new ChangeOrderSchedSetItem
                {
                    PoItem = poItem,
                    SchedLine = line.SchedLine,
                    DeliveryDate = NullIfBlank(line.DeliveryDate),
                    Quantity = quantity,
                });
            }

            if (!string.IsNullOrWhiteSpace(line.SerialNo))
            {
                accounts.Add(new ChangeOrderAccountSetItem
                {
                    PoItem = poItem,
                    SerialNo = line.SerialNo,
                    GlAccount = NullIfBlank(line.GlAccount),
                    WbsElement = NullIfBlank(line.WbsElement),
                    Network = NullIfBlank(line.Network),
                    Activity = NullIfBlank(line.Activity),
                });
            }
        }

        request.PoSchedSet = schedules.Count > 0 ? schedules : null;
        request.PoAccountSet = accounts.Count > 0 ? accounts : null;

        return request;
    }

    private static bool HasItemChange(ChangeOrderItemSetItem item) =>
        item.DeleteInd is not null || item.ShortText is not null || item.Quantity is not null
        || item.NetPrice is not null || item.PriceUnit is not null;

    private static string? FormatDecimal(decimal? value, string format) =>
        value?.ToString(format, CultureInfo.InvariantCulture);

    private static string? NullIfBlank(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private async Task<ChangeOrderResult> SendToSapAsync(ChangeOrderRequest request, CancellationToken cancellationToken)
    {
        var requestUri = $"/sap/opu/odata/sap/Z_PO_CREATE_SRV/POHEADSet?sap-client={_options.ShkrSapClient}";

        var client = httpClientFactory.CreateClient(ShkrSapClientName);

        logger.LogInformation(
            "Calling SAP Z_PO_CREATE_SRV (change) for PO {PoNumber}.",
            request.PoNumber);

        using var response = await client.PostAsJsonAsync(requestUri, request, RequestSerializerOptions, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError(
                "SAP Z_PO_CREATE_SRV change call failed with status {StatusCode}: {SapErrorMessage}",
                (int)response.StatusCode, sapErrorMessage);
            return new ChangeOrderResult(false, null, sapErrorMessage);
        }

        var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<CreatePurchaseOrderResponseBody>>(cancellationToken)
            ?? throw new InvalidOperationException("SAP Z_PO_CREATE_SRV returned an empty response body.");

        if (string.IsNullOrWhiteSpace(envelope.D.PoNumber))
        {
            throw new InvalidOperationException("SAP Z_PO_CREATE_SRV returned 201 but no PoNumber in the response body.");
        }

        return new ChangeOrderResult(true, envelope.D.PoNumber, null);
    }

    private async Task<ChangeOrderHeader?> GetHeaderAsync(long recordId, CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT record_id, po_number
            FROM dbo.xx_changeorder_hdr_stg_tbl_ob
            WHERE record_id = @RecordId AND process_status = 'N'
            """;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@RecordId", recordId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new ChangeOrderHeader
        {
            RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
            PoNumber = GetString(reader, "po_number"),
        };
    }

    private async Task<List<ChangeOrderLine>> GetLinesAsync(long hdrRecordId, CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                record_id, hdr_record_id, line_action, po_item, delete_ind, short_text, mat_grp, plant, quantity, po_unit,
                net_price, price_unit, tax_code, acctasscat, sched_line, delivery_date, serial_no,
                wbs_element, gl_account, network, activity
            FROM dbo.xx_changeorder_line_stg_tbl_ob
            WHERE hdr_record_id = @HdrRecordId
            ORDER BY po_item ASC, record_id ASC
            """;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@HdrRecordId", hdrRecordId);

        var lines = new List<ChangeOrderLine>();

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            lines.Add(new ChangeOrderLine
            {
                RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
                HdrRecordId = reader.GetInt64(reader.GetOrdinal("hdr_record_id")),
                LineAction = GetString(reader, "line_action"),
                PoItem = GetString(reader, "po_item"),
                DeleteInd = GetString(reader, "delete_ind"),
                ShortText = GetString(reader, "short_text"),
                MatGrp = GetString(reader, "mat_grp"),
                Plant = GetString(reader, "plant"),
                Quantity = GetDecimal(reader, "quantity"),
                PoUnit = GetString(reader, "po_unit"),
                NetPrice = GetDecimal(reader, "net_price"),
                PriceUnit = GetString(reader, "price_unit"),
                TaxCode = GetString(reader, "tax_code"),
                AcctAssCat = GetString(reader, "acctasscat"),
                SchedLine = GetString(reader, "sched_line"),
                DeliveryDate = GetString(reader, "delivery_date"),
                SerialNo = GetString(reader, "serial_no"),
                WbsElement = GetString(reader, "wbs_element"),
                GlAccount = GetString(reader, "gl_account"),
                Network = GetString(reader, "network"),
                Activity = GetString(reader, "activity"),
            });
        }

        return lines;
    }

    private const int ErrorMsgMaxLength = 2000;

    private async Task PersistResultAsync(long hdrRecordId, ChangeOrderResult result, CancellationToken cancellationToken)
    {
        var status = result.Success ? StatusSuccess : StatusError;
        var now = DateTime.Now;
        var errorMsg = result.ErrorMessage is { Length: > ErrorMsgMaxLength }
            ? result.ErrorMessage[..ErrorMsgMaxLength]
            : result.ErrorMessage;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        const string updateHeaderSql = """
            UPDATE dbo.xx_changeorder_hdr_stg_tbl_ob
            SET process_status = @ProcessStatus, sap_po_id = @SapPoId, error_msg = @ErrorMsg, last_update_date = @LastUpdateDate
            WHERE record_id = @RecordId
            """;

        await using (var headerCommand = new SqlCommand(updateHeaderSql, connection))
        {
            headerCommand.Parameters.AddWithValue("@ProcessStatus", status);
            headerCommand.Parameters.AddWithValue("@SapPoId", (object?)result.PoNumber ?? DBNull.Value);
            headerCommand.Parameters.AddWithValue("@ErrorMsg", (object?)errorMsg ?? DBNull.Value);
            headerCommand.Parameters.AddWithValue("@LastUpdateDate", now);
            headerCommand.Parameters.AddWithValue("@RecordId", hdrRecordId);
            await headerCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        const string updateLinesSql = """
            UPDATE dbo.xx_changeorder_line_stg_tbl_ob
            SET process_status = @ProcessStatus, error_msg = @ErrorMsg, last_update_date = @LastUpdateDate
            WHERE hdr_record_id = @HdrRecordId
            """;

        await using (var linesCommand = new SqlCommand(updateLinesSql, connection))
        {
            linesCommand.Parameters.AddWithValue("@ProcessStatus", status);
            linesCommand.Parameters.AddWithValue("@ErrorMsg", (object?)errorMsg ?? DBNull.Value);
            linesCommand.Parameters.AddWithValue("@LastUpdateDate", now);
            linesCommand.Parameters.AddWithValue("@HdrRecordId", hdrRecordId);
            await linesCommand.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static string? GetString(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
    }

    private static decimal? GetDecimal(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetDecimal(ordinal);
    }
}
