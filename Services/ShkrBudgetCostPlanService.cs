using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;


namespace SHKRIntegration.Services;

public sealed class ShkrBudgetCostPlanService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrNetworkActivityOptions> networkActivityOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrBudgetCostPlanService> logger)
{
    public const string ShkrSapClientName = "ShkrBudgetCostPlan";

    private const string ServicePath = "/sap/opu/odata/sap/Z_PS_NETWORK_SRV/";
    private const string CsrfHeaderName = "x-csrf-token";

    // SAP Description on an activity is String(40); a longer one is cut rather than refused.
    private const int SapDescriptionLength = 40;

    private const string StatusSuccess = "S";
    private const string StatusError = "E";

    // A second call while a run is still posting waits for it, then finds the activities already sent.
    private static readonly SemaphoreSlim RunLock = new(1, 1);

    private const int ErrorMsgMaxLength = 2000;

    private static readonly JsonSerializerOptions RequestSerializerOptions = new(JsonSerializerDefaults.General)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrNetworkActivityOptions _activityOptions = networkActivityOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    public async Task<BudgetCostNetworkCreateResult> CreateAsync(long pmWebBudgetId, CancellationToken cancellationToken = default)
    {
        var header = await GetHeaderAsync(pmWebBudgetId, cancellationToken)
            ?? throw new ArgumentException(
                $"No Budget header found for record_id {pmWebBudgetId} with process_status = 'N'.");

        var lines = await GetLinesAsync(header.RecordId, cancellationToken);
        if (lines.Count == 0)
        {
            throw new ArgumentException($"Budget header {header.RecordId} has no lines.");
        }

        try
        {
            var request = BuildRequest(header, lines);

            var result = await SendToSapAsync(request, cancellationToken);

            await PersistResultAsync(header.RecordId, result, cancellationToken);

            logger.LogInformation(
                "Budget create (header record_id={RecordId}) completed: Success={Success}, Network={Network}.",
                header.RecordId, result.Success, result.Network);

            return result;
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            logger.LogError(ex, "Budgetcreate failed for header record_id {RecordId}.", header.RecordId);
            await PersistResultAsync(header.RecordId, new BudgetCostNetworkCreateResult(false, null, ex.Message), cancellationToken);
            throw;
        }
    }

    private static BudgetCostNetworkCreateRequest BuildRequest(
        BudgetHeader header, List<BudgetLine> lines)
    {
        var request = new BudgetCostNetworkCreateRequest
        {
            Network = header.SapNetwork ?? string.Empty,
        };

        foreach (var line in lines)
        {
            request.ActivitySet.Add(new BudgetCostNetworkActivityItem
            {
                Activity = line.SapActivity ?? string.Empty,
                Description = line.SapActivityDescription ?? string.Empty,
                ControlKey = line.SapControlKey ?? string.Empty,
                Plant = line.SapPlant?.ToString() ?? string.Empty,
                WorkCntr =  string.Empty,
                DurationNormalUnit =  string.Empty,
                UnWork =  string.Empty,
                WbsElement = line.SapWbsElement ?? string.Empty,
                Price = FormatDecimal(line.Price, "0.00"),
                PriceUnit = line.PriceUnit.ToString() ?? string.Empty,
            });
        }

        return request;
    }

    private static string FormatDecimal(decimal? value, string format) =>
        value?.ToString(format, CultureInfo.InvariantCulture) ?? string.Empty;

    private async Task<string> FetchCsrfTokenAsync(HttpClient client, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"{ServicePath}?sap-client={_options.ShkrSapClient}");
        request.Headers.TryAddWithoutValidation(CsrfHeaderName, "Fetch");

        using var response = await client.SendAsync(request, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            throw new HttpRequestException(
                $"Z_PS_NETWORK_SRV answered {(int)response.StatusCode} ({response.StatusCode}): {sapErrorMessage}");
        }

        var token = response.Headers.TryGetValues(CsrfHeaderName, out var values) ? values.FirstOrDefault() : null;
        if (string.IsNullOrEmpty(token))
        {
            throw new HttpRequestException($"Z_PS_NETWORK_SRV answered {(int)response.StatusCode} but sent no {CsrfHeaderName} header.");
        }

        logger.LogInformation("Network Activity: CSRF token fetched.");
        return token;
    }

    private async Task<BudgetCostNetworkCreateResult> SendToSapAsync(
        BudgetCostNetworkCreateRequest requestData, CancellationToken cancellationToken)
    {
        var requestUri = $"/sap/opu/odata/sap/Z_PO_CREATE_SRV/POHEADSet?sap-client={_options.ShkrSapClient}";

        var client = httpClientFactory.CreateClient(ShkrSapClientName);

        string csrfToken;
        csrfToken = await FetchCsrfTokenAsync(client, cancellationToken);

        var requestJson = JsonSerializer.Serialize(requestData, RequestSerializerOptions);
        string? responseBody = null;
        Dictionary<long, string?> outcomes;

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{ServicePath}NETWORKSet?sap-client={_options.ShkrSapClient}");
        request.Headers.TryAddWithoutValidation(CsrfHeaderName, csrfToken);
        request.Content = new StringContent(requestJson, Encoding.UTF8, "application/json");

        using var response = await client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError(
                "SAP Z_PO_CREATE_SRV call failed with status {StatusCode}: {SapErrorMessage}",
                (int)response.StatusCode, sapErrorMessage);
            return new BudgetCostNetworkCreateResult(false, null, sapErrorMessage);
        }

        var messages = new List<SapReturnMessage>();
        var envelope = JsonSerializer.Deserialize<ODataEnvelope<NetworkCreateResponse>>(body, JsonSerializerOptions.Web);
        messages = envelope?.D.ReturnSet?.Results ?? [];

        return new BudgetCostNetworkCreateResult(true, envelope?.D.Network, null);
    }

    private async Task<BudgetHeader?> GetHeaderAsync(long pmWebBudgetId, CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT record_id, pmweb_budget_id, project_code, project_id, sap_network, process_status
            FROM xx_budget_hdr_stg_tbl_ob
            WHERE pmweb_budget_id = @PmWebBudgetId AND process_status = 'N'
            """;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@PmWebBudgetId", pmWebBudgetId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new BudgetHeader
        {
            RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
            ProjectCode = GetString(reader, "project_code"),
            ProjectId = reader.GetInt64(reader.GetOrdinal("project_id")),
            SapNetwork = GetString(reader, "sap_network"),
            ProcessStatus = GetString(reader, "process_status"),
        };
    }

    private async Task<List<BudgetLine>> GetLinesAsync(long hdrRecordId, CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                record_id, hdr_record_id, pmweb_budget_line_id, sap_activity, sap_activity_desc,
                sap_control_key, sap_plant, sap_wbs_element, price_unit, price, process_status
            FROM xx_budget_line_stg_tbl_ob
            WHERE hdr_record_id = @HdrRecordId AND process_status = 'N'
            ORDER BY record_id
            """;
       
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@HdrRecordId", hdrRecordId);

        var lines = new List<BudgetLine>();

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            lines.Add(new BudgetLine
            {
                RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
                HdrRecordId = reader.GetInt64(reader.GetOrdinal("hdr_record_id")),
                PmWebBudgetLineId = reader.GetInt64(reader.GetOrdinal("pmweb_budget_line_id")),
                SapActivity = GetString(reader, "sap_activity"),
                SapActivityDescription = GetString(reader, "sap_activity_desc"),
                SapControlKey = GetString(reader, "sap_control_key"),
                SapPlant = GetString(reader, "sap_plant"),
                PriceUnit = reader.GetInt32(reader.GetOrdinal("price_unit")),
                Price = reader.GetDecimal(reader.GetOrdinal("price")),
                ProcessStatus = GetString(reader, "process_status"),
            });
        }

        return lines;
    }

    private async Task PersistResultAsync(long hdrRecordId, BudgetCostNetworkCreateResult result, CancellationToken cancellationToken)
    {
        var status = result.Success ? StatusSuccess : StatusError;
        var now = DateTime.UtcNow;
        var errorMsg = result.ErrorMessage is { Length: > ErrorMsgMaxLength }
            ? result.ErrorMessage[..ErrorMsgMaxLength]
            : result.ErrorMessage;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        const string updateHeaderSql = """
            UPDATE dbo.xx_budget_hdr_stg_tbl_ob
            SET process_status   = @process_status,
                error_msg       = @error_msg,
                last_update_date = GETDATE()
            WHERE record_id = @record_id
            """;

        await using (var headerCommand = new SqlCommand(updateHeaderSql, connection))
        {
            headerCommand.Parameters.AddWithValue("@process_status", status);
            headerCommand.Parameters.AddWithValue("@error_msg", (object?)errorMsg ?? DBNull.Value);
            headerCommand.Parameters.AddWithValue("@record_id", hdrRecordId);
            await headerCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        const string updateLinesSql = """
            UPDATE dbo.xx_budget_line_stg_tbl_ob
            SET process_status = @ProcessStatus, 
                error_msg = @error_msg, 
                last_update_date = GETDATE()
            WHERE hdr_record_id = @HdrRecordId
            """;

        await using (var linesCommand = new SqlCommand(updateLinesSql, connection))
        {
            linesCommand.Parameters.AddWithValue("@ProcessStatus", status);
            linesCommand.Parameters.AddWithValue("@error_msg", (object?)errorMsg ?? DBNull.Value);
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
