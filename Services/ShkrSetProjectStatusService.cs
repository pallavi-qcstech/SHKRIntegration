using System.Net;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Extensions.Options;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrSetProjectStatusService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    ILogger<ShkrSetProjectStatusService> logger)
{
    public const string ShkrSapClientName = "ShkrSapSetProjectStatus";

    public const string ServicePath = "/sap/opu/odata/sap/ZPS_PROJ_STATUS_SRV/";
    public const string EntitySet = "ProjectStatusSet";
    public const int ProjectDefinitionMaxLength = 24;
    public const string AllowedUserStatus = "20";

    private const string CsrfHeaderName = "x-csrf-token";

    private static readonly JsonSerializerOptions RequestSerializerOptions = new(JsonSerializerDefaults.General)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;

    public async Task<SetProjectStatusResult> SetUserStatusAsync(
        string? projectDefinition, string? userStatus, CancellationToken cancellationToken = default)
    {
        var project = projectDefinition?.Trim() ?? string.Empty;
        var status = userStatus?.Trim() ?? string.Empty;

        var inputError = ValidateInput(project, status);
        if (inputError is not null)
        {
            return Fail(project, status, StatusCodes.Status400BadRequest, inputError);
        }

        var client = httpClientFactory.CreateClient(ShkrSapClientName);

        try
        {
            using var tokenRequest = new HttpRequestMessage(HttpMethod.Get, $"{ServicePath}?sap-client={_options.ShkrSapClient}");
            tokenRequest.Headers.TryAddWithoutValidation(CsrfHeaderName, "Fetch");
            using var tokenResponse = await client.SendAsync(tokenRequest, cancellationToken);

            if (!tokenResponse.IsSuccessStatusCode)
            {
                var tokenBody = await tokenResponse.Content.ReadAsStringAsync(cancellationToken);
                var tokenError = $"ZPS_PROJ_STATUS_SRV CSRF fetch answered {(int)tokenResponse.StatusCode}: {ReadSapError(tokenBody, (int)tokenResponse.StatusCode)}";
                logger.LogError("Project status {ProjectDefinition} -> {UserStatus}: {Error}", project, status, tokenError);
                return Fail(project, status, StatusCodes.Status502BadGateway, tokenError, (int)tokenResponse.StatusCode);
            }

            var token = tokenResponse.Headers.TryGetValues(CsrfHeaderName, out var values) ? values.FirstOrDefault() : null;
            if (string.IsNullOrEmpty(token))
            {
                const string noTokenError = "ZPS_PROJ_STATUS_SRV CSRF fetch sent no x-csrf-token header; SAP was not changed.";
                logger.LogError("Project status {ProjectDefinition} -> {UserStatus}: {Error}", project, status, noTokenError);
                return Fail(project, status, StatusCodes.Status502BadGateway, noTokenError, (int)tokenResponse.StatusCode);
            }

            var requestJson = JsonSerializer.Serialize(
                new SetProjectStatusRequest { ProjectDefinition = project, SetUserStatus = status }, RequestSerializerOptions);

            using var request = new HttpRequestMessage(HttpMethod.Post, $"{ServicePath}{EntitySet}?sap-client={_options.ShkrSapClient}");
            request.Headers.TryAddWithoutValidation(CsrfHeaderName, token);
            request.Content = new StringContent(requestJson, Encoding.UTF8, "application/json");

            using var response = await client.SendAsync(request, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);

            var result = Evaluate(project, status, (int)response.StatusCode, body);
            if (result.Success)
            {
                logger.LogInformation("Project status {ProjectDefinition} -> {UserStatus}: set. Active user statuses: {ActiveUserStatuses}.",
                    project, status, result.ActiveUserStatuses);
            }
            else
            {
                logger.LogWarning("Project status {ProjectDefinition} -> {UserStatus}: not set (SAP {SapHttpStatus}) - {Error}",
                    project, status, result.SapHttpStatus, result.Error);
            }

            return result;
        }
        catch (Exception ex) when (ex is HttpRequestException || (ex is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            logger.LogError(ex, "Project status {ProjectDefinition} -> {UserStatus}: no answer from SAP.", project, status);
            return Fail(project, status, StatusCodes.Status504GatewayTimeout, $"No answer from SAP: {ex.Message}");
        }
    }

    public static string? ValidateInput(string project, string status)
    {
        var errors = new List<string>();

        if (project.Length == 0)
        {
            errors.Add("projectDefinition is required.");
        }
        else if (project.Length > ProjectDefinitionMaxLength)
        {
            errors.Add($"projectDefinition '{project}' is longer than {ProjectDefinitionMaxLength} characters.");
        }

        if (status.Length == 0)
        {
            errors.Add("userStatus is required.");
        }
        else if (!string.Equals(status, AllowedUserStatus, StringComparison.Ordinal))
        {
            errors.Add($"User status should be {AllowedUserStatus} (received '{status}').");
        }

        return errors.Count == 0 ? null : string.Join(" ", errors) + " SAP was not called.";
    }

    public static SetProjectStatusResult Evaluate(string project, string status, int httpStatus, string body)
    {
        if (httpStatus == (int)HttpStatusCode.Unauthorized)
        {
            return Fail(project, status, StatusCodes.Status502BadGateway, "SAP returned 401 - check the SAP account.", httpStatus);
        }

        if (httpStatus is < 200 or >= 300)
        {
            var sapError = ReadSapError(body, httpStatus);
            var reply = httpStatus is >= 400 and < 500 ? StatusCodes.Status422UnprocessableEntity : StatusCodes.Status502BadGateway;
            return new SetProjectStatusResult(project, status, false, httpStatus, null, sapError, null,
                $"SAP refused the status change: {sapError}", reply);
        }

        SetProjectStatusResponse? answer = null;
        try
        {
            answer = JsonSerializer.Deserialize<ODataEnvelope<SetProjectStatusResponse>>(body)?.D;
        }
        catch (JsonException)
        {
        }

        if (answer is null)
        {
            return new SetProjectStatusResult(project, status, false, httpStatus, null, null, null,
                $"SAP answered {httpStatus} with a body that is not the ProjectStatusSet OData reply; check the project in SAP.",
                StatusCodes.Status502BadGateway);
        }

        if (answer.Success != true)
        {
            return new SetProjectStatusResult(project, status, false, httpStatus, answer.ActiveUserStatuses, answer.Message,
                answer.ResultLog, $"SAP answered {httpStatus} but Success is not true.", StatusCodes.Status502BadGateway);
        }

        if (!CarriesStatus(answer.ActiveUserStatuses, status))
        {
            return new SetProjectStatusResult(project, status, false, httpStatus, answer.ActiveUserStatuses, answer.Message,
                answer.ResultLog,
                $"SAP answered {httpStatus} but the project does not carry user status {status.ToUpperInvariant()} (ActiveUserStatuses: '{answer.ActiveUserStatuses}').",
                StatusCodes.Status502BadGateway);
        }

        return new SetProjectStatusResult(project, status, true, httpStatus, answer.ActiveUserStatuses, answer.Message,
            answer.ResultLog, null, StatusCodes.Status200OK);
    }

    public static bool CarriesStatus(string? activeUserStatuses, string status) =>
        (activeUserStatuses ?? string.Empty)
            .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Any(s => string.Equals(s, status.Trim(), StringComparison.OrdinalIgnoreCase));

    public static string ReadSapError(string body, int statusCode)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return $"{statusCode} (no response body)";
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !document.RootElement.TryGetProperty("error", out var error))
            {
                return body;
            }

            var texts = new List<string>();
            if (error.TryGetProperty("innererror", out var innerError) &&
                innerError.TryGetProperty("errordetails", out var details) &&
                details.ValueKind == JsonValueKind.Array)
            {
                foreach (var detail in details.EnumerateArray())
                {
                    if (!detail.TryGetProperty("message", out var message) || message.ValueKind != JsonValueKind.String)
                    {
                        continue;
                    }

                    var text = message.GetString()!.Trim();
                    var code = detail.TryGetProperty("code", out var codeElement) && codeElement.ValueKind == JsonValueKind.String
                        ? codeElement.GetString()
                        : null;

                    if (text.Length == 0 || (code is not null && code.StartsWith("/IWBEP/", StringComparison.OrdinalIgnoreCase)))
                    {
                        continue;
                    }

                    texts.Add(string.IsNullOrWhiteSpace(code) ? text : $"{code}: {text}");
                }
            }

            if (texts.Count == 0 &&
                error.TryGetProperty("message", out var topMessage) &&
                topMessage.ValueKind == JsonValueKind.Object &&
                topMessage.TryGetProperty("value", out var value) &&
                value.ValueKind == JsonValueKind.String &&
                !string.IsNullOrWhiteSpace(value.GetString()))
            {
                texts.Add(value.GetString()!.Trim());
            }

            return texts.Count == 0 ? body : string.Join("; ", texts.Distinct());
        }
        catch (JsonException)
        {
            return body;
        }
    }

    private static SetProjectStatusResult Fail(string project, string status, int replyStatusCode, string error, int? sapHttpStatus = null) =>
        new(project, status, false, sapHttpStatus, null, null, null, error, replyStatusCode);
}
