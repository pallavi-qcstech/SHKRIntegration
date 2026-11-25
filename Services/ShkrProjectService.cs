using System.Data;
using System.Globalization;
using System.Net.Http.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrProjectService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrProjectService> logger)
{
    public const string ShkrSapClientName = "ShkrSapProject";

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    public async Task<List<Proj>> GetAllProjectsAsync(
        // string? projectCode,
        DateTime lastUpdateFrom, CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var requestUri = $"/sap/opu/odata/SAP/ZPS_PROJ_SRV/PROJSet?sap-client={_options.ShkrSapClient}";

        var filters = new List<string>
        {
            $"Createdon ge '{lastUpdateFrom.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)}'"
        };
        // if (!string.IsNullOrWhiteSpace(projectCode))
        // {
        //     filters.Add($"Projectcode eq '{projectCode}'");
        // }
        requestUri += $"&$filter={string.Join(" and ", filters)}";

        using var response = await client.GetAsync(requestUri, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError(
                "SAP Project call to {RequestUri} failed with status {StatusCode}: {SapErrorMessage}",
                requestUri, (int)response.StatusCode, sapErrorMessage);
            throw new HttpRequestException(
                $"SAP call to {requestUri} failed with status {(int)response.StatusCode} ({response.StatusCode}): {sapErrorMessage}");
        }

        var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<ODataResultSet<Proj>>>(cancellationToken)
            ?? throw new InvalidOperationException($"SAP call to {requestUri} returned an empty response body.");

        return envelope.D.Results;
    }

    public async Task RunShkrProjectsAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand("dbo.SHK_INT_PROJECT_IB_PRC", connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<SyncResult> FetchSapDataToStagingTableAsync(
        // string? projectCode,
        DateTime lastUpdateFrom, CancellationToken cancellationToken = default)
    {
        var projects = await GetAllProjectsAsync(lastUpdateFrom, cancellationToken);

        logger.LogInformation(
            "Project sync for projects created on or after {LastUpdateDate:yyyy-MM-dd} (SAP filter Createdon ge): {Count} project(s) fetched, staging and promoting.",
            lastUpdateFrom, projects.Count);

        var staged = 0;
        var errors = new List<string>();

        foreach (var project in projects)
        {
            try
            {
                await SaveProject(project, lastUpdateFrom, cancellationToken);
                staged++;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Project sync failed to stage ProjectCode {ProjectCode}.", project.ProjectCode);
                errors.Add($"{project.ProjectCode}: {ex.Message}");
            }
        }

        await RunShkrProjectsAsync(cancellationToken);

        return new SyncResult(projects.Count, staged, errors.Count, errors);
    }

    public async Task SaveProject(Proj project, DateTime filterDate, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        const string latestSql = """
            SELECT TOP (1) record_id, process_status
            FROM dbo.xx_project_stg_tbl_ib
            WHERE project_code = @ProjectCode
            ORDER BY record_id DESC
            """;

        const string updateSql = """
            UPDATE dbo.xx_project_stg_tbl_ib
            SET project_name = @ProjectName, project_profile = @ProjectProfile, Start_Date = @StartDate,
                company_code = @CompanyCode, pr_doc_type = @PrDocType, po_doc_type = @PoDocType,
                operation_flag = @OperationFlag, process_status = @ProcessStatus,
                error_msg = NULL, creation_date = @CreationDate, last_update_date = @LastUpdateDate
            WHERE record_id = @RecordId
            """;

        const string insertSql = """
            INSERT INTO dbo.xx_project_stg_tbl_ib
                (project_code, project_name, project_profile, Start_Date, company_code, pr_doc_type, po_doc_type,
                 operation_flag, process_status, creation_date, last_update_date)
            VALUES
                (@ProjectCode, @ProjectName, @ProjectProfile, @StartDate, @CompanyCode, @PrDocType, @PoDocType,
                 @OperationFlag, @ProcessStatus, @CreationDate, @LastUpdateDate)
            """;

        long? waitingRecordId = null;
        await using (var latestCmd = new SqlCommand(latestSql, connection))
        {
            latestCmd.Parameters.AddWithValue("@ProjectCode", project.ProjectCode);
            await using var reader = await latestCmd.ExecuteReaderAsync(cancellationToken);
            if (await reader.ReadAsync(cancellationToken))
            {
                var status = reader.IsDBNull(1) ? null : reader.GetString(1).Trim();
                if (status is "N" or "E")
                {
                    waitingRecordId = Convert.ToInt64(reader.GetValue(0), CultureInfo.InvariantCulture);
                }
            }
        }

        await using var command = new SqlCommand(waitingRecordId is null ? insertSql : updateSql, connection);
        if (waitingRecordId is not null)
        {
            command.Parameters.AddWithValue("@RecordId", waitingRecordId.Value);
        }

        command.Parameters.AddWithValue("@ProjectCode", project.ProjectCode);
        command.Parameters.AddWithValue("@ProjectName", project.ProjectName);
        command.Parameters.AddWithValue("@ProjectProfile", project.ProjectProfile);
        command.Parameters.AddWithValue("@StartDate", (object?)project.StartDate ?? DBNull.Value);
        command.Parameters.AddWithValue("@CompanyCode", project.CompanyCode);
        command.Parameters.AddWithValue("@PrDocType", string.IsNullOrWhiteSpace(project.PrDocType) ? DBNull.Value : project.PrDocType.Trim());
        command.Parameters.AddWithValue("@PoDocType", string.IsNullOrWhiteSpace(project.PoDocType) ? DBNull.Value : project.PoDocType.Trim());
        command.Parameters.AddWithValue("@OperationFlag", "I");
        command.Parameters.AddWithValue("@ProcessStatus", "N");
        command.Parameters.Add("@CreationDate", SqlDbType.Date).Value = filterDate.Date;
        command.Parameters.Add("@LastUpdateDate", SqlDbType.Date).Value = DateTime.Now.Date;

        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
