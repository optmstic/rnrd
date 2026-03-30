# Managing Relational and Non-Relational Data — Project Report

## 1. Introduction

Adventure Works Bicycles is a fictional company that manufactures and sells bicycles, components, apparel, and accessories globally. The company serves two types of customers: retail stores (resellers) that buy products for resale, and individual consumers who purchase directly via the online store. Adventure Works does not currently operate any physical retail stores of its own.

This project addresses two business problems using T-SQL against the AdventureWorks database:

- **Stock Clearance (Sections III–IV):** Extend the database to support online auctions for products being replaced by new models.
- **Brick and Mortar Expansion (Section V):** Recommend two US cities for opening the company's first physical retail stores.

All work is delivered in a single idempotent T-SQL script (`auction.sql`). The script can be executed multiple times against the AdventureWorks database without errors or data duplication.

## 2. Stock Clearance — Online Auctions

### 2.1 Problem

Every December, when new bicycle models are announced, there is still a considerable stock of older models. A previous discount campaign did not solve the problem. The leadership team decided to implement an online auction system covering all products for which a new model is expected within two weeks. The auction runs during the last two weeks of November, including Black Friday, when a high workload is expected.

### 2.2 Solution Design

The solution extends the AdventureWorks database by creating a new `Auction` schema containing three tables and five stored procedures. The script is fully idempotent — all table creation uses `IF NOT EXISTS` guards, stored procedures use `CREATE OR ALTER`, and the configuration data is populated only once.

#### Tables

| Table | Purpose |
|---|---|
| `Auction.Configuration` | Single-row table storing global thresholds: minimum bid increment, maximum bid multiplier, and MakeFlag pricing multipliers. A `CHECK (ConfigID = 1)` constraint enforces the single-row design. These values can be changed by an administrator without modifying code. |
| `Auction.Product` | One row per auction. Tracks the product being auctioned, initial and last bid price, start and expire dates, maximum bid price, and auction status (`Active`, `Cancelled`, `Closed`). A foreign key references `Production.Product`. Only one active auction per ProductID is allowed at any time. |
| `Auction.Bids` | One row per bid. Tracks the auction, customer, bid value, timestamp, and bid status (`Active`, `Inactive`, `Cancelled`, `Winner`, `Lost`). Foreign keys reference `Auction.Product` and `Sales.Customer`. |

#### Assumptions

The functional specification leaves certain design decisions open. The following assumptions were made:

- **Single unit per auction.** The specification does not mention quantity, so the system assumes each auction covers one item.
- **Total bid value.** The `@BidAmount` parameter represents the total bid, not an increment over the previous bid. This follows standard auction convention and avoids ambiguity.
- **Immediate close at maximum price.** When a bid reaches the maximum price (ListPrice multiplied by MaxBidMultiplier), the auction closes immediately and the bidder is declared the winner, since no higher bid is possible.
- **Tie-breaking rule.** If multiple bids share the highest value, the latest bid (by `BidDate`) wins. This ensures a deterministic outcome.
- **Manual status update.** The `uspUpdateProductAuctionStatus` procedure is invoked manually before dispatching orders, as stated in the specification. The system does not assume any automated scheduling.
- **Cancelled bid preservation.** When an auction is cancelled, all related bids are marked as "Cancelled" rather than deleted, so they remain visible in the customer's bid history.
- **Configuration persistence.** The Configuration table is pre-populated once with default values during the first script execution. Subsequent runs do not overwrite administrator changes.

#### Business Rules Implemented

- **Eligibility:** Only products where both `SellEndDate` and `DiscontinuedDate` are NULL can be auctioned. This ensures only currently commercialized products enter the auction.
- **Initial Bid Pricing:** Products not manufactured in-house (`MakeFlag = 0`) start at 75% of the listed price. Products manufactured in-house (`MakeFlag = 1`) start at 50%. These multipliers are stored in the Configuration table and can be adjusted without code changes.
- **Bid Limits:** The minimum bid increment defaults to $0.05. The maximum bid equals the listed price multiplied by the `MaxBidMultiplier` (default 1.00). Both thresholds are global and configurable via the Configuration table.
- **Concurrency:** Only one active auction per ProductID is allowed at any time.

#### Stored Procedures

**uspAddProductToAuction** receives a `@ProductID` and optionally `@ExpireDate` and `@InitialBidPrice`. If `@ExpireDate` is not provided, the auction expires in one week. If `@InitialBidPrice` is not provided, it is calculated using the MakeFlag pricing rules from the Configuration table. The procedure validates that the product exists, is currently commercialized (both `SellEndDate` and `DiscontinuedDate` are NULL), and does not already have an active auction.

**uspTryBidProduct** receives `@ProductID`, `@CustomerID`, and optionally `@BidAmount`. If `@BidAmount` is omitted, the bid defaults to the current price plus the minimum increment from the Configuration table. The procedure validates that the bid is higher than the current bid, meets the minimum increment, and does not exceed the maximum. If the bid reaches the maximum price, the auction is closed immediately and the bidder is marked as the winner. The previous highest bid is marked as "Inactive".

**uspRemoveProductFromAuction** receives `@ProductID` and cancels the active auction. Both the auction status and all related bid statuses are set to "Cancelled" so they remain visible in the customer's bid history.

**uspListBidsOffersHistory** receives `@CustomerID`, `@StartTime`, `@EndTime`, and `@Active` (defaults to 1). When `@Active = 1`, it returns only bids on currently active auctions. When `@Active = 0`, it returns all bids including those on cancelled or closed auctions, providing the customer with a complete history.

**uspUpdateProductAuctionStatus** takes no parameters. It closes all auctions past their expire date, marks the highest bidder as the winner (using the latest bid as a tiebreaker), and marks all remaining bids as lost. This procedure is manually invoked before processing orders for dispatch.

All stored procedures include `TRY...CATCH` error handling. Procedures that modify multiple tables use explicit transactions with rollback on error, ensuring data consistency.

### 2.3 Configuration Table Defaults

| Setting | Default Value | Meaning |
|---|---|---|
| MinBidIncrement | $0.05 | Minimum amount a bid must exceed the current price |
| MaxBidMultiplier | 1.00 | Maximum bid = ListPrice x 1.00 (100% of listed price) |
| MakeFlag0_Multiplier | 0.75 | Initial bid for non-in-house products = 75% of ListPrice |
| MakeFlag1_Multiplier | 0.50 | Initial bid for in-house products = 50% of ListPrice |

These defaults are populated once during the first script execution and are not overwritten on subsequent runs. An administrator can update these values at any time using a simple `UPDATE` statement.

## 3. Brick and Mortar Expansion

### 3.1 Problem

Adventure Works wants to open its first two physical retail stores in the United States to sell directly to individual customers. However, the company does not want to compete directly with stores that buy its products for resale, as this could jeopardize the wholesale business. Therefore, cities where the best 30 US-based resellers are located must be excluded from consideration.

### 3.2 Assumptions

The specification asks for a recommendation but does not prescribe the selection methodology. The following assumptions were made:

- **Definition of "best" resellers.** The specification does not define what makes a reseller the "best". Total sales revenue (`TotalDue` from `Sales.SalesOrderHeader`) is used as the ranking criterion, as it is the most objective and measurable indicator of a reseller's business volume with Adventure Works.
- **Reseller location.** A reseller's city is determined by its registered business address (`Person.BusinessEntityAddress`), not by shipping destinations. This represents where the business operates.
- **Individual customer identification.** Individual customers are identified by `StoreID IS NULL` in `Sales.Customer`, which distinguishes direct online buyers from store (reseller) contacts in the AdventureWorks data model.
- **Customer location.** A customer's city is determined by the shipping address (`ShipToAddressID`) on their orders, as this represents where the customer actually receives products and therefore where retail demand exists.
- **Components category exclusion.** The AdventureWorks database contains four product categories: Bikes, Components, Clothing, and Accessories. However, Components are exclusively purchased by resellers and workshops — no individual customer in the entire database has ever bought a product from the Components category. This is a database-wide pattern, not specific to any city. The maximum number of product categories any city can have from individual customer sales is therefore three (Bikes, Clothing, Accessories). Requiring all four would eliminate every city in the database. The category diversity threshold is set to three, which effectively means "the city has individual customer demand across all consumer-facing product lines."
- **No competition on components.** Although the recommended cities have existing resellers that sell components, the physical store targets individual consumers — a different customer segment. The store would not stock components, and there is no direct competition with local resellers on that product line.
- **Yearly trend window.** The analysis covers the most recent three calendar years available in the database (2012–2014) to assess whether demand is current and sustained.

### 3.3 Methodology

The recommendation is based on five analytical steps, all implemented as T-SQL queries in the `auction.sql` script. The queries use temp tables (`#ExcludedCities`, `#TopCandidates`) to store intermediate results and avoid repeating complex subqueries.

**Step 1 — Identify the top 30 US resellers.** Resellers (stores) are ranked by their total sales revenue (`TotalDue` from `Sales.SalesOrderHeader`). Only US-based resellers are considered. This produces a list of 30 stores that represent Adventure Works' most valuable wholesale partners.

**Step 2 — Exclude their cities.** The distinct US cities where these top 30 resellers have their registered business addresses are collected into the `#ExcludedCities` temp table. This ensures Adventure Works does not open a retail store in a city where it could compete directly with a top reseller.

**Step 3 — Rank remaining cities and select top 2.** All US cities with individual customer orders (`StoreID IS NULL`) are ranked by total revenue and customer count, excluding the cities from Step 2. A correlated subquery in the `HAVING` clause ensures only cities with individual customer sales in at least three product categories are considered. Since Components are never purchased by individual customers, the three consumer-facing categories — Bikes, Clothing, and Accessories — are the maximum any city can achieve. This filter ensures the recommended cities have broad demand across all product lines the store would sell. The top 2 cities by total revenue are stored in the `#TopCandidates` temp table. A broader top-20 ranking is also displayed for context, using `RANK()` window functions for both revenue and customer count.

**Step 4 — Product category breakdown.** For the top 2 candidate cities, a breakdown of individual customer revenue by product category (Bikes, Clothing, Accessories) confirms the demand profile. This uses `SUM(IIF(...))` to pivot the categories into columns, producing one row per city.

**Step 5 — Yearly sales trend.** Revenue and order count per year for the top 2 cities over the last three calendar years shows whether demand is growing, stable, or declining. A store investment requires confidence that demand will persist.

### 3.4 Results

#### Excluded Cities

The top 30 US resellers are concentrated in 29 distinct cities including Austin, Memphis, Minneapolis, among others. These cities are removed from consideration. The fact that 30 resellers map to 29 cities indicates that two top resellers share one city.

#### Recommended Cities

Based on the analysis, the two recommended cities are:

**1. Bellflower, California**
- Total revenue from individual customers: $334018.09
- Number of unique customers: 194
- Number of orders: 243
- Average order value: $1374.56

**2. Burbank, California**
- Total revenue from individual customers: $305487.15
- Number of unique customers: 192
- Number of orders: 238
- Average order value: $1283.56

Both cities are located in California, which reflects the strong concentration of Adventure Works' individual customer base in that state. Bellflower leads in total revenue, order count, and average order value. Burbank is close behind with a similar customer base size.

#### Product Category Demand

| City | Bikes | Clothing | Accessories |
|---|---|---|---|
| Bellflower | $292758.29 | $3644.66 | $5875.86 |
| Burbank | $267154.06 | $3199.74 | $6105.15 |

In both cities, Bikes represent the dominant revenue source (over 96% of total), which is expected given that bicycles are Adventure Works' core product and highest-priced category. Clothing and Accessories contribute smaller but consistent revenue, confirming that customers in these cities buy across the full range of consumer-facing product lines.

In the AdventureWorks database, no individual customer has ever purchased from the Components category. Components are exclusively sold to resellers and workshops, representing a business-to-business segment. This is consistent across all US cities, not specific to the recommended ones. Although both Bellflower and Burbank have existing resellers that sell components, the proposed physical store targets individual consumers — a different customer segment. The store and the local resellers serve different markets (retail consumers versus workshops and businesses), so there is no direct competition on that product line.

#### Yearly Trend

| City | Year | Orders | Revenue |
|---|---|---|---|
| Bellflower | 2012 | 33 | $89230.10 |
| Bellflower | 2013 | 101 | $94702.49 |
| Bellflower | 2014 | 97 | $105819.12 |
| Burbank | 2012 | 26 | $73334.93 |
| Burbank | 2013 | 92 | $86148.06 |
| Burbank | 2014 | 105 | $87088.32 |

Both cities show consistent revenue growth from 2012 to 2014. Bellflower grew from $89230.10 to $105819.12, an increase of 18.6%. Burbank grew from $73334.93 to $87088.32, an increase of 18.7%. Order volume tripled from 2012 to 2013 in both cities and remained stable into 2014, indicating that the initial growth was not a one-time spike but a sustained trend. This upward trajectory in both revenue and order volume supports the viability of a long-term retail investment in either city.

### 3.5 Justification

The two cities were selected based on the following criteria, applied in order:

1. **No conflict with top resellers** — both cities are free from top-30 US resellers, avoiding any risk to the wholesale business.
2. **Category diversity** — both cities have individual customer sales in all three consumer-facing product categories (Bikes, Clothing, Accessories), ensuring the store can stock a full product range.
3. **Highest revenue from individual customers** — Bellflower and Burbank rank first and second among all eligible cities, proving strong existing demand for Adventure Works products.
4. **Large customer base** — with 194 and 192 unique customers respectively, both cities have a broad buyer base rather than reliance on a few high-spending individuals, making the store viable long-term.
5. **Stable and growing sales trend** — revenue grew approximately 18.6% over three years in both cities, with order volume tripling from 2012 to 2013 and holding steady. This confirms demand is not declining.

## 4. Conclusion

The `auction.sql` script delivers both project requirements in a single idempotent file. The Stock Clearance section creates the Auction schema with three tables and five stored procedures, all with proper error handling and transaction management. The Configuration table allows all business thresholds to be adjusted without code changes. The Brick and Mortar section provides five analytical queries that systematically identify Bellflower and Burbank, California as the recommended locations for Adventure Works' first two physical retail stores, supported by revenue data, customer counts, product category analysis, and yearly trends.

## References

- Microsoft (2014a). AdventureWorks Sample Databases. Available at: https://www.sqldatadictionary.com/AdventureWorks2014/
