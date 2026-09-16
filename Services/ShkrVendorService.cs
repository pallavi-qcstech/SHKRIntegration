using System.Data;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SHKRIntegration.Models;
using SHKRIntegration.Options;

namespace SHKRIntegration.Services;

public sealed class ShkrVendorService(
    IHttpClientFactory httpClientFactory,
    IOptions<ShkrSapApiOptions> shkrSapOptions,
    IOptions<ShkrVendorOptions> vendorOptions,
    IOptions<ShkrDatabaseOptions> databaseOptions,
    ILogger<ShkrVendorService> logger) : BackgroundService
{
    public const string ShkrSapClientName = "ShkrSap";

    private readonly ShkrSapApiOptions _shkrSapOptions = shkrSapOptions.Value;
    private readonly ShkrVendorOptions _vendorOptions = vendorOptions.Value;
    private readonly ShkrDatabaseOptions _databaseOptions = databaseOptions.Value;

    private static readonly JsonSerializerOptions RequestSerializerOptions = new(JsonSerializerDefaults.General);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            var nextRun = DateTime.UtcNow.Date + _vendorOptions.DailyRunTimeUtc;
            if (nextRun <= DateTime.UtcNow)
            {
                nextRun = nextRun.AddDays(1);
            }

            try
            {
                await Task.Delay(nextRun - DateTime.UtcNow, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            try
            {
                logger.LogInformation("Daily vendor staging sync starting.");

                var lastRunEndDateUtc = await GetLastRunEndDateAsync(stoppingToken);
                var (startDate, endDate) = ResolveSyncDateRange(_vendorOptions, DateTime.UtcNow, lastRunEndDateUtc);

                var allVendors = await GetAllVendors(
                    startDate.ToString(SapDateFormat), endDate.ToString(SapDateFormat), stoppingToken);

                var errors = new List<string>();
                var processed = 0;

                foreach (var detail in allVendors.VendorDetailsSet.Results)
                {
                    stoppingToken.ThrowIfCancellationRequested();

                    if (!long.TryParse(detail.VendorId, out var numericVendorId))
                    {
                        logger.LogWarning("Vendor {VendorId}: VendorID is not numeric, skipped.", detail.VendorId);
                        errors.Add($"Vendor {detail.VendorId}: VendorID is not numeric, skipped.");
                        continue;
                    }

                    try
                    {
                        await SaveVendor(numericVendorId, detail, stoppingToken);
                        processed++;
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        logger.LogError(ex, "Vendor sync failed for VendorID {VendorId}.", detail.VendorId);
                        errors.Add($"Vendor {detail.VendorId}: {ex.Message}");
                    }
                }

                logger.LogInformation(
                    "Daily vendor staging sync completed: {Processed} processed, {Failed} failed.",
                    processed, errors.Count);

                await InsertRunRecordAsync(startDate, endDate, stoppingToken);

                await using (var storedProcedureConnection = new SqlConnection(_databaseOptions.ConnectionString))
                {
                    await storedProcedureConnection.OpenAsync(stoppingToken);

                    await using var promotionCommand = new SqlCommand("dbo.SHKR_INT_AddVendors", storedProcedureConnection)
                    {
                        CommandType = CommandType.StoredProcedure
                    };

                    await promotionCommand.ExecuteNonQueryAsync(stoppingToken);
                    logger.LogInformation("SHKR_INT_AddVendors executed.");
                }

                await LogStaleStagingErrorsAsync(stoppingToken);
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Daily vendor staging sync run failed.");
            }
        }
    }

    private const int StaleErrorThresholdDays = 7;
    private const string SapDateFormat = "yyyyMMdd";

    // Precedence: (1) the persisted watermark (last run's End_Date) as the new Start_Date, through
    // today; (2) on a genuine first-ever run (no watermark row exists yet), options.InitialLookbackDays
    // back from today.
    public static (DateTime StartDate, DateTime EndDate) ResolveSyncDateRange(
        ShkrVendorOptions options, DateTime utcNow, DateTime? lastRunEndDateUtc)
    {
        var endDate = utcNow.Date;
        var startDate = lastRunEndDateUtc?.Date ?? endDate.AddDays(-options.InitialLookbackDays);

        return (startDate, endDate);
    }

    // Reads the watermark left by the last run. Null means no run has ever completed successfully
    // yet, so ResolveSyncDateRange falls back to InitialLookbackDays.
    public async Task<DateTime?> GetLastRunEndDateAsync(CancellationToken cancellationToken = default)
    {
        const string sql = "SELECT TOP 1 RunEndDate FROM dbo.xx_vendor_sync_run_tbl_ib ORDER BY Id DESC";

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);

        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result as DateTime?;
    }

    // Advances the watermark. Called unconditionally once the SAP fetch + per-vendor staging loop
    // finish, regardless of individual vendor staging errors. A failed vendor stays retryable via
    // its own staging row; the watermark only tracks whether this run's fetch+staging pass
    // completed, not whether every vendor in it was promoted.
    public async Task InsertRunRecordAsync(DateTime runStartDate, DateTime runEndDate, CancellationToken cancellationToken = default)
    {
        const string sql = """
            INSERT INTO dbo.xx_vendor_sync_run_tbl_ib (RunStartDate, RunEndDate, CreatedDate)
            VALUES (@RunStartDate, @RunEndDate, @CreatedDate)
            """;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@RunStartDate", runStartDate);
        command.Parameters.AddWithValue("@RunEndDate", runEndDate);
        command.Parameters.AddWithValue("@CreatedDate", DateTime.Now);

        await command.ExecuteNonQueryAsync(cancellationToken);
        logger.LogInformation("Vendor sync watermark advanced to {RunEndDate:yyyy-MM-dd}.", runEndDate);
    }

    // Promotion rejections (e.g. the open country-code issue) have no scheduled retry — a row only
    // leaves ProcessStatus='E' if the same VendorID reappears in a future SAP fetch, or someone
    // manually resets it. This just surfaces rows that have been stuck a while so they aren't forgotten.
    public async Task<IReadOnlyList<long>> LogStaleStagingErrorsAsync(CancellationToken cancellationToken = default)
    {
        const string sql = """
            SELECT VendorID FROM dbo.xx_vendor_stg_tbl_ib
            WHERE ProcessStatus = 'E' AND LastUpdateDate <= @Threshold
            """;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@Threshold", DateTime.Now.AddDays(-StaleErrorThresholdDays));

        var staleVendorIds = new List<long>();
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                staleVendorIds.Add(reader.GetInt64(0));
            }
        }

        if (staleVendorIds.Count > 0)
        {
            logger.LogWarning(
                "{Count} vendor(s) have been stuck in ProcessStatus='E' in xx_vendor_stg_tbl_ib for " +
                "{ThresholdDays}+ days: {VendorIds}",
                staleVendorIds.Count, StaleErrorThresholdDays, string.Join(", ", staleVendorIds));
        }

        return staleVendorIds;
    }

    public async Task<VendorHeaderData> GetAllVendors(string startDate, string endDate, CancellationToken cancellationToken = default)
    {
        var requestUri = $"/sap/opu/odata/SAP/Z_VEND_DETAILS_SRV/HEADERSet?sap-client={_shkrSapOptions.ShkrSapClient}";

        var requestBody = new
        {
            VendorID = string.Empty,
            Start_Date = startDate,
            End_Date = endDate,
            VendorDetailsSet = new object[]
            {
                new
                {
                    VendorAddressSet = new object[] { new { } },
                    VendorContactSet = new object[] { new { } },
                    VendorCompanySet = new object[] { new { } }
                }
            }
        };

        var client = httpClientFactory.CreateClient(ShkrSapClientName);

        using var response = await client.PostAsJsonAsync(requestUri, requestBody, RequestSerializerOptions, cancellationToken);
        response.EnsureSuccessStatusCode();

        var envelope = await response.Content.ReadFromJsonAsync<ODataEnvelope<VendorHeaderData>>(cancellationToken)
            ?? throw new InvalidOperationException("SAP Vendor Details returned an empty response body.");

        return envelope.D;
    }

    public async Task SaveVendor(long vendorId, VendorDetail detail, CancellationToken cancellationToken = default)
    {
        var now = DateTime.Now;

        await using var connection = new SqlConnection(_databaseOptions.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);

        try
        {
            await SaveVendorDetails(connection, transaction, vendorId, [detail], now, cancellationToken);
            await SaveVendorAddresses(connection, transaction, vendorId, detail.VendorAddressSet.Results, now, cancellationToken);
            await SaveVendorContacts(connection, transaction, vendorId, detail.VendorContactSet.Results, now, cancellationToken);
            await SaveVendorCompanies(connection, transaction, vendorId, detail.VendorCompanySet.Results, now, cancellationToken);

            await transaction.CommitAsync(cancellationToken);
        }
        catch
        {
            await transaction.RollbackAsync(cancellationToken);
            throw;
        }
    }

    private static async Task SaveVendorDetails(
        SqlConnection connection, SqlTransaction transaction, long vendorId,
        IReadOnlyList<VendorDetail> details, DateTime now, CancellationToken cancellationToken)
    {
        const string existsSql = "SELECT COUNT(1) FROM dbo.xx_vendor_stg_tbl_ib WHERE VendorID = @VendorID";

        const string updateSql = """
            UPDATE dbo.xx_vendor_stg_tbl_ib
            SET VendorCode = @VendorCode, VendorName = @VendorName, VendorType = @VendorType, Country = @Country,
                City = @City, POBox = @POBox, PostalCode = @PostalCode, AddressLine1 = @AddressLine1,
                AddressLine2 = @AddressLine2, Street = @Street, Telephone1 = @Telephone1, Telephone2 = @Telephone2,
                Fax = @Fax, EmailAddress = @EmailAddress, ActiveFlag = @ActiveFlag,
                OperationFlag = @OperationFlag, ProcessStatus = @ProcessStatus, ProcessError = NULL,
                LastUpdateDate = @LastUpdateDate
            WHERE VendorID = @VendorID
            """;

        const string insertSql = """
            INSERT INTO dbo.xx_vendor_stg_tbl_ib
                (VendorID, VendorCode, VendorName, VendorType, Country, City, POBox, PostalCode,
                 AddressLine1, AddressLine2, Street, Telephone1, Telephone2, Fax, EmailAddress, ActiveFlag,
                 OperationFlag, ProcessStatus, CreatedDate, LastUpdateDate)
            VALUES
                (@VendorID, @VendorCode, @VendorName, @VendorType, @Country, @City, @POBox, @PostalCode,
                 @AddressLine1, @AddressLine2, @Street, @Telephone1, @Telephone2, @Fax, @EmailAddress, @ActiveFlag,
                 @OperationFlag, @ProcessStatus, @CreatedDate, @LastUpdateDate)
            """;

        foreach (var detail in details)
        {
            var exists = await RowExists(connection, transaction, existsSql, cancellationToken,
                ("@VendorID", vendorId));

            await using var command = new SqlCommand(exists ? updateSql : insertSql, connection, transaction);
            command.Parameters.AddWithValue("@VendorID", vendorId);
            command.Parameters.AddWithValue("@VendorCode", detail.VendorCode);
            command.Parameters.AddWithValue("@VendorName", detail.VendorName);
            command.Parameters.AddWithValue("@VendorType", detail.VendorType);
            command.Parameters.AddWithValue("@Country", detail.Country);
            command.Parameters.AddWithValue("@City", detail.City);
            command.Parameters.AddWithValue("@POBox", detail.PoBox);
            command.Parameters.AddWithValue("@PostalCode", detail.PostalCode);
            command.Parameters.AddWithValue("@AddressLine1", detail.AddressLine1);
            command.Parameters.AddWithValue("@AddressLine2", detail.AddressLine2);
            command.Parameters.AddWithValue("@Street", detail.Street);
            command.Parameters.AddWithValue("@Telephone1", detail.Telephone1);
            command.Parameters.AddWithValue("@Telephone2", detail.Telephone2);
            command.Parameters.AddWithValue("@Fax", detail.Fax);
            command.Parameters.AddWithValue("@EmailAddress", detail.EmailAddress);
            command.Parameters.AddWithValue("@ActiveFlag", detail.ActiveFlag);
            AddTrackingParameters(command, now);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private async Task SaveVendorAddresses(
        SqlConnection connection, SqlTransaction transaction, long vendorId,
        IReadOnlyList<VendorAddress> addresses, DateTime now, CancellationToken cancellationToken)
    {
        const string existsSql = """
            SELECT COUNT(1) FROM dbo.xx_vendor_address_stg_tbl_ib WHERE VendorID = @VendorID AND AddressId = @AddressId
            """;

        const string updateSql = """
            UPDATE dbo.xx_vendor_address_stg_tbl_ib
            SET AddressLine1 = @AddressLine1, AddressLine2 = @AddressLine2, Street = @Street, City = @City,
                POBox = @POBox, PostalCode = @PostalCode, Country = @Country, ActiveFlag = @ActiveFlag,
                OperationFlag = @OperationFlag, ProcessStatus = @ProcessStatus, ProcessError = NULL,
                LastUpdateDate = @LastUpdateDate
            WHERE VendorID = @VendorID AND AddressId = @AddressId
            """;

        const string insertSql = """
            INSERT INTO dbo.xx_vendor_address_stg_tbl_ib
                (VendorID, AddressId, AddressLine1, AddressLine2, Street, City, POBox, PostalCode, Country, ActiveFlag,
                 OperationFlag, ProcessStatus, CreatedDate, LastUpdateDate)
            VALUES
                (@VendorID, @AddressId, @AddressLine1, @AddressLine2, @Street, @City, @POBox, @PostalCode, @Country, @ActiveFlag,
                 @OperationFlag, @ProcessStatus, @CreatedDate, @LastUpdateDate)
            """;

        foreach (var address in addresses)
        {
            if (!long.TryParse(address.AddressId, out var addressId))
            {
                logger.LogWarning(
                    "Vendor {VendorId}: skipping address with non-numeric AddressId {AddressId}.",
                    vendorId, address.AddressId);
                continue;
            }

            var exists = await RowExists(connection, transaction, existsSql, cancellationToken,
                ("@VendorID", vendorId), ("@AddressId", addressId));

            await using var command = new SqlCommand(exists ? updateSql : insertSql, connection, transaction);
            command.Parameters.AddWithValue("@VendorID", vendorId);
            command.Parameters.AddWithValue("@AddressId", addressId);
            command.Parameters.AddWithValue("@AddressLine1", address.AddressLine1);
            command.Parameters.AddWithValue("@AddressLine2", address.AddressLine2);
            command.Parameters.AddWithValue("@Street", address.Street);
            command.Parameters.AddWithValue("@City", address.City);
            command.Parameters.AddWithValue("@POBox", address.PoBox);
            command.Parameters.AddWithValue("@PostalCode", address.PostalCode);
            command.Parameters.AddWithValue("@Country", address.Country);
            command.Parameters.AddWithValue("@ActiveFlag", address.ActiveFlag);
            AddTrackingParameters(command, now);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private async Task SaveVendorContacts(
        SqlConnection connection, SqlTransaction transaction, long vendorId,
        IReadOnlyList<VendorContact> contacts, DateTime now, CancellationToken cancellationToken)
    {
        const string existsSql = """
            SELECT COUNT(1) FROM dbo.xx_vendor_contacts_stg_tbl_ib WHERE VendorID = @VendorID AND ContactId = @ContactId
            """;

        const string updateSql = """
            UPDATE dbo.xx_vendor_contacts_stg_tbl_ib
            SET FirstName = @FirstName, LastName = @LastName, Title = @Title, Telephone1 = @Telephone1,
                Telephone2 = @Telephone2, Fax = @Fax, EmailAddress = @EmailAddress, ActiveFlag = @ActiveFlag,
                OperationFlag = @OperationFlag, ProcessStatus = @ProcessStatus, ProcessError = NULL,
                LastUpdateDate = @LastUpdateDate
            WHERE VendorID = @VendorID AND ContactId = @ContactId
            """;

        const string insertSql = """
            INSERT INTO dbo.xx_vendor_contacts_stg_tbl_ib
                (VendorID, ContactId, FirstName, LastName, Title, Telephone1, Telephone2, Fax, EmailAddress, ActiveFlag,
                 OperationFlag, ProcessStatus, CreatedDate, LastUpdateDate)
            VALUES
                (@VendorID, @ContactId, @FirstName, @LastName, @Title, @Telephone1, @Telephone2, @Fax, @EmailAddress, @ActiveFlag,
                 @OperationFlag, @ProcessStatus, @CreatedDate, @LastUpdateDate)
            """;

        foreach (var contact in contacts)
        {
            if (!long.TryParse(contact.ContactId, out var contactId))
            {
                logger.LogWarning(
                    "Vendor {VendorId}: skipping contact with non-numeric ContactId {ContactId}.",
                    vendorId, contact.ContactId);
                continue;
            }

            var exists = await RowExists(connection, transaction, existsSql, cancellationToken,
                ("@VendorID", vendorId), ("@ContactId", contactId));

            await using var command = new SqlCommand(exists ? updateSql : insertSql, connection, transaction);
            command.Parameters.AddWithValue("@VendorID", vendorId);
            command.Parameters.AddWithValue("@ContactId", contactId);
            command.Parameters.AddWithValue("@FirstName", contact.FirstName);
            command.Parameters.AddWithValue("@LastName", contact.LastName);
            command.Parameters.AddWithValue("@Title", contact.Title);
            command.Parameters.AddWithValue("@Telephone1", contact.Telephone1);
            command.Parameters.AddWithValue("@Telephone2", contact.Telephone2);
            command.Parameters.AddWithValue("@Fax", contact.Fax);
            command.Parameters.AddWithValue("@EmailAddress", contact.EmailAddress);
            command.Parameters.AddWithValue("@ActiveFlag", contact.ActiveFlag);
            AddTrackingParameters(command, now);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task SaveVendorCompanies(
        SqlConnection connection, SqlTransaction transaction, long vendorId,
        IReadOnlyList<VendorCompany> companies, DateTime now, CancellationToken cancellationToken)
    {
        const string existsSql = """
            SELECT COUNT(1) FROM dbo.xx_vendor_company_map_stg_tl_ib
            WHERE VendorID = @VendorID AND CompanyCode = @CompanyCode AND ActiveFlag = @ActiveFlag
            """;

        const string updateSql = """
            UPDATE dbo.xx_vendor_company_map_stg_tl_ib
            SET PaymentTerms = @PaymentTerms,
                OperationFlag = @OperationFlag, ProcessStatus = @ProcessStatus, ProcessError = NULL,
                LastUpdateDate = @LastUpdateDate
            WHERE VendorID = @VendorID AND CompanyCode = @CompanyCode AND ActiveFlag = @ActiveFlag
            """;

        const string insertSql = """
            INSERT INTO dbo.xx_vendor_company_map_stg_tl_ib
                (VendorID, CompanyCode, ActiveFlag, PaymentTerms,
                 OperationFlag, ProcessStatus, CreatedDate, LastUpdateDate)
            VALUES
                (@VendorID, @CompanyCode, @ActiveFlag, @PaymentTerms,
                 @OperationFlag, @ProcessStatus, @CreatedDate, @LastUpdateDate)
            """;

        foreach (var company in companies)
        {
            var exists = await RowExists(connection, transaction, existsSql, cancellationToken,
                ("@VendorID", vendorId), ("@CompanyCode", company.CompanyCode), ("@ActiveFlag", company.ActiveFlag));

            await using var command = new SqlCommand(exists ? updateSql : insertSql, connection, transaction);
            command.Parameters.AddWithValue("@VendorID", vendorId);
            command.Parameters.AddWithValue("@CompanyCode", company.CompanyCode);
            command.Parameters.AddWithValue("@ActiveFlag", company.ActiveFlag);
            command.Parameters.AddWithValue("@PaymentTerms", DBNull.Value);
            AddTrackingParameters(command, now);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static void AddTrackingParameters(SqlCommand command, DateTime now)
    {
        command.Parameters.AddWithValue("@OperationFlag", "I");
        command.Parameters.AddWithValue("@ProcessStatus", "N");
        command.Parameters.AddWithValue("@CreatedDate", now);
        command.Parameters.AddWithValue("@LastUpdateDate", now);
    }

    private static async Task<bool> RowExists(
        SqlConnection connection, SqlTransaction transaction, string existsSql, CancellationToken cancellationToken,
        params (string Name, object Value)[] keyParameters)
    {
        await using var command = new SqlCommand(existsSql, connection, transaction);
        foreach (var (name, value) in keyParameters)
        {
            command.Parameters.AddWithValue(name, value);
        }

        var count = (int)(await command.ExecuteScalarAsync(cancellationToken))!;
        return count > 0;
    }
}
