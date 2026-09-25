using System.Data;
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
        string? creatdon = null, string? projectCode = null, CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var requestUri = $"/sap/opu/odata/SAP/ZPS_PROJ_SRV/PROJSet?sap-client={_options.ShkrSapClient}";

        var filters = new List<string>();
        if (!string.IsNullOrWhiteSpace(creatdon))
        {
            filters.Add($"Creatdon eq '{creatdon}'");
        }
        if (!string.IsNullOrWhiteSpace(projectCode))
        {
            filters.Add($"Projectcode eq '{projectCode}'");
        }
        if (filters.Count > 0)
        {
            requestUri += $"&$filter={string.Join(" and ", filters)}";
        }

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

    public async Task SaveProject(Proj project, CancellationToken cancellationToken = default)
    {
        var now = DateTime.Now;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        const string existsSql = "SELECT COUNT(1) FROM dbo.xx_project_stg_tbl_ib WHERE project_code = @ProjectCode";

        const string updateSql = """
            UPDATE dbo.xx_project_stg_tbl_ib
            SET project_name = @ProjectName, project_profile = @ProjectProfile, Start_Date = @StartDate,
                company_code = @CompanyCode, operation_flag = @OperationFlag, process_status = @ProcessStatus,
                error_msg = NULL, last_update_date = @LastUpdateDate
            WHERE project_code = @ProjectCode
            """;

        const string insertSql = """
            INSERT INTO dbo.xx_project_stg_tbl_ib
                (project_code, project_name, project_profile, Start_Date, company_code,
                 operation_flag, process_status, creation_date, last_update_date)
            VALUES
                (@ProjectCode, @ProjectName, @ProjectProfile, @StartDate, @CompanyCode,
                 @OperationFlag, @ProcessStatus, @CreationDate, @LastUpdateDate)
            """;

        await using var existsCmd = new SqlCommand(existsSql, connection);
        existsCmd.Parameters.AddWithValue("@ProjectCode", project.ProjectCode);
        var exists = (int)(await existsCmd.ExecuteScalarAsync(cancellationToken))! > 0;

        await using var command = new SqlCommand(exists ? updateSql : insertSql, connection);
        command.Parameters.AddWithValue("@ProjectCode", project.ProjectCode);
        command.Parameters.AddWithValue("@ProjectName", project.ProjectName);
        command.Parameters.AddWithValue("@ProjectProfile", project.ProjectProfile);
        command.Parameters.AddWithValue("@StartDate", (object?)project.StartDate ?? DBNull.Value);
        command.Parameters.AddWithValue("@CompanyCode", project.CompanyCode);
        command.Parameters.AddWithValue("@OperationFlag", "I");
        command.Parameters.AddWithValue("@ProcessStatus", "N");
        command.Parameters.AddWithValue("@LastUpdateDate", now);
        if (!exists)
        {
            command.Parameters.AddWithValue("@CreationDate", (object?)project.CreatedOn ?? DBNull.Value);
        }

        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
