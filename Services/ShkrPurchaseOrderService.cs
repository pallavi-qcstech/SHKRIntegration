using System.Globalization;
using System.Net.Http.Json;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrPurchaseOrderService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrPurchaseOrderService> logger)
{
    public const string ShkrSapClientName = "ShkrSapPurchaseOrder";

    private const string StatusSuccess = "S";
    private const string StatusError = "E";

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    private static readonly JsonSerializerOptions RequestSerializerOptions = new(JsonSerializerDefaults.General)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    public async Task<PurchaseOrderCreateResult> CreateAsync(long recordId, CancellationToken cancellationToken = default)
    {
        var header = await GetHeaderAsync(recordId, cancellationToken)
            ?? throw new ArgumentException(
                $"No Purchase Order header found for record_id {recordId} with process_status = 'N'.");

        var lines = await GetLinesAsync(header.RecordId, cancellationToken);
        if (lines.Count == 0)
        {
            throw new ArgumentException($"Purchase Order header {header.RecordId} has no lines.");
        }

        PurchaseOrderCreateResult result;
        try
        {
            var request = BuildRequest(header, lines);

            result = await SendToSapAsync(request, CancellationToken.None);
        }
        catch (Exception ex)
        {
            var sapCheck = $"ME23N, vendor {header.Vendor}, PR {lines[0].PreqNo}";
            var message = ex.ToSapCreateFailureMessage("PO", sapCheck);
            logger.LogError(ex, "Purchase Order create failed for header record_id {RecordId}: {Message}", header.RecordId, message);
            await SaveResultAsync(header.RecordId, new PurchaseOrderCreateResult(false, null, message));
            throw;
        }

        await SaveResultAsync(header.RecordId, result);

        logger.LogInformation(
            "Purchase Order create (header record_id={RecordId}) completed: Success={Success}, PoNumber={PoNumber}.",
            header.RecordId, result.Success, result.PoNumber);

        return result;
    }

    private async Task SaveResultAsync(long hdrRecordId, PurchaseOrderCreateResult result)
    {
        try
        {
            await PersistResultAsync(hdrRecordId, result, CancellationToken.None);
        }
        catch (Exception first)
        {
            logger.LogWarning(first, "Saving the Purchase Order result for header record_id {RecordId} failed; trying once more.", hdrRecordId);
            try
            {
                await PersistResultAsync(hdrRecordId, result, CancellationToken.None);
            }
            catch (Exception second)
            {
                logger.LogError(second,
                    "Saving the Purchase Order result for header record_id {RecordId} failed again. SAP result: Success={Success}, PoNumber={PoNumber}, Error={Error}",
                    hdrRecordId, result.Success, result.PoNumber, result.ErrorMessage);
                throw;
            }
        }
    }

    public static CreatePurchaseOrderRequest BuildRequest(
        PurchaseOrderHeader header, List<PurchaseOrderLine> lines)
    {
        var request = new CreatePurchaseOrderRequest
        {
            CompCode = header.CompCode ?? string.Empty,
            DocType = header.DocType ?? string.Empty,
            Vendor = header.Vendor ?? string.Empty,
            PurchOrg = header.PurchOrg ?? string.Empty,
            PurGroup = header.PurGroup ?? string.Empty,
            Currency = header.Currency ?? string.Empty,
            DocDate = header.DocDate ?? string.Empty,
        };

        var serialNoByGlAccount = SerialNoByGlAccount(lines);

        foreach (var line in lines)
        {
            var poItem = line.PoItem ?? string.Empty;

            request.PoItemSet.Add(new PoItemSetItem
            {
                PoItem = poItem,
                ItemCat = line.ItemCat ?? string.Empty,
                ShortText = line.ShortText ?? string.Empty,
                Plant = line.Plant ?? string.Empty,
                MatlGroup = line.MatGrp ?? string.Empty,
                Quantity = FormatQuantity(line.Quantity),
                PoUnit = line.PoUnit ?? string.Empty,
                TaxCode = line.TaxCode ?? string.Empty,
                AcctAssCat = line.AcctAssCat ?? string.Empty,
                PreqItem = line.PreqItem ?? string.Empty,
                PreqNo = line.PreqNo ?? string.Empty,
            });

            request.PoAccountSet.Add(new PoAccountSetItem
            {
                PoItem = poItem,
                SerialNo = serialNoByGlAccount[GlKey(line)],
                GlAccount = line.GlAccount ?? string.Empty,
                WbsElement = NullIfBlank(line.WbsElement),
                Network = NullIfBlank(line.Network),
                Activity = NullIfBlank(line.Activity),
            });

            request.PoSrvSet.Add(new PoServiceSetItem
            {
                PoItem = poItem,
                ShortText = line.SrvShortText ?? string.Empty,
                Quantity = FormatQuantity(line.SrvQuantity),
                BaseUom = line.SrvUom ?? string.Empty,
                GrPrice = FormatDecimal(line.SrvGrPrice, "0.##"),
                MatlGroup = line.SrvMatlGroup ?? string.Empty,
            });
        }

        return request;
    }

    private static string FormatDecimal(decimal? value, string format) =>
        value?.ToString(format, CultureInfo.InvariantCulture) ?? string.Empty;

    private static Dictionary<string, string> SerialNoByGlAccount(List<PurchaseOrderLine> lines)
    {
        var serials = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in lines.OrderBy(l => l.PoItem ?? string.Empty, StringComparer.Ordinal))
        {
            var gl = GlKey(line);
            if (!serials.ContainsKey(gl))
            {
                serials[gl] = (serials.Count + 1).ToString("00", CultureInfo.InvariantCulture);
            }
        }

        return serials;
    }

    private static string GlKey(PurchaseOrderLine line) => (line.GlAccount ?? string.Empty).Trim();

    private static string FormatQuantity(decimal? value) =>
        value is null ? string.Empty : decimal.Truncate(value.Value).ToString("0", CultureInfo.InvariantCulture);

    private static string? NullIfBlank(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private async Task<PurchaseOrderCreateResult> SendToSapAsync(
        CreatePurchaseOrderRequest request, CancellationToken cancellationToken)
    {
        var requestUri = $"/sap/opu/odata/sap/Z_PO_CREATE_SRV/POHEADSet?sap-client={_options.ShkrSapClient}";

        var client = httpClientFactory.CreateClient(ShkrSapClientName);

        logger.LogInformation(
            "Calling SAP Z_PO_CREATE_SRV for Vendor {Vendor}.",
            request.Vendor);

        using var response = await client.PostAsJsonAsync(requestUri, request, RequestSerializerOptions, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError(
                "SAP Z_PO_CREATE_SRV call failed with status {StatusCode}: {SapErrorMessage}",
                (int)response.StatusCode, sapErrorMessage);
            return new PurchaseOrderCreateResult(false, null, sapErrorMessage);
        }

        ODataEnvelope<CreatePurchaseOrderResponseBody>? envelope;
        try
        {
            envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<CreatePurchaseOrderResponseBody>>(cancellationToken);
        }
        catch (Exception ex)
        {
            throw new SapCreateReplyException("SAP Z_PO_CREATE_SRV answered with success but the response body could not be read.", ex);
        }

        if (envelope is null)
        {
            throw new SapCreateReplyException("SAP Z_PO_CREATE_SRV returned an empty response body.");
        }

        if (string.IsNullOrWhiteSpace(envelope.D?.PoNumber))
        {
            throw new SapCreateReplyException("SAP Z_PO_CREATE_SRV returned 201 but no PoNumber in the response body.");
        }

        return new PurchaseOrderCreateResult(true, envelope.D.PoNumber, null);
    }

    private async Task<PurchaseOrderHeader?> GetHeaderAsync(long recordId, CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT record_id, comp_code, doc_type, vendor, purch_org, pur_group, currency, doc_date
            FROM dbo.xx_purchaseorder_hdr_stg_tbl_ob
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

        return new PurchaseOrderHeader
        {
            RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
            CompCode = GetString(reader, "comp_code"),
            DocType = GetString(reader, "doc_type"),
            Vendor = GetString(reader, "vendor"),
            PurchOrg = GetString(reader, "purch_org"),
            PurGroup = GetString(reader, "pur_group"),
            Currency = GetString(reader, "currency"),
            DocDate = GetString(reader, "doc_date"),
        };
    }

    private async Task<List<PurchaseOrderLine>> GetLinesAsync(long hdrRecordId, CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                record_id, hdr_record_id, po_item, short_text, mat_grp, plant, quantity, po_unit,
                net_price, price_unit, tax_code, acctasscat, wbs_element, gl_account,
                network, activity, preq_no, preq_item, delivery_date,
                item_cat, srv_short_text, srv_quantity, srv_uom, srv_gr_price, srv_matl_group
            FROM dbo.xx_purchaseorder_line_stg_tbl_ob
            WHERE hdr_record_id = @HdrRecordId
            ORDER BY record_id ASC
            """;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@HdrRecordId", hdrRecordId);

        var lines = new List<PurchaseOrderLine>();

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            lines.Add(new PurchaseOrderLine
            {
                RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
                HdrRecordId = reader.GetInt64(reader.GetOrdinal("hdr_record_id")),
                PoItem = GetString(reader, "po_item"),
                ShortText = GetString(reader, "short_text"),
                MatGrp = GetString(reader, "mat_grp"),
                Plant = GetString(reader, "plant"),
                Quantity = GetDecimal(reader, "quantity"),
                PoUnit = GetString(reader, "po_unit"),
                NetPrice = GetDecimal(reader, "net_price"),
                PriceUnit = GetString(reader, "price_unit"),
                TaxCode = GetString(reader, "tax_code"),
                AcctAssCat = GetString(reader, "acctasscat"),
                WbsElement = GetString(reader, "wbs_element"),
                GlAccount = GetString(reader, "gl_account"),
                Network = GetString(reader, "network"),
                Activity = GetString(reader, "activity"),
                PreqNo = GetString(reader, "preq_no"),
                PreqItem = GetString(reader, "preq_item"),
                DeliveryDate = GetString(reader, "delivery_date"),
                ItemCat = GetString(reader, "item_cat"),
                SrvShortText = GetString(reader, "srv_short_text"),
                SrvQuantity = GetDecimal(reader, "srv_quantity"),
                SrvUom = GetString(reader, "srv_uom"),
                SrvGrPrice = GetDecimal(reader, "srv_gr_price"),
                SrvMatlGroup = GetString(reader, "srv_matl_group"),
            });
        }

        return lines;
    }

    private const int ErrorMsgMaxLength = 2000;

    private async Task PersistResultAsync(long hdrRecordId, PurchaseOrderCreateResult result, CancellationToken cancellationToken)
    {
        var status = result.Success ? StatusSuccess : StatusError;
        var now = DateTime.Now;
        var errorMsg = result.ErrorMessage is { Length: > ErrorMsgMaxLength }
            ? result.ErrorMessage[..ErrorMsgMaxLength]
            : result.ErrorMessage;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        const string updateHeaderSql = """
            UPDATE dbo.xx_purchaseorder_hdr_stg_tbl_ob
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
            UPDATE dbo.xx_purchaseorder_line_stg_tbl_ob
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
