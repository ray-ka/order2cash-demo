-- =============================================================================
-- 02_seed_data.sql
-- Populates customers, products, and a few sample orders.
-- Run as ORDER2CASH user after 01_schema.sql.
-- =============================================================================

-- ── Customers ─────────────────────────────────────────────────────────────────
INSERT INTO customers (name, email) VALUES ('Alice Hartmann',   'alice@example.com');
INSERT INTO customers (name, email) VALUES ('Ben Nakamura',     'ben@example.com');
INSERT INTO customers (name, email) VALUES ('Chloe Osei',       'chloe@example.com');
INSERT INTO customers (name, email) VALUES ('David Müller',     'david@example.com');
INSERT INTO customers (name, email) VALUES ('Elena Vasquez',    'elena@example.com');
INSERT INTO customers (name, email) VALUES ('Farhan Qureshi',   'farhan@example.com');
INSERT INTO customers (name, email) VALUES ('Greta Lindström',  'greta@example.com');

-- ── Products ──────────────────────────────────────────────────────────────────
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Laptop Pro 15',       1299.99, 50);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Wireless Mouse',         29.99, 200);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Mechanical Keyboard',   149.99, 80);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('USB-C Hub 7-port',       59.99, 120);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('27" 4K Monitor',        499.99, 30);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Webcam HD 1080p',        89.99, 100);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Noise-Cancelling Headphones', 249.99, 60);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Desk Lamp LED',          39.99, 150);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Cable Management Kit',   19.99, 300);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Ergonomic Chair',       599.99, 20);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Standing Desk',         899.99, 15);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Laptop Stand',           49.99, 90);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('USB Microphone',        129.99, 45);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Portable SSD 1TB',      109.99, 70);
INSERT INTO products (name, unit_price, stock_qty) VALUES ('Power Strip Surge',      34.99, 180);

-- ── Sample orders (created manually to show varied states) ────────────────────
-- Order 1: already FULFILLED (Alice, Laptop + Mouse)
INSERT INTO orders (customer_id, order_date, status, total_amount)
    VALUES (1, SYSDATE - 10, 'FULFILLED', 1329.98);
INSERT INTO order_lines (order_id, product_id, quantity, unit_price)
    VALUES (1, 1, 1, 1299.99);
INSERT INTO order_lines (order_id, product_id, quantity, unit_price)
    VALUES (1, 2, 1, 29.99);

-- Order 2: VALIDATED (Ben, Keyboard + Hub)
INSERT INTO orders (customer_id, order_date, status, total_amount)
    VALUES (2, SYSDATE - 3, 'VALIDATED', 209.98);
INSERT INTO order_lines (order_id, product_id, quantity, unit_price)
    VALUES (2, 3, 1, 149.99);
INSERT INTO order_lines (order_id, product_id, quantity, unit_price)
    VALUES (2, 4, 1, 59.99);

-- Order 3: CANCELLED (Chloe)
INSERT INTO orders (customer_id, order_date, status, total_amount)
    VALUES (3, SYSDATE - 5, 'CANCELLED', 499.99);
INSERT INTO order_lines (order_id, product_id, quantity, unit_price)
    VALUES (3, 5, 1, 499.99);

COMMIT;
