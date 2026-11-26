using System.Data;
using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

// PMWeb -> SAP Network Activity sync. Every run takes the activities of dbo.WBS not yet sent successfully, posts
// them to Z_PS_NETWORK_SRV one network at a time, and records S or E per activity in xx_sap_activity_tbl_ob.
public sealed class ShkrNetworkActivityService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrNetworkActivityOptions> networkActivityOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrNetworkActivityService> logger)
{
    public const string ShkrSapClientName = "ShkrSapNetworkActivity";

    private const string ServicePath = "/sap/opu/odata/sap/Z_PS_NETWORK_SRV/";
    private const string CsrfHeaderName = "x-csrf-token";

    // SAP Description on an activity is String(40); a longer one is cut rather than refused.
    private const int SapDescriptionLength = 40;

    private const string StatusSuccess = "S";
    private const string StatusError = "E";

    // A second call while a run is still posting waits for it, then finds the activities already sent.
    private static readonly SemaphoreSlim RunLock = new(1, 1);

    private static readonly JsonSerializerOptions RequestSerializerOptions = new(JsonSerializerDefaults.General)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrNetworkActivityOptions _activityOptions = networkActivityOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    public async Task<NetworkActivitySyncResult> SyncAsync(CancellationToken cancellationToken = default)
    {
        await RunLock.WaitAsync(cancellationToken);
        try
        {
            return await RunAsync(cancellationToken);
        }
        finally
        {
            RunLock.Release();
        }
    }

    private async Task<NetworkActivitySyncResult> RunAsync(CancellationToken cancellationToken)
    {
        var (batchId, rows) = await CreateBatchAsync(cancellationToken);
        var networks = rows.GroupBy(r => r.Network).ToList();

        logger.LogInformation("Network Activity batch {BatchId}: {Activities} activity(ies) in {Networks} network(s) to send.",
            batchId, rows.Count, networks.Count);

        if (rows.Count == 0)
        {
            return new NetworkActivitySyncResult(batchId, 0, 0, 0, 0, []);
        }

        // One client for the whole run: the CSRF token is bound to the session cookie the client's handler keeps.
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var errors = new List<string>();

        string csrfToken;
        try
        {
            csrfToken = await FetchCsrfTokenAsync(client, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            // Without a token no POST can succeed: every row of the batch is E and is retried next run
            var error = $"CSRF token fetch failed: {ex.GetBaseException().Message}";
            logger.LogError(ex, "Network Activity batch {BatchId}: {Error}", batchId, error);
            foreach (var row in rows)
            {
                await SaveOutcomeAsync(row, StatusError, error, null, null, cancellationToken);
            }
            return new NetworkActivitySyncResult(batchId, networks.Count, rows.Count, 0, rows.Count, [error]);
        }

        var failed = 0;
        foreach (var network in networks)
        {
            var (networkFailed, token, networkErrors) =
                await ProcessNetworkAsync(client, csrfToken, network.Key, network.ToList(), cancellationToken);
            csrfToken = token;
            failed += networkFailed;
            errors.AddRange(networkErrors);
        }

        logger.LogInformation("Network Activity batch {BatchId}: {Succeeded} S, {Failed} E.",
            batchId, rows.Count - failed, failed);

        return new NetworkActivitySyncResult(batchId, networks.Count, rows.Count, rows.Count - failed, failed, errors);
    }

    // One POST per network, carrying all of its activities. A failure here is recorded on that network's rows and
    // never stops the next network. Returns the token in use afterwards - it may have been fetched again.
    private async Task<(int Failed, string CsrfToken, List<string> Errors)> ProcessNetworkAsync(
        HttpClient client, string csrfToken, string network, List<NetworkActivityRow> rows,
        CancellationToken cancellationToken)
    {
        var requestJson = JsonSerializer.Serialize(BuildRequest(network, rows), RequestSerializerOptions);
        string? responseBody = null;
        Dictionary<long, string?> outcomes;

        try
        {
            var (statusCode, body, token) = await PostWithCsrfRetryAsync(client, csrfToken, requestJson, cancellationToken);
            csrfToken = token;
            responseBody = body;
            outcomes = await EvaluateAsync(network, rows, statusCode, body, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            // Timeout, DNS, TLS... - SAP was not reached or did not answer
            var error = $"SAP call failed: {ex.GetBaseException().Message}";
            logger.LogError(ex, "Network {Network}: {Error}", network, error);
            outcomes = rows.ToDictionary(r => r.RecordId, _ => (string?)error);
        }

        foreach (var row in rows)
        {
            var error = outcomes[row.RecordId];
            await SaveOutcomeAsync(row, error is null ? StatusSuccess : StatusError, error, requestJson, responseBody,
                cancellationToken);
        }

        var networkErrors = outcomes.Values.Where(e => e is not null).Select(e => $"Network {network}: {e}").Distinct().ToList();
        var failed = outcomes.Values.Count(e => e is not null);

        if (failed == 0)
        {
            logger.LogInformation("Network {Network}: {Count} activity(ies) sent successfully.", network, rows.Count);
        }
        else
        {
            logger.LogError("Network {Network}: {Failed} of {Count} activity(ies) failed - {Errors}",
                network, failed, rows.Count, string.Join(" | ", networkErrors));
        }

        return (failed, csrfToken, networkErrors);
    }

    private NetworkCreateRequest BuildRequest(string network, List<NetworkActivityRow> rows)
    {
        var request = new NetworkCreateRequest { Network = network };

        foreach (var row in rows)
        {
            var description = row.Description ?? string.Empty;
            if (description.Length > SapDescriptionLength)
            {
                logger.LogWarning("Network {Network} activity {Activity}: description cut to {Length} characters for SAP.",
                    network, row.Activity, SapDescriptionLength);
                description = description[..SapDescriptionLength];
            }

            request.ActivitySet.Add(new NetworkActivityItem
            {
                Activity = row.Activity,
                Description = description,
                ControlKey = row.ControlKey ?? _activityOptions.ControlKey,
                Plant = row.Plant ?? _activityOptions.Plant,
                WorkCntr = string.Empty,
                DurationNormalUnit = _activityOptions.DurationNormalUnit,
                UnWork = _activityOptions.UnWork,
                WbsElement = row.WbsElement ?? string.Empty,
                ExtraFields = _activityOptions.ExtraActivityFields.Count == 0
                    ? null
                    : _activityOptions.ExtraActivityFields.ToDictionary(f => f.Key, f => (object)f.Value)
            });
        }

        return request;
    }

    // 2xx: read RETURNSet - a message of Type E or A is a failure. It is put on the activity it names; a failure
    // that names no activity fails the whole network. Anything else: every activity is E with the SAP error text.
    // Returns the error per record, null for success.
    private async Task<Dictionary<long, string?>> EvaluateAsync(
        string network, List<NetworkActivityRow> rows, HttpStatusCode statusCode, string body,
        CancellationToken cancellationToken)
    {
        if ((int)statusCode is < 200 or >= 300)
        {
            using var errorResponse = new HttpResponseMessage(statusCode) { Content = new StringContent(body) };
            var error = await errorResponse.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError("Network {Network}: SAP answered {StatusCode}: {SapErrorMessage}", network, (int)statusCode, error);
            return rows.ToDictionary(r => r.RecordId, _ => (string?)error);
        }

        var messages = new List<SapReturnMessage>();
        if (!string.IsNullOrWhiteSpace(body))
        {
            try
            {
                var envelope = JsonSerializer.Deserialize<ODataEnvelope<NetworkCreateResponse>>(body, JsonSerializerOptions.Web);
                messages = envelope?.D.ReturnSet?.Results ?? [];
            }
            catch (JsonException ex)
            {
                logger.LogWarning(ex, "Network {Network}: SAP answered {StatusCode} with a body that is not OData JSON.",
                    network, (int)statusCode);
            }
        }

        var networkErrors = new List<string>();
        var activityErrors = rows.ToDictionary(r => r.RecordId, _ => new List<string>());

        foreach (var message in messages.Where(m => m.IsFailure))
        {
            var matched = rows.Where(r => message.IsAbout(network, r.Activity)).ToList();
            if (matched.Count == 0)
            {
                networkErrors.Add(message.ToString());
            }

            foreach (var row in matched)
            {
                activityErrors[row.RecordId].Add(message.ToString());
            }
        }

        return rows.ToDictionary(r => r.RecordId, r =>
        {
            var errors = networkErrors.Concat(activityErrors[r.RecordId]).ToList();
            return errors.Count == 0 ? null : string.Join("; ", errors);
        });
    }

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

    // A token can expire between networks. SAP answers that with 403 and "CSRF token validation failed"; the token
    // is fetched again once and the POST repeated once - never more.
    private async Task<(HttpStatusCode StatusCode, string Body, string CsrfToken)> PostWithCsrfRetryAsync(
        HttpClient client, string csrfToken, string requestJson, CancellationToken cancellationToken)
    {
        var (statusCode, body, csrfRejected) = await PostAsync(client, csrfToken, requestJson, cancellationToken);

        if (csrfRejected)
        {
            logger.LogWarning("Network Activity: CSRF token rejected (HTTP 403) - fetching a new token and retrying once.");
            csrfToken = await FetchCsrfTokenAsync(client, cancellationToken);
            (statusCode, body, _) = await PostAsync(client, csrfToken, requestJson, cancellationToken);
        }

        return (statusCode, body, csrfToken);
    }

    private async Task<(HttpStatusCode StatusCode, string Body, bool CsrfRejected)> PostAsync(
        HttpClient client, string csrfToken, string requestJson, CancellationToken cancellationToken)
    {
        // The token is set here, so ShkrSapCsrfTokenHandler leaves the request alone instead of fetching its own.
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{ServicePath}NETWORKSet?sap-client={_options.ShkrSapClient}");
        request.Headers.TryAddWithoutValidation(CsrfHeaderName, csrfToken);
        request.Content = new StringContent(requestJson, Encoding.UTF8, "application/json");

        using var response = await client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        var csrfRejected = response.StatusCode == HttpStatusCode.Forbidden &&
            ((response.Headers.TryGetValues(CsrfHeaderName, out var values) &&
              string.Equals(values.FirstOrDefault(), "Required", StringComparison.OrdinalIgnoreCase)) ||
             body.Contains("CSRF token validation failed", StringComparison.OrdinalIgnoreCase));

        return (response.StatusCode, body, csrfRejected);
    }

    private async Task<(long BatchId, List<NetworkActivityRow> Rows)> CreateBatchAsync(CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand("dbo.SHK_INT_SAP_ACTIVITY_OB_BATCH_PRC", connection)
        {
            CommandType = CommandType.StoredProcedure
        };
        command.Parameters.AddWithValue("@control_key", _activityOptions.ControlKey);
        command.Parameters.AddWithValue("@plant", _activityOptions.Plant);
        var batchParameter = command.Parameters.Add("@batch_id", SqlDbType.BigInt);
        batchParameter.Direction = ParameterDirection.Output;

        var rows = new List<NetworkActivityRow>();
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                rows.Add(new NetworkActivityRow
                {
                    RecordId = reader.GetInt64(reader.GetOrdinal("record_id")),
                    Network = GetString(reader, "network") ?? string.Empty,
                    Activity = GetString(reader, "activity") ?? string.Empty,
                    Description = GetString(reader, "description"),
                    WbsElement = GetString(reader, "wbs_element"),
                    ControlKey = GetString(reader, "control_key"),
                    Plant = GetString(reader, "plant"),
                });
            }
        }

        // An output parameter is only readable once the reader is closed
        return (Convert.ToInt64(batchParameter.Value), rows);
    }

    private async Task SaveOutcomeAsync(
        NetworkActivityRow row, string status, string? error, string? requestJson, string? responseBody,
        CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
            await connection.OpenAsync(cancellationToken);

            await using var command = new SqlCommand("dbo.SHK_INT_SAP_ACTIVITY_OB_UPD_PRC", connection)
            {
                CommandType = CommandType.StoredProcedure
            };
            command.Parameters.AddWithValue("@record_id", row.RecordId);
            command.Parameters.AddWithValue("@process_status", status);
            command.Parameters.AddWithValue("@error_desc", (object?)error ?? DBNull.Value);
            command.Parameters.AddWithValue("@request_payload", (object?)requestJson ?? DBNull.Value);
            command.Parameters.AddWithValue("@response_payload", (object?)responseBody ?? DBNull.Value);

            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // The row stays N; it has no S row, so a later run selects the activity again
            logger.LogError(ex,
                "Could not save the outcome of record {RecordId} (network {Network}, activity {Activity}, status {Status}).",
                row.RecordId, row.Network, row.Activity, status);
        }
    }

    private static string? GetString(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
    }
}
