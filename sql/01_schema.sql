-- =============================================================================
-- 01_schema.sql
-- Creates the ORDER2CASH user/schema and all tables for the Order-to-Cash demo.
-- Run as SYSDBA (sys / YourStrongPwd123 as sysdba).
-- =============================================================================

-- ── 1. Create the schema user ────────────────────────────────────────────────
-- Drop first if re-running (ignore ORA-01918 if user doesn't exist yet).
-- NOTE: run_demo.py kills any live ORDER2CASH sessions before executing this
-- file, to avoid ORA-01940. If running manually via SQL*Plus, kill sessions
-- first: SELECT sid,serial# FROM v$session WHERE username='ORDER2CASH';
--        ALTER SYSTEM KILL SESSION 'sid,serial#' IMMEDIATE;
BEGIN
    EXECUTE IMMEDIATE 'DROP USER order2cash CASCADE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1918 THEN RAISE; END IF;
END;
/

CREATE USER order2cash IDENTIFIED BY Order2cashPwd#1
    DEFAULT TABLESPACE USERS
    TEMPORARY TABLESPACE TEMP
    QUOTA UNLIMITED ON USERS;

GRANT CONNECT, RESOURCE TO order2cash;

-- ── 2. Switch to ORDER2CASH schema (script continues as that user) ───────────
-- (When run via Python/oracledb we reconnect as order2cash after this block)

-- Everything below executes as ORDER2CASH
-- =============================================================================

-- ── 3. Customers ─────────────────────────────────────────────────────────────
CREATE TABLE order2cash.customers (
    customer_id  NUMBER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         VARCHAR2(100)  NOT NULL,
    email        VARCHAR2(200)  NOT NULL CONSTRAINT uq_cust_email UNIQUE,
    created_at   DATE           DEFAULT SYSDATE NOT NULL
);

-- ── 4. Products ──────────────────────────────────────────────────────────────
CREATE TABLE order2cash.products (
    product_id   NUMBER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         VARCHAR2(200)  NOT NULL,
    unit_price   NUMBER(10,2)   NOT NULL CONSTRAINT chk_price CHECK (unit_price > 0),
    stock_qty    NUMBER         DEFAULT 0 NOT NULL
                                CONSTRAINT chk_stock CHECK (stock_qty >= 0)
);

-- ── 5. Orders ────────────────────────────────────────────────────────────────
-- Status follows a strict lifecycle: PENDING -> VALIDATED -> FULFILLED
--                                                         -> CANCELLED
CREATE TABLE order2cash.orders (
    order_id      NUMBER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   NUMBER         NOT NULL,
    order_date    DATE           DEFAULT SYSDATE NOT NULL,
    status        VARCHAR2(20)   DEFAULT 'PENDING' NOT NULL
                                 CONSTRAINT chk_order_status
                                     CHECK (status IN ('PENDING','VALIDATED','FULFILLED','CANCELLED')),
    total_amount  NUMBER(12,2)   DEFAULT 0 NOT NULL,
    CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id)
        REFERENCES order2cash.customers (customer_id)
);

-- ── 6. Order Lines ───────────────────────────────────────────────────────────
CREATE TABLE order2cash.order_lines (
    order_line_id  NUMBER        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id       NUMBER        NOT NULL,
    product_id     NUMBER        NOT NULL,
    quantity       NUMBER        NOT NULL CONSTRAINT chk_qty CHECK (quantity > 0),
    unit_price     NUMBER(10,2)  NOT NULL,
    CONSTRAINT fk_lines_order   FOREIGN KEY (order_id)
        REFERENCES order2cash.orders (order_id),
    CONSTRAINT fk_lines_product FOREIGN KEY (product_id)
        REFERENCES order2cash.products (product_id)
);

-- ── 7. Supporting indexes ────────────────────────────────────────────────────
-- Orders are most often looked up by customer or status
CREATE INDEX order2cash.idx_orders_customer ON order2cash.orders (customer_id);
CREATE INDEX order2cash.idx_orders_status   ON order2cash.orders (status);
CREATE INDEX order2cash.idx_lines_order     ON order2cash.order_lines (order_id);
CREATE INDEX order2cash.idx_lines_product   ON order2cash.order_lines (product_id);

COMMIT;
