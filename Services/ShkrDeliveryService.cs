using System.Net.Http.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrDeliveryService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrDeliveryService> logger)
{
    public const string ShkrSapClientName = "ShkrSapDelivery";

    private const int PageSize = 500;

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    public static string BuildLastUpdateFilter(DateTime lastUpdateFrom) =>
        $"LastUpdateDateTime ge datetime'{lastUpdateFrom.Date:yyyy-MM-dd'T'HH:mm:ss}'";

    public async Task<List<DeliveryHeader>> GetChangedDeliveriesAsync(
        DateTime lastUpdateFrom, CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var filter = BuildLastUpdateFilter(lastUpdateFrom);

        var all = new List<DeliveryHeader>();
        var skip = 0;

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var requestUri =
                $"/sap/opu/odata/SAP/ZSD_DELIVERY_SRV/DLVHeaderSet?sap-client={_options.ShkrSapClient}" +
                $"&$filter={Uri.EscapeDataString(filter)}&$expand=Lines&$top={PageSize}&$skip={skip}";

            using var response = await client.GetAsync(requestUri, cancellationToken);

            if (!response.IsSuccessStatusCode)
            {
                var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
                logger.LogError(
                    "SAP Delivery call to {RequestUri} failed with status {StatusCode}: {SapErrorMessage}",
                    requestUri, (int)response.StatusCode, sapErrorMessage);
                throw new HttpRequestException(
                    $"SAP call to {requestUri} failed with status {(int)response.StatusCode} ({response.StatusCode}): {sapErrorMessage}");
            }

            var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<ODataResultSet<DeliveryHeader>>>(cancellationToken)
                ?? throw new InvalidOperationException($"SAP call to {requestUri} returned an empty response body.");

            var page = envelope.D.Results;
            all.AddRange(page);

            if (page.Count < PageSize)
            {
                break;
            }

            skip += PageSize;
        }

        return all;
    }

    public async Task<SyncResult> FetchSapDataToStagingTableAsync(DateTime lastUpdateFrom, CancellationToken cancellationToken = default)
    {
        var effectiveDate = lastUpdateFrom.Date;

        var deliveries = await GetChangedDeliveriesAsync(effectiveDate, cancellationToken);

        logger.LogInformation(
            "Delivery sync for records created or changed since {Date:yyyy-MM-dd}, SAP filter {Filter}: {Count} delivery(ies) fetched, staging.",
            effectiveDate, BuildLastUpdateFilter(effectiveDate), deliveries.Count);

        var staged = 0;
        var errors = new List<string>();

        var orderedDeliveries = deliveries
            .OrderBy(d => d.DeliveryNumber.Length)
            .ThenBy(d => d.DeliveryNumber, StringComparer.Ordinal)
            .ToList();

        foreach (var delivery in orderedDeliveries)
        {
            try
            {
                await SaveDelivery(delivery, cancellationToken);
                staged++;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Delivery sync failed to stage DeliveryNumber {DeliveryNumber}.",
                    delivery.DeliveryNumber);
                errors.Add($"{delivery.DeliveryNumber}: {ex.Message}");
            }
        }

        return new SyncResult(deliveries.Count, staged, errors.Count, errors);
    }

    public async Task SaveDelivery(DeliveryHeader delivery, CancellationToken cancellationToken = default)
    {
        var now = DateTime.Now;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);

        try
        {
            var hdrRecordId = await SaveHeader(connection, transaction, delivery, now, cancellationToken);
            await SaveLines(connection, transaction, delivery.DeliveryNumber, hdrRecordId, delivery.Lines.Results, now, cancellationToken);

            await transaction.CommitAsync(cancellationToken);
        }
        catch
        {
            await transaction.RollbackAsync(cancellationToken);
            throw;
        }
    }

    private static async Task<long> SaveHeader(
        SqlConnection connection, SqlTransaction transaction, DeliveryHeader d, DateTime now,
        CancellationToken cancellationToken)
    {
        const string insertSql = """
            INSERT INTO dbo.xx_delivery_hdr_stg_tbl_ib
                (DeliveryNumber, CreationDateTime, LastUpdateDateTime, CreatedByName, DocumentDate,
                 DocumentStatus, ShipToPartyNumber, ShippingPoint, ShippingPointName, Date_to, Date_from,
                 DeliveryType, DeliveryTypeDesc, IsSaleDelivery, IsReturnDelivery, IsFullyInvoiced,
                 BillingStatus, ItemChangeDate, GoodsMovementStatus, GoodsMovementStatusDesc,
                 OverallPickingStatus, OverallPickingStatusDesc, WarehouseActivityStatus,
                 WarehouseActivityStatusDesc, BillingStatusDesc,
                 operation_flag, process_status, creation_date, last_update_date)
            OUTPUT INSERTED.record_id
            VALUES
                (@DeliveryNumber, @CreationDateTime, @LastUpdateDateTime, @CreatedByName, @DocumentDate,
                 @DocumentStatus, @ShipToPartyNumber, @ShippingPoint, @ShippingPointName, @DateTo, @DateFrom,
                 @DeliveryType, @DeliveryTypeDesc, @IsSaleDelivery, @IsReturnDelivery, @IsFullyInvoiced,
                 @BillingStatus, @ItemChangeDate, @GoodsMovementStatus, @GoodsMovementStatusDesc,
                 @OverallPickingStatus, @OverallPickingStatusDesc, @WarehouseActivityStatus,
                 @WarehouseActivityStatusDesc, @BillingStatusDesc,
                 @OperationFlag, @ProcessStatus, @StagingCreationDate, @StagingLastUpdateDate)
            """;

        await using var command = new SqlCommand(insertSql, connection, transaction);
        command.Parameters.AddWithValue("@DeliveryNumber", d.DeliveryNumber);
        command.Parameters.AddWithValue("@CreationDateTime", (object?)d.CreationDateTime ?? DBNull.Value);
        command.Parameters.AddWithValue("@LastUpdateDateTime", (object?)d.LastUpdateDateTime ?? DBNull.Value);
        command.Parameters.AddWithValue("@CreatedByName", d.CreatedByName);
        command.Parameters.AddWithValue("@DocumentDate", (object?)d.DocumentDate ?? DBNull.Value);
        command.Parameters.AddWithValue("@DocumentStatus", d.DocumentStatus);
        command.Parameters.AddWithValue("@ShipToPartyNumber", d.ShipToPartyNumber);
        command.Parameters.AddWithValue("@ShippingPoint", d.ShippingPoint);
        command.Parameters.AddWithValue("@ShippingPointName", d.ShippingPointName);
        command.Parameters.AddWithValue("@DateTo", d.DateTo);
        command.Parameters.AddWithValue("@DateFrom", d.DateFrom);
        command.Parameters.AddWithValue("@DeliveryType", d.DeliveryType);
        command.Parameters.AddWithValue("@DeliveryTypeDesc", d.DeliveryTypeDesc);
        command.Parameters.AddWithValue("@IsSaleDelivery", d.IsSaleDelivery);
        command.Parameters.AddWithValue("@IsReturnDelivery", d.IsReturnDelivery);
        command.Parameters.AddWithValue("@IsFullyInvoiced", d.IsFullyInvoiced);
        command.Parameters.AddWithValue("@BillingStatus", d.BillingStatus);
        command.Parameters.AddWithValue("@ItemChangeDate", d.ItemChangeDate);
        command.Parameters.AddWithValue("@GoodsMovementStatus", d.GoodsMovementStatus);
        command.Parameters.AddWithValue("@GoodsMovementStatusDesc", d.GoodsMovementStatusDesc);
        command.Parameters.AddWithValue("@OverallPickingStatus", d.OverallPickingStatus);
        command.Parameters.AddWithValue("@OverallPickingStatusDesc", d.OverallPickingStatusDesc);
        command.Parameters.AddWithValue("@WarehouseActivityStatus", d.WarehouseActivityStatus);
        command.Parameters.AddWithValue("@WarehouseActivityStatusDesc", d.WarehouseActivityStatusDesc);
        command.Parameters.AddWithValue("@BillingStatusDesc", d.BillingStatusDesc);
        command.Parameters.AddWithValue("@OperationFlag", "I");
        command.Parameters.AddWithValue("@ProcessStatus", "N");
        command.Parameters.AddWithValue("@StagingLastUpdateDate", now.Date);
        command.Parameters.AddWithValue("@StagingCreationDate", now.Date);

        return (long)(await command.ExecuteScalarAsync(cancellationToken))!;
    }

    private static async Task SaveLines(
        SqlConnection connection, SqlTransaction transaction, string deliveryNumber, long hdrRecordId,
        IReadOnlyList<DeliveryLine> lines, DateTime now, CancellationToken cancellationToken)
    {
        const string insertSql = """
            INSERT INTO dbo.xx_delivery_line_stg_tbl_ib
                (hdr_record_id, DeliveryNumber, LineNumber, SalesOrderNumber, Material, ItemDescription, DeliveredQuantity,
                 PickedQuantity, Uom, Plant, WarehouseNo, Quantity, Status, WbsElement, SalesOrderItem,
                 OriginalDeliveryNumber, OriginalDeliveryItem, ItemChangeDate, PickingStatus, PickingStatusDesc,
                 WarehouseActivityStatus, WarehouseActivityStatusDesc, GoodsMovementStatus,
                 GoodsMovementStatusDesc, BillingStatus, BillingStatusDesc,
                 operation_flag, process_status, creation_date, last_update_date)
            VALUES
                (@HdrRecordId, @DeliveryNumber, @LineNumber, @SalesOrderNumber, @Material, @ItemDescription, @DeliveredQuantity,
                 @PickedQuantity, @Uom, @Plant, @WarehouseNo, @Quantity, @Status, @WbsElement, @SalesOrderItem,
                 @OriginalDeliveryNumber, @OriginalDeliveryItem, @ItemChangeDate, @PickingStatus, @PickingStatusDesc,
                 @WarehouseActivityStatus, @WarehouseActivityStatusDesc, @GoodsMovementStatus,
                 @GoodsMovementStatusDesc, @BillingStatus, @BillingStatusDesc,
                 @OperationFlag, @ProcessStatus, @StagingCreationDate, @StagingLastUpdateDate)
            """;

        var orderedLines = lines
            .OrderBy(l => l.LineNumber.Length)
            .ThenBy(l => l.LineNumber, StringComparer.Ordinal);

        foreach (var line in orderedLines)
        {
            await using var command = new SqlCommand(insertSql, connection, transaction);
            command.Parameters.AddWithValue("@HdrRecordId", hdrRecordId);
            command.Parameters.AddWithValue("@DeliveryNumber", deliveryNumber);
            command.Parameters.AddWithValue("@LineNumber", line.LineNumber);
            command.Parameters.AddWithValue("@SalesOrderNumber", line.SalesOrderNumber);
            command.Parameters.AddWithValue("@Material", line.Material);
            command.Parameters.AddWithValue("@ItemDescription", line.ItemDescription);
            command.Parameters.AddWithValue("@DeliveredQuantity", (object?)line.DeliveredQuantity ?? DBNull.Value);
            command.Parameters.AddWithValue("@PickedQuantity", (object?)line.PickedQuantity ?? DBNull.Value);
            command.Parameters.AddWithValue("@Uom", line.Uom);
            command.Parameters.AddWithValue("@Plant", line.Plant);
            command.Parameters.AddWithValue("@WarehouseNo", line.WarehouseNo);
            command.Parameters.AddWithValue("@Quantity", (object?)line.Quantity ?? DBNull.Value);
            command.Parameters.AddWithValue("@Status", line.Status);
            command.Parameters.AddWithValue("@WbsElement", line.WbsElement);
            command.Parameters.AddWithValue("@SalesOrderItem", line.SalesOrderItem);
            command.Parameters.AddWithValue("@OriginalDeliveryNumber", line.OriginalDeliveryNumber);
            command.Parameters.AddWithValue("@OriginalDeliveryItem", line.OriginalDeliveryItem);
            command.Parameters.AddWithValue("@ItemChangeDate", line.ItemChangeDate);
            command.Parameters.AddWithValue("@PickingStatus", line.PickingStatus);
            command.Parameters.AddWithValue("@PickingStatusDesc", line.PickingStatusDesc);
            command.Parameters.AddWithValue("@WarehouseActivityStatus", line.WarehouseActivityStatus);
            command.Parameters.AddWithValue("@WarehouseActivityStatusDesc", line.WarehouseActivityStatusDesc);
            command.Parameters.AddWithValue("@GoodsMovementStatus", line.GoodsMovementStatus);
            command.Parameters.AddWithValue("@GoodsMovementStatusDesc", line.GoodsMovementStatusDesc);
            command.Parameters.AddWithValue("@BillingStatus", line.BillingStatus);
            command.Parameters.AddWithValue("@BillingStatusDesc", line.BillingStatusDesc);
            command.Parameters.AddWithValue("@OperationFlag", "I");
            command.Parameters.AddWithValue("@ProcessStatus", "N");
            command.Parameters.AddWithValue("@StagingLastUpdateDate", now.Date);
            command.Parameters.AddWithValue("@StagingCreationDate", now.Date);

            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }
}
