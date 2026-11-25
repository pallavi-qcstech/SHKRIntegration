using System.Globalization;
using System.Net;
using System.Text.Json;
using Microsoft.Extensions.Options;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrGetProjectStatusService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    ILogger<ShkrGetProjectStatusService> logger)
{
    public const string ShkrSapClientName = "ShkrSapGetProjectStatus";

    public const string ServicePath = "/sap/opu/odata/sap/Z_PROJ_DEF_SRV/";
    public const string EntitySet = "PROJSet";
    public const string Approved = "Approved";
    public const string NotApproved = "Not Approved";

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private volatile bool _stoppedBy401;

    public async Task<GetProjectStatusResult> GetStatusAsync(
        string? projectNumber, CancellationToken cancellationToken = default)
    {
        var project = projectNumber?.Trim() ?? string.Empty;

        var inputError = ValidateInput(project);
        if (inputError is not null)
        {
            return Fail(project, StatusCodes.Status400BadRequest, inputError);
        }

        if (_stoppedBy401)
        {
            return Fail(project, StatusCodes.Status503ServiceUnavailable,
                "SAP returned 401 earlier. Fix the SAP account, then restart the application.");
        }

        var requestUri = BuildRequestUri(project, _options.ShkrSapClient);

        try
        {
            var client = httpClientFactory.CreateClient(ShkrSapClientName);
            using var response = await client.GetAsync(requestUri, cancellationToken);

            if (response.StatusCode == HttpStatusCode.Unauthorized)
            {
                _stoppedBy401 = true;
                logger.LogCritical(
                    "SAP returned 401 for project status {ProjectNumber}. Project status reads are stopped until the application is restarted (no retry, to avoid locking the SAP account).",
                    project);
                return Fail(project, StatusCodes.Status502BadGateway, "SAP returned 401 - stopped, no retry.",
                    (int)HttpStatusCode.Unauthorized);
            }

            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            var result = Evaluate(project, (int)response.StatusCode, body);

            if (result.Error is null)
            {
                logger.LogInformation("Project status {ProjectNumber}: SAP project {SapProjectNumber} is '{Status}'.",
                    project, result.SapProjectNumber, result.Status);
            }
            else
            {
                logger.LogWarning("Project status {ProjectNumber}: SAP {SapHttpStatus} - {Error}",
                    project, result.SapHttpStatus, result.Error);
            }

            return result;
        }
        catch (Exception ex) when (ex is HttpRequestException || (ex is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            logger.LogError(ex, "Project status {ProjectNumber}: no answer from SAP.", project);
            return Fail(project, StatusCodes.Status504GatewayTimeout, $"No answer from SAP: {ex.Message}");
        }
    }

    public static string? ValidateInput(string project)
    {
        if (project.Length == 0)
        {
            return "projectNumber is required. SAP was not called.";
        }

        if (project.Contains('*'))
        {
            return $"projectNumber '{project}' must not contain '*' (SAP would read it as a pattern). SAP was not called.";
        }

        return null;
    }

    public static string BuildRequestUri(string projectNumber, string sapClient)
    {
        var filter = Uri.EscapeDataString($"ProjectNumber eq '{projectNumber.Replace("'", "''")}'");
        return $"{ServicePath}{EntitySet}?sap-client={Uri.EscapeDataString(sapClient)}&sap-language=EN&$filter={filter}&$format=json";
    }

    public static GetProjectStatusResult Evaluate(string project, int httpStatus, string body)
    {
        if (httpStatus is < 200 or >= 300)
        {
            var sapError = ShkrSetProjectStatusService.ReadSapError(body, httpStatus);
            var reply = httpStatus is >= 400 and < 500 ? StatusCodes.Status422UnprocessableEntity : StatusCodes.Status502BadGateway;
            return Fail(project, reply, $"SAP refused the project status read: {sapError}", httpStatus);
        }

        var entries = TryReadResults(body);
        if (entries is null)
        {
            return Fail(project, StatusCodes.Status502BadGateway,
                $"SAP answered {httpStatus} with a body that is not the PROJSet OData result list.", httpStatus);
        }

        if (entries.Count == 0)
        {
            return Fail(project, StatusCodes.Status404NotFound,
                $"Project {project} was not found in SAP (Z_PROJ_DEF_SRV PROJSet).", httpStatus);
        }

        if (entries.Count > 1)
        {
            var numbers = string.Join(", ", entries.Select(e => $"'{e.ProjectNumber}'"));
            return Fail(project, StatusCodes.Status502BadGateway,
                $"SAP returned {entries.Count} projects for {project} ({numbers}); the status is not used.", httpStatus);
        }

        var entry = entries[0];
        var status = entry.Status?.Trim();
        var createdOn = entry.CreatedOn?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

        if (string.Equals(status, Approved, StringComparison.Ordinal) ||
            string.Equals(status, NotApproved, StringComparison.Ordinal))
        {
            return new GetProjectStatusResult(project, entry.ProjectNumber, entry.ProjectType, createdOn, status,
                string.Equals(status, Approved, StringComparison.Ordinal), httpStatus, null, StatusCodes.Status200OK);
        }

        return new GetProjectStatusResult(project, entry.ProjectNumber, entry.ProjectType, createdOn, entry.Status,
            false, httpStatus,
            $"SAP returned status '{entry.Status}' for {project}; expected '{Approved}' or '{NotApproved}'.",
            StatusCodes.Status502BadGateway);
    }

    private static List<GetProjectStatusEntry>? TryReadResults(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("d", out var d) &&
                d.ValueKind == JsonValueKind.Object &&
                d.TryGetProperty("results", out var results) &&
                results.ValueKind == JsonValueKind.Array)
            {
                return results.Deserialize<List<GetProjectStatusEntry>>();
            }
        }
        catch (JsonException)
        {
        }

        return null;
    }

    private static GetProjectStatusResult Fail(string project, int replyStatusCode, string error, int? sapHttpStatus = null) =>
        new(project, null, null, null, null, false, sapHttpStatus, error, replyStatusCode);
}
