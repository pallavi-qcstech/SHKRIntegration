using System.Data;
using System.Net.Http.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrProductHierarchyService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrProductHierarchyService> logger)
{
    public const string ShkrSapClientName = "ShkrSapProductHierarchy";
    public const string ProcedureName = "dbo.SHK_INT_PRODUCTHIERARCHY_PRC";

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    private const string UpsertSql = """
        UPDATE dbo.xx_producthierarchy_stg_tbl_ib
        SET product_hierarchy = @ProductHierarchy, parent_hierarchy = @ParentHierarchy,
            hierarchy_level = @HierarchyLevel, node_code = @NodeCode, description = @Description,
            has_children = @HasChildren, operation_flag = @OperationFlag, process_status = @ProcessStatus,
            error_msg = NULL, creation_date = @CreationDate, last_update_date = @LastUpdateDate
        WHERE product_hierarchy = @ProductHierarchy;

        IF @@ROWCOUNT = 0
            INSERT INTO dbo.xx_producthierarchy_stg_tbl_ib
                (product_hierarchy, parent_hierarchy, hierarchy_level, node_code, description, has_children,
                 operation_flag, process_status, creation_date, last_update_date)
            VALUES
                (@ProductHierarchy, @ParentHierarchy, @HierarchyLevel, @NodeCode, @Description, @HasChildren,
                 @OperationFlag, @ProcessStatus, @CreationDate, @LastUpdateDate);
        """;

    public async Task<List<ProductHierarchyNode>> GetProductHierarchyAsync(CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var requestUri =
            $"/sap/opu/odata/sap/ZPRODHIER_SRV/ProdHierNodes?sap-client={_options.ShkrSapClient}&sap-language={_options.ShkrSapLanguage}&$format=json";

        using var response = await client.GetAsync(requestUri, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError(
                "SAP Product Hierarchy call to {RequestUri} failed with status {StatusCode}: {SapErrorMessage}",
                requestUri, (int)response.StatusCode, sapErrorMessage);
            throw new HttpRequestException(
                $"SAP call to {requestUri} failed with status {(int)response.StatusCode} ({response.StatusCode}): {sapErrorMessage}");
        }

        var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<ODataResultSet<ProductHierarchyNode>>>(cancellationToken)
            ?? throw new InvalidOperationException($"SAP call to {requestUri} returned an empty response body.");

        var nodes = envelope.D.Results;

        logger.LogInformation(
            "SAP Product Hierarchy call returned HTTP {StatusCode} with {Count} node(s).",
            (int)response.StatusCode, nodes.Count);

        return nodes;
    }

    public async Task<SyncResult> FetchSapDataToStagingTableAsync(CancellationToken cancellationToken = default)
    {
        var nodes = await GetProductHierarchyAsync(cancellationToken);

        var (staged, errors) = await SaveNodesAsync(nodes, DateTime.Now, cancellationToken);

        logger.LogInformation(
            "Product Hierarchy staging completed: {Fetched} fetched, {Staged} staged, {Failed} failed.",
            nodes.Count, staged, errors.Count);

        await RunShkrProductHierarchyAsync(cancellationToken);
        logger.LogInformation("{ProcedureName} executed.", ProcedureName);

        return new SyncResult(nodes.Count, staged, errors.Count, errors);
    }

    public async Task<(int Staged, List<string> Errors)> SaveNodesAsync(
        IReadOnlyList<ProductHierarchyNode> nodes, DateTime runTime, CancellationToken cancellationToken = default)
    {
        var staged = 0;
        var errors = new List<string>();

        if (nodes.Count == 0)
        {
            return (staged, errors);
        }

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        foreach (var node in nodes)
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                await SaveNodeAsync(connection, node, runTime, cancellationToken);
                staged++;
            }
            catch (SqlException ex) when (connection.State == ConnectionState.Open)
            {
                logger.LogError(ex, "Product Hierarchy sync failed to stage node {ProductHierarchy}.", node.ProductHierarchy);
                errors.Add($"{node.ProductHierarchy}: {ex.Message}");
            }
            catch (SqlException ex)
            {
                logger.LogError(
                    ex,
                    "Product Hierarchy staging stopped: database connection lost after {Staged} of {Total} node(s) staged ({Failed} failed); {ProcedureName} not run.",
                    staged, nodes.Count, errors.Count, ProcedureName);
                throw;
            }
        }

        return (staged, errors);
    }

    public async Task RunShkrProductHierarchyAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(ProcedureName, connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task SaveNodeAsync(
        SqlConnection connection, ProductHierarchyNode node, DateTime runTime, CancellationToken cancellationToken)
    {
        await using var command = new SqlCommand(UpsertSql, connection);
        var parameters = command.Parameters;

        AddText(parameters, "@ProductHierarchy", SqlDbType.VarChar, 18, node.ProductHierarchy);
        AddText(parameters, "@ParentHierarchy", SqlDbType.VarChar, 18, node.ParentHierarchy);
        AddText(parameters, "@HierarchyLevel", SqlDbType.VarChar, 1, node.HierarchyLevel);
        AddText(parameters, "@NodeCode", SqlDbType.VarChar, 8, node.NodeCode);
        AddText(parameters, "@Description", SqlDbType.VarChar, 40, node.Description);
        AddText(parameters, "@HasChildren", SqlDbType.VarChar, 1, node.HasChildren);
        AddText(parameters, "@OperationFlag", SqlDbType.VarChar, 1, "I");
        AddText(parameters, "@ProcessStatus", SqlDbType.VarChar, 1, "N");
        parameters.Add("@CreationDate", SqlDbType.DateTime2).Value = runTime;
        parameters.Add("@LastUpdateDate", SqlDbType.DateTime2).Value = runTime;

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static void AddText(SqlParameterCollection parameters, string name, SqlDbType type, int columnSize, string? value)
    {
        var size = value is null ? columnSize : Math.Max(columnSize, value.Length);
        parameters.Add(name, type, size).Value = value is null ? DBNull.Value : value;
    }
}
