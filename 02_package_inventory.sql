-- =====================================================================
-- SMART INVENTORY & REORDER PREDICTION SYSTEM
-- Module: 02_package_inventory.sql
-- Purpose: Core business logic package (spec + body)
--
-- Highlight feature for interview: pkg_inventory.forecast_reorder_qty
-- calculates a weighted moving average of the last N days' consumption
-- (pulled straight from stock_txn_log) and combines it with the
-- supplier lead time to suggest how much stock to reorder — done
-- entirely in PL/SQL, no external analytics tool required.
-- =====================================================================

CREATE OR REPLACE PACKAGE pkg_inventory AS

    -- Places a new sales order and its line items in one transaction
    PROCEDURE place_order (
        p_warehouse_id  IN NUMBER,
        p_product_id    IN NUMBER,
        p_qty           IN NUMBER,
        p_order_id      OUT NUMBER
    );

    -- Receives stock from a supplier (goods-in)
    PROCEDURE receive_stock (
        p_product_id    IN NUMBER,
        p_warehouse_id  IN NUMBER,
        p_qty           IN NUMBER
    );

    -- Weighted moving average forecast -> suggested reorder quantity
    FUNCTION forecast_reorder_qty (
        p_product_id    IN NUMBER,
        p_warehouse_id  IN NUMBER,
        p_lookback_days IN NUMBER DEFAULT 30
    ) RETURN NUMBER;

    -- Runs forecast for every product/warehouse and raises alerts
    PROCEDURE run_reorder_scan;

END pkg_inventory;
/

CREATE OR REPLACE PACKAGE BODY pkg_inventory AS

    -- -----------------------------------------------------------------
    -- Internal helper: writes to the audit log via autonomous
    -- transaction so the log entry persists even if the caller's
    -- transaction later rolls back.
    -- -----------------------------------------------------------------
    PROCEDURE log_txn (
        p_product_id   IN NUMBER,
        p_warehouse_id IN NUMBER,
        p_txn_type     IN VARCHAR2,
        p_qty_change   IN NUMBER
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO stock_txn_log (product_id, warehouse_id, txn_type, qty_change)
        VALUES (p_product_id, p_warehouse_id, p_txn_type, p_qty_change);
        COMMIT;
    END log_txn;

    -- -----------------------------------------------------------------
    PROCEDURE place_order (
        p_warehouse_id  IN NUMBER,
        p_product_id    IN NUMBER,
        p_qty           IN NUMBER,
        p_order_id      OUT NUMBER
    ) IS
        v_available NUMBER;
    BEGIN
        SELECT qty_on_hand INTO v_available
        FROM product_stock
        WHERE product_id = p_product_id AND warehouse_id = p_warehouse_id
        FOR UPDATE;  -- lock the row to prevent race conditions on concurrent orders

        IF v_available < p_qty THEN
            RAISE_APPLICATION_ERROR(-20001,
                'Insufficient stock: available ' || v_available || ', requested ' || p_qty);
        END IF;

        INSERT INTO orders (warehouse_id) VALUES (p_warehouse_id)
        RETURNING order_id INTO p_order_id;

        INSERT INTO order_items (order_id, product_id, qty_ordered)
        VALUES (p_order_id, p_product_id, p_qty);

        UPDATE product_stock
        SET qty_on_hand = qty_on_hand - p_qty, last_updated = SYSDATE
        WHERE product_id = p_product_id AND warehouse_id = p_warehouse_id;

        UPDATE orders SET status = 'FULFILLED' WHERE order_id = p_order_id;

        log_txn(p_product_id, p_warehouse_id, 'ISSUE', -p_qty);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END place_order;

    -- -----------------------------------------------------------------
    PROCEDURE receive_stock (
        p_product_id    IN NUMBER,
        p_warehouse_id  IN NUMBER,
        p_qty           IN NUMBER
    ) IS
    BEGIN
        MERGE INTO product_stock ps
        USING (SELECT p_product_id AS product_id, p_warehouse_id AS warehouse_id FROM dual) src
        ON (ps.product_id = src.product_id AND ps.warehouse_id = src.warehouse_id)
        WHEN MATCHED THEN
            UPDATE SET qty_on_hand = qty_on_hand + p_qty, last_updated = SYSDATE
        WHEN NOT MATCHED THEN
            INSERT (product_id, warehouse_id, qty_on_hand, last_updated)
            VALUES (p_product_id, p_warehouse_id, p_qty, SYSDATE);

        log_txn(p_product_id, p_warehouse_id, 'RECEIPT', p_qty);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END receive_stock;

    -- -----------------------------------------------------------------
    -- Forecast engine: gives more weight to recent consumption days
    -- (a simple linear-weighted moving average), then adds a buffer
    -- proportional to the supplier's lead time.
    -- -----------------------------------------------------------------
    FUNCTION forecast_reorder_qty (
        p_product_id    IN NUMBER,
        p_warehouse_id  IN NUMBER,
        p_lookback_days IN NUMBER DEFAULT 30
    ) RETURN NUMBER IS
        v_weighted_daily_avg NUMBER := 0;
        v_lead_time          NUMBER := 7;
        v_suggested_qty      NUMBER;
    BEGIN
        -- Weighted moving average: each day's consumption is weighted
        -- by recency (day 1 ago = weight 30, day 30 ago = weight 1)
        SELECT NVL(SUM(daily_qty * weight) / NULLIF(SUM(weight), 0), 0)
        INTO v_weighted_daily_avg
        FROM (
            SELECT
                TRUNC(txn_time) AS txn_day,
                SUM(ABS(qty_change)) AS daily_qty,
                (p_lookback_days - (TRUNC(SYSDATE) - TRUNC(txn_time))) AS weight
            FROM stock_txn_log
            WHERE product_id = p_product_id
              AND warehouse_id = p_warehouse_id
              AND txn_type = 'ISSUE'
              AND txn_time >= SYSDATE - p_lookback_days
            GROUP BY TRUNC(txn_time)
        );

        BEGIN
            SELECT s.lead_time_days INTO v_lead_time
            FROM products p JOIN suppliers s ON s.supplier_id = p.supplier_id
            WHERE p.product_id = p_product_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN v_lead_time := 7;  -- fallback default
        END;

        -- Suggested qty = expected demand during lead time + 20% safety buffer
        v_suggested_qty := CEIL(v_weighted_daily_avg * v_lead_time * 1.2);

        RETURN v_suggested_qty;
    END forecast_reorder_qty;

    -- -----------------------------------------------------------------
    PROCEDURE run_reorder_scan IS
        v_suggested NUMBER;
    BEGIN
        FOR r IN (
            SELECT ps.product_id, ps.warehouse_id, ps.qty_on_hand, p.reorder_min
            FROM product_stock ps
            JOIN products p ON p.product_id = ps.product_id
            WHERE p.active_flag = 'Y'
        ) LOOP
            IF r.qty_on_hand <= r.reorder_min THEN
                v_suggested := pkg_inventory.forecast_reorder_qty(r.product_id, r.warehouse_id);

                INSERT INTO low_stock_alerts
                    (product_id, warehouse_id, qty_on_hand, suggested_qty)
                VALUES
                    (r.product_id, r.warehouse_id, r.qty_on_hand, GREATEST(v_suggested, r.reorder_min));
            END IF;
        END LOOP;
        COMMIT;
    END run_reorder_scan;

END pkg_inventory;
/
