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

    // Both creatdon and projectCode are confirmed non-functional server-side as of 2026-09-25 (and
    // creatdon since 2026-09-16) - PROJSet's $metadata declares every property sap:filterable="false",
    // and this was verified behaviorally too: $filter=Projectcode eq '<real code>' still returns the
    // full ~318-row unfiltered set, tested against multiple real project codes. Kept anyway, same as
    // creatdon, so the request already matches the agreed contract if/when SAP enables filtering.
    // Don't rely on either parameter to actually scope the response - filter client-side on the
    // returned list instead.
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

        // Real schema confirmed live on production 2026-09-25 (INFORMATION_SCHEMA.COLUMNS query) -
        // dbo.xx_project_stg_tbl_ib uses snake_case columns, NOT the PascalCase this file briefly
        // reverted to. record_id is a real IDENTITY column, never included in the INSERT. End_Date
        // and attribute1-10 have no source yet and are left NULL by omission.
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
