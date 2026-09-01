-- =============================================================================
-- 04_pkg_order_mgmt_body.sql
-- Package body for pkg_order_mgmt.
-- Run as ORDER2CASH user after the spec.
--
-- TRANSACTION CONTROL: no procedure in this package issues COMMIT or
-- ROLLBACK. Both are the caller's responsibility. Embedding COMMIT here
-- would silently commit whatever else the caller had pending in the same
-- transaction; embedding ROLLBACK here would silently undo it. A reusable
-- package has no way to know what else is in the caller's transaction, so
-- it must not make that call.
-- =============================================================================

CREATE OR REPLACE PACKAGE BODY pkg_order_mgmt AS

    -- =========================================================================
    -- PRIVATE helpers
    -- =========================================================================

    -- Fetches the current status of an order; raises e_order_not_found if
    -- the row doesn't exist.  Centralising this avoids duplicating the
    -- SELECT + exception logic across every procedure that checks status.
    FUNCTION get_order_status (p_order_id IN NUMBER) RETURN VARCHAR2 IS
        v_status orders.status%TYPE;
    BEGIN
        SELECT status
          INTO v_status
          FROM orders
         WHERE order_id = p_order_id;
        RETURN v_status;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20003,
                'Order ' || p_order_id || ' does not exist.');
    END get_order_status;


    -- =========================================================================
    -- create_order
    -- =========================================================================
    -- DESIGN: We receive a PL/SQL collection (t_line_item_tbl) and use FORALL
    -- to INSERT all line rows in a single round-trip to the SQL engine.
    -- Row-by-row INSERT inside a loop would generate N context switches between
    -- the PL/SQL and SQL engines; FORALL collapses that to one, which matters
    -- on large orders and scales better as order size grows.
    PROCEDURE create_order (
        p_customer_id  IN  NUMBER,
        p_lines        IN  t_line_item_tbl,
        o_order_id     OUT NUMBER
    ) IS
        v_total  NUMBER := 0;
        v_price  products.unit_price%TYPE;
    BEGIN
        -- Basic guard: nothing to insert
        IF p_lines IS NULL OR p_lines.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Order must contain at least one line item.');
        END IF;

        -- ── Step 1: compute total amount by looking up each product's price ───
        -- We resolve prices here (not from the caller) to prevent price
        -- tampering; unit_price is also stored on the line for historical record.
        FOR i IN 1 .. p_lines.COUNT LOOP
            BEGIN
                SELECT unit_price
                  INTO v_price
                  FROM products
                 WHERE product_id = p_lines(i).product_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20004,
                        'Product ' || p_lines(i).product_id || ' not found.');
            END;
            v_total := v_total + (v_price * p_lines(i).quantity);
        END LOOP;

        -- ── Step 2: insert the order header ──────────────────────────────────
        INSERT INTO orders (customer_id, order_date, status, total_amount)
        VALUES (p_customer_id, SYSDATE, 'PENDING', v_total)
        RETURNING order_id INTO o_order_id;

        -- ── Step 3: bulk-insert all line items ───────────────────────────────
        FORALL i IN 1 .. p_lines.COUNT
            INSERT INTO order_lines (order_id, product_id, quantity, unit_price)
            SELECT o_order_id,
                   p_lines(i).product_id,
                   p_lines(i).quantity,
                   unit_price          -- pull live price from products table
              FROM products
             WHERE product_id = p_lines(i).product_id;

        DBMS_OUTPUT.PUT_LINE('[create_order] Order #' || o_order_id ||
            ' created with ' || p_lines.COUNT || ' line(s). Total: ' ||
            TO_CHAR(v_total, 'FM$999,990.00'));

    EXCEPTION
        -- Propagate our named exceptions unchanged so callers can branch on
        -- exactly what went wrong rather than receiving a generic OTHERS wrap.
        WHEN e_invalid_order_status OR e_product_not_found THEN
            RAISE;
        WHEN OTHERS THEN
            -- Distinct code (-20099) from any business exception above, so a
            -- caller catching e.g. e_invalid_order_status by name can never
            -- accidentally catch an unrelated failure here instead.
            RAISE_APPLICATION_ERROR(-20099,
                'create_order failed: ' || SQLERRM);
    END create_order;


    -- =========================================================================
    -- validate_stock
    -- =========================================================================
    -- DESIGN: p_lines joins directly against PRODUCTS via TABLE() in a single
    -- set-based query. This replaced an earlier version that opened one
    -- parameterised cursor per line item (N round trips to the SQL engine).
    -- TABLE() only works because t_line_item_tbl is a SQL-level object type
    -- (see 01_schema.sql) rather than a PL/SQL-only record/collection.
    PROCEDURE validate_stock (
        p_lines         IN  t_line_item_tbl,
        o_total_value   OUT NUMBER
    ) IS
        v_total  NUMBER := 0;

        TYPE t_check_row IS RECORD (
            product_id     products.product_id%TYPE,
            name           products.name%TYPE,
            stock_qty      products.stock_qty%TYPE,
            unit_price     products.unit_price%TYPE,
            requested_qty  NUMBER
        );
        TYPE t_check_tbl IS TABLE OF t_check_row;
        v_rows t_check_tbl;
    BEGIN
        o_total_value := 0;

        IF p_lines IS NULL OR p_lines.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Order must contain at least one line item.');
        END IF;

        -- One statement, one round trip — regardless of how many lines p_lines
        -- holds. Assumes at most one line per product_id (matches how every
        -- caller in this repo builds its line collection).
        SELECT p.product_id, p.name, p.stock_qty, p.unit_price, l.quantity
          BULK COLLECT INTO v_rows
          FROM products p
          JOIN TABLE(p_lines) l ON l.product_id = p.product_id;

        IF v_rows.COUNT < p_lines.COUNT THEN
            RAISE_APPLICATION_ERROR(-20004,
                'One or more requested products do not exist.');
        END IF;

        FOR i IN 1 .. v_rows.COUNT LOOP
            IF v_rows(i).stock_qty < v_rows(i).requested_qty THEN
                RAISE_APPLICATION_ERROR(-20001,
                    'Insufficient stock for product "' || v_rows(i).name ||
                    '" (id=' || v_rows(i).product_id || '): requested ' ||
                    v_rows(i).requested_qty || ', available ' || v_rows(i).stock_qty || '.');
            END IF;

            v_total := v_total + (v_rows(i).unit_price * v_rows(i).requested_qty);

            DBMS_OUTPUT.PUT_LINE('[validate_stock] Product "' || v_rows(i).name ||
                '" OK — stock: ' || v_rows(i).stock_qty ||
                ', requested: ' || v_rows(i).requested_qty);
        END LOOP;

        o_total_value := v_total;
        DBMS_OUTPUT.PUT_LINE('[validate_stock] All ' || p_lines.COUNT ||
            ' line(s) validated. Estimated value: ' ||
            TO_CHAR(v_total, 'FM$999,990.00'));

    EXCEPTION
        WHEN e_insufficient_stock OR e_product_not_found OR e_invalid_order_status THEN
            RAISE;
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20099,
                'validate_stock failed: ' || SQLERRM);
    END validate_stock;


    -- =========================================================================
    -- validate_order
    -- =========================================================================
    -- DESIGN: This is the procedure that actually performs the PENDING ->
    -- VALIDATED transition. Previously nothing in this package set VALIDATED
    -- at all — only a test script's raw UPDATE did, which meant the status
    -- machine had no real gatekeeper for that step.
    PROCEDURE validate_order (
        p_order_id IN NUMBER
    ) IS
        v_status  orders.status%TYPE;

        CURSOR c_check IS
            SELECT p.product_id, p.name, p.stock_qty, ol.quantity
              FROM order_lines ol
              JOIN products p ON p.product_id = ol.product_id
             WHERE ol.order_id = p_order_id;
        TYPE t_check_tbl IS TABLE OF c_check%ROWTYPE;
        v_rows t_check_tbl;
    BEGIN
        v_status := get_order_status(p_order_id);   -- raises e_order_not_found

        IF v_status != 'PENDING' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'Cannot validate order #' || p_order_id ||
                ': expected status PENDING, found ' || v_status || '.');
        END IF;

        OPEN c_check;
        FETCH c_check BULK COLLECT INTO v_rows;
        CLOSE c_check;

        IF v_rows.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'Order #' || p_order_id || ' has no line items.');
        END IF;

        FOR i IN 1 .. v_rows.COUNT LOOP
            IF v_rows(i).stock_qty < v_rows(i).quantity THEN
                RAISE_APPLICATION_ERROR(-20001,
                    'Insufficient stock for product "' || v_rows(i).name ||
                    '" (id=' || v_rows(i).product_id || '): requested ' ||
                    v_rows(i).quantity || ', available ' || v_rows(i).stock_qty || '.');
            END IF;
        END LOOP;

        UPDATE orders SET status = 'VALIDATED' WHERE order_id = p_order_id;

        DBMS_OUTPUT.PUT_LINE('[validate_order] Order #' || p_order_id ||
            ' -> VALIDATED (' || v_rows.COUNT || ' line(s) checked).');

    EXCEPTION
        WHEN e_order_not_found OR e_invalid_order_status OR e_insufficient_stock THEN
            RAISE;
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20099,
                'validate_order failed for order #' || p_order_id || ': ' || SQLERRM);
    END validate_order;


    -- =========================================================================
    -- fulfill_order
    -- =========================================================================
    -- DESIGN: Stock decrements use BULK COLLECT + FORALL to avoid N individual
    -- UPDATE statements. Before decrementing, the affected product rows are
    -- locked with SELECT ... FOR UPDATE and stock is re-verified under that
    -- lock. validate_order may have run long before this call, and another
    -- order could have consumed the same stock in the meantime — locking and
    -- re-checking here closes that gap, rather than leaving it to the
    -- stock_qty >= 0 CHECK constraint to fail the statement after the fact.
    PROCEDURE fulfill_order (p_order_id IN NUMBER) IS
        v_status  orders.status%TYPE;

        -- SYS.ODCINUMBERLIST is a built-in SQL nested table of NUMBER — using
        -- it here means we don't need a custom type just to pass a list of
        -- ids into TABLE() below.
        v_product_ids   SYS.ODCINUMBERLIST;
        v_quantities    SYS.ODCINUMBERLIST;
        v_locked_ids    SYS.ODCINUMBERLIST;
        v_locked_stock  SYS.ODCINUMBERLIST;

        -- Locked stock snapshot keyed by product_id, for O(1) lookup against
        -- v_product_ids/v_quantities.
        TYPE t_stock_map IS TABLE OF NUMBER INDEX BY VARCHAR2(40);
        v_stock_map t_stock_map;

    BEGIN
        -- ── Guard: order must exist and be VALIDATED ──────────────────────────
        v_status := get_order_status(p_order_id);   -- raises e_order_not_found

        IF v_status != 'VALIDATED' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'Cannot fulfill order #' || p_order_id ||
                ': expected status VALIDATED, found ' || v_status || '.');
        END IF;

        -- ── Step 1: bulk-collect all line items for this order ────────────────
        SELECT product_id, quantity
          BULK COLLECT INTO v_product_ids, v_quantities
          FROM order_lines
         WHERE order_id = p_order_id;

        IF v_product_ids.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'Order #' || p_order_id || ' has no line items.');
        END IF;

        -- ── Step 2: lock the affected product rows and re-verify stock ────────
        SELECT product_id, stock_qty
          BULK COLLECT INTO v_locked_ids, v_locked_stock
          FROM products
         WHERE product_id IN (SELECT column_value FROM TABLE(v_product_ids))
           FOR UPDATE;

        FOR i IN 1 .. v_locked_ids.COUNT LOOP
            v_stock_map(TO_CHAR(v_locked_ids(i))) := v_locked_stock(i);
        END LOOP;

        FOR i IN 1 .. v_product_ids.COUNT LOOP
            IF v_stock_map(TO_CHAR(v_product_ids(i))) < v_quantities(i) THEN
                RAISE_APPLICATION_ERROR(-20001,
                    'Insufficient stock for product id=' || v_product_ids(i) ||
                    ' at fulfillment time: requested ' || v_quantities(i) ||
                    ', available ' || v_stock_map(TO_CHAR(v_product_ids(i))) || '.');
            END IF;
        END LOOP;

        -- ── Step 3: bulk-decrement stock (rows already locked above) ──────────
        FORALL i IN 1 .. v_product_ids.COUNT
            UPDATE products
               SET stock_qty = stock_qty - v_quantities(i)
             WHERE product_id = v_product_ids(i);

        -- ── Step 4: mark order FULFILLED ────────────────────────────────────
        UPDATE orders
           SET status = 'FULFILLED'
         WHERE order_id = p_order_id;

        DBMS_OUTPUT.PUT_LINE('[fulfill_order] Order #' || p_order_id ||
            ' fulfilled. ' || v_product_ids.COUNT || ' product(s) decremented.');

    EXCEPTION
        WHEN e_order_not_found OR e_invalid_order_status OR e_insufficient_stock THEN
            RAISE;
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20099,
                'fulfill_order failed for order #' || p_order_id || ': ' || SQLERRM);
    END fulfill_order;


    -- =========================================================================
    -- cancel_order
    -- =========================================================================
    -- DESIGN: The only path to CANCELLED. Valid starting states are PENDING
    -- and VALIDATED; a FULFILLED or already-CANCELLED order cannot be
    -- cancelled. Previously CANCELLED was unreachable from any code path at
    -- all — this closes that gap.
    PROCEDURE cancel_order (p_order_id IN NUMBER) IS
        v_status orders.status%TYPE;
    BEGIN
        v_status := get_order_status(p_order_id);   -- raises e_order_not_found

        IF v_status NOT IN ('PENDING', 'VALIDATED') THEN
            RAISE_APPLICATION_ERROR(-20002,
                'Cannot cancel order #' || p_order_id ||
                ': orders in status ' || v_status || ' cannot be cancelled.');
        END IF;

        UPDATE orders SET status = 'CANCELLED' WHERE order_id = p_order_id;

        DBMS_OUTPUT.PUT_LINE('[cancel_order] Order #' || p_order_id || ' -> CANCELLED.');

    EXCEPTION
        WHEN e_order_not_found OR e_invalid_order_status THEN
            RAISE;
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20099,
                'cancel_order failed for order #' || p_order_id || ': ' || SQLERRM);
    END cancel_order;

END pkg_order_mgmt;
/
