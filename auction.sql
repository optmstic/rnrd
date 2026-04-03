-- =========================================================================================
-- auction.sql | Relational and Non-Relational Data Project 2026 - Group L
-- =========================================================================================
-- INDEX
--   1. Schema Creation
--   2. Table Creation
--      2.1 Auction.Configuration
--      2.2 Auction.Product
--      2.3 Auction.Bids
--   3. Stored Procedures
--      3.1 uspAddProductToAuction
--      3.2 uspTryBidProduct
--      3.3 uspRemoveProductFromAuction
--      3.4 uspListBidsOffersHistory
--      3.5 uspUpdateProductAuctionStatus
--   4. Brick and Mortar Store Recommendation
--      4.1 Top 30 US resellers
--      4.2 Excluded cities
--      4.3 Candidate cities ranked
--      4.4 Product category breakdown
--      4.5 Yearly sales trend
-- =========================================================================================

USE AdventureWorks;
GO

-- 0. Clean up previous version (uncomment to reset during development)
-- DROP TABLE IF EXISTS Auction.Bids;
-- DROP TABLE IF EXISTS Auction.Product;
-- DROP TABLE IF EXISTS Auction.Configuration;
-- GO

-- 1. Schema
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Auction')
BEGIN
    EXEC('CREATE SCHEMA Auction');
END;
GO

-- 2.1 Configuration
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'Auction' AND TABLE_NAME = 'Configuration')
BEGIN
    CREATE TABLE Auction.Configuration (
        ConfigID             INT            PRIMARY KEY DEFAULT 1,
        MinBidIncrement      MONEY          NOT NULL,
        MaxBidMultiplier     DECIMAL(5,2)   NOT NULL,
        MakeFlag0_Multiplier DECIMAL(5,2)   NOT NULL,
        MakeFlag1_Multiplier DECIMAL(5,2)   NOT NULL,
        CHECK (ConfigID = 1)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM Auction.Configuration WHERE ConfigID = 1)
BEGIN
    INSERT INTO Auction.Configuration (ConfigID, MinBidIncrement, MaxBidMultiplier, MakeFlag0_Multiplier, MakeFlag1_Multiplier)
    VALUES (1, 0.05, 1.00, 0.75, 0.50);
END;
GO

-- 2.2 Product
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'Auction' AND TABLE_NAME = 'Product')
BEGIN
    CREATE TABLE Auction.Product (
        AuctionID       INT          IDENTITY(1,1) PRIMARY KEY,
        ProductID       INT          NOT NULL,
        InitialBidPrice MONEY        NOT NULL,
        LastBidPrice    MONEY        NULL,
        StartDate       DATETIME     NOT NULL DEFAULT GETDATE(),
        ExpireDate      DATETIME     NOT NULL,
        AuctionStatus   VARCHAR(20)  NOT NULL DEFAULT 'Active'
            CHECK (AuctionStatus IN ('Active', 'Cancelled', 'FINISHED by TIME', 'FINISHED by PRICE')),
        MaxBidPrice     MONEY        NOT NULL,
        CONSTRAINT FK_AuctionProduct_Product FOREIGN KEY (ProductID) REFERENCES Production.Product(ProductID)
    );
END;
GO

-- 2.3 Bids
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'Auction' AND TABLE_NAME = 'Bids')
BEGIN
    CREATE TABLE Auction.Bids (
        BidID       INT          IDENTITY(1,1) PRIMARY KEY,
        AuctionID   INT          NOT NULL,
        CustomerID  INT          NOT NULL,
        BidValue    MONEY        NOT NULL,
        BidStatus   VARCHAR(20)  NOT NULL DEFAULT 'Active'
            CHECK (BidStatus IN ('Active', 'Inactive', 'Cancelled', 'Winner', 'Lost')),
        BidDate     DATETIME     NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_Bids_Auction  FOREIGN KEY (AuctionID)  REFERENCES Auction.Product(AuctionID),
        CONSTRAINT FK_Bids_Customer FOREIGN KEY (CustomerID) REFERENCES Sales.Customer(CustomerID)
    );
END;
GO

-- =========================================================================================
-- 3. Stored Procedures
-- =========================================================================================

-- 3.1 uspAddProductToAuction
CREATE OR ALTER PROCEDURE Auction.uspAddProductToAuction
    @ProductID       INT,
    @ExpireDate      DATETIME = NULL,
    @InitialBidPrice MONEY    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @ProductID IS NULL
            THROW 50000, 'ProductID cannot be NULL.', 1;

        IF NOT EXISTS (SELECT 1 FROM Production.Product WHERE ProductID = @ProductID)
            THROW 50001, 'Product not found.', 1;

        IF EXISTS (SELECT 1 FROM Auction.Product WHERE ProductID = @ProductID AND AuctionStatus = 'Active')
            THROW 50002, 'This product already has an active auction.', 1;

        DECLARE @SellEndDate DATETIME, @DiscontinuedDate DATETIME;
        DECLARE @MakeFlag BIT, @ListPrice MONEY;

        SELECT @SellEndDate = SellEndDate, @DiscontinuedDate = DiscontinuedDate,
               @MakeFlag = MakeFlag, @ListPrice = ListPrice
        FROM Production.Product
        WHERE ProductID = @ProductID;

        IF @SellEndDate IS NOT NULL OR @DiscontinuedDate IS NOT NULL
            THROW 50003, 'Product is not currently commercialized.', 1;

        DECLARE @MaxBidMultiplier DECIMAL(5,2);
        DECLARE @MakeFlag0_Mult DECIMAL(5,2), @MakeFlag1_Mult DECIMAL(5,2);

        SELECT @MaxBidMultiplier = MaxBidMultiplier,
               @MakeFlag0_Mult = MakeFlag0_Multiplier,
               @MakeFlag1_Mult = MakeFlag1_Multiplier
        FROM Auction.Configuration WHERE ConfigID = 1;

        IF @ExpireDate IS NULL
            SET @ExpireDate = DATEADD(WEEK, 1, GETDATE());

        IF @InitialBidPrice IS NULL
            SET @InitialBidPrice = IIF(@MakeFlag = 0, @ListPrice * @MakeFlag0_Mult, @ListPrice * @MakeFlag1_Mult);

        DECLARE @MaxBidPrice MONEY = @ListPrice * @MaxBidMultiplier;

        INSERT INTO Auction.Product (ProductID, InitialBidPrice, LastBidPrice, StartDate, ExpireDate, AuctionStatus, MaxBidPrice)
        VALUES (@ProductID, @InitialBidPrice, NULL, GETDATE(), @ExpireDate, 'Active', @MaxBidPrice);

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

-- 3.2 uspTryBidProduct
CREATE OR ALTER PROCEDURE Auction.uspTryBidProduct
    @ProductID  INT,
    @CustomerID INT,
    @BidAmount  MONEY = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @ProductID IS NULL OR @CustomerID IS NULL
            THROW 50010, 'ProductID and CustomerID are required.', 1;

        IF NOT EXISTS (SELECT 1 FROM Sales.Customer WHERE CustomerID = @CustomerID)
            THROW 50011, 'Customer not found.', 1;

        DECLARE @AuctionID INT, @CurrentBid MONEY, @MaxBidPrice MONEY, @ExpireDate DATETIME;
        DECLARE @MinBidIncrement MONEY;

        SELECT @MinBidIncrement = MinBidIncrement
        FROM Auction.Configuration WHERE ConfigID = 1;

        SELECT @AuctionID = AuctionID,
               @CurrentBid = ISNULL(LastBidPrice, InitialBidPrice),
               @MaxBidPrice = MaxBidPrice,
               @ExpireDate = ExpireDate
        FROM Auction.Product
        WHERE ProductID = @ProductID AND AuctionStatus = 'Active';

        IF @AuctionID IS NULL
            THROW 50012, 'No active auction found for this product.', 1;

        IF GETDATE() > @ExpireDate
            THROW 50013, 'This auction has expired.', 1;

        IF @BidAmount IS NULL
            SET @BidAmount = @CurrentBid + @MinBidIncrement;

        IF @BidAmount > @MaxBidPrice
            THROW 50014, 'Bid exceeds the maximum bid limit.', 1;

        IF @BidAmount <= @CurrentBid
            THROW 50015, 'Bid must be higher than the current bid.', 1;

        IF (@BidAmount - @CurrentBid) < @MinBidIncrement AND @BidAmount < @MaxBidPrice
            THROW 50016, 'Bid increment is below the minimum.', 1;

        BEGIN TRANSACTION;
            INSERT INTO Auction.Bids (AuctionID, CustomerID, BidValue, BidStatus, BidDate)
            VALUES (@AuctionID, @CustomerID, @BidAmount, 'Active', GETDATE());

            UPDATE Auction.Bids SET BidStatus = 'Inactive'
            WHERE AuctionID = @AuctionID AND BidStatus = 'Active' AND BidValue < @BidAmount;

            UPDATE Auction.Product SET LastBidPrice = @BidAmount
            WHERE AuctionID = @AuctionID;

            IF @BidAmount = @MaxBidPrice
            BEGIN
                UPDATE Auction.Product SET AuctionStatus = 'FINISHED by PRICE' WHERE AuctionID = @AuctionID;
                UPDATE Auction.Bids SET BidStatus = 'Winner' WHERE AuctionID = @AuctionID AND BidValue = @BidAmount;
                UPDATE Auction.Bids SET BidStatus = 'Lost'
                WHERE AuctionID = @AuctionID AND BidStatus IN ('Active', 'Inactive');
            END
        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- 3.3 uspRemoveProductFromAuction
CREATE OR ALTER PROCEDURE Auction.uspRemoveProductFromAuction
    @ProductID INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @ProductID IS NULL
            THROW 50020, 'ProductID cannot be NULL.', 1;

        DECLARE @AuctionID INT;
        SELECT @AuctionID = AuctionID
        FROM Auction.Product
        WHERE ProductID = @ProductID AND AuctionStatus = 'Active';

        IF @AuctionID IS NULL
            THROW 50021, 'No active auction found for this product.', 1;

        BEGIN TRANSACTION;
            UPDATE Auction.Product SET AuctionStatus = 'Cancelled' WHERE AuctionID = @AuctionID;
            UPDATE Auction.Bids SET BidStatus = 'Cancelled' WHERE AuctionID = @AuctionID;
        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- 3.4 uspListBidsOffersHistory
CREATE OR ALTER PROCEDURE Auction.uspListBidsOffersHistory
    @CustomerID INT,
    @StartTime  DATETIME,
    @EndTime    DATETIME,
    @Active     BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @CustomerID IS NULL
            THROW 50030, 'CustomerID cannot be NULL.', 1;

        IF NOT EXISTS (SELECT 1 FROM Sales.Customer WHERE CustomerID = @CustomerID)
            THROW 50031, 'Customer not found.', 1;

        IF @StartTime IS NULL OR @EndTime IS NULL
            THROW 50032, 'StartTime and EndTime are required.', 1;

        SELECT B.BidID, B.AuctionID, P.ProductID, B.BidValue, B.BidStatus, B.BidDate, P.AuctionStatus
        FROM Auction.Bids B
        INNER JOIN Auction.Product P ON B.AuctionID = P.AuctionID
        WHERE B.CustomerID = @CustomerID
          AND B.BidDate BETWEEN @StartTime AND @EndTime
          AND (@Active = 0 OR P.AuctionStatus = 'Active')
        ORDER BY B.BidDate DESC;

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

-- 3.5 uspUpdateProductAuctionStatus
CREATE OR ALTER PROCEDURE Auction.uspUpdateProductAuctionStatus
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
            -- Close expired auctions
            UPDATE Auction.Product SET AuctionStatus = 'FINISHED by TIME'
            WHERE AuctionStatus = 'Active' AND ExpireDate < GETDATE();

            -- Mark highest bidder as winner
            UPDATE B SET BidStatus = 'Winner'
            FROM Auction.Bids B
            INNER JOIN Auction.Product P ON B.AuctionID = P.AuctionID
            WHERE P.AuctionStatus = 'FINISHED by TIME' AND B.BidStatus = 'Active'
              AND B.BidValue = P.LastBidPrice
              AND B.BidDate = (SELECT MAX(B2.BidDate) FROM Auction.Bids B2
                               WHERE B2.AuctionID = B.AuctionID AND B2.BidValue = P.LastBidPrice);

            -- Mark remaining bids as lost
            UPDATE B SET BidStatus = 'Lost'
            FROM Auction.Bids B
            INNER JOIN Auction.Product P ON B.AuctionID = P.AuctionID
            WHERE P.AuctionStatus = 'FINISHED by TIME' AND B.BidStatus IN ('Active', 'Inactive');
        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- =========================================================================================
-- 4. Brick and Mortar Store Recommendation
-- =========================================================================================

-- Temp table: excluded cities (cities of the top 30 US resellers)
IF OBJECT_ID('tempdb..#ExcludedCities') IS NOT NULL DROP TABLE #ExcludedCities;

SELECT DISTINCT A.City, SP.Name AS StateName
INTO #ExcludedCities
FROM (
    SELECT TOP 30 S.BusinessEntityID
    FROM Sales.Store S
    INNER JOIN Person.BusinessEntityAddress BEA ON S.BusinessEntityID = BEA.BusinessEntityID
    INNER JOIN Person.Address A ON BEA.AddressID = A.AddressID
    INNER JOIN Person.StateProvince SP ON A.StateProvinceID = SP.StateProvinceID
    INNER JOIN Sales.Customer C ON C.StoreID = S.BusinessEntityID
    INNER JOIN Sales.SalesOrderHeader SOH ON SOH.CustomerID = C.CustomerID
    WHERE SP.CountryRegionCode = 'US'
    GROUP BY S.BusinessEntityID
    ORDER BY SUM(SOH.TotalDue) DESC
) T30
INNER JOIN Person.BusinessEntityAddress BEA ON T30.BusinessEntityID = BEA.BusinessEntityID
INNER JOIN Person.Address A ON BEA.AddressID = A.AddressID
INNER JOIN Person.StateProvince SP ON A.StateProvinceID = SP.StateProvinceID
WHERE SP.CountryRegionCode = 'US';
GO

-- Temp table: eligible cities with financials and ZIP prefix
IF OBJECT_ID('tempdb..#CityMetrics') IS NOT NULL DROP TABLE #CityMetrics;

SELECT A.City, SP.Name AS StateName,
       SUM(SOH.TotalDue) AS TotalRevenue,
       COUNT(DISTINCT C.CustomerID) AS CustomerCount,
       COUNT(DISTINCT SOH.SalesOrderID) AS OrderCount,
       AVG(SOH.TotalDue) AS AvgOrderValue,
       (SELECT TOP 1 CAST(LEFT(A2.PostalCode, 3) AS INT)
        FROM Person.Address A2
        INNER JOIN Person.StateProvince SP2 ON A2.StateProvinceID = SP2.StateProvinceID
        WHERE A2.City = A.City AND SP2.Name = SP.Name
          AND A2.PostalCode LIKE '[0-9][0-9][0-9]%'
        GROUP BY LEFT(A2.PostalCode, 3)
        ORDER BY COUNT(*) DESC) AS ZipPrefix
INTO #CityMetrics
FROM Sales.Customer C
INNER JOIN Sales.SalesOrderHeader SOH ON SOH.CustomerID = C.CustomerID
INNER JOIN Person.Address A ON SOH.ShipToAddressID = A.AddressID
INNER JOIN Person.StateProvince SP ON A.StateProvinceID = SP.StateProvinceID
WHERE SP.CountryRegionCode = 'US' AND C.StoreID IS NULL
  AND NOT EXISTS (SELECT 1 FROM #ExcludedCities EC WHERE EC.City = A.City AND EC.StateName = SP.Name)
GROUP BY A.City, SP.Name
HAVING (SELECT COUNT(DISTINCT PC.Name)
        FROM Sales.SalesOrderHeader SOH2
        INNER JOIN Sales.Customer C2 ON SOH2.CustomerID = C2.CustomerID AND C2.StoreID IS NULL
        INNER JOIN Person.Address A2 ON SOH2.ShipToAddressID = A2.AddressID
        INNER JOIN Person.StateProvince SP2 ON A2.StateProvinceID = SP2.StateProvinceID
        INNER JOIN Sales.SalesOrderDetail SOD ON SOH2.SalesOrderID = SOD.SalesOrderID
        INNER JOIN Production.Product P ON SOD.ProductID = P.ProductID
        LEFT JOIN Production.ProductSubcategory PSC ON P.ProductSubcategoryID = PSC.ProductSubcategoryID
        LEFT JOIN Production.ProductCategory PC ON PSC.ProductCategoryID = PC.ProductCategoryID
        WHERE A2.City = A.City AND SP2.Name = SP.Name) >= 3;
GO

-- Temp table: top 2 candidate cities (metro-area spread)
IF OBJECT_ID('tempdb..#TopCandidates') IS NOT NULL DROP TABLE #TopCandidates;

DECLARE @Pick1Zip INT;
SELECT TOP 1 @Pick1Zip = ZipPrefix FROM #CityMetrics ORDER BY TotalRevenue DESC;

SELECT City, StateName, ZipPrefix
INTO #TopCandidates
FROM (
    SELECT TOP 1 City, StateName, ZipPrefix
    FROM #CityMetrics ORDER BY TotalRevenue DESC
    UNION ALL
    SELECT TOP 1 City, StateName, ZipPrefix
    FROM #CityMetrics
    WHERE ABS(ZipPrefix - @Pick1Zip) > 20
    ORDER BY TotalRevenue DESC
) R;
GO

-- 4.1 Top 30 US resellers by revenue
SELECT S.Name AS StoreName, A.City, SP.Name AS StateName, SUM(SOH.TotalDue) AS TotalSales
FROM Sales.Store S
INNER JOIN Person.BusinessEntityAddress BEA ON S.BusinessEntityID = BEA.BusinessEntityID
INNER JOIN Person.Address A ON BEA.AddressID = A.AddressID
INNER JOIN Person.StateProvince SP ON A.StateProvinceID = SP.StateProvinceID
INNER JOIN Sales.Customer C ON C.StoreID = S.BusinessEntityID
INNER JOIN Sales.SalesOrderHeader SOH ON SOH.CustomerID = C.CustomerID
WHERE SP.CountryRegionCode = 'US'
GROUP BY S.BusinessEntityID, S.Name, A.City, SP.Name
ORDER BY TotalSales DESC
OFFSET 0 ROWS FETCH NEXT 30 ROWS ONLY;
GO

-- 4.2 Excluded cities
SELECT * FROM #ExcludedCities ORDER BY City;
GO

-- 4.3 Candidate cities ranked by individual customer revenue
-- ZipPrefix: 3-digit postal code area. Cities within 20 of each other share a metro area.
SELECT CM.City, CM.StateName, CM.ZipPrefix,
       CM.TotalRevenue, CM.CustomerCount, CM.OrderCount, CM.AvgOrderValue,
       RANK() OVER (ORDER BY CM.TotalRevenue DESC) AS RevenueRank
FROM #CityMetrics CM
ORDER BY CM.TotalRevenue DESC
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
GO

-- 4.4 Product category breakdown for top 2 cities
SELECT TC.City, TC.StateName,
       SUM(IIF(PC.Name = 'Bikes', SOD.LineTotal, 0)) AS Bikes,
       SUM(IIF(PC.Name = 'Clothing', SOD.LineTotal, 0)) AS Clothing,
       SUM(IIF(PC.Name = 'Accessories', SOD.LineTotal, 0)) AS Accessories
FROM #TopCandidates TC
INNER JOIN Person.Address A ON A.City = TC.City
INNER JOIN Person.StateProvince SP ON A.StateProvinceID = SP.StateProvinceID AND SP.Name = TC.StateName
INNER JOIN Sales.SalesOrderHeader SOH ON SOH.ShipToAddressID = A.AddressID
INNER JOIN Sales.Customer C ON SOH.CustomerID = C.CustomerID AND C.StoreID IS NULL
INNER JOIN Sales.SalesOrderDetail SOD ON SOH.SalesOrderID = SOD.SalesOrderID
INNER JOIN Production.Product P ON SOD.ProductID = P.ProductID
LEFT JOIN Production.ProductSubcategory PSC ON P.ProductSubcategoryID = PSC.ProductSubcategoryID
LEFT JOIN Production.ProductCategory PC ON PSC.ProductCategoryID = PC.ProductCategoryID
GROUP BY TC.City, TC.StateName
ORDER BY TC.City;
GO

-- 4.5 Yearly sales trend for top 2 cities
SELECT TC.City, TC.StateName, YEAR(SOH.OrderDate) AS OrderYear,
       COUNT(DISTINCT SOH.SalesOrderID) AS OrderCount,
       SUM(SOH.TotalDue) AS YearlyRevenue
FROM #TopCandidates TC
INNER JOIN Person.Address A ON A.City = TC.City
INNER JOIN Person.StateProvince SP ON A.StateProvinceID = SP.StateProvinceID AND SP.Name = TC.StateName
INNER JOIN Sales.SalesOrderHeader SOH ON SOH.ShipToAddressID = A.AddressID
INNER JOIN Sales.Customer C ON SOH.CustomerID = C.CustomerID AND C.StoreID IS NULL
WHERE YEAR(SOH.OrderDate) >= (SELECT MAX(YEAR(OrderDate)) - 2 FROM Sales.SalesOrderHeader)
GROUP BY TC.City, TC.StateName, YEAR(SOH.OrderDate)
ORDER BY TC.City, OrderYear;
GO
