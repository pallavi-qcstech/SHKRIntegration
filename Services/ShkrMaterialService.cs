using System.Data;
using System.Net.Http.Json;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrMaterialService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrMaterialService> logger)
{
    public const string ShkrSapClientName = "ShkrSapMaterial";
    public const string ProcedureName = "dbo.SHK_INT_MATERIAL_PRC";

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    private static readonly JsonSerializerOptions RequestSerializerOptions = new(JsonSerializerDefaults.General)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private const string UpsertSql = """
        UPDATE dbo.xx_material_stg_tbl_ib
        SET material_number = @MaterialNumber, material_name = @MaterialName, description = @Description,
            company_code = @CompanyCode, material_group = @MaterialGroup, material_group_descr = @MaterialGroupDescr,
            material_type = @MaterialType, industry = @Industry, base_unit_of_measure = @BaseUom,
            purchase_order_unit_of_measure = @PoUom, department = @Department, division = @Division,
            product_hierarchy = @ProductHierarchy, lab_office = @LabOffice,
            operation_flag = @OperationFlag, process_status = @ProcessStatus, error_msg = NULL,
            creation_date = @CreationDate, last_update_date = @LastUpdateDate
        WHERE material_number = @MaterialNumber;

        IF @@ROWCOUNT = 0
            INSERT INTO dbo.xx_material_stg_tbl_ib
                (material_number, material_name, description, company_code, material_group, material_group_descr,
                 material_type, industry, base_unit_of_measure, purchase_order_unit_of_measure, department, division,
                 product_hierarchy, lab_office, operation_flag, process_status, creation_date, last_update_date)
            VALUES
                (@MaterialNumber, @MaterialName, @Description, @CompanyCode, @MaterialGroup, @MaterialGroupDescr,
                 @MaterialType, @Industry, @BaseUom, @PoUom, @Department, @Division,
                 @ProductHierarchy, @LabOffice, @OperationFlag, @ProcessStatus, @CreationDate, @LastUpdateDate);
        """;

    public async Task<List<MaterialItem>> GetMaterialsAsync(string? materialNumber, CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var requestUri =
            $"/sap/opu/odata/SAP/Z_MATERIAL_DET_SRV/HEADERSet?sap-client={_options.ShkrSapClient}&sap-language={_options.ShkrSapLanguage}";

        var requestBody = new MaterialRequest { MaterialNumber = materialNumber ?? string.Empty };

        using var response = await client.PostAsJsonAsync(requestUri, requestBody, RequestSerializerOptions, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError(
                "SAP Material call to {RequestUri} failed with status {StatusCode}: {SapErrorMessage}",
                requestUri, (int)response.StatusCode, sapErrorMessage);
            throw new HttpRequestException(
                $"SAP call to {requestUri} failed with status {(int)response.StatusCode} ({response.StatusCode}): {sapErrorMessage}");
        }

        var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<MaterialHeader>>(cancellationToken)
            ?? throw new InvalidOperationException($"SAP call to {requestUri} returned an empty response body.");

        var materials = envelope.D.ItemSet?.Results ?? [];

        logger.LogInformation(
            "SAP Material call returned HTTP {StatusCode} with {Count} material(s) (MaterialNumber='{MaterialNumber}').",
            (int)response.StatusCode, materials.Count, requestBody.MaterialNumber);

        return materials;
    }

    public async Task<SyncResult> FetchSapDataToStagingTableAsync(
        string? materialNumber, CancellationToken cancellationToken = default)
    {
        var materials = await GetMaterialsAsync(materialNumber, cancellationToken);

        var (staged, errors) = await SaveMaterialsAsync(materials, DateTime.Now.Date, cancellationToken);

        logger.LogInformation(
            "Material staging completed: {Fetched} fetched, {Staged} staged, {Failed} failed.",
            materials.Count, staged, errors.Count);

        await RunShkrMaterialsAsync(cancellationToken);
        logger.LogInformation("{ProcedureName} executed.", ProcedureName);

        return new SyncResult(materials.Count, staged, errors.Count, errors);
    }

    public async Task<(int Staged, List<string> Errors)> SaveMaterialsAsync(
        IReadOnlyList<MaterialItem> materials, DateTime runDate, CancellationToken cancellationToken = default)
    {
        var staged = 0;
        var errors = new List<string>();

        if (materials.Count == 0)
        {
            return (staged, errors);
        }

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        foreach (var material in materials)
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                await SaveMaterialAsync(connection, material, runDate, cancellationToken);
                staged++;
            }
            catch (SqlException ex) when (connection.State == ConnectionState.Open)
            {
                logger.LogError(ex, "Material sync failed to stage MaterialNumber {MaterialNumber}.", material.MaterialNumber);
                errors.Add($"{material.MaterialNumber}: {ex.Message}");
            }
            catch (SqlException ex)
            {
                logger.LogError(
                    ex,
                    "Material staging stopped: database connection lost after {Staged} of {Total} material(s) staged ({Failed} failed); {ProcedureName} not run.",
                    staged, materials.Count, errors.Count, ProcedureName);
                throw;
            }
        }

        return (staged, errors);
    }

    public async Task RunShkrMaterialsAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(ProcedureName, connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task SaveMaterialAsync(
        SqlConnection connection, MaterialItem material, DateTime runDate, CancellationToken cancellationToken)
    {
        await using var command = new SqlCommand(UpsertSql, connection);
        var parameters = command.Parameters;

        AddText(parameters, "@MaterialNumber", SqlDbType.VarChar, 40, material.MaterialNumber);
        AddText(parameters, "@MaterialName", SqlDbType.NVarChar, 240, material.MaterialName);
        AddText(parameters, "@Description", SqlDbType.NVarChar, 240, material.Description);
        AddText(parameters, "@CompanyCode", SqlDbType.VarChar, 4, material.CompanyCode);
        AddText(parameters, "@MaterialGroup", SqlDbType.VarChar, 9, material.MaterialGroup);
        AddText(parameters, "@MaterialGroupDescr", SqlDbType.NVarChar, 240, material.MaterialGroupDescr);
        AddText(parameters, "@MaterialType", SqlDbType.VarChar, 4, material.MaterialType);
        AddText(parameters, "@Industry", SqlDbType.VarChar, 1, material.Industry);
        AddText(parameters, "@BaseUom", SqlDbType.VarChar, 3, material.BaseUnitOfMeasure);
        AddText(parameters, "@PoUom", SqlDbType.VarChar, 3, material.PurchaseOrderUnitOfMeasure);
        AddText(parameters, "@Department", SqlDbType.VarChar, 3, material.Department);
        AddText(parameters, "@Division", SqlDbType.VarChar, 2, material.Division);
        AddText(parameters, "@ProductHierarchy", SqlDbType.VarChar, 18, material.ProductHierarchy);
        AddText(parameters, "@LabOffice", SqlDbType.VarChar, 3, material.LabOffice);
        AddText(parameters, "@OperationFlag", SqlDbType.VarChar, 1, "I");
        AddText(parameters, "@ProcessStatus", SqlDbType.VarChar, 1, "N");
        parameters.Add("@CreationDate", SqlDbType.Date).Value = runDate;
        parameters.Add("@LastUpdateDate", SqlDbType.Date).Value = runDate;

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static void AddText(SqlParameterCollection parameters, string name, SqlDbType type, int columnSize, string? value)
    {
        var size = value is null ? columnSize : Math.Max(columnSize, value.Length);
        parameters.Add(name, type, size).Value = value is null ? DBNull.Value : value;
    }
}
