-- =====================================================================
-- SMART INVENTORY & REORDER PREDICTION SYSTEM
-- Module: 01_schema.sql
-- Purpose: Core table structures for the ERP inventory module
-- Author : Hassan
-- =====================================================================

-- Drop objects if re-running (safe cleanup for dev environment)
BEGIN
   FOR t IN (SELECT table_name FROM user_tables WHERE table_name IN
       ('ORDER_ITEMS','ORDERS','STOCK_TXN_LOG','LOW_STOCK_ALERTS',
        'PRODUCT_STOCK','SUPPLIERS','WAREHOUSES','PRODUCTS'))
   LOOP
      EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS';
   END LOOP;
END;
/

-- ---------------------------------------------------------------------
-- Master tables
-- ---------------------------------------------------------------------
CREATE TABLE suppliers (
    supplier_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_name   VARCHAR2(120) NOT NULL,
    lead_time_days  NUMBER(3)     NOT NULL,  -- avg days supplier takes to deliver
    contact_email   VARCHAR2(120)
);

CREATE TABLE warehouses (
    warehouse_id    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    warehouse_name  VARCHAR2(120) NOT NULL,
    location        VARCHAR2(200)
);

CREATE TABLE products (
    product_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku             VARCHAR2(40)  NOT NULL UNIQUE,
    product_name    VARCHAR2(150) NOT NULL,
    unit_price      NUMBER(10,2)  NOT NULL,
    supplier_id     NUMBER        REFERENCES suppliers(supplier_id),
    reorder_min     NUMBER(8)     DEFAULT 10 NOT NULL,   -- floor safety stock
    active_flag     CHAR(1)       DEFAULT 'Y' CHECK (active_flag IN ('Y','N'))
);

-- ---------------------------------------------------------------------
-- Stock position per warehouse (current on-hand quantity)
-- ---------------------------------------------------------------------
CREATE TABLE product_stock (
    product_id      NUMBER NOT NULL REFERENCES products(product_id),
    warehouse_id    NUMBER NOT NULL REFERENCES warehouses(warehouse_id),
    qty_on_hand     NUMBER(10) DEFAULT 0 NOT NULL,
    last_updated    DATE DEFAULT SYSDATE,
    CONSTRAINT pk_product_stock PRIMARY KEY (product_id, warehouse_id),
    CONSTRAINT chk_qty_non_negative CHECK (qty_on_hand >= 0)
);

-- ---------------------------------------------------------------------
-- Orders (sales orders that consume stock)
-- ---------------------------------------------------------------------
CREATE TABLE orders (
    order_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    warehouse_id    NUMBER NOT NULL REFERENCES warehouses(warehouse_id),
    order_date      DATE DEFAULT SYSDATE NOT NULL,
    status          VARCHAR2(20) DEFAULT 'PLACED'
                    CHECK (status IN ('PLACED','FULFILLED','CANCELLED'))
);

CREATE TABLE order_items (
    order_item_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        NUMBER NOT NULL REFERENCES orders(order_id),
    product_id      NUMBER NOT NULL REFERENCES products(product_id),
    qty_ordered     NUMBER(8) NOT NULL CHECK (qty_ordered > 0)
);

-- ---------------------------------------------------------------------
-- Audit trail — every stock movement, written via autonomous transaction
-- so it survives even if the parent transaction rolls back.
-- ---------------------------------------------------------------------
CREATE TABLE stock_txn_log (
    log_id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id      NUMBER NOT NULL,
    warehouse_id    NUMBER NOT NULL,
    txn_type        VARCHAR2(20) NOT NULL,   -- 'ISSUE', 'RECEIPT', 'ADJUSTMENT'
    qty_change      NUMBER(10) NOT NULL,     -- negative = stock leaving
    txn_time        TIMESTAMP DEFAULT SYSTIMESTAMP,
    performed_by    VARCHAR2(60) DEFAULT USER
);

-- ---------------------------------------------------------------------
-- Low stock alerts — auto-populated by trigger when stock crosses
-- the reorder point calculated by the forecasting engine.
-- ---------------------------------------------------------------------
CREATE TABLE low_stock_alerts (
    alert_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id      NUMBER NOT NULL,
    warehouse_id    NUMBER NOT NULL,
    qty_on_hand     NUMBER(10) NOT NULL,
    suggested_qty   NUMBER(10) NOT NULL,
    raised_on       TIMESTAMP DEFAULT SYSTIMESTAMP,
    resolved_flag   CHAR(1) DEFAULT 'N' CHECK (resolved_flag IN ('Y','N'))
);
