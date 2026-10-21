using System.Data;
using System.Net.Http.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrReservationService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrReservationService> logger)
{
    public const string ShkrSapClientName = "ShkrSapReservation";

    // ZMM_RESV_DETAIL_SRV caps every read at 5000 rows before paging, so a result of exactly this size may be
    // incomplete. The fix is a narrower filter, not a higher $top.
    private const int SapRowCap = 5000;

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    // The service has no change-date filter and refuses a read without a filter on Reservation, ProjectDefinition,
    // WbsElement, Network or Material - so the daily run reads by project, one call per PMWeb project.
    public async Task<List<ReservationItem>> GetReservationsForProjectAsync(
        string projectDefinition, CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var filter = $"ProjectDefinition eq '{projectDefinition.Replace("'", "''")}'";

        var requestUri =
            $"/sap/opu/odata/sap/ZMM_RESV_DETAIL_SRV/ReservationSet?sap-client={_options.ShkrSapClient}" +
            $"&$filter={Uri.EscapeDataString(filter)}&$format=json";

        using var response = await client.GetAsync(requestUri, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
            logger.LogError(
                "SAP Reservation call to {RequestUri} failed with status {StatusCode}: {SapErrorMessage}",
                requestUri, (int)response.StatusCode, sapErrorMessage);
            throw new HttpRequestException(
                $"SAP call to {requestUri} failed with status {(int)response.StatusCode} ({response.StatusCode}): {sapErrorMessage}");
        }

        var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<ODataResultSet<ReservationItem>>>(cancellationToken)
            ?? throw new InvalidOperationException($"SAP call to {requestUri} returned an empty response body.");

        var items = envelope.D.Results;

        if (items.Count >= SapRowCap)
        {
            logger.LogWarning(
                "Reservation read for project {ProjectDefinition} returned {Count} rows, the SAP cap - the result may be incomplete.",
                projectDefinition, items.Count);
        }

        return items;
    }

    public async Task<SyncResult> FetchSapDataToStagingTableAsync(
        string? projectDefinition, CancellationToken cancellationToken = default)
    {
        var projects = string.IsNullOrWhiteSpace(projectDefinition)
            ? await GetActiveProjectNumbers(cancellationToken)
            : [projectDefinition.Trim()];

        logger.LogInformation("Reservation sync: reading {Count} project(s) from SAP.", projects.Count);

        var fetched = 0;
        var staged = 0;
        var errors = new List<string>();

        foreach (var project in projects)
        {
            cancellationToken.ThrowIfCancellationRequested();

            List<ReservationItem> items;
            try
            {
                items = await GetReservationsForProjectAsync(project, cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // One project failing in SAP must not stop the rest of the daily run.
                logger.LogError(ex, "Reservation sync failed to read project {ProjectDefinition}.", project);
                errors.Add($"Project {project}: {ex.Message}");
                continue;
            }

            fetched += items.Count;

            foreach (var item in items)
            {
                try
                {
                    await SaveReservation(item, cancellationToken);
                    staged++;
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    logger.LogError(ex, "Reservation sync failed to stage Reservation {Reservation} Item {Item}.",
                        item.Reservation, item.Item);
                    errors.Add($"{item.Reservation}/{item.Item}: {ex.Message}");
                }
            }
        }

        logger.LogInformation(
            "Reservation sync finished: {Fetched} fetched, {Staged} staged, {Failed} failed.",
            fetched, staged, errors.Count);

        await RunShkrReservationAsync(cancellationToken);

        return new SyncResult(fetched, staged, errors.Count, errors);
    }

    public async Task RunShkrReservationAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand("dbo.SHK_INT_RESERVATION_IB_PRC", connection)
        {
            CommandType = CommandType.StoredProcedure
        };

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private async Task<List<string>> GetActiveProjectNumbers(CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT DISTINCT ProjectNumber
            FROM dbo.Projects
            WHERE IsActive = 1 AND ISNULL(ProjectNumber, '') <> ''
            """;

        var projectNumbers = new List<string>();

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            projectNumbers.Add(reader.GetString(0));
        }

        return projectNumbers;
    }

    // Reservation + Item is the unique key: an existing row is updated, a new one inserted. Either way it goes back
    // to process_status N with its PMWeb ids cleared, so SHK_INT_RESERVATION_IB_PRC derives them afresh.
    public async Task SaveReservation(ReservationItem r, CancellationToken cancellationToken = default)
    {
        const string upsertSql = """
            IF EXISTS (SELECT 1 FROM dbo.xx_sap_reservation_details_stg_tbl_ib
                       WHERE Reservation = @Reservation AND Item = @Item)
            BEGIN
                UPDATE dbo.xx_sap_reservation_details_stg_tbl_ib
                SET OrderCategory = @OrderCategory, ReservationType = @ReservationType,
                    RequirementsDate = @RequirementsDate, ProjectDefinition = @ProjectDefinition,
                    WbsElement = @WbsElement, Network = @Network, Activity = @Activity, Material = @Material,
                    MaterialText = @MaterialText, Plant = @Plant, StorageLocation = @StorageLocation,
                    RequirementQuantity = @RequirementQuantity, UnitOfEntry = @UnitOfEntry,
                    ItemCategory = @ItemCategory, PriceUnit = @PriceUnit, Price = @Price, Currency = @Currency,
                    GlAccount = @GlAccount, ProfitCenter = @ProfitCenter, MovementAllowed = @MovementAllowed,
                    QuantityWithdrawn = @QuantityWithdrawn, IsDeleted = @IsDeleted,
                    pmweb_project_id = NULL, pmweb_material_id = NULL,
                    pmweb_costcode_id = NULL, pmweb_wbs_id = NULL,
                    operation_flag = 'U', process_status = 'N', error_msg = NULL,
                    last_update_date = @StagingDate
                WHERE Reservation = @Reservation AND Item = @Item;
            END
            ELSE
            BEGIN
                INSERT INTO dbo.xx_sap_reservation_details_stg_tbl_ib
                    (OrderCategory, Reservation, Item, ReservationType, RequirementsDate, ProjectDefinition,
                     WbsElement, Network, Activity, Material, MaterialText, Plant, StorageLocation,
                     RequirementQuantity, UnitOfEntry, ItemCategory, PriceUnit, Price, Currency, GlAccount,
                     ProfitCenter, MovementAllowed, QuantityWithdrawn, IsDeleted,
                     operation_flag, process_status, creation_date, last_update_date)
                VALUES
                    (@OrderCategory, @Reservation, @Item, @ReservationType, @RequirementsDate, @ProjectDefinition,
                     @WbsElement, @Network, @Activity, @Material, @MaterialText, @Plant, @StorageLocation,
                     @RequirementQuantity, @UnitOfEntry, @ItemCategory, @PriceUnit, @Price, @Currency, @GlAccount,
                     @ProfitCenter, @MovementAllowed, @QuantityWithdrawn, @IsDeleted,
                     'I', 'N', @StagingDate, @StagingDate);
            END
            """;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(upsertSql, connection);
        command.Parameters.AddWithValue("@OrderCategory", r.OrderCategory);
        command.Parameters.AddWithValue("@Reservation", r.Reservation);
        command.Parameters.AddWithValue("@Item", r.Item);
        command.Parameters.AddWithValue("@ReservationType", r.ReservationType);
        command.Parameters.AddWithValue("@RequirementsDate", (object?)ToCalendarDate(r.RequirementsDate) ?? DBNull.Value);
        command.Parameters.AddWithValue("@ProjectDefinition", r.ProjectDefinition);
        command.Parameters.AddWithValue("@WbsElement", r.WbsElement);
        command.Parameters.AddWithValue("@Network", r.Network);
        command.Parameters.AddWithValue("@Activity", r.Activity);
        command.Parameters.AddWithValue("@Material", r.Material);
        command.Parameters.AddWithValue("@MaterialText", r.MaterialText);
        command.Parameters.AddWithValue("@Plant", r.Plant);
        command.Parameters.AddWithValue("@StorageLocation", r.StorageLocation);
        command.Parameters.AddWithValue("@RequirementQuantity", (object?)r.RequirementQuantity ?? DBNull.Value);
        command.Parameters.AddWithValue("@UnitOfEntry", r.UnitOfEntry);
        command.Parameters.AddWithValue("@ItemCategory", r.ItemCategory);
        command.Parameters.AddWithValue("@PriceUnit", (object?)r.PriceUnit ?? DBNull.Value);
        command.Parameters.AddWithValue("@Price", (object?)r.Price ?? DBNull.Value);
        command.Parameters.AddWithValue("@Currency", r.Currency);
        command.Parameters.AddWithValue("@GlAccount", r.GlAccount);
        command.Parameters.AddWithValue("@ProfitCenter", r.ProfitCenter);
        command.Parameters.AddWithValue("@MovementAllowed", r.MovementAllowed);
        command.Parameters.AddWithValue("@QuantityWithdrawn", (object?)r.QuantityWithdrawn ?? DBNull.Value);
        command.Parameters.AddWithValue("@IsDeleted", r.IsDeleted);
        command.Parameters.AddWithValue("@StagingDate", DateTime.Now.Date);

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    // RequirementsDate is a plain date in SAP (RESB-BDTER) that the service turns into a timestamp at local midnight,
    // so it arrives in UTC a few hours early - 10.04.2025 comes back as 2025-04-09T21:00Z. Rounding to the nearest
    // day gives back the SAP date for any offset under twelve hours.
    private static DateTime? ToCalendarDate(DateTime? value) => value?.AddHours(12).Date;
}
