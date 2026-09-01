-- =============================================================================
-- test_pkg_order_mgmt.sql
-- Integration test for pkg_order_mgmt.
-- Run as ORDER2CASH user with SERVEROUTPUT ON.
--
-- Tests:
--   1. Happy path  : create -> validate_order -> fulfill_order
--   2. Failure path: insufficient stock raises e_insufficient_stock cleanly
--   3. fulfill_order on a PENDING (non-validated) order
--   4. fulfill_order on a nonexistent order
--   5. validate_stock / create_order with a nonexistent product
--   6. validate_order on a nonexistent order
--   7. cancel_order from PENDING, then fulfill attempt on the cancelled order
--   8. cancel_order on an already-FULFILLED order (must be rejected)
--
-- NOTE: the package issues no COMMIT/ROLLBACK of its own — this script
-- commits explicitly after each successful mutating step, exactly as a
-- real caller would.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    -- ── Shared variables ──────────────────────────────────────────────────────
    v_order_id           NUMBER;
    v_fulfilled_order_id NUMBER;  -- captured from TEST 1, reused by TEST 8
    v_total_value        NUMBER;
    v_lines              t_line_item_tbl;
    v_status             orders.status%TYPE;

    -- Helper to print a section header
    PROCEDURE banner(p_text IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('══════════════════════════════════════════════');
        DBMS_OUTPUT.PUT_LINE('  ' || p_text);
        DBMS_OUTPUT.PUT_LINE('══════════════════════════════════════════════');
    END;

BEGIN

    -- =========================================================================
    -- TEST 1: Happy path — create -> validate_order -> fulfill_order
    -- =========================================================================
    banner('TEST 1: Happy path (create -> validate_order -> fulfill_order)');

    -- Build a 3-line order: Wireless Mouse x2, Mechanical Keyboard x1, USB-C Hub x1
    -- Product IDs are deterministic from seed data (inserted in order).
    v_lines := t_line_item_tbl(
        t_line_item_obj(2, 2),   -- Wireless Mouse      (stock: 200)
        t_line_item_obj(3, 1),   -- Mechanical Keyboard (stock: 80)
        t_line_item_obj(4, 1)    -- USB-C Hub           (stock: 120)
    );

    -- Step 1a: Validate stock before creating the order
    DBMS_OUTPUT.PUT_LINE('--- Step 1: validate_stock ---');
    pkg_order_mgmt.validate_stock(
        p_lines       => v_lines,
        o_total_value => v_total_value
    );
    DBMS_OUTPUT.PUT_LINE('validate_stock returned total value: ' ||
        TO_CHAR(v_total_value, 'FM$999,990.00'));

    -- Step 1b: Create the order
    DBMS_OUTPUT.PUT_LINE('--- Step 2: create_order ---');
    pkg_order_mgmt.create_order(
        p_customer_id => 4,   -- David Müller
        p_lines       => v_lines,
        o_order_id    => v_order_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('create_order returned order_id: ' || v_order_id);

    SELECT status INTO v_status FROM orders WHERE order_id = v_order_id;
    DBMS_OUTPUT.PUT_LINE('DB status after create: ' || v_status);

    -- Step 1c: Validate the order through the package (no more manual UPDATE)
    DBMS_OUTPUT.PUT_LINE('--- Step 3: validate_order ---');
    pkg_order_mgmt.validate_order(p_order_id => v_order_id);
    COMMIT;

    SELECT status INTO v_status FROM orders WHERE order_id = v_order_id;
    DBMS_OUTPUT.PUT_LINE('DB status after validate_order: ' || v_status);

    -- Step 1d: Fulfill the order
    DBMS_OUTPUT.PUT_LINE('--- Step 4: fulfill_order ---');
    pkg_order_mgmt.fulfill_order(p_order_id => v_order_id);
    COMMIT;

    SELECT status INTO v_status FROM orders WHERE order_id = v_order_id;
    DBMS_OUTPUT.PUT_LINE('DB status after fulfill: ' || v_status);

    DECLARE
        v_mouse_stock  NUMBER;
        v_kb_stock     NUMBER;
        v_hub_stock    NUMBER;
    BEGIN
        SELECT stock_qty INTO v_mouse_stock FROM products WHERE product_id = 2;
        SELECT stock_qty INTO v_kb_stock    FROM products WHERE product_id = 3;
        SELECT stock_qty INTO v_hub_stock   FROM products WHERE product_id = 4;
        DBMS_OUTPUT.PUT_LINE('Stock after fulfill:');
        DBMS_OUTPUT.PUT_LINE('  Wireless Mouse      -> ' || v_mouse_stock || ' (was 200, decremented by 2)');
        DBMS_OUTPUT.PUT_LINE('  Mechanical Keyboard -> ' || v_kb_stock    || ' (was 80,  decremented by 1)');
        DBMS_OUTPUT.PUT_LINE('  USB-C Hub           -> ' || v_hub_stock   || ' (was 120, decremented by 1)');
    END;

    v_fulfilled_order_id := v_order_id;
    DBMS_OUTPUT.PUT_LINE('TEST 1 PASSED');


    -- =========================================================================
    -- TEST 2: Failure path — insufficient stock raises e_insufficient_stock
    -- =========================================================================
    banner('TEST 2: Insufficient stock -> e_insufficient_stock');

    -- Ergonomic Chair (product_id=10) has only 20 in stock; we request 999.
    v_lines := t_line_item_tbl(
        t_line_item_obj(10, 999)   -- Ergonomic Chair (stock: 20), deliberately over
    );

    BEGIN
        DBMS_OUTPUT.PUT_LINE('Attempting validate_stock with qty=999 for Ergonomic Chair (stock=20)...');
        pkg_order_mgmt.validate_stock(
            p_lines       => v_lines,
            o_total_value => v_total_value
        );
        DBMS_OUTPUT.PUT_LINE('ERROR: validate_stock should have raised e_insufficient_stock but did not!');
    EXCEPTION
        WHEN pkg_order_mgmt.e_insufficient_stock THEN
            DBMS_OUTPUT.PUT_LINE('Caught e_insufficient_stock as expected.');
            DBMS_OUTPUT.PUT_LINE('Exception message: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 2 PASSED');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('UNEXPECTED exception: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 2 FAILED');
    END;


    -- =========================================================================
    -- TEST 3: fulfill_order on wrong status raises e_invalid_order_status
    -- =========================================================================
    banner('TEST 3: fulfill_order on PENDING order -> e_invalid_order_status');

    -- Create a fresh order but leave it PENDING (don't validate)
    v_lines := t_line_item_tbl(
        t_line_item_obj(8, 1)   -- Desk Lamp LED (stock: 150)
    );

    pkg_order_mgmt.create_order(
        p_customer_id => 5,
        p_lines       => v_lines,
        o_order_id    => v_order_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Created order #' || v_order_id || ' (status=PENDING)');

    BEGIN
        pkg_order_mgmt.fulfill_order(p_order_id => v_order_id);
        DBMS_OUTPUT.PUT_LINE('ERROR: fulfill_order should have raised exception but did not!');
    EXCEPTION
        WHEN pkg_order_mgmt.e_invalid_order_status THEN
            DBMS_OUTPUT.PUT_LINE('Caught e_invalid_order_status as expected.');
            DBMS_OUTPUT.PUT_LINE('Exception message: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 3 PASSED');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('UNEXPECTED exception: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 3 FAILED');
    END;


    -- =========================================================================
    -- TEST 4: fulfill_order on a nonexistent order_id -> e_order_not_found
    -- =========================================================================
    banner('TEST 4: fulfill_order(99999) -> e_order_not_found');

    BEGIN
        pkg_order_mgmt.fulfill_order(p_order_id => 99999);
        DBMS_OUTPUT.PUT_LINE('ERROR: fulfill_order should have raised e_order_not_found but did not!');
    EXCEPTION
        WHEN pkg_order_mgmt.e_order_not_found THEN
            DBMS_OUTPUT.PUT_LINE('Caught e_order_not_found as expected.');
            DBMS_OUTPUT.PUT_LINE('Exception message: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 4 PASSED');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('UNEXPECTED exception: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 4 FAILED');
    END;


    -- =========================================================================
    -- TEST 5: validate_stock with nonexistent product_id -> e_product_not_found
    -- =========================================================================
    banner('TEST 5: validate_stock(product_id=88888) -> e_product_not_found');

    v_lines := t_line_item_tbl(
        t_line_item_obj(88888, 1)   -- does not exist
    );

    BEGIN
        pkg_order_mgmt.validate_stock(
            p_lines       => v_lines,
            o_total_value => v_total_value
        );
        DBMS_OUTPUT.PUT_LINE('ERROR: validate_stock should have raised e_product_not_found but did not!');
    EXCEPTION
        WHEN pkg_order_mgmt.e_product_not_found THEN
            DBMS_OUTPUT.PUT_LINE('Caught e_product_not_found as expected.');
            DBMS_OUTPUT.PUT_LINE('SQLCODE : ' || SQLCODE);
            DBMS_OUTPUT.PUT_LINE('Exception message: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 5 PASSED');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('UNEXPECTED exception (' || SQLCODE || '): ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 5 FAILED');
    END;


    -- =========================================================================
    -- TEST 6: validate_order on a nonexistent order_id -> e_order_not_found
    -- =========================================================================
    banner('TEST 6: validate_order(99999) -> e_order_not_found');

    BEGIN
        pkg_order_mgmt.validate_order(p_order_id => 99999);
        DBMS_OUTPUT.PUT_LINE('ERROR: validate_order should have raised e_order_not_found but did not!');
    EXCEPTION
        WHEN pkg_order_mgmt.e_order_not_found THEN
            DBMS_OUTPUT.PUT_LINE('Caught e_order_not_found as expected.');
            DBMS_OUTPUT.PUT_LINE('Exception message: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 6 PASSED');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('UNEXPECTED exception: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 6 FAILED');
    END;


    -- =========================================================================
    -- TEST 7: cancel_order from PENDING, then fulfill attempt must fail
    -- =========================================================================
    banner('TEST 7: cancel_order (PENDING -> CANCELLED), then fulfill rejected');

    v_lines := t_line_item_tbl(
        t_line_item_obj(6, 1)   -- any in-stock product
    );

    pkg_order_mgmt.create_order(
        p_customer_id => 6,
        p_lines       => v_lines,
        o_order_id    => v_order_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Created order #' || v_order_id || ' (status=PENDING)');

    pkg_order_mgmt.cancel_order(p_order_id => v_order_id);
    COMMIT;

    SELECT status INTO v_status FROM orders WHERE order_id = v_order_id;
    DBMS_OUTPUT.PUT_LINE('DB status after cancel_order: ' || v_status);

    BEGIN
        pkg_order_mgmt.fulfill_order(p_order_id => v_order_id);
        DBMS_OUTPUT.PUT_LINE('ERROR: fulfill_order should have rejected a CANCELLED order!');
    EXCEPTION
        WHEN pkg_order_mgmt.e_invalid_order_status THEN
            DBMS_OUTPUT.PUT_LINE('Caught e_invalid_order_status as expected.');
            DBMS_OUTPUT.PUT_LINE('Exception message: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 7 PASSED');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('UNEXPECTED exception: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 7 FAILED');
    END;


    -- =========================================================================
    -- TEST 8: cancel_order on an already-FULFILLED order must be rejected
    -- =========================================================================
    banner('TEST 8: cancel_order on a FULFILLED order -> e_invalid_order_status');

    -- Reuse the order fulfilled back in TEST 1.
    BEGIN
        pkg_order_mgmt.cancel_order(p_order_id => v_fulfilled_order_id);
        DBMS_OUTPUT.PUT_LINE('ERROR: cancel_order should have rejected a FULFILLED order!');
    EXCEPTION
        WHEN pkg_order_mgmt.e_invalid_order_status THEN
            DBMS_OUTPUT.PUT_LINE('Caught e_invalid_order_status as expected.');
            DBMS_OUTPUT.PUT_LINE('Exception message: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 8 PASSED');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('UNEXPECTED exception: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('TEST 8 FAILED');
    END;


    banner('ALL TESTS COMPLETE');

END;
/
