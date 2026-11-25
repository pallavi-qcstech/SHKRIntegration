using System.Net.Http.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Extensions;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrInvoiceService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrInvoiceService> logger)
{
    public const string ShkrSapClientName = "ShkrSapInvoice";

    private const int PageSize = 500;

    private const string HeaderTable = "dbo.xx_invoice_hdr_stg_tbl_ib";
    private const string LineTable = "dbo.xx_invoice_line_stg_tbl_ib";

    private readonly ShkrSapApiOptions _options = shkrSapOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    public static string BuildLastUpdateFilter(DateTime lastUpdateFrom) =>
        $"LastUpdateDateTime ge datetime'{lastUpdateFrom.Date:yyyy-MM-dd'T'HH:mm:ss}'";

    public async Task<List<InvoiceHeader>> GetChangedInvoicesAsync(
        DateTime lastUpdateFrom, CancellationToken cancellationToken = default)
    {
        var client = httpClientFactory.CreateClient(ShkrSapClientName);
        var filter = BuildLastUpdateFilter(lastUpdateFrom);

        var all = new List<InvoiceHeader>();
        var skip = 0;

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var requestUri =
                $"/sap/opu/odata/sap/ZSD_INVOICE_SRV_SRV/INVHeaderSet?sap-client={_options.ShkrSapClient}" +
                $"&$filter={Uri.EscapeDataString(filter)}&$expand=Lines&$top={PageSize}&$skip={skip}&$format=json";

            using var response = await client.GetAsync(requestUri, cancellationToken);

            if (!response.IsSuccessStatusCode)
            {
                var sapErrorMessage = await response.ReadSapErrorMessageAsync(cancellationToken);
                logger.LogError(
                    "SAP Invoice call to {RequestUri} failed with status {StatusCode}: {SapErrorMessage}",
                    requestUri, (int)response.StatusCode, sapErrorMessage);
                throw new HttpRequestException(
                    $"SAP call to {requestUri} failed with status {(int)response.StatusCode} ({response.StatusCode}): {sapErrorMessage}");
            }

            var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<ODataResultSet<InvoiceHeader>>>(cancellationToken)
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
        var effectiveFrom = lastUpdateFrom.Date;

        var invoices = await GetChangedInvoicesAsync(effectiveFrom, cancellationToken);

        logger.LogInformation(
            "Invoice sync for invoices created or changed since {From:yyyy-MM-dd}, SAP filter {Filter}: {Count} invoice(s) fetched, staging.",
            effectiveFrom, BuildLastUpdateFilter(effectiveFrom), invoices.Count);

        var staged = 0;
        var errors = new List<string>();

        var orderedInvoices = invoices
            .OrderBy(i => i.InvoiceNumber.Length)
            .ThenBy(i => i.InvoiceNumber, StringComparer.Ordinal)
            .ToList();

        foreach (var invoice in orderedInvoices)
        {
            try
            {
                await SaveInvoice(invoice, cancellationToken);
                staged++;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Invoice sync failed to stage InvoiceNumber {InvoiceNumber}.",
                    invoice.InvoiceNumber);
                errors.Add($"{invoice.InvoiceNumber}: {ex.Message}");
            }
        }

        logger.LogInformation(
            "Invoice sync since {From:yyyy-MM-dd} finished: {Fetched} fetched, {Staged} staged, {Failed} failed.",
            effectiveFrom, invoices.Count, staged, errors.Count);

        return new SyncResult(invoices.Count, staged, errors.Count, errors);
    }

    public async Task SaveInvoice(InvoiceHeader invoice, CancellationToken cancellationToken = default)
    {
        var now = DateTime.Now;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);

        try
        {
            var hdrRecordId = await InsertHeader(connection, transaction, invoice, now, cancellationToken);
            await InsertLines(connection, transaction, invoice.InvoiceNumber, hdrRecordId, invoice.Lines.Results, now, cancellationToken);

            await transaction.CommitAsync(cancellationToken);
        }
        catch
        {
            await transaction.RollbackAsync(cancellationToken);
            throw;
        }
    }

    private static async Task<long> InsertHeader(
        SqlConnection connection, SqlTransaction transaction, InvoiceHeader h, DateTime now,
        CancellationToken cancellationToken)
    {
        (string Column, object? Value)[] values =
        [
            .. HeaderValues(h),
            ("operation_flag", "I"),
            ("process_status", "N"),
            ("creation_date", now.Date),
            ("last_update_date", now.Date)
        ];

        await using var command = BuildInsert(connection, transaction, HeaderTable, values, "OUTPUT INSERTED.record_id");

        return (long)(await command.ExecuteScalarAsync(cancellationToken))!;
    }

    private static async Task InsertLines(
        SqlConnection connection, SqlTransaction transaction, string invoiceNumber, long hdrRecordId,
        IReadOnlyList<InvoiceLine> lines, DateTime now, CancellationToken cancellationToken)
    {
        foreach (var l in OrderLines(lines))
        {
            await InsertLine(connection, transaction, invoiceNumber, hdrRecordId, l, now, cancellationToken);
        }
    }

    private static async Task InsertLine(
        SqlConnection connection, SqlTransaction transaction, string invoiceNumber, long hdrRecordId,
        InvoiceLine l, DateTime now, CancellationToken cancellationToken)
    {
        (string Column, object? Value)[] values =
        [
            ("hdr_record_id", hdrRecordId),
            .. LineValues(invoiceNumber, l),
            ("operation_flag", "I"),
            ("process_status", "N"),
            ("creation_date", now.Date),
            ("last_update_date", now.Date)
        ];

        await using var command = BuildInsert(connection, transaction, LineTable, values, string.Empty);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static IEnumerable<InvoiceLine> OrderLines(IReadOnlyList<InvoiceLine> lines) =>
        lines
            .OrderBy(l => l.LineNumber.Length)
            .ThenBy(l => l.LineNumber, StringComparer.Ordinal);

    private static (string Column, object? Value)[] HeaderValues(InvoiceHeader h) =>
    [
        ("InvoiceNumber", h.InvoiceNumber),
        ("InvoiceDescription", h.InvoiceDescription),
        ("BillingType", h.BillingType),
        ("BillingTypeDesc", h.BillingTypeDesc),
        ("DocumentCategory", h.DocumentCategory),
        ("IsCreditMemo", h.IsCreditMemo),
        ("IsSaleInvoice", h.IsSaleInvoice),
        ("IsReturnInvoice", h.IsReturnInvoice),
        ("IsCancellation", h.IsCancellation),
        ("IsCancelled", h.IsCancelled),
        ("CancelledInvoice", h.CancelledInvoice),
        ("CustomerReference", h.CustomerReference),
        ("Assignment", h.Assignment),
        ("BillingDate", h.BillingDate),
        ("CreationDateTime", h.CreationDateTime),
        ("LastUpdateDateTime", h.LastUpdateDateTime),
        ("CreatedByName", h.CreatedByName),
        ("PayerNumber", h.PayerNumber),
        ("PayerName", h.PayerName),
        ("SoldToPartyNumber", h.SoldToPartyNumber),
        ("ShipToPartyNumber", h.ShipToPartyNumber),
        ("BillToPartyNumber", h.BillToPartyNumber),
        ("CustomerVatNumber", h.CustomerVatNumber),
        ("CustomerTaxNumber", h.CustomerTaxNumber),
        ("DestinationCountry", h.DestinationCountry),
        ("SalesOrg", h.SalesOrg),
        ("DistributionChannel", h.DistributionChannel),
        ("Division", h.Division),
        ("SalesDistrict", h.SalesDistrict),
        ("CompanyCode", h.CompanyCode),
        ("FiscalYear", h.FiscalYear),
        ("Currency", h.Currency),
        ("ExchangeRate", h.ExchangeRate),
        ("PaymentTerms", h.PaymentTerms),
        ("PaymentTermsDesc", h.PaymentTermsDesc),
        ("PaymentMethod", h.PaymentMethod),
        ("Incoterms1", h.Incoterms1),
        ("Incoterms2", h.Incoterms2),
        ("ShippingConditions", h.ShippingConditions),
        ("NetValue", h.NetValue),
        ("TaxAmount", h.TaxAmount),
        ("GrossValue", h.GrossValue),
        ("GrossPrice", h.GrossPrice),
        ("DiscountAmount", h.DiscountAmount),
        ("VatPercentage", h.VatPercentage),
        ("ItemCount", h.ItemCount),
        ("AccountingStatus", h.AccountingStatus),
        ("IsPostedToAccounting", h.IsPostedToAccounting),
        ("AccountingDocument", h.AccountingDocument)
    ];

    private static (string Column, object? Value)[] LineValues(string invoiceNumber, InvoiceLine l) =>
    [
        ("InvoiceNumber", invoiceNumber),
        ("LineNumber", l.LineNumber),
        ("ItemCategory", l.ItemCategory),
        ("Material", l.Material),
        ("ItemDescription", l.ItemDescription),
        ("MaterialGroup", l.MaterialGroup),
        ("ProductHierarchy", l.ProductHierarchy),
        ("Batch", l.Batch),
        ("BilledQuantity", l.BilledQuantity),
        ("Uom", l.Uom),
        ("BilledQuantityInBaseUnit", l.BilledQuantityInBaseUnit),
        ("BaseUnit", l.BaseUnit),
        ("Plant", l.Plant),
        ("StorageLocation", l.StorageLocation),
        ("ProfitCenter", l.ProfitCenter),
        ("NetAmount", l.NetAmount),
        ("TaxAmount", l.TaxAmount),
        ("NetValueWithTax", l.NetValueWithTax),
        ("Cost", l.Cost),
        ("TaxCode", l.TaxCode),
        ("GrossUnitPrice", l.GrossUnitPrice),
        ("TotalGrossAmount", l.TotalGrossAmount),
        ("DiscPercentage", l.DiscPercentage),
        ("DiscAmount", l.DiscAmount),
        ("TotalDiscAmount", l.TotalDiscAmount),
        ("VatPercentage", l.VatPercentage),
        ("TotalVatAmount", l.TotalVatAmount),
        ("NetWeight", l.NetWeight),
        ("GrossWeight", l.GrossWeight),
        ("WeightUnit", l.WeightUnit),
        ("Volume", l.Volume),
        ("VolumeUnit", l.VolumeUnit),
        ("DeliveryNumber", l.DeliveryNumber),
        ("DeliveryItem", l.DeliveryItem),
        ("SalesOrderNumber", l.SalesOrderNumber),
        ("SalesOrderItem", l.SalesOrderItem),
        ("ReturnOrderNumber", l.ReturnOrderNumber),
        ("ReturnOrderItem", l.ReturnOrderItem),
        ("WbsElement", l.WbsElement),
        ("WbsDescription", l.WbsDescription),
        ("ProjectCode", l.ProjectCode),
        ("ProjectDescription", l.ProjectDescription)
    ];

    private static SqlCommand BuildInsert(
        SqlConnection connection, SqlTransaction transaction, string table,
        (string Column, object? Value)[] values, string outputClause)
    {
        var columns = string.Join(", ", values.Select(v => $"[{v.Column}]"));
        var parameters = string.Join(", ", values.Select((_, i) => $"@p{i}"));
        var sql = $"INSERT INTO {table} ({columns}) {outputClause} VALUES ({parameters})";

        var command = new SqlCommand(sql, connection, transaction);
        AddValues(command, values);

        return command;
    }

    private static void AddValues(SqlCommand command, (string Column, object? Value)[] values)
    {
        for (var i = 0; i < values.Length; i++)
        {
            command.Parameters.AddWithValue($"@p{i}", values[i].Value ?? DBNull.Value);
        }
    }
}
