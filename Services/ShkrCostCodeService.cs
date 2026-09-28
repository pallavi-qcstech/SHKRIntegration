using System.Data;
using System.Net.Http.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrCostCodeService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrCostCodeService> logger)
{
    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    
    public async Task<List<WbsHierarchy>> GetWbsHierarchyAsync(
        string projectCode, CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrProjectService.ShkrSapClientName);
        var requestUri =
            $"/sap/opu/odata/SAP/ZPS_PROJ_SRV/hierarchySet?sap-client={_options.ShkrSapClient}&$filter=PROJECTCODE eq '{projectCode}'";

        using var response = await client.GetAsync(requestUri, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError(
                "SAP hierarchySet call to {RequestUri} failed with status {StatusCode}: {SapErrorMessage}",
                requestUri, (int)response.StatusCode, sapErrorMessage);
            throw new HttpRequestException(
                $"SAP call to {requestUri} failed with status {(int)response.StatusCode} ({response.StatusCode}): {sapErrorMessage}");
        }

        var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<ODataResultSet<WbsHierarchy>>>(cancellationToken)
            ?? throw new InvalidOperationException($"SAP call to {requestUri} returned an empty response body.");

        return envelope.D.Results;
    }

    public async Task SaveCostCode(WbsHierarchy wbs, CancellationToken cancellationToken = default)
    {
        var now = DateTime.Now;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        // Business key = (project_code, sap_wbs): re-running a sync for the same project
        // refreshes existing WBS rows instead of duplicating them.
        const string existsSql =
            "SELECT COUNT(1) FROM dbo.xx_sap_costcode_stg_tbl_ib WHERE project_code = @ProjectCode AND sap_wbs = @SapWbs";

        const string updateSql = """
            UPDATE dbo.xx_sap_costcode_stg_tbl_ib
            SET project_name = @ProjectName, sap_wbs_name = @SapWbsName, parent_wbs = @ParentWbs,
                wbs_type = @WbsType, sap_stripped_wbs = @SapStrippedWbs, operation_flag = @OperationFlag,
                process_status = @ProcessStatus, error_msg = NULL, last_update_date = @LastUpdateDate
            WHERE project_code = @ProjectCode AND sap_wbs = @SapWbs
            """;

        const string insertSql = """
            INSERT INTO dbo.xx_sap_costcode_stg_tbl_ib
                (project_code, project_name, sap_wbs, sap_wbs_name, parent_wbs, wbs_type,
                 sap_stripped_wbs, operation_flag, process_status, creation_date, last_update_date)
            VALUES
                (@ProjectCode, @ProjectName, @SapWbs, @SapWbsName, @ParentWbs, @WbsType,
                 @SapStrippedWbs, @OperationFlag, @ProcessStatus, @CreationDate, @LastUpdateDate)
            """;

        await using var existsCmd = new SqlCommand(existsSql, connection);
        existsCmd.Parameters.AddWithValue("@ProjectCode", wbs.ProjectCode);
        existsCmd.Parameters.AddWithValue("@SapWbs", wbs.Wbs);
        var exists = (int)(await existsCmd.ExecuteScalarAsync(cancellationToken))! > 0;

        await using var command = new SqlCommand(exists ? updateSql : insertSql, connection);
        command.Parameters.AddWithValue("@ProjectCode", wbs.ProjectCode);
        command.Parameters.AddWithValue("@ProjectName", wbs.ProjectName);
        command.Parameters.AddWithValue("@SapWbs", wbs.Wbs);
        command.Parameters.AddWithValue("@SapWbsName", wbs.Name);
        command.Parameters.AddWithValue("@ParentWbs", string.IsNullOrEmpty(wbs.UpWbs) ? DBNull.Value : wbs.UpWbs);

        // NOT YET CONFIRMED: staging SAP's DETAIL field  ("WBS Element" / "Network" /
        // "Activity"). SHK_INT_SAPCOSTCODE_IB_PRC's logic compares against the literal
        // "Network Activity", which will never match live SAP's "Activity" value as staged here -
        // flagged to the user, not silently translated. 
        command.Parameters.AddWithValue("@WbsType", wbs.Detail);

        // NOT YET CONFIRMED: sap_stripped_wbs's real stripping rule is unknown - defaulting to a
        // verbatim copy of sap_wbs (identity transform, no data loss) until the business rule is
        // provided. Same doc as above.
        command.Parameters.AddWithValue("@SapStrippedWbs", wbs.Wbs);

        command.Parameters.AddWithValue("@OperationFlag", "I");
        command.Parameters.AddWithValue("@ProcessStatus", "N");
        command.Parameters.AddWithValue("@LastUpdateDate", now);
        if (!exists)
        {
            command.Parameters.AddWithValue("@CreationDate", now);
        }

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task RunShkrCostCodesAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand("dbo.SHK_INT_SAPCOSTCODE_IB_PRC", connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
