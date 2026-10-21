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

public sealed class ShkrProjectRequisitionService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrProjectRequisitionService> logger)
{
    public const string ShkrSapClientName = "ShkrSapProjectRequisition";

    private const string StatusSuccess = "S";
    private const string StatusError = "E";

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    private static readonly JsonSerializerOptions RequestSerializerOptions = new(JsonSerializerDefaults.General)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    public async Task<ProjectRequisitionCreateResult> CreateAsync(long recordId, CancellationToken cancellationToken = default)
    {
        var header = await GetHeaderAsync(recordId, cancellationToken)
            ?? throw new ArgumentException(
                $"No Project Requisition header found for record_id {recordId} with process_status = 'N'.");

        var lines = await GetLinesAsync(header.RecordId, cancellationToken);
        if (lines.Count == 0)
        {
            throw new ArgumentException($"Project Requisition header {header.RecordId} has no lines.");
        }

        try
        {
            var request = BuildRequest(header, lines);

            var result = await SendToSapAsync(request, cancellationToken);

            await PersistResultAsync(header.RecordId, result, cancellationToken);

            logger.LogInformation(
                "Project Requisition create (header record_id={RecordId}) completed: Success={Success}, Banfn={Banfn}.",
                header.RecordId, result.Success, result.Banfn);

            return result;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "Project Requisition create failed for header record_id {RecordId}.", header.RecordId);
            await PersistResultAsync(header.RecordId, new ProjectRequisitionCreateResult(false, null, ex.Message), cancellationToken);
            throw;
        }
    }

    private static CreateProjectRequisitionRequest BuildRequest(
        ProjectRequisitionHeader header, List<ProjectRequisitionLine> lines)
    {
        var request = new CreateProjectRequisitionRequest
        {
            Banfn = string.Empty,
            Bsart = header.DocType ?? string.Empty,
        };

        foreach (var line in lines)
        {
            request.PrHeaderSet.Add(new PrHeaderSetItem
            {
                TrackingNo = line.TrackingNo ?? string.Empty,
                PreqItem = line.PrebidLineNo ?? string.Empty,
                DocType = line.DocType ?? string.Empty,
                ShortText = line.ShortText ?? string.Empty,
                Material = line.Material ?? string.Empty,
                MatGrp = line.MatGrp ?? string.Empty,
                Plant = line.Plant ?? string.Empty,
                PurGroup = line.PurGroup ?? string.Empty,
                Quantity = FormatDecimal(line.Quantity, "0.000"),
                Unit = line.Uom ?? string.Empty,
                PreqDate = line.PrebidDate ?? string.Empty,
                RelDate = line.RelDate ?? string.Empty,
                DelivDate = line.DelivDate ?? string.Empty,
                ItemCat = line.ItemCat ?? string.Empty,
                AcctAssCat = line.AcctAssCat ?? string.Empty,
                CAmtBapi = FormatDecimal(line.PrebidAmount, "0.00"),
                PriceUnit = line.PriceUnit ?? string.Empty,
                Currency = line.Currency ?? string.Empty,
            });

            request.AccountSet.Add(new PrAccountSetItem
            {
                PreqNo = line.PrebidNo ?? string.Empty,
                PreqItem = line.PrebidLineNo ?? string.Empty,
                SerialNo = line.SerialNo ?? string.Empty,
                WbsElemE = line.WbsElement ?? string.Empty,
                Network = line.Network ?? string.Empty,
                Activity = line.Activity ?? string.Empty,
                ProjExt = line.ProjExt ?? string.Empty,
                GlAcct = line.GlAcct ?? string.Empty,
                CoArea = line.CoArea ?? string.Empty,
            });
        }

        return request;
    }

    private static string FormatDecimal(decimal? value, string format) =>
        value?.ToString(format, CultureInfo.InvariantCulture) ?? string.Empty;

    private async Task<ProjectRequisitionCreateResult> SendToSapAsync(
        CreateProjectRequisitionRequest request, CancellationToken cancellationToken)
    {
        var requestUri = $"/sap/opu/odata/SAP/Z_PR_CREATION_SRV/HEADERSet?sap-client={_options.ShkrSapClient}";

        var client = httpClientFactory.CreateClient(ShkrSapClientName);

        logger.LogInformation(
            "Calling SAP Z_PR_CREATION_SRV for TRACKINGNO {TrackingNo}.",
            request.PrHeaderSet.Count > 0 ? request.PrHeaderSet[0].TrackingNo : "(none)");

        using var response = await client.PostAsJsonAsync(requestUri, request, RequestSerializerOptions, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError(
                "SAP Z_PR_CREATION_SRV call failed with status {StatusCode}: {SapErrorMessage}",
                (int)response.StatusCode, sapErrorMessage);
            return new ProjectRequisitionCreateResult(false, null, sapErrorMessage);
        }

        var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<CreateProjectRequisitionResponseBody>>(cancellationToken)
            ?? throw new InvalidOperationException("SAP Z_PR_CREATION_SRV returned an empty response body.");

        if (string.IsNullOrWhiteSpace(envelope.D.Banfn))
        {
            throw new InvalidOperationException("SAP Z_PR_CREATION_SRV returned 201 but no BANFN in the response body.");
        }

        return new ProjectRequisitionCreateResult(true, envelope.D.Banfn, null);
    }

    private async Task<ProjectRequisitionHeader?> GetHeaderAsync(long recordId, CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT record_id, doc_type
            FROM dbo.xx_projectrequisition_hdr_stg_tbl_ob
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

        return new ProjectRequisitionHeader
        {
            RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
            DocType = GetString(reader, "doc_type"),
        };
    }

    private async Task<List<ProjectRequisitionLine>> GetLinesAsync(long hdrRecordId, CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                record_id, hdr_record_id, tracking_no, prebid_line_no, doc_type, short_text, material,
                mat_grp, plant, pur_group, quantity, uom, prebid_date, rel_date, deliv_date,
                item_cat, acctasscat, prebid_amount, price_unit, currency, prebid_no,
                serial_no, wbs_element, network, activity, proj_ext, gl_acct, co_area
            FROM dbo.xx_projectrequisition_line_stg_tbl_ob
            WHERE hdr_record_id = @HdrRecordId
            ORDER BY record_id ASC
            """;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@HdrRecordId", hdrRecordId);

        var lines = new List<ProjectRequisitionLine>();

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            lines.Add(new ProjectRequisitionLine
            {
                RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
                HdrRecordId = reader.GetInt64(reader.GetOrdinal("hdr_record_id")),
                TrackingNo = GetString(reader, "tracking_no"),
                PrebidLineNo = GetString(reader, "prebid_line_no"),
                DocType = GetString(reader, "doc_type"),
                ShortText = GetString(reader, "short_text"),
                Material = GetString(reader, "material"),
                MatGrp = GetString(reader, "mat_grp"),
                Plant = GetString(reader, "plant"),
                PurGroup = GetString(reader, "pur_group"),
                Quantity = GetDecimal(reader, "quantity"),
                Uom = GetString(reader, "uom"),
                PrebidDate = GetString(reader, "prebid_date"),
                RelDate = GetString(reader, "rel_date"),
                DelivDate = GetString(reader, "deliv_date"),
                ItemCat = GetString(reader, "item_cat"),
                AcctAssCat = GetString(reader, "acctasscat"),
                PrebidAmount = GetDecimal(reader, "prebid_amount"),
                PriceUnit = GetString(reader, "price_unit"),
                Currency = GetString(reader, "currency"),
                PrebidNo = GetString(reader, "prebid_no"),
                SerialNo = GetString(reader, "serial_no"),
                WbsElement = GetString(reader, "wbs_element"),
                Network = GetString(reader, "network"),
                Activity = GetString(reader, "activity"),
                ProjExt = GetString(reader, "proj_ext"),
                GlAcct = GetString(reader, "gl_acct"),
                CoArea = GetString(reader, "co_area"),
            });
        }

        return lines;
    }

    private const int ErrorMsgMaxLength = 2000;

    private async Task PersistResultAsync(long hdrRecordId, ProjectRequisitionCreateResult result, CancellationToken cancellationToken)
    {
        var status = result.Success ? StatusSuccess : StatusError;
        var now = DateTime.Now;
        var errorMsg = result.ErrorMessage is { Length: > ErrorMsgMaxLength }
            ? result.ErrorMessage[..ErrorMsgMaxLength]
            : result.ErrorMessage;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        const string updateHeaderSql = """
            UPDATE dbo.xx_projectrequisition_hdr_stg_tbl_ob
            SET process_status = @ProcessStatus, sap_pr_id = @SapPrId, error_msg = @ErrorMsg, last_update_date = @LastUpdateDate
            WHERE record_id = @RecordId
            """;

        await using (var headerCommand = new SqlCommand(updateHeaderSql, connection))
        {
            headerCommand.Parameters.AddWithValue("@ProcessStatus", status);
            headerCommand.Parameters.AddWithValue("@SapPrId", (object?)result.Banfn ?? DBNull.Value);
            headerCommand.Parameters.AddWithValue("@ErrorMsg", (object?)errorMsg ?? DBNull.Value);
            headerCommand.Parameters.AddWithValue("@LastUpdateDate", now);
            headerCommand.Parameters.AddWithValue("@RecordId", hdrRecordId);
            await headerCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        const string updateLinesSql = """
            UPDATE dbo.xx_projectrequisition_line_stg_tbl_ob
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
