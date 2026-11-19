using System.Data;
using System.Globalization;
using System.Net.Http.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrWBSService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrWBSService> logger)
{
    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    public async Task<List<WbsHierarchy>> GetWbsHierarchyAsync(
        // string projectCode,
        DateTime createdon, CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrProjectService.ShkrSapClientName);
        // var requestUri =
        //     $"/sap/opu/odata/SAP/ZPS_PROJ_SRV/hierarchySet?sap-client={_options.ShkrSapClient}&$filter=PROJECTCODE eq '{projectCode}'";
        var requestUri =
            $"/sap/opu/odata/SAP/ZPS_PROJ_SRV/hierarchySet?sap-client={_options.ShkrSapClient}&$filter=CREATEDON eq '{createdon.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)}'";

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

    public async Task SaveWbs(WbsHierarchy wbs, DateTime filterDate, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        const string existsSql =
            "SELECT COUNT(1) FROM dbo.xx_sap_costcode_stg_tbl_ib WHERE project_code = @ProjectCode AND sap_wbs = @SapWbs AND ISNULL(parent_wbs, '') = ISNULL(@ParentWbs, '')";

        const string updateSql = """
            UPDATE dbo.xx_sap_costcode_stg_tbl_ib
            SET project_name = @ProjectName, sap_wbs_name = @SapWbsName, parent_wbs = @ParentWbs,
                wbs_type = @WbsType, sap_stripped_wbs = @SapStrippedWbs, plant = @Plant,
                con_key = @ConKey, func_area = @FuncArea, sap_createdon = @SapCreatedOn,
                operation_flag = @OperationFlag, process_status = @ProcessStatus, error_msg = NULL,
                process_status_wbs = @ProcessStatusWbs, error_msg_wbs = NULL, pmweb_wbs_id = NULL, pmweb_wbs_config_id = NULL,
                creation_date = @CreationDate, last_update_date = @LastUpdateDate
            WHERE project_code = @ProjectCode AND sap_wbs = @SapWbs AND ISNULL(parent_wbs, '') = ISNULL(@ParentWbs, '')
            """;

        const string insertSql = """
            INSERT INTO dbo.xx_sap_costcode_stg_tbl_ib
                (project_code, project_name, sap_wbs, sap_wbs_name, parent_wbs, wbs_type,
                 sap_stripped_wbs, plant, con_key, func_area, sap_createdon, operation_flag,
                 process_status, process_status_wbs, creation_date, last_update_date)
            VALUES
                (@ProjectCode, @ProjectName, @SapWbs, @SapWbsName, @ParentWbs, @WbsType,
                 @SapStrippedWbs, @Plant, @ConKey, @FuncArea, @SapCreatedOn, @OperationFlag,
                 @ProcessStatus, @ProcessStatusWbs, @CreationDate, @LastUpdateDate)
            """;

        await using var existsCmd = new SqlCommand(existsSql, connection);
        existsCmd.Parameters.AddWithValue("@ProjectCode", wbs.ProjectCode);
        existsCmd.Parameters.AddWithValue("@SapWbs", wbs.Wbs);
        existsCmd.Parameters.AddWithValue("@ParentWbs", string.IsNullOrEmpty(wbs.UpWbs) ? DBNull.Value : wbs.UpWbs);
        var exists = (int)(await existsCmd.ExecuteScalarAsync(cancellationToken))! > 0;

        await using var command = new SqlCommand(exists ? updateSql : insertSql, connection);
        command.Parameters.AddWithValue("@ProjectCode", wbs.ProjectCode);
        command.Parameters.AddWithValue("@ProjectName", wbs.ProjectName);
        command.Parameters.AddWithValue("@SapWbs", wbs.Wbs);
        command.Parameters.AddWithValue("@SapWbsName", wbs.Name);
        command.Parameters.AddWithValue("@ParentWbs", string.IsNullOrEmpty(wbs.UpWbs) ? DBNull.Value : wbs.UpWbs);

        command.Parameters.AddWithValue("@WbsType", wbs.Detail);

        command.Parameters.AddWithValue("@SapStrippedWbs", ComputeSapStrippedWbs(wbs));

        command.Parameters.AddWithValue("@Plant", string.IsNullOrEmpty(wbs.Plant) ? DBNull.Value : wbs.Plant);
        command.Parameters.AddWithValue("@ConKey", string.IsNullOrEmpty(wbs.ConKey) ? DBNull.Value : wbs.ConKey);
        command.Parameters.AddWithValue("@FuncArea", string.IsNullOrEmpty(wbs.FuncArea) ? DBNull.Value : wbs.FuncArea);
        command.Parameters.AddWithValue("@SapCreatedOn", string.IsNullOrEmpty(wbs.CreatedOn) ? DBNull.Value : wbs.CreatedOn);

        command.Parameters.AddWithValue("@OperationFlag", "I");
        command.Parameters.AddWithValue("@ProcessStatus", "N");
        command.Parameters.Add("@CreationDate", SqlDbType.Date).Value = filterDate.Date;
        command.Parameters.Add("@LastUpdateDate", SqlDbType.Date).Value = DateTime.Now.Date;
        command.Parameters.AddWithValue("@ProcessStatusWbs", "N");

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private string ComputeSapStrippedWbs(WbsHierarchy wbs)
    {
        if (string.IsNullOrEmpty(wbs.UpWbs) ||
            !string.Equals(wbs.Detail, "WBS Element", StringComparison.OrdinalIgnoreCase))
        {
            return wbs.Wbs;
        }

        var suffixLength = wbs.Wbs.Length - wbs.UpWbs.Length;
        if (suffixLength <= 0)
        {
            logger.LogWarning(
                "WBS {Wbs} is not longer than its parent {ParentWbs}; sap_stripped_wbs staged as empty.",
                wbs.Wbs, wbs.UpWbs);
            return string.Empty;
        }

        var suffix = wbs.Wbs[^suffixLength..];
        return suffix[0] == '-' ? suffix[1..] : suffix;
    }

    public async Task RunShkrWBSAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand("dbo.SHK_INT_SAPCOSTCODE_IB_PRC", connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<SyncResult> FetchSapDataToStagingTableAsync(
        // string projectCode,
        DateTime createdon, CancellationToken cancellationToken = default)
    {
        var wbsRows = await GetWbsHierarchyAsync(createdon, cancellationToken);

        logger.LogInformation(
            "Manual WBS sync for CREATEDON={Createdon:yyyy-MM-dd}: {Count} WBS row(s) fetched, staging and promoting.",
            createdon, wbsRows.Count);

        var staged = 0;
        var errors = new List<string>();

        foreach (var wbs in wbsRows)
        {
            try
            {
                await SaveWbs(wbs, createdon, cancellationToken);
                staged++;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "WBS sync failed to stage WBS {Wbs} for project {ProjectCode}.", wbs.Wbs, wbs.ProjectCode);
                errors.Add($"{wbs.Wbs}: {ex.Message}");
            }
        }

        await RunShkrWBSAsync(cancellationToken);

        return new SyncResult(wbsRows.Count, staged, errors.Count, errors);
    }
}
