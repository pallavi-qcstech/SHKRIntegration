using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Models;
using SHKRIntegration.Options;


namespace SHKRIntegration.Services;

public sealed class ShkrBudgetCostPlanService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrBudgetCostPlanService> logger)
{
    public const string ShkrSapClientName = "ShkrBudgetCostPlan";

    private const string ServicePath = "/sap/opu/odata/sap/Z_PS_NETWORK_SRV/";
    private const string CsrfHeaderName = "x-csrf-token";
    private const string TranType = "Budgets";

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
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    public async Task<BudgetCostCreateResult> CreateAsync(long pmWebBudgetId, CancellationToken cancellationToken = default)
    {
        await RunLock.WaitAsync(cancellationToken);
        try
        {
            var headers = await GetHeadersAsync(pmWebBudgetId, cancellationToken);
            if (headers.Count == 0)
            {
                throw new ArgumentException(
                    $"No Budget header found for pmweb_budget_id {pmWebBudgetId} with process_status = 'N'.");
            }

            logger.LogInformation("Budget {PmWebBudgetId}: {Count} network(s) to send ({RecordIds}).",
                pmWebBudgetId, headers.Count, string.Join(", ", headers.Select(h => h.RecordId)));

            var results = new List<BudgetCostHeaderResult>();
            foreach (var header in headers)
            {
                results.Add(await ProcessHeaderAsync(header, cancellationToken));
            }

            var succeeded = results.Count(r => r.Success);
            logger.LogInformation("Budget {PmWebBudgetId}: {Succeeded} of {Count} network(s) succeeded.",
                pmWebBudgetId, succeeded, results.Count);

            return new BudgetCostCreateResult(
                pmWebBudgetId, succeeded == results.Count, results.Count, succeeded, results.Count - succeeded, results);
        }
        finally
        {
            RunLock.Release();
        }
    }

    private async Task<BudgetCostHeaderResult> ProcessHeaderAsync(BudgetHeader header, CancellationToken cancellationToken)
    {
        BudgetCostNetworkCreateResult result;
        try
        {
            var lines = await GetLinesAsync(header.RecordId, cancellationToken);
            var dataError = ValidateLines(lines);

            if (dataError is not null)
            {
                result = new BudgetCostNetworkCreateResult(false, header.SapNetwork, dataError);
            }
            else
            {
                var request = BuildRequest(header, lines);
                result = await SendToSapAsync(request, cancellationToken);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            logger.LogError(ex, "Budget create failed for header record_id {RecordId}.", header.RecordId);
            result = new BudgetCostNetworkCreateResult(false, header.SapNetwork, ex.Message);
        }

        await PersistResultAsync(header.RecordId, result, cancellationToken);

        if (result.Success)
        {
            logger.LogInformation("Budget header record_id {RecordId}, network {Network}: S.",
                header.RecordId, header.SapNetwork);
        }
        else
        {
            logger.LogError("Budget header record_id {RecordId}, network {Network}: E - {Error}",
                header.RecordId, header.SapNetwork, result.ErrorMessage);
        }

        return new BudgetCostHeaderResult(header.RecordId, header.SapNetwork, result.Success, result.ErrorMessage);
    }

    private static string? ValidateLines(List<BudgetLine> lines)
    {
        if (lines.Count == 0)
        {
            return "Budget header has no lines with process_status = 'N'.";
        }

        var missing = lines
            .Where(l => l.Price is null || l.PriceUnit is null)
            .Select(l => l.RecordId)
            .ToList();

        return missing.Count == 0
            ? null
            : $"price or price_unit is NULL on budget line record_id {string.Join(", ", missing)}.";
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
                Plant = line.SapPlant ?? string.Empty,
                WorkCntr = string.Empty,
                DurationNormalUnit = string.Empty,
                UnWork = string.Empty,
                WbsElement = line.SapWbsElement ?? string.Empty,
                Price = FormatDecimal(line.Price, "0.00"),
                PriceUnit = line.PriceUnit?.ToString(CultureInfo.InvariantCulture) ?? string.Empty,
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
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            throw new HttpRequestException(
                $"Z_PS_NETWORK_SRV answered {(int)response.StatusCode} ({response.StatusCode}): {ReadSapError(body, (int)response.StatusCode)}");
        }

        var token = response.Headers.TryGetValues(CsrfHeaderName, out var values) ? values.FirstOrDefault() : null;
        if (string.IsNullOrEmpty(token))
        {
            throw new HttpRequestException($"Z_PS_NETWORK_SRV answered {(int)response.StatusCode} but sent no {CsrfHeaderName} header.");
        }

        logger.LogInformation("Budget: CSRF token fetched.");
        return token;
    }

    private async Task<BudgetCostNetworkCreateResult> SendToSapAsync(
        BudgetCostNetworkCreateRequest requestData, CancellationToken cancellationToken)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var csrfToken = await FetchCsrfTokenAsync(client, cancellationToken);

        var requestJson = JsonSerializer.Serialize(requestData, RequestSerializerOptions);

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{ServicePath}NETWORKSet?sap-client={_options.ShkrSapClient}");
        request.Headers.TryAddWithoutValidation(CsrfHeaderName, csrfToken);
        request.Content = new StringContent(requestJson, Encoding.UTF8, "application/json");

        using var response = await client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = $"HTTP {(int)response.StatusCode}: {ReadSapError(body, (int)response.StatusCode)}";
            logger.LogError("SAP NETWORKSet call for network {Network} failed: {SapErrorMessage}",
                requestData.Network, sapErrorMessage);
            return new BudgetCostNetworkCreateResult(false, requestData.Network, sapErrorMessage);
        }

        List<SapReturnMessage> messages = [];
        string? network = requestData.Network;
        if (!string.IsNullOrWhiteSpace(body))
        {
            try
            {
                var envelope = JsonSerializer.Deserialize<ODataEnvelope<NetworkCreateResponse>>(body, JsonSerializerOptions.Web);
                messages = envelope?.D.ReturnSet?.Results ?? [];
                if (!string.IsNullOrWhiteSpace(envelope?.D.Network))
                {
                    network = envelope.D.Network;
                }
            }
            catch (JsonException ex)
            {
                logger.LogWarning(ex, "SAP NETWORKSet for network {Network} answered {StatusCode} with a body that is not OData JSON.",
                    requestData.Network, (int)response.StatusCode);
            }
        }

        var failures = messages.Where(m => m.IsFailure).Select(m => m.ToString()).ToList();
        return failures.Count == 0
            ? new BudgetCostNetworkCreateResult(true, network, null)
            : new BudgetCostNetworkCreateResult(false, network, string.Join("; ", failures));
    }

    private static string ReadSapError(string body, int statusCode)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return $"{statusCode} (no response body)";
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            if (!document.RootElement.TryGetProperty("error", out var error))
            {
                return body;
            }

            var texts = new List<string>();
            var genericTexts = new List<string>();
            string? transactionId = null;

            if (error.TryGetProperty("innererror", out var innerError))
            {
                if (innerError.TryGetProperty("transactionid", out var transactionIdElement) &&
                    transactionIdElement.ValueKind == JsonValueKind.String)
                {
                    transactionId = transactionIdElement.GetString();
                }

                if (innerError.TryGetProperty("errordetails", out var errorDetails) &&
                    errorDetails.ValueKind == JsonValueKind.Array)
                {
                    foreach (var detail in errorDetails.EnumerateArray())
                    {
                        if (detail.TryGetProperty("message", out var detailMessage) &&
                            detailMessage.ValueKind == JsonValueKind.String)
                        {
                            var code = detail.TryGetProperty("code", out var codeElement) &&
                                       codeElement.ValueKind == JsonValueKind.String
                                ? codeElement.GetString()
                                : null;
                            var text = detailMessage.GetString()!.Trim();
                            if (text.Length == 0)
                            {
                                continue;
                            }

                            if (IsGenericSapError(code, text))
                            {
                                genericTexts.Add(text);
                            }
                            else
                            {
                                texts.Add(string.IsNullOrWhiteSpace(code) ? text : $"{code}: {text}");
                            }
                        }
                    }
                }
            }

            if (texts.Count == 0 &&
                error.TryGetProperty("message", out var message) &&
                message.TryGetProperty("value", out var value) &&
                value.ValueKind == JsonValueKind.String &&
                !string.IsNullOrWhiteSpace(value.GetString()))
            {
                var text = value.GetString()!.Trim();
                if (IsGenericSapError(null, text))
                {
                    genericTexts.Add(text);
                }
                else
                {
                    texts.Add(text);
                }
            }

            if (texts.Count == 0)
            {
                texts.AddRange(genericTexts);
            }

            if (texts.Count == 0)
            {
                return body;
            }

            var joined = string.Join("; ", texts.Distinct());
            return transactionId is null ? joined : $"{joined} (SAP transaction {transactionId})";
        }
        catch (JsonException)
        {
            return body;
        }
    }

    private static bool IsGenericSapError(string? code, string text) =>
        (code is not null && code.StartsWith("/IWBEP/", StringComparison.OrdinalIgnoreCase)) ||
        text.StartsWith("Errors occurred during processing", StringComparison.OrdinalIgnoreCase) ||
        text.Equals("An exception was raised", StringComparison.OrdinalIgnoreCase);

    private async Task<List<BudgetHeader>> GetHeadersAsync(long pmWebBudgetId, CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT record_id, pmweb_budget_id, project_code, project_id, sap_network, process_status
            FROM xx_budget_hdr_stg_tbl_ob
            WHERE pmweb_budget_id = @PmWebBudgetId
              AND process_status = 'N'
              AND attribute1 = @TranType
            ORDER BY record_id
            """;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@PmWebBudgetId", pmWebBudgetId);
        command.Parameters.AddWithValue("@TranType", TranType);

        var headers = new List<BudgetHeader>();

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            headers.Add(new BudgetHeader
            {
                RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
                ProjectCode = GetString(reader, "project_code"),
                ProjectId = GetInt64(reader, "project_id"),
                SapNetwork = GetString(reader, "sap_network"),
                ProcessStatus = GetString(reader, "process_status"),
            });
        }

        return headers;
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
                PmWebBudgetLineId = GetInt64(reader, "pmweb_budget_line_id"),
                SapActivity = GetString(reader, "sap_activity"),
                SapActivityDescription = GetString(reader, "sap_activity_desc"),
                SapControlKey = GetString(reader, "sap_control_key"),
                SapPlant = GetString(reader, "sap_plant"),
                SapWbsElement = GetString(reader, "sap_wbs_element"),
                PriceUnit = GetInt32(reader, "price_unit"),
                Price = GetDecimal(reader, "price"),
                ProcessStatus = GetString(reader, "process_status"),
            });
        }

        return lines;
    }

    private async Task PersistResultAsync(long hdrRecordId, BudgetCostNetworkCreateResult result, CancellationToken cancellationToken)
    {
        var status = result.Success ? StatusSuccess : StatusError;
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

        if (status == StatusSuccess)
        {
            await UpdateProjectStatus(hdrRecordId, cancellationToken);
        }
    }

    private async Task UpdateProjectStatus(long hdrRecordId, CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        const string updateProjectStatusSql = """
            UPDATE xx_budget_hdr_stg_tbl_ob SET sap_approval_status = 20
            WHERE record_id = @record_id
            	AND project_code = (SELECT project_code FROM xx_budget_hdr_stg_tbl_ob WHERE record_id = @record_id)
            """;

        await using var headerCommand = new SqlCommand(updateProjectStatusSql, connection);
        headerCommand.Parameters.AddWithValue("@record_id", hdrRecordId);
        await headerCommand.ExecuteNonQueryAsync(cancellationToken);
    }

    private static string? GetString(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
    }

    private static long? GetInt64(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : Convert.ToInt64(reader.GetValue(ordinal), CultureInfo.InvariantCulture);
    }

    private static int? GetInt32(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal), CultureInfo.InvariantCulture);
    }

    private static decimal? GetDecimal(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetDecimal(ordinal);
    }
}
