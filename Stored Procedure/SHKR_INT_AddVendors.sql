USE [PMWeb]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



CREATE OR ALTER PROC [dbo].[SHKR_INT_AddVendors]
AS
SET NOCOUNT ON
SET XACT_ABORT ON

BEGIN
    DECLARE @ErrorDesc   VARCHAR(MAX) = '';
    DECLARE @ErrorStatus INT = 0;
    
    DECLARE @Now         DATETIME2 = GETDATE();

    BEGIN TRY
     
        DELETE a FROM dbo.xx_vendor_stg_tbl_ib a
        WHERE a.ProcessStatus = 'E'
          AND EXISTS (SELECT 1 FROM dbo.xx_vendor_stg_tbl_ib x WHERE x.ProcessStatus = 'N' AND x.VendorID = a.VendorID);

        DELETE a FROM dbo.xx_vendor_address_stg_tbl_ib a
        WHERE a.ProcessStatus = 'E'
          AND EXISTS (SELECT 1 FROM dbo.xx_vendor_address_stg_tbl_ib x WHERE x.ProcessStatus = 'N' AND x.VendorID = a.VendorID AND x.AddressId = a.AddressId);

        DELETE a FROM dbo.xx_vendor_contacts_stg_tbl_ib a
        WHERE a.ProcessStatus = 'E'
          AND EXISTS (SELECT 1 FROM dbo.xx_vendor_contacts_stg_tbl_ib x WHERE x.ProcessStatus = 'N' AND x.VendorID = a.VendorID AND x.ContactId = a.ContactId);

        DELETE a FROM dbo.xx_vendor_company_map_stg_tl_ib a
        WHERE a.ProcessStatus = 'E'
          AND EXISTS (SELECT 1 FROM dbo.xx_vendor_company_map_stg_tl_ib x WHERE x.ProcessStatus = 'N' AND x.VendorID = a.VendorID AND x.CompanyCode = a.CompanyCode AND x.ActiveFlag = a.ActiveFlag);

        UPDATE m
        SET ProcessStatus = 'E',
            ProcessError = 'Duplicate CompanyCode with conflicting ActiveFlag values for this vendor.',
            LastUpdateDate = @Now
        FROM dbo.xx_vendor_company_map_stg_tl_ib m
        WHERE m.ProcessStatus = 'N'
          AND EXISTS (
              SELECT 1
              FROM dbo.xx_vendor_company_map_stg_tl_ib d
              WHERE d.VendorID = m.VendorID
                AND d.CompanyCode = m.CompanyCode
                AND d.ProcessStatus = 'N'
              GROUP BY d.VendorID, d.CompanyCode
              HAVING COUNT(*) > 1
          );


        DECLARE
            @VendorID      BIGINT,
            @VendorCode    VARCHAR(30),
            @VendorName    VARCHAR(250),
            @VendorType    VARCHAR(80),
            @Country       VARCHAR(80),
            @City          VARCHAR(150),
            @POBox         VARCHAR(150),
            @PostalCode    VARCHAR(150),
            @AddressLine1  VARCHAR(150),
            @AddressLine2  VARCHAR(150),
            @Street        VARCHAR(150),
            @Telephone1    VARCHAR(30),
            @Telephone2    VARCHAR(30),
            @Fax           VARCHAR(30),
            @EmailAddress  VARCHAR(150),
            @ActiveFlag    VARCHAR(1),
            @OperationFlag VARCHAR(1),
            @IsActive      BIT,
            @CountryId     BIGINT,
            @NameId        BIGINT,
            @DestVendorId  BIGINT,
            @DestVendorAddressId BIGINT;

        DECLARE vendor_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT VendorID, VendorCode, VendorName, VendorType, Country, City, POBox, PostalCode,
                   AddressLine1, AddressLine2, Street, Telephone1, Telephone2, Fax, EmailAddress, ActiveFlag, OperationFlag
            FROM dbo.xx_vendor_stg_tbl_ib
            WHERE ProcessStatus = 'N';

        OPEN vendor_cursor;
        FETCH NEXT FROM vendor_cursor INTO
            @VendorID, @VendorCode, @VendorName, @VendorType, @Country, @City, @POBox, @PostalCode,
            @AddressLine1, @AddressLine2, @Street, @Telephone1, @Telephone2, @Fax, @EmailAddress, @ActiveFlag, @OperationFlag;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ErrorStatus = 0;
            SET @ErrorDesc = '';
            SET @DestVendorId = NULL;
            SET @DestVendorAddressId = NULL;

            SET @IsActive = CASE WHEN (@ActiveFlag = 'Y' OR @ActiveFlag IS NULL OR @ActiveFlag = '') THEN 1 ELSE 0 END;

            SET @DestVendorId = ISNULL((SELECT TOP 1 Id FROM dbo.Companies WHERE CompanyCode = @VendorCode), 0);

            SET @OperationFlag = CASE WHEN @DestVendorId <> 0 THEN 'U' ELSE 'I' END;

            IF @ErrorStatus = 0 AND @OperationFlag = 'I'
            BEGIN
                SET @NameId = ISNULL((SELECT TOP 1 Id FROM dbo.Companies WHERE CompanyName = @VendorName AND CompanyCode <> @VendorCode), 0);
                IF @NameId > 0
                    SELECT @ErrorStatus = 1, @ErrorDesc = @ErrorDesc + 'Duplicate vendor name. ';
            END

            SET @CountryId = ISNULL((SELECT TOP 1 Id FROM dbo.Countries WHERE Country = @Country), -1);
            IF @ErrorStatus = 0 AND @CountryId = -1
                SELECT @ErrorStatus = 1, @ErrorDesc = @ErrorDesc + 'Invalid country code. ';

            IF @ErrorStatus = 0
            BEGIN
                IF @OperationFlag IN ('U')
                BEGIN
                    UPDATE dbo.Companies
                    SET CompanyName    = @VendorName,
                        CountryId      = @CountryId,
                        IsActive       = @IsActive,
                        Reference      = CAST(@VendorID AS VARCHAR(20)),
                        LastUpdatedBy  = 5,
                        LastUpdateDate = GETDATE()
                    WHERE Id = @DestVendorId;
                END
                ELSE
                BEGIN
                    INSERT INTO dbo.Companies
                        (CompanyName, CompanyCode, CompanyTypeId, IsActive, CreateDate, CreatedBy, CountryId, Reference)
                    VALUES
                        (@VendorName, @VendorCode, NULL, @IsActive, GETDATE(), 5, @CountryId, CAST(@VendorID AS VARCHAR(20)));

                    SET @DestVendorId = SCOPE_IDENTITY();
                END

                IF EXISTS (SELECT 1 FROM dbo.CompanyAddresses WHERE CompanyId = @DestVendorId AND AddressCode = @VendorCode)
                BEGIN
                    UPDATE dbo.CompanyAddresses
                    SET Address1 = @AddressLine1, Address2 = @AddressLine2, City = @City, Zip = @PostalCode,
                        CountryId = @CountryId, Phone = @Telephone1, AltPhone = @Telephone2, Fax = @Fax,
                        Email = @EmailAddress, IsActive = @IsActive
                    WHERE CompanyId = @DestVendorId AND AddressCode = @VendorCode;

                    SELECT @DestVendorAddressId = Id FROM dbo.CompanyAddresses WHERE CompanyId = @DestVendorId AND AddressCode = @VendorCode;
                END
                ELSE
                BEGIN
                    INSERT INTO dbo.CompanyAddresses
                        (CompanyId, AddressCode, Address1, Address2, City, Zip, CountryId, Phone, AltPhone, Fax, Email, IsActive, IsPrimary)
                    VALUES
                        (@DestVendorId, @VendorCode, @AddressLine1, @AddressLine2, @City, @PostalCode, @CountryId, @Telephone1, @Telephone2, @Fax, @EmailAddress, @IsActive, 1);

                    SET @DestVendorAddressId = SCOPE_IDENTITY();
                END

                UPDATE dbo.xx_vendor_stg_tbl_ib
                SET ProcessStatus = 'S', ProcessError = 'Vendor processed successfully', pmwebCompanyId = @DestVendorId, LastUpdateDate = @Now
                WHERE VendorID = @VendorID AND ProcessStatus = 'N';
            END
            ELSE
            BEGIN
                UPDATE dbo.xx_vendor_stg_tbl_ib
                SET ProcessStatus = 'E', ProcessError = @ErrorDesc, LastUpdateDate = @Now
                WHERE VendorID = @VendorID AND ProcessStatus = 'N';
            END

            DECLARE
                @AddrAddressId     BIGINT,
                @AddrLine1         VARCHAR(150),
                @AddrLine2         VARCHAR(150),
                @AddrStreet        VARCHAR(150),
                @AddrCity          VARCHAR(150),
                @AddrPOBox         VARCHAR(150),
                @AddrPostalCode    VARCHAR(150),
                @AddrCountry       VARCHAR(150),
                @AddrActiveFlag    VARCHAR(1),
                @AddrOperationFlag VARCHAR(1),
                @AddrIsActive      BIT,
                @AddrCountryId     BIGINT,
                @AddrErrorStatus   INT,
                @AddrErrorDesc     VARCHAR(MAX),
                @DestAddressId     BIGINT;

            DECLARE address_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT AddressId, AddressLine1, AddressLine2, Street, City, POBox, PostalCode, Country, ActiveFlag, OperationFlag
                FROM dbo.xx_vendor_address_stg_tbl_ib
                WHERE VendorID = @VendorID AND ProcessStatus = 'N'
                ORDER BY AddressId;

            OPEN address_cursor;
            FETCH NEXT FROM address_cursor INTO
                @AddrAddressId, @AddrLine1, @AddrLine2, @AddrStreet, @AddrCity, @AddrPOBox, @AddrPostalCode, @AddrCountry, @AddrActiveFlag, @AddrOperationFlag;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @AddrErrorStatus = 0;
                SET @AddrErrorDesc = '';
                SET @DestAddressId = NULL;

                IF @ErrorStatus = 0
                BEGIN
                    SET @AddrIsActive = CASE WHEN (@AddrActiveFlag = 'Y' OR @AddrActiveFlag IS NULL OR @AddrActiveFlag = '') THEN 1 ELSE 0 END;

                    SET @AddrCountryId = ISNULL((SELECT TOP 1 Id FROM dbo.Countries WHERE Country = @AddrCountry), -1);
                    IF @AddrCountryId = -1
                        SELECT @AddrErrorStatus = 1, @AddrErrorDesc = @AddrErrorDesc + 'Invalid country code. ';

                    IF @AddrErrorStatus = 0
                    BEGIN
                        SET @DestAddressId = ISNULL((SELECT Id FROM dbo.CompanyAddresses WHERE CompanyId = @DestVendorId AND AddressCode = CAST(@AddrAddressId AS VARCHAR(30))), 0);

                        IF @DestAddressId <> 0
                        BEGIN
                            UPDATE dbo.CompanyAddresses
                            SET Address1 = @AddrLine1, Address2 = @AddrLine2, City = @AddrCity, Zip = @AddrPostalCode,
                                CountryId = @AddrCountryId, IsActive = @AddrIsActive
                            WHERE Id = @DestAddressId;
                        END
                        ELSE
                        BEGIN
                            INSERT INTO dbo.CompanyAddresses
                                (CompanyId, AddressCode, Address1, Address2, City, Zip, CountryId, IsActive, IsPrimary)
                            VALUES
                                (@DestVendorId, CAST(@AddrAddressId AS VARCHAR(30)), @AddrLine1, @AddrLine2, @AddrCity, @AddrPostalCode, @AddrCountryId, @AddrIsActive, 0);

                            SET @DestAddressId = SCOPE_IDENTITY();
                        END

                        UPDATE dbo.xx_vendor_address_stg_tbl_ib
                        SET ProcessStatus = 'S', ProcessError = 'Address processed successfully', pmwebAddressId = @DestAddressId, LastUpdateDate = @Now
                        WHERE VendorID = @VendorID AND AddressId = @AddrAddressId AND ProcessStatus = 'N';
                    END
                    ELSE
                    BEGIN
                        UPDATE dbo.xx_vendor_address_stg_tbl_ib
                        SET ProcessStatus = 'E', ProcessError = @AddrErrorDesc, LastUpdateDate = @Now
                        WHERE VendorID = @VendorID AND AddressId = @AddrAddressId AND ProcessStatus = 'N';
                    END
                END
                ELSE
                BEGIN
                    UPDATE dbo.xx_vendor_address_stg_tbl_ib
                    SET ProcessStatus = 'E', ProcessError = 'Parent vendor failed validation. ' + @ErrorDesc, LastUpdateDate = @Now
                    WHERE VendorID = @VendorID AND AddressId = @AddrAddressId AND ProcessStatus = 'N';
                END

                FETCH NEXT FROM address_cursor INTO
                    @AddrAddressId, @AddrLine1, @AddrLine2, @AddrStreet, @AddrCity, @AddrPOBox, @AddrPostalCode, @AddrCountry, @AddrActiveFlag, @AddrOperationFlag;
            END
            CLOSE address_cursor;
            DEALLOCATE address_cursor;


            DECLARE
                @ContContactId     BIGINT,
                @ContFirstName     VARCHAR(150),
                @ContLastName      VARCHAR(150),
                @ContTitle         VARCHAR(150),
                @ContTelephone1    VARCHAR(30),
                @ContTelephone2    VARCHAR(30),
                @ContFax           VARCHAR(30),
                @ContEmail         VARCHAR(150),
                @ContActiveFlag    VARCHAR(1),
                @ContOperationFlag VARCHAR(1),
                @ContIsActive      BIT,
                @DestContactId     BIGINT;

            DECLARE contact_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT ContactId, FirstName, LastName, Title, Telephone1, Telephone2, Fax, EmailAddress, ActiveFlag, OperationFlag
                FROM dbo.xx_vendor_contacts_stg_tbl_ib
                WHERE VendorID = @VendorID AND ProcessStatus = 'N';

            OPEN contact_cursor;
            FETCH NEXT FROM contact_cursor INTO
                @ContContactId, @ContFirstName, @ContLastName, @ContTitle, @ContTelephone1, @ContTelephone2, @ContFax, @ContEmail, @ContActiveFlag, @ContOperationFlag;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @DestContactId = NULL;

                IF @ErrorStatus = 0 AND @DestVendorAddressId IS NOT NULL
                BEGIN
                    SET @ContIsActive = CASE WHEN (@ContActiveFlag = 'Y' OR @ContActiveFlag IS NULL OR @ContActiveFlag = '') THEN 1 ELSE 0 END;

                    SET @DestContactId = ISNULL((SELECT Id FROM dbo.CompanyAddressesContacts WHERE CompanyAdressId = @DestVendorAddressId AND Email = @ContEmail), 0);

                   
                    IF @DestContactId <> 0
                    BEGIN
                        UPDATE dbo.CompanyAddressesContacts
                        SET FirstName = @ContFirstName, LastName = @ContLastName, Title = @ContTitle,
                            Phone = @ContTelephone1, AltPhone = @ContTelephone2, Fax = @ContFax,
                            Email = @ContEmail, IsActive = @ContIsActive
                        WHERE Id = @DestContactId;
                    END
                    ELSE
                    BEGIN
                        INSERT INTO dbo.CompanyAddressesContacts
                            (CompanyAdressId, UserName, FirstName, LastName, Title, Phone, AltPhone, Fax, Email, IsActive)
                        VALUES
                            (@DestVendorAddressId, @ContEmail, @ContFirstName, @ContLastName, @ContTitle, @ContTelephone1, @ContTelephone2, @ContFax, @ContEmail, @ContIsActive);

                        SET @DestContactId = SCOPE_IDENTITY();
                    END

                    UPDATE dbo.xx_vendor_contacts_stg_tbl_ib
                    SET ProcessStatus = 'S', ProcessError = 'Contact processed successfully', pmwebContactId = @DestContactId, LastUpdateDate = @Now
                    WHERE VendorID = @VendorID AND ContactId = @ContContactId AND ProcessStatus = 'N';
                END
                ELSE
                BEGIN
                    UPDATE dbo.xx_vendor_contacts_stg_tbl_ib
                    SET ProcessStatus = 'E',
                        ProcessError = CASE WHEN @ErrorStatus <> 0 THEN 'Parent vendor failed validation. ' + @ErrorDesc
                                             ELSE 'No header address available to link this contact to. ' END,
                        LastUpdateDate = @Now
                    WHERE VendorID = @VendorID AND ContactId = @ContContactId AND ProcessStatus = 'N';
                END

                FETCH NEXT FROM contact_cursor INTO
                    @ContContactId, @ContFirstName, @ContLastName, @ContTitle, @ContTelephone1, @ContTelephone2, @ContFax, @ContEmail, @ContActiveFlag, @ContOperationFlag;
            END
            CLOSE contact_cursor;
            DEALLOCATE contact_cursor;

            DECLARE
                @MapCompanyCode   VARCHAR(30),
                @MapActiveFlag    VARCHAR(1),
                @MapOperationFlag VARCHAR(1);

            DECLARE company_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT CompanyCode, ActiveFlag, OperationFlag
                FROM dbo.xx_vendor_company_map_stg_tl_ib
                WHERE VendorID = @VendorID AND ProcessStatus = 'N';

            OPEN company_cursor;
            FETCH NEXT FROM company_cursor INTO @MapCompanyCode, @MapActiveFlag, @MapOperationFlag;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                UPDATE dbo.xx_vendor_company_map_stg_tl_ib
                SET ProcessStatus = 'S', ProcessError = 'Staged only - no PMWeb destination table defined yet.', LastUpdateDate = @Now
                WHERE VendorID = @VendorID AND CompanyCode = @MapCompanyCode AND ProcessStatus = 'N';

                FETCH NEXT FROM company_cursor INTO @MapCompanyCode, @MapActiveFlag, @MapOperationFlag;
            END
            CLOSE company_cursor;
            DEALLOCATE company_cursor;

            FETCH NEXT FROM vendor_cursor INTO
                @VendorID, @VendorCode, @VendorName, @VendorType, @Country, @City, @POBox, @PostalCode,
                @AddressLine1, @AddressLine2, @Street, @Telephone1, @Telephone2, @Fax, @EmailAddress, @ActiveFlag, @OperationFlag;
        END

        CLOSE vendor_cursor;
        DEALLOCATE vendor_cursor;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END
GO
