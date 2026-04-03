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
| `Auction.Product` | One row per auction. Tracks the product being auctioned, initial and last bid price, start and expire dates, maximum bid price, and auction status (`Active`, `Cancelled`, `FINISHED by TIME`, `FINISHED by PRICE`). The `LastBidPrice` column starts as NULL and is only set when the first bid is placed, allowing the system to distinguish between auctions with no bids and auctions at their starting price. A foreign key references `Production.Product`. Only one active auction per ProductID is allowed at any time. |
| `Auction.Bids` | One row per bid. Tracks the auction, customer, bid value, timestamp, and bid status (`Active`, `Inactive`, `Cancelled`, `Winner`, `Lost`). A CHECK constraint enforces these values. Foreign keys reference `Auction.Product` and `Sales.Customer`. |

#### Assumptions

The functional specification leaves certain design decisions open. The following assumptions were made:

- **Single unit per auction.** The specification does not mention quantity, so the system assumes each auction covers one item.
- **Total bid value.** The `@BidAmount` parameter represents the total bid, not an increment over the previous bid. This follows standard auction convention and avoids ambiguity.
- **Immediate close at maximum price.** When a bid reaches the maximum price (ListPrice multiplied by MaxBidMultiplier), the auction finishes immediately with status `FINISHED by PRICE` and the bidder is declared the winner, since no higher bid is possible. All other bids are marked as `Lost`.
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

**uspAddProductToAuction** (`@ProductID`, optional `@ExpireDate`, optional `@InitialBidPrice`) — defaults expire to one week and price to the MakeFlag-based calculation. Validates the product exists, is currently commercialized, and has no active auction.

**uspTryBidProduct** (`@ProductID`, `@CustomerID`, optional `@BidAmount`) — defaults to current price plus minimum increment. When no bids exist, falls back to the initial bid price. Validates the bid exceeds the current price, meets minimum increment, and does not exceed the maximum. If the bid reaches the maximum, the auction finishes as `FINISHED by PRICE` and the bidder wins; all other bids are marked `Lost`.

**uspRemoveProductFromAuction** (`@ProductID`) — cancels the active auction. Both auction and bid statuses are set to "Cancelled" for history preservation.

**uspListBidsOffersHistory** (`@CustomerID`, `@StartTime`, `@EndTime`, `@Active` default 1) — returns bids on active auctions only (`@Active = 1`) or full history including finished/cancelled (`@Active = 0`).

**uspUpdateProductAuctionStatus** (no params) — finalizes expired auctions as `FINISHED by TIME`, marks the highest bidder as winner (latest bid as tiebreaker), and remaining bids as `Lost`. Manually invoked before dispatch.

All procedures use `TRY...CATCH` error handling with explicit transactions and rollback where multiple tables are modified.

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
- **Components category exclusion.** Of the four product categories (Bikes, Components, Clothing, Accessories), Components are exclusively purchased by resellers — no individual customer has ever bought one. The category diversity threshold is therefore set to three (all consumer-facing categories). The physical stores would not stock components, so there is no direct competition with local resellers.
- **Geographic proximity via ZIP codes.** Since the database lacks geographic coordinates, the first three digits of US postal codes are used as a metro-area proxy. Two cities whose 3-digit prefixes differ by 20 or less are treated as the same metro (e.g. Greater Los Angeles spans 900–935; San Francisco at 941+ is separate).
- **Yearly trend window.** The analysis covers the most recent three calendar years available in the database (2012–2014) to assess whether demand is current and sustained.

### 3.3 Methodology

The recommendation is based on five analytical steps, all implemented as T-SQL queries in the `auction.sql` script. The queries use temp tables (`#ExcludedCities`, `#TopCandidates`) to store intermediate results and avoid repeating complex subqueries.

**Step 1 — Identify the top 30 US resellers.** Resellers (stores) are ranked by their total sales revenue (`TotalDue` from `Sales.SalesOrderHeader`). Only US-based resellers are considered. This produces a list of 30 stores that represent Adventure Works' most valuable wholesale partners.

**Step 2 — Exclude their cities.** The distinct US cities where these top 30 resellers have their registered business addresses are collected into the `#ExcludedCities` temp table. This ensures Adventure Works does not open a retail store in a city where it could compete directly with a top reseller.

**Step 3 — Rank remaining cities and select top 2 with geographic spread.** All US cities with individual customer orders (`StoreID IS NULL`) are ranked by total revenue, excluding the cities from Step 2. A `HAVING` clause ensures only cities with sales in all three consumer-facing categories qualify. To avoid selecting two cities in the same metro area, the query applies a greedy approach using the ZIP-prefix proximity rule from the assumptions: pick the highest-revenue city first, then pick the next-best city whose 3-digit ZIP prefix differs by more than 20. A broader top-20 ranking is also displayed for context using `RANK()` window functions.

**Step 4 — Product category breakdown.** For the top 2 candidate cities, a breakdown of individual customer revenue by product category (Bikes, Clothing, Accessories) confirms the demand profile. This uses `SUM(IIF(...))` to pivot the categories into columns, producing one row per city.

**Step 5 — Yearly sales trend.** Revenue and order count per year for the top 2 cities over the last three calendar years shows whether demand is growing, stable, or declining. A store investment requires confidence that demand will persist.

### 3.4 Results

#### Excluded Cities

The top 30 US resellers are concentrated in 29 distinct cities including Austin, Memphis and Minneapolis, among others. These cities are removed from consideration. The fact that 30 resellers map to 29 cities indicates that two top resellers share one city, specifically Seattle.

#### Recommended Cities

Based on the analysis, the two recommended cities are:

**1. Bellflower, California** (Greater Los Angeles area)
- Total revenue from individual customers: $334018.09
- Number of unique customers: 194
- Number of orders: 243
- Average order value: $1374.56

**2. Berkeley, California** (San Francisco Bay Area)
- Total revenue from individual customers: $258138.46
- Number of orders (last 3 years): 229
- Revenue breakdown: Bikes $247942.88, Clothing $3361.24, Accessories $6834.34

Without the geographic spread constraint, the top two cities would be Bellflower and Burbank — both in Greater Los Angeles, only ~20 km apart. By applying the ZIP-prefix metro clustering, the second pick shifts to Berkeley in the Bay Area (~550 km away), sacrificing ~$47,000 in revenue compared to Burbank ($305,487.15) but gaining access to an entirely separate market.

#### Product Category Demand

| City | Bikes | Clothing | Accessories |
|---|---|---|---|
| Bellflower | $292758.29 | $3644.66 | $5875.86 |
| Berkeley | $247942.88 | $3361.24 | $6834.34 |

Bikes dominate revenue in both cities (~96%), which is expected given bicycles are the highest-priced category. Clothing and Accessories contribute smaller but consistent revenue, confirming broad demand across all consumer-facing product lines. Berkeley has slightly higher Accessories revenue ($6834 vs $5876), suggesting stronger cross-selling potential.

#### Yearly Trend

| City | Year | Orders | Revenue |
|---|---|---|---|
| Bellflower | 2012 | 33 | $89230.10 |
| Bellflower | 2013 | 101 | $94702.49 |
| Bellflower | 2014 | 97 | $105819.12 |
| Berkeley | 2012 | 23 | $50807.42 |
| Berkeley | 2013 | 107 | $91615.40 |
| Berkeley | 2014 | 99 | $91418.33 |

Both cities show strong growth from 2012 to 2013 followed by stabilization in 2014. Bellflower grew 18.6% overall ($89,230 → $105,819) with order volume tripling from 33 to 101 and holding at 97. Berkeley shows steeper growth — revenue nearly doubled from $50,807 to $91,615 (80.3%) with orders surging from 23 to 107 — then held steady in 2014 ($91,418, 99 orders). This pattern of rapid expansion followed by retention, rather than decline, is a positive signal for retail investment in both markets.

### 3.5 Justification

The two cities were selected based on the following criteria, applied in order:

1. **No conflict with top resellers** — both cities are free from top-30 US resellers, avoiding risk to the wholesale business.
2. **Category diversity** — both cities have sales in all three consumer-facing categories, ensuring a full product range.
3. **Highest revenue** — Bellflower ranks first among eligible cities; Berkeley is the highest-revenue city outside the LA metro area.
4. **Geographic spread** — the ZIP-prefix clustering ensures the two stores serve independent markets (~550 km apart) rather than competing in the same metro.
5. **Large customer base** — broad buyer base in both cities, not reliant on a few high-spending individuals.
6. **Growing sales trend** — revenue grew consistently over 2012–2014 in both cities, confirming sustained demand.

## 4. Conclusion

The `auction.sql` script delivers both requirements in a single idempotent file. The auction system uses three tables and five stored procedures with distinct completion statuses (`FINISHED by TIME` and `FINISHED by PRICE`) and a fully configurable Configuration table. The store expansion analysis systematically identifies Bellflower (Greater Los Angeles) and Berkeley (San Francisco Bay Area) as the recommended locations, supported by revenue rankings, geographic spread analysis, category breakdowns, and yearly trends.

## References

- Microsoft (2014a). AdventureWorks Sample Databases. Available at: https://www.sqldatadictionary.com/AdventureWorks2014/
