using System.Data;
using System.Net.Http.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrProjectService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions)
{
    public const string ShkrSapClientName = "ShkrSapProject";

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    public async Task<List<Proj>> GetAllProjectsAsync(CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var requestUri = $"/sap/opu/odata/SAP/ZPS_PROJ_SRV/PROJSet?sap-client={_options.ShkrSapClient}";

        var envelope = await client.GetFromJsonAsync<ODataEnvelope<ODataResultSet<Proj>>>(requestUri, cancellationToken)
            ?? throw new InvalidOperationException($"SAP call to {requestUri} returned an empty response body.");

        return envelope.D.Results;
    }

    public async Task RunShkrProjectsAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand("dbo.SHKR_INT_AddProjects", connection)
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

        const string existsSql = "SELECT COUNT(1) FROM dbo.xx_project_stg_tbl_ib WHERE Projectcode = @Projectcode";

        const string updateSql = """
            UPDATE dbo.xx_project_stg_tbl_ib
            SET ProjectProfile = @ProjectProfile, Projectname = @Projectname, Startdate = @Startdate,
                CreatedOn = @CreatedOn, Companycode = @Companycode,
                OperationFlag = @OperationFlag, ProcessStatus = @ProcessStatus, ProcessError = NULL,
                LastUpdateDate = @LastUpdateDate
            WHERE Projectcode = @Projectcode
            """;

        const string insertSql = """
            INSERT INTO dbo.xx_project_stg_tbl_ib
                (ProjectProfile, Projectcode, Projectname, Startdate, CreatedOn, Companycode,
                 OperationFlag, ProcessStatus, CreatedDate, LastUpdateDate)
            VALUES
                (@ProjectProfile, @Projectcode, @Projectname, @Startdate, @CreatedOn, @Companycode,
                 @OperationFlag, @ProcessStatus, @CreatedDate, @LastUpdateDate)
            """;

        await using var existsCmd = new SqlCommand(existsSql, connection);
        existsCmd.Parameters.AddWithValue("@Projectcode", project.ProjectCode);
        var exists = (int)(await existsCmd.ExecuteScalarAsync(cancellationToken))! > 0;

        await using var command = new SqlCommand(exists ? updateSql : insertSql, connection);
        command.Parameters.AddWithValue("@ProjectProfile", project.ProjectProfile);
        command.Parameters.AddWithValue("@Projectcode", project.ProjectCode);
        command.Parameters.AddWithValue("@Projectname", project.ProjectName);
        command.Parameters.AddWithValue("@Startdate", (object?)project.StartDate ?? DBNull.Value);
        command.Parameters.AddWithValue("@CreatedOn", (object?)project.CreatedOn ?? DBNull.Value);
        command.Parameters.AddWithValue("@Companycode", project.CompanyCode);
        AddTrackingParameters(command, now);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static void AddTrackingParameters(SqlCommand command, DateTime now)
    {
        command.Parameters.AddWithValue("@OperationFlag", "I");
        command.Parameters.AddWithValue("@ProcessStatus", "N");
        command.Parameters.AddWithValue("@CreatedDate", now);
        command.Parameters.AddWithValue("@LastUpdateDate", now);
    }
}
