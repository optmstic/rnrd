# Adventure Works — Online Auction & Store Expansion

**Course:** Managing Relational and Non-Relational Data (2026)
**Database:** AdventureWorks (SQL Server / T-SQL)

## Overview

This project extends the AdventureWorks database to address two business problems:

1. **Stock Clearance (Online Auctions)** — An auction system to clear older product stock before new model announcements.
2. **Brick and Mortar Expansion** — Data-driven recommendation of two US cities for Adventure Works' first physical retail stores.

Everything is delivered in a single idempotent T-SQL script that can be executed repeatedly without errors.

## Files

| File | Description |
|---|---|
| `auction.sql` | Main deliverable. Idempotent T-SQL script containing the Auction schema (tables + stored procedures) and the store expansion analytical queries. |
| `report.md` | Project report in Markdown with full documentation of the solution design, assumptions, methodology, results, and justification. |

## Auction System

### Schema: `Auction`

| Object | Type | Purpose |
|---|---|---|
| `Configuration` | Table | Single-row global config (bid increment, max multiplier, MakeFlag pricing). |
| `Product` | Table | One row per auction. Tracks status, pricing bounds, expiry. |
| `Bids` | Table | One row per bid. Tracks value, status, customer. |
| `uspAddProductToAuction` | Stored Procedure | Creates an auction for an eligible product. |
| `uspTryBidProduct` | Stored Procedure | Places a bid with validation and auto-close at max price. |
| `uspRemoveProductFromAuction` | Stored Procedure | Cancels an active auction (preserves bid history). |
| `uspListBidsOffersHistory` | Stored Procedure | Returns a customer's bid history (active or full). |
| `uspUpdateProductAuctionStatus` | Stored Procedure | Finalizes expired auctions, marks winners and losers. |

### Key Business Rules

- Only currently commercialized products (`SellEndDate` and `DiscontinuedDate` are NULL)
- Initial bid: 75% of ListPrice (`MakeFlag = 0`) or 50% (`MakeFlag = 1`)
- Min increment: $0.05, max bid: ListPrice x MaxBidMultiplier — all configurable
- One active auction per product at a time

## Store Expansion

The analytical queries recommend **Bellflower** and **Burbank**, California based on:

1. Excluding cities with the top 30 US resellers
2. Requiring sales in all 3 consumer-facing categories (Bikes, Clothing, Accessories)
3. Ranking by total individual customer revenue
4. Confirming growing yearly trends (2012–2014)

## Usage

1. Open `auction.sql` in SQL Server Management Studio (SSMS)
2. Execute against the `AdventureWorks` database
3. The script creates the schema, tables, stored procedures, and runs the analytical queries
