# order2cash-demo

A standalone PL/SQL backend demo modelling a simplified **Order-to-Cash** workflow. Built to showcase professional Oracle database engineering skills independently of any production system (production Oracle work is covered by NDA and cannot be shared directly).

---

## Project summary

The project implements the core lifecycle of a sales order — creation, stock validation, and fulfilment — entirely in the Oracle database tier. There is no application layer. The goal is to demonstrate clean package design, correct use of Oracle-specific features (BULK COLLECT/FORALL, explicit cursors, named exceptions), and a disciplined approach to error handling.

---

## Schema overview

All objects live in a dedicated `ORDER2CASH` schema.

| Table | Purpose |
|---|---|
| `customers` | Buyer master: name, email, created_at |
| `products` | Product catalogue: name, unit_price, stock_qty |
| `orders` | Order header: FK to customer, date, status, total_amount |
| `order_lines` | Line items: FK to order + product, quantity, locked unit_price |

**Order status lifecycle:**

```
PENDING → VALIDATED → FULFILLED
                   → CANCELLED
```

A `CHECK` constraint on `orders.status` enforces the allowed values at the database level so no application code can write an invalid state.

All primary keys use `GENERATED ALWAYS AS IDENTITY` (Oracle 12c+). Foreign keys and `NOT NULL` constraints are declared explicitly. Indexes cover the most common filter columns (`customer_id`, `status`, `order_id` on lines).

---

## Package: `pkg_order_mgmt`

### Public types (spec)

| Type | Kind | Purpose |
|---|---|---|
| `t_line_item` | RECORD | One line submitted by the caller: `product_id`, `quantity` |
| `t_line_item_tbl` | TABLE OF t_line_item | Unbounded collection of line items |

### Custom exceptions (spec)

| Exception | SQLCODE | Raised when |
|---|---|---|
| `e_insufficient_stock` | -20001 | A product exists but its stock_qty is less than the requested quantity |
| `e_invalid_order_status` | -20002 | An order-state transition is not permitted (e.g. fulfilling a PENDING order, submitting zero lines) |
| `e_order_not_found` | -20003 | The order_id does not exist |
| `e_product_not_found` | -20004 | A product_id in the line items does not exist |

Declared in the spec (not the body) so any calling block can catch them by name without referencing internal package state.

### Procedures

**`create_order(p_customer_id, p_lines, o_order_id OUT)`**  
Inserts the order header and all line items. Returns the generated `order_id`.

**`validate_stock(p_lines, o_total_value OUT)`**  
Checks stock availability for every requested line. Raises `e_insufficient_stock` on first failure with a descriptive message (product name, requested qty, available qty).

**`fulfill_order(p_order_id)`**  
Transitions a `VALIDATED` order to `FULFILLED` and decrements stock.

---

## Design decisions

### Packages over standalone procedures
A package groups the spec (public contract) from the body (implementation). This allows the spec to be pinned in Oracle's shared pool, reduces parse overhead for high-frequency calls, and lets us change the body without invalidating callers — exactly how a stable API is designed.

### Records and collection types in the spec
`t_line_item` and `t_line_item_tbl` are declared in the package spec, not the body. This means callers can construct and populate the collection before they call any procedure. The alternative — constructing a collection inside the package — would require a dedicated "builder" API and limit the caller's ability to compose orders from dynamic sources.

### FORALL for bulk insert/update
`create_order` uses `FORALL` to insert all line items in a single SQL round-trip. A `FOR` loop with individual `INSERT` statements would generate one context switch per line between the PL/SQL and SQL engines. For a typical 10-line order that is negligible; for a wholesale upload of hundreds of lines it becomes the dominant cost. `FORALL` is the idiomatic Oracle pattern here.

`fulfill_order` uses `BULK COLLECT` + `FORALL` for the same reason: collect all (product_id, quantity) pairs in one `SELECT`, then decrement stock in one batched `UPDATE`.

### Explicit cursor in `validate_stock`
`validate_stock` uses a parameterised explicit cursor (one `OPEN`/`FETCH`/`CLOSE` per line) rather than N individual `SELECT INTO` calls because:

1. The cursor declaration makes the intent explicit and self-documenting — a reader can see the full query in one place.
2. `%ROWTYPE` binding means column additions to the query are automatically reflected in the loop variable without rename churn.
3. It separates the query definition from the loop logic, which matters when the query is non-trivial.

### Named exceptions over SQLCODE checks
`WHEN pkg_order_mgmt.e_insufficient_stock THEN` is more readable, searchable, and refactoring-safe than `WHEN OTHERS THEN IF SQLCODE = -20001`. Named exceptions are part of the package contract — they appear in the spec alongside the procedures, so callers can discover them without reading the body.

No `WHEN OTHERS THEN NULL` (silent swallowing). Every `WHEN OTHERS` block re-raises with `RAISE_APPLICATION_ERROR`, preserving the error context for the caller.

---

## How to run locally

### Prerequisites

- Oracle Database Free running at `localhost:1521/FREEPDB1`
  - Docker: `docker run -d -p 1521:1521 -e ORACLE_PWD=YourStrongPwd123 container-registry.oracle.com/database/free:latest`
  - (Requires a free Oracle Container Registry account at container-registry.oracle.com to pull)
- Python 3.9+ with `oracledb`: `pip install oracledb`

### Execution

```bash
# From the project root
python run_demo.py
```

The runner:
1. Connects as SYSDBA, drops and recreates the `ORDER2CASH` schema.
2. Reconnects as `ORDER2CASH`, inserts seed data.
3. Compiles `pkg_order_mgmt` (spec then body), checks `user_errors`.
4. Runs the test suite and captures DBMS_OUTPUT.
5. Writes real output to `test/sample_output.txt` and exits non-zero on any failure.

### Manual SQL*Plus execution

```sql
-- As sysdba
@sql/01_schema.sql

-- As order2cash
@sql/02_seed_data.sql
@sql/03_pkg_order_mgmt_spec.sql
@sql/04_pkg_order_mgmt_body.sql

SET SERVEROUTPUT ON
@test/test_pkg_order_mgmt.sql
```

---

## File layout

```
order2cash-demo/
├── sql/
│   ├── 01_schema.sql              — DROP/CREATE user, tables, indexes
│   ├── 02_seed_data.sql           — 7 customers, 15 products, 3 sample orders
│   ├── 03_pkg_order_mgmt_spec.sql — Package specification (public contract)
│   └── 04_pkg_order_mgmt_body.sql — Package body (implementation)
├── test/
│   ├── test_pkg_order_mgmt.sql    — Integration test (3 scenarios)
│   └── sample_output.txt          — Actual captured output from live DB run
├── run_demo.py                    — Python driver (schema → seed → compile → test)
└── README.md
```

---

## Roadmap

**Scope note:** This repo is a focused, single-package demo — one schema, one package (`pkg_order_mgmt`), three procedures. A broader PL/SQL stored-procedure library covering additional business domains, dynamic SQL, and scheduled jobs is a separate, not-yet-built project; nothing in this repo implies or scaffolds that larger effort.

- **Oracle APEX front end** — a form-based UI for order entry and fulfilment status, planned as a follow-up demo once the PL/SQL layer is stable.
- `pkg_reporting` — aggregate views: revenue by customer, stock-level alerts, fulfilment rate.
- Audit log table + trigger on `orders.status` changes.
