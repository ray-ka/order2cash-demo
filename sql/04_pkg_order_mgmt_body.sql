-- =============================================================================
-- 04_pkg_order_mgmt_body.sql
-- Package body for pkg_order_mgmt.
-- Run as ORDER2CASH user after the spec.
-- =============================================================================

CREATE OR REPLACE PACKAGE BODY pkg_order_mgmt AS

    -- =========================================================================
    -- PRIVATE helpers
    -- =========================================================================

    -- Fetches the current status of an order; raises e_order_not_found if
    -- the row doesn't exist.  Centralising this avoids duplicating the
    -- SELECT + exception logic across fulfill_order and any future procedures.
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
        -- FORALL submits the entire collection as a single SQL statement.
        -- The SQL%BULK_ROWCOUNT pseudo-collection could be inspected post-hoc
        -- for audit, but we omit that here for brevity.
        FORALL i IN 1 .. p_lines.COUNT
            INSERT INTO order_lines (order_id, product_id, quantity, unit_price)
            SELECT o_order_id,
                   p_lines(i).product_id,
                   p_lines(i).quantity,
                   unit_price          -- pull live price from products table
              FROM products
             WHERE product_id = p_lines(i).product_id;

        COMMIT;

        DBMS_OUTPUT.PUT_LINE('[create_order] Order #' || o_order_id ||
            ' created with ' || p_lines.COUNT || ' line(s). Total: ' ||
            TO_CHAR(v_total, 'FM$999,990.00'));

    EXCEPTION
        -- Propagate our named exceptions unchanged so callers can branch on
        -- exactly what went wrong rather than receiving a generic OTHERS wrap.
        -- e_invalid_order_status: raised by the empty-lines guard above.
        -- e_product_not_found:    raised by the product price-lookup loop above.
        WHEN e_invalid_order_status OR e_product_not_found THEN
            ROLLBACK;
            RAISE;
        WHEN OTHERS THEN
            -- Re-raise as a descriptive error; never swallow silently.
            ROLLBACK;
            RAISE_APPLICATION_ERROR(-20002,
                'create_order failed: ' || SQLERRM);
    END create_order;


    -- =========================================================================
    -- validate_stock
    -- =========================================================================
    -- DESIGN: We use a parameterised explicit cursor (opened once per line item)
    -- rather than implicit SELECT INTO because:
    --   a) %ROWTYPE binds the loop variable to the cursor's column projection,
    --      so adding a column to the SELECT is a single-site change and the
    --      loop variable automatically reflects it — no variable rename churn.
    --   b) Explicit cursor state (%NOTFOUND, %ISOPEN) makes the product-not-found
    --      check declarative rather than relying on a NO_DATA_FOUND exception
    --      inside every iteration's inner BEGIN/EXCEPTION/END block.
    --   c) The named cursor declaration separates query definition from loop
    --      logic, which aids readability when the SELECT is non-trivial.
    -- NOTE: The cursor IS opened once per element in p_lines (N opens total).
    -- That is intentional here: we need per-item error messages with the
    -- product name and exact quantities, which a single bulk query would make
    -- harder to produce cleanly without a secondary lookup on failure.
    PROCEDURE validate_stock (
        p_lines         IN  t_line_item_tbl,
        o_total_value   OUT NUMBER
    ) IS
        v_total     NUMBER := 0;

        -- Parameterised explicit cursor: fetches stock and price for one product
        -- at a time, passing requested_qty as a bind parameter so the loop body
        -- receives a complete %ROWTYPE without a separate variable for qty.
        CURSOR c_stock (p_product_id IN NUMBER, p_qty IN NUMBER) IS
            SELECT p.product_id,
                   p.name,
                   p.stock_qty,
                   p.unit_price,
                   p_qty AS requested_qty
              FROM products p
             WHERE p.product_id = p_product_id;

        v_row c_stock%ROWTYPE;
    BEGIN
        o_total_value := 0;

        FOR i IN 1 .. p_lines.COUNT LOOP
            OPEN c_stock(p_lines(i).product_id, p_lines(i).quantity);
            FETCH c_stock INTO v_row;

            IF c_stock%NOTFOUND THEN
                CLOSE c_stock;
                RAISE_APPLICATION_ERROR(-20004,
                    'Product ' || p_lines(i).product_id || ' not found.');
            END IF;

            CLOSE c_stock;

            -- Core stock check — raise named exception so callers can
            -- distinguish "not enough stock" from generic errors.
            IF v_row.stock_qty < v_row.requested_qty THEN
                RAISE_APPLICATION_ERROR(-20001,
                    'Insufficient stock for product "' || v_row.name ||
                    '" (id=' || v_row.product_id || '): requested ' ||
                    v_row.requested_qty || ', available ' || v_row.stock_qty || '.');
            END IF;

            v_total := v_total + (v_row.unit_price * v_row.requested_qty);

            DBMS_OUTPUT.PUT_LINE('[validate_stock] Product "' || v_row.name ||
                '" OK — stock: ' || v_row.stock_qty ||
                ', requested: ' || v_row.requested_qty);
        END LOOP;

        o_total_value := v_total;
        DBMS_OUTPUT.PUT_LINE('[validate_stock] All ' || p_lines.COUNT ||
            ' line(s) validated. Estimated value: ' ||
            TO_CHAR(v_total, 'FM$999,990.00'));

    EXCEPTION
        -- Propagate named exceptions unchanged; both carry a descriptive message.
        WHEN e_insufficient_stock OR e_product_not_found THEN
            RAISE;
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20002,
                'validate_stock failed: ' || SQLERRM);
    END validate_stock;


    -- =========================================================================
    -- fulfill_order
    -- =========================================================================
    -- DESIGN: Stock decrements use BULK COLLECT + FORALL rather than a cursor
    -- loop to avoid N individual UPDATE statements.  We first collect all
    -- (product_id, quantity) pairs from order_lines, then fire a single bulk
    -- UPDATE.  This keeps the SQL engine's undo/redo generation concentrated
    -- in one statement, which is more efficient for larger orders.
    PROCEDURE fulfill_order (p_order_id IN NUMBER) IS
        v_status  orders.status%TYPE;

        -- BULK COLLECT targets
        TYPE t_num_tbl IS TABLE OF NUMBER;
        v_product_ids  t_num_tbl;
        v_quantities   t_num_tbl;

    BEGIN
        -- ── Guard: order must exist and be VALIDATED ──────────────────────────
        v_status := get_order_status(p_order_id);   -- raises e_order_not_found

        IF v_status != 'VALIDATED' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'Cannot fulfill order #' || p_order_id ||
                ': expected status VALIDATED, found ' || v_status || '.');
        END IF;

        -- ── Step 1: bulk-collect all line items for this order ────────────────
        -- BULK COLLECT fetches all rows in one round-trip, populating the
        -- two parallel collections we'll use in the FORALL below.
        SELECT product_id, quantity
          BULK COLLECT INTO v_product_ids, v_quantities
          FROM order_lines
         WHERE order_id = p_order_id;

        IF v_product_ids.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20003,
                'Order #' || p_order_id || ' has no line items.');
        END IF;

        -- ── Step 2: bulk-decrement stock ──────────────────────────────────────
        -- FORALL sends all UPDATEs as one batched statement.
        -- The CHECK constraint on products.stock_qty (>= 0) acts as a
        -- last-resort guard; validate_stock should be called before this.
        FORALL i IN 1 .. v_product_ids.COUNT
            UPDATE products
               SET stock_qty = stock_qty - v_quantities(i)
             WHERE product_id = v_product_ids(i);

        -- ── Step 3: mark order FULFILLED ────────────────────────────────────
        UPDATE orders
           SET status = 'FULFILLED'
         WHERE order_id = p_order_id;

        COMMIT;

        DBMS_OUTPUT.PUT_LINE('[fulfill_order] Order #' || p_order_id ||
            ' fulfilled. ' || v_product_ids.COUNT || ' product(s) decremented.');

    EXCEPTION
        WHEN e_order_not_found OR e_invalid_order_status THEN
            ROLLBACK;
            RAISE;
        WHEN OTHERS THEN
            -- Could be a CHECK constraint violation (stock went negative)
            ROLLBACK;
            RAISE_APPLICATION_ERROR(-20001,
                'fulfill_order failed for order #' || p_order_id || ': ' || SQLERRM);
    END fulfill_order;

END pkg_order_mgmt;
/
