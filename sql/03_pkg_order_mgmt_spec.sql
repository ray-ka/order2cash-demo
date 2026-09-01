-- =============================================================================
-- 03_pkg_order_mgmt_spec.sql
-- Package specification for pkg_order_mgmt.
-- Run as ORDER2CASH user after the spec.
--
-- DESIGN NOTE: t_line_item_obj / t_line_item_tbl are SQL-level types (created
-- in 01_schema.sql), not PL/SQL-only types nested in this spec. That's what
-- lets validate_stock join the incoming collection against PRODUCTS in one
-- set-based query via TABLE(CAST(...)) rather than looping row by row.
--
-- Custom exceptions are declared here so a calling block can catch them by
-- name without having to inspect the body — this mirrors the contract-first
-- principle of a well-designed API.
-- =============================================================================

CREATE OR REPLACE PACKAGE pkg_order_mgmt AS

    -- ── Custom exceptions (declared here, init'd as named constants in body) ───
    -- Putting them in the spec means any anonymous block can catch them with
    --   EXCEPTION WHEN pkg_order_mgmt.e_insufficient_stock THEN …
    -- which is far more readable than catching SQLCODE values.
    -- Each exception maps to exactly one failure category so callers can
    -- branch on WHAT went wrong, not just that something did.
    e_insufficient_stock    EXCEPTION;  -- product exists but stock < requested qty
    e_invalid_order_status  EXCEPTION;  -- order-state transition not permitted
    e_order_not_found       EXCEPTION;  -- order_id does not exist
    e_product_not_found     EXCEPTION;  -- product_id does not exist
    e_unexpected_error      EXCEPTION;  -- anything NOT covered by the four above

    -- Exception init codes in Oracle's user-defined safe range (-20000..-20999).
    -- e_unexpected_error gets its own code (-20099) deliberately separate from
    -- the four business exceptions above: a WHEN OTHERS handler must never
    -- reuse a business exception's code, or a caller catching that exception
    -- by name will silently swallow unrelated failures (e.g. a constraint
    -- violation showing up as "insufficient stock").
    PRAGMA EXCEPTION_INIT(e_insufficient_stock,   -20001);
    PRAGMA EXCEPTION_INIT(e_invalid_order_status, -20002);
    PRAGMA EXCEPTION_INIT(e_order_not_found,      -20003);
    PRAGMA EXCEPTION_INIT(e_product_not_found,    -20004);
    PRAGMA EXCEPTION_INIT(e_unexpected_error,     -20099);

    -- ── Subprogram declarations ───────────────────────────────────────────────
    -- Order lifecycle: PENDING -> VALIDATED -> FULFILLED
    --                                       -> CANCELLED
    -- Every transition below is performed by exactly one procedure, and every
    -- procedure enforces which starting status it will accept.

    -- Creates a new order header (status PENDING) and inserts all lines in
    -- one bulk operation. Returns the generated order_id via OUT parameter.
    -- Does NOT commit — the caller controls the transaction boundary.
    PROCEDURE create_order (
        p_customer_id  IN  NUMBER,
        p_lines        IN  t_line_item_tbl,
        o_order_id     OUT NUMBER
    );

    -- Stateless feasibility check: validates that every product in p_lines
    -- has enough stock, without reference to any specific order. Useful for
    -- checking availability before create_order is even called.
    -- Raises e_product_not_found if a product_id does not exist.
    -- Raises e_insufficient_stock (with a descriptive message) if stock < qty.
    -- Returns estimated total value via OUT parameter so the caller can log it.
    PROCEDURE validate_stock (
        p_lines          IN  t_line_item_tbl,
        o_total_value   OUT NUMBER   -- estimated order value at current prices
    );

    -- Re-checks stock for an EXISTING order's line items and, if sufficient,
    -- transitions it PENDING -> VALIDATED. This is the procedure that was
    -- previously missing: nothing else in this package may set VALIDATED.
    -- Raises e_order_not_found, e_invalid_order_status (wrong starting status),
    -- or e_insufficient_stock. Does NOT commit.
    PROCEDURE validate_order (
        p_order_id  IN  NUMBER
    );

    -- Transitions a VALIDATED order to FULFILLED, decrementing stock in bulk.
    -- Locks the affected product rows (SELECT ... FOR UPDATE) and re-verifies
    -- stock immediately before decrementing, closing the gap where stock
    -- could change between validate_order and fulfill_order under concurrent
    -- orders for the same product.
    -- Raises e_order_not_found, e_invalid_order_status, or e_insufficient_stock.
    -- Does NOT commit.
    PROCEDURE fulfill_order (
        p_order_id  IN  NUMBER
    );

    -- Cancels an order that has not yet been fulfilled. Valid from PENDING
    -- or VALIDATED only; a FULFILLED or already-CANCELLED order raises
    -- e_invalid_order_status. This is the only path to CANCELLED status.
    -- Does NOT commit.
    PROCEDURE cancel_order (
        p_order_id  IN  NUMBER
    );

END pkg_order_mgmt;
/
