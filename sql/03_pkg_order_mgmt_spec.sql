-- =============================================================================
-- 03_pkg_order_mgmt_spec.sql
-- Package specification for pkg_order_mgmt.
-- Run as ORDER2CASH user.
--
-- DESIGN NOTE: All public types are declared in the spec so callers can
-- construct collections without needing package-body knowledge.  Custom
-- exceptions are also in the spec so a calling block can catch them by name
-- without having to inspect the body — this mirrors the contract-first
-- principle of a well-designed API.
-- =============================================================================

CREATE OR REPLACE PACKAGE pkg_order_mgmt AS

    -- ── Public record type: one line item submitted by the caller ─────────────
    -- Using a record rather than individual parameters keeps the procedure
    -- signature stable; adding a field later is a spec-only change.
    TYPE t_line_item IS RECORD (
        product_id  NUMBER,
        quantity    NUMBER
    );

    -- ── Collection of line items ───────────────────────────────────────────────
    -- TABLE OF (not VARRAY) so callers can pass arbitrary cardinality and the
    -- engine can use BULK operations internally without a size cap.
    TYPE t_line_item_tbl IS TABLE OF t_line_item;

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

    -- Exception init codes in Oracle's user-defined safe range (-20000..-20999).
    PRAGMA EXCEPTION_INIT(e_insufficient_stock,   -20001);
    PRAGMA EXCEPTION_INIT(e_invalid_order_status, -20002);
    PRAGMA EXCEPTION_INIT(e_order_not_found,      -20003);
    PRAGMA EXCEPTION_INIT(e_product_not_found,    -20004);

    -- ── Subprogram declarations ───────────────────────────────────────────────

    -- Creates a new order header and inserts all lines in one bulk operation.
    -- Returns the generated order_id via OUT parameter.
    PROCEDURE create_order (
        p_customer_id  IN  NUMBER,
        p_lines        IN  t_line_item_tbl,
        o_order_id     OUT NUMBER
    );

    -- Validates that every product in p_lines has enough stock.
    -- Raises e_product_not_found if a product_id does not exist.
    -- Raises e_insufficient_stock (with a descriptive message) if stock < qty.
    -- Returns estimated total value via OUT parameter so the caller can log it.
    PROCEDURE validate_stock (
        p_lines          IN  t_line_item_tbl,
        o_total_value   OUT NUMBER   -- estimated order value at current prices
    );

    -- Transitions a VALIDATED order to FULFILLED, decrementing stock in bulk.
    -- Raises e_order_not_found or e_invalid_order_status on bad input.
    PROCEDURE fulfill_order (
        p_order_id  IN  NUMBER
    );

END pkg_order_mgmt;
/
