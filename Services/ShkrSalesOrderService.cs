using System.Net.Http.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrSalesOrderService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrSalesOrderService> logger)
{
    public const string ShkrSapClientName = "ShkrSapSalesOrder";

    private const int PageSize = 500;

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    public static string BuildLastUpdateFilter(DateTime lastUpdateFrom) =>
        $"LastUpdateDateTime ge datetime'{lastUpdateFrom.Date:yyyy-MM-dd'T'HH:mm:ss}'";

    public async Task<List<SalesOrderHeader>> GetChangedSalesOrdersAsync(
        DateTime lastUpdateFrom, CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var filter = BuildLastUpdateFilter(lastUpdateFrom);

        var all = new List<SalesOrderHeader>();
        var skip = 0;

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var requestUri =
                $"/sap/opu/odata/SAP/ZSD_SALEORDER_SRV/SOHeaderSet?sap-client={_options.ShkrSapClient}" +
                $"&$filter={Uri.EscapeDataString(filter)}&$expand=Lines&$top={PageSize}&$skip={skip}";

            using var response = await client.GetAsync(requestUri, cancellationToken);

            if (!response.IsSuccessStatusCode)
            {
                var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
                logger.LogError(
                    "SAP Sales order call to {RequestUri} failed with status {StatusCode}: {SapErrorMessage}",
                    requestUri, (int)response.StatusCode, sapErrorMessage);
                throw new HttpRequestException(
                    $"SAP call to {requestUri} failed with status {(int)response.StatusCode} ({response.StatusCode}): {sapErrorMessage}");
            }

            var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<ODataResultSet<SalesOrderHeader>>>(cancellationToken)
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

        var orders = await GetChangedSalesOrdersAsync(effectiveDate, cancellationToken);

        logger.LogInformation(
            "Sales order sync for records created or changed since {Date:yyyy-MM-dd}, SAP filter {Filter}: {Count} order(s) fetched, staging.",
            effectiveDate, BuildLastUpdateFilter(effectiveDate), orders.Count);

        var staged = 0;
        var errors = new List<string>();

        var orderedOrders = orders
            .OrderBy(o => o.SalesDocumentNumber.Length)
            .ThenBy(o => o.SalesDocumentNumber, StringComparer.Ordinal)
            .ToList();

        foreach (var order in orderedOrders)
        {
            try
            {
                await SaveSalesOrder(order, cancellationToken);
                staged++;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Sales order sync failed to stage SalesDocumentNumber {SalesDocumentNumber}.",
                    order.SalesDocumentNumber);
                errors.Add($"{order.SalesDocumentNumber}: {ex.Message}");
            }
        }

        return new SyncResult(orders.Count, staged, errors.Count, errors);
    }

    public async Task SaveSalesOrder(SalesOrderHeader order, CancellationToken cancellationToken = default)
    {
        var now = DateTime.Now;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);

        try
        {
            var hdrRecordId = await SaveHeader(connection, transaction, order, now, cancellationToken);
            await SaveLines(connection, transaction, order.SalesDocumentNumber, hdrRecordId, order.Lines.Results, now, cancellationToken);

            await transaction.CommitAsync(cancellationToken);
        }
        catch
        {
            await transaction.RollbackAsync(cancellationToken);
            throw;
        }
    }

    private static async Task<long> SaveHeader(
        SqlConnection connection, SqlTransaction transaction, SalesOrderHeader o, DateTime now,
        CancellationToken cancellationToken)
    {
        const string insertSql = """
            INSERT INTO dbo.xx_salesorder_hdr_stg_tbl_ib
                (CreationDateTime, DocumentDate, IsReturnOrder, IsSaleOrder, ItemChangeDate,
                 LastUpdateDateTime, SalesDocumentNumber, SalesOrg, SoldToPartyNumber, AdvanceAmt,
                 AdvancePercentage, C4CProjectName, C4CProjectNumber, CreatedByName, Currency, CustomerName,
                 Date_from, Date_to, DiscountAmount, DistributionChannel, Division, DocumentStatus,
                 DownPaymentCharges, DownPaymentPercentage, ExchangeRate, ExpectedAwardDate,
                 ExpectedDeliveryDate, GrossPrice, InstallationCharges, Message, NetValueWithoutTax,
                 NetValueWithTax, OrderReason, OrderType, OrderTypeDesc, PaymentTerms, ProgressUpdateDate,
                 RetentionAmt, RetentionPercentage, SalesGroup, SalesOffice, SalesPersonCommission,
                 SalesPersonName, SalesPersonNumber, ShipToPartyNumber, VatAmount, VatPercentage, Version,
                 operation_flag, process_status, creation_date, last_update_date)
            OUTPUT INSERTED.record_id
            VALUES
                (@CreationDateTime, @DocumentDate, @IsReturnOrder, @IsSaleOrder, @ItemChangeDate,
                 @LastUpdateDateTime, @SalesDocumentNumber, @SalesOrg, @SoldToPartyNumber, @AdvanceAmt,
                 @AdvancePercentage, @C4CProjectName, @C4CProjectNumber, @CreatedByName, @Currency, @CustomerName,
                 @DateFrom, @DateTo, @DiscountAmount, @DistributionChannel, @Division, @DocumentStatus,
                 @DownPaymentCharges, @DownPaymentPercentage, @ExchangeRate, @ExpectedAwardDate,
                 @ExpectedDeliveryDate, @GrossPrice, @InstallationCharges, @Message, @NetValueWithoutTax,
                 @NetValueWithTax, @OrderReason, @OrderType, @OrderTypeDesc, @PaymentTerms, @ProgressUpdateDate,
                 @RetentionAmt, @RetentionPercentage, @SalesGroup, @SalesOffice, @SalesPersonCommission,
                 @SalesPersonName, @SalesPersonNumber, @ShipToPartyNumber, @VatAmount, @VatPercentage, @Version,
                 @OperationFlag, @ProcessStatus, @StagingCreationDate, @StagingLastUpdateDate)
            """;

        await using var command = new SqlCommand(insertSql, connection, transaction);
        command.Parameters.AddWithValue("@CreationDateTime", (object?)o.CreationDateTime ?? DBNull.Value);
        command.Parameters.AddWithValue("@DocumentDate", (object?)o.DocumentDate ?? DBNull.Value);
        command.Parameters.AddWithValue("@IsReturnOrder", o.IsReturnOrder);
        command.Parameters.AddWithValue("@IsSaleOrder", o.IsSaleOrder);
        command.Parameters.AddWithValue("@ItemChangeDate", o.ItemChangeDate);
        command.Parameters.AddWithValue("@LastUpdateDateTime", (object?)o.LastUpdateDateTime ?? DBNull.Value);
        command.Parameters.AddWithValue("@SalesDocumentNumber", o.SalesDocumentNumber);
        command.Parameters.AddWithValue("@SalesOrg", o.SalesOrg);
        command.Parameters.AddWithValue("@SoldToPartyNumber", o.SoldToPartyNumber);
        command.Parameters.AddWithValue("@AdvanceAmt", (object?)o.AdvanceAmt ?? DBNull.Value);
        command.Parameters.AddWithValue("@AdvancePercentage", (object?)o.AdvancePercentage ?? DBNull.Value);
        command.Parameters.AddWithValue("@C4CProjectName", o.C4CProjectName);
        command.Parameters.AddWithValue("@C4CProjectNumber", o.C4CProjectNumber);
        command.Parameters.AddWithValue("@CreatedByName", o.CreatedByName);
        command.Parameters.AddWithValue("@Currency", o.Currency);
        command.Parameters.AddWithValue("@CustomerName", o.CustomerName);
        command.Parameters.AddWithValue("@DateFrom", o.DateFrom);
        command.Parameters.AddWithValue("@DateTo", o.DateTo);
        command.Parameters.AddWithValue("@DiscountAmount", (object?)o.DiscountAmount ?? DBNull.Value);
        command.Parameters.AddWithValue("@DistributionChannel", o.DistributionChannel);
        command.Parameters.AddWithValue("@Division", o.Division);
        command.Parameters.AddWithValue("@DocumentStatus", o.DocumentStatus);
        command.Parameters.AddWithValue("@DownPaymentCharges", (object?)o.DownPaymentCharges ?? DBNull.Value);
        command.Parameters.AddWithValue("@DownPaymentPercentage", (object?)o.DownPaymentPercentage ?? DBNull.Value);
        command.Parameters.AddWithValue("@ExchangeRate", (object?)o.ExchangeRate ?? DBNull.Value);
        command.Parameters.AddWithValue("@ExpectedAwardDate", (object?)o.ExpectedAwardDate ?? DBNull.Value);
        command.Parameters.AddWithValue("@ExpectedDeliveryDate", (object?)o.ExpectedDeliveryDate ?? DBNull.Value);
        command.Parameters.AddWithValue("@GrossPrice", (object?)o.GrossPrice ?? DBNull.Value);
        command.Parameters.AddWithValue("@InstallationCharges", (object?)o.InstallationCharges ?? DBNull.Value);
        command.Parameters.AddWithValue("@Message", o.Message);
        command.Parameters.AddWithValue("@NetValueWithoutTax", (object?)o.NetValueWithoutTax ?? DBNull.Value);
        command.Parameters.AddWithValue("@NetValueWithTax", (object?)o.NetValueWithTax ?? DBNull.Value);
        command.Parameters.AddWithValue("@OrderReason", o.OrderReason);
        command.Parameters.AddWithValue("@OrderType", o.OrderType);
        command.Parameters.AddWithValue("@OrderTypeDesc", o.OrderTypeDesc);
        command.Parameters.AddWithValue("@PaymentTerms", o.PaymentTerms);
        command.Parameters.AddWithValue("@ProgressUpdateDate", (object?)o.ProgressUpdateDate ?? DBNull.Value);
        command.Parameters.AddWithValue("@RetentionAmt", (object?)o.RetentionAmt ?? DBNull.Value);
        command.Parameters.AddWithValue("@RetentionPercentage", (object?)o.RetentionPercentage ?? DBNull.Value);
        command.Parameters.AddWithValue("@SalesGroup", o.SalesGroup);
        command.Parameters.AddWithValue("@SalesOffice", o.SalesOffice);
        command.Parameters.AddWithValue("@SalesPersonCommission", (object?)o.SalesPersonCommission ?? DBNull.Value);
        command.Parameters.AddWithValue("@SalesPersonName", o.SalesPersonName);
        command.Parameters.AddWithValue("@SalesPersonNumber", o.SalesPersonNumber);
        command.Parameters.AddWithValue("@ShipToPartyNumber", o.ShipToPartyNumber);
        command.Parameters.AddWithValue("@VatAmount", (object?)o.VatAmount ?? DBNull.Value);
        command.Parameters.AddWithValue("@VatPercentage", (object?)o.VatPercentage ?? DBNull.Value);
        command.Parameters.AddWithValue("@Version", o.Version);
        command.Parameters.AddWithValue("@OperationFlag", "I");
        command.Parameters.AddWithValue("@ProcessStatus", "N");
        command.Parameters.AddWithValue("@StagingLastUpdateDate", now.Date);
        command.Parameters.AddWithValue("@StagingCreationDate", now.Date);

        return (long)(await command.ExecuteScalarAsync(cancellationToken))!;
    }

    private static async Task SaveLines(
        SqlConnection connection, SqlTransaction transaction, string salesDocumentNumber, long hdrRecordId,
        IReadOnlyList<SalesOrderLine> lines, DateTime now, CancellationToken cancellationToken)
    {
        const string insertSql = """
            INSERT INTO dbo.xx_salesorder_line_stg_tbl_ib
                (hdr_record_id, ItemChangeDate, SalesDocumentNumber, LineNumber, Material, ItemDescription, WbsElement,
                 WbsDescription, ProjectCode, ProjectDescription, Quantity, Uom, Plant, StorageLocation,
                 GrossUnitPrice, TotalGrossAmount, DiscPercentage, DiscAmount, TotalDiscAmount, VatPercentage,
                 TotalVatAmount, NetValueWithTax, AdvancePercentage, AdvanceAmt, InstallationCharges,
                 DownPaymentPercentage, DownPaymentCharges, ReferenceDocument, ReferenceDocumentItem,
                 ReferenceDocumentCategory, OriginalSalesOrder, OriginalSalesOrderItem, RejectionReason,
                 QuotationNumber, QuotationItem,
                 operation_flag, process_status, creation_date, last_update_date)
            VALUES
                (@HdrRecordId, @ItemChangeDate, @SalesDocumentNumber, @LineNumber, @Material, @ItemDescription, @WbsElement,
                 @WbsDescription, @ProjectCode, @ProjectDescription, @Quantity, @Uom, @Plant, @StorageLocation,
                 @GrossUnitPrice, @TotalGrossAmount, @DiscPercentage, @DiscAmount, @TotalDiscAmount, @VatPercentage,
                 @TotalVatAmount, @NetValueWithTax, @AdvancePercentage, @AdvanceAmt, @InstallationCharges,
                 @DownPaymentPercentage, @DownPaymentCharges, @ReferenceDocument, @ReferenceDocumentItem,
                 @ReferenceDocumentCategory, @OriginalSalesOrder, @OriginalSalesOrderItem, @RejectionReason,
                 @QuotationNumber, @QuotationItem,
                 @OperationFlag, @ProcessStatus, @StagingCreationDate, @StagingLastUpdateDate)
            """;

        var orderedLines = lines
            .OrderBy(l => l.LineNumber.Length)
            .ThenBy(l => l.LineNumber, StringComparer.Ordinal);

        foreach (var line in orderedLines)
        {
            await using var command = new SqlCommand(insertSql, connection, transaction);
            command.Parameters.AddWithValue("@HdrRecordId", hdrRecordId);
            command.Parameters.AddWithValue("@ItemChangeDate", line.ItemChangeDate);
            command.Parameters.AddWithValue("@SalesDocumentNumber", salesDocumentNumber);
            command.Parameters.AddWithValue("@LineNumber", line.LineNumber);
            command.Parameters.AddWithValue("@Material", line.Material);
            command.Parameters.AddWithValue("@ItemDescription", line.ItemDescription);
            command.Parameters.AddWithValue("@WbsElement", line.WbsElement);
            command.Parameters.AddWithValue("@WbsDescription", line.WbsDescription);
            command.Parameters.AddWithValue("@ProjectCode", line.ProjectCode);
            command.Parameters.AddWithValue("@ProjectDescription", line.ProjectDescription);
            command.Parameters.AddWithValue("@Quantity", (object?)line.Quantity ?? DBNull.Value);
            command.Parameters.AddWithValue("@Uom", line.Uom);
            command.Parameters.AddWithValue("@Plant", line.Plant);
            command.Parameters.AddWithValue("@StorageLocation", line.StorageLocation);
            command.Parameters.AddWithValue("@GrossUnitPrice", (object?)line.GrossUnitPrice ?? DBNull.Value);
            command.Parameters.AddWithValue("@TotalGrossAmount", (object?)line.TotalGrossAmount ?? DBNull.Value);
            command.Parameters.AddWithValue("@DiscPercentage", (object?)line.DiscPercentage ?? DBNull.Value);
            command.Parameters.AddWithValue("@DiscAmount", (object?)line.DiscAmount ?? DBNull.Value);
            command.Parameters.AddWithValue("@TotalDiscAmount", (object?)line.TotalDiscAmount ?? DBNull.Value);
            command.Parameters.AddWithValue("@VatPercentage", (object?)line.VatPercentage ?? DBNull.Value);
            command.Parameters.AddWithValue("@TotalVatAmount", (object?)line.TotalVatAmount ?? DBNull.Value);
            command.Parameters.AddWithValue("@NetValueWithTax", (object?)line.NetValueWithTax ?? DBNull.Value);
            command.Parameters.AddWithValue("@AdvancePercentage", (object?)line.AdvancePercentage ?? DBNull.Value);
            command.Parameters.AddWithValue("@AdvanceAmt", (object?)line.AdvanceAmt ?? DBNull.Value);
            command.Parameters.AddWithValue("@InstallationCharges", (object?)line.InstallationCharges ?? DBNull.Value);
            command.Parameters.AddWithValue("@DownPaymentPercentage", (object?)line.DownPaymentPercentage ?? DBNull.Value);
            command.Parameters.AddWithValue("@DownPaymentCharges", (object?)line.DownPaymentCharges ?? DBNull.Value);
            command.Parameters.AddWithValue("@ReferenceDocument", line.ReferenceDocument);
            command.Parameters.AddWithValue("@ReferenceDocumentItem", line.ReferenceDocumentItem);
            command.Parameters.AddWithValue("@ReferenceDocumentCategory", line.ReferenceDocumentCategory);
            command.Parameters.AddWithValue("@OriginalSalesOrder", line.OriginalSalesOrder);
            command.Parameters.AddWithValue("@OriginalSalesOrderItem", line.OriginalSalesOrderItem);
            command.Parameters.AddWithValue("@RejectionReason", line.RejectionReason);
            command.Parameters.AddWithValue("@QuotationNumber", line.QuotationNumber);
            command.Parameters.AddWithValue("@QuotationItem", line.QuotationItem);
            command.Parameters.AddWithValue("@OperationFlag", "I");
            command.Parameters.AddWithValue("@ProcessStatus", "N");
            command.Parameters.AddWithValue("@StagingLastUpdateDate", now.Date);
            command.Parameters.AddWithValue("@StagingCreationDate", now.Date);

            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }
}
