-- =====================================================================
-- SMART INVENTORY & REORDER PREDICTION SYSTEM
-- Module: 03_triggers.sql
-- Purpose: Real-time triggers layered on top of pkg_inventory
-- =====================================================================

-- ---------------------------------------------------------------------
-- TRIGGER 1: Real-time low-stock alert
-- Fires the instant stock drops at/below reorder_min, instead of
-- waiting for the batch scan (pkg_inventory.run_reorder_scan).
-- Uses a compound trigger to safely call the forecast function
-- (which itself queries tables) without mutating-table errors.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_stock_alert_check
FOR UPDATE OF qty_on_hand ON product_stock
COMPOUND TRIGGER

    TYPE t_rowid_tab IS TABLE OF ROWID INDEX BY PLS_INTEGER;
    v_rows t_rowid_tab;
    v_cnt  PLS_INTEGER := 0;

    AFTER EACH ROW IS
    BEGIN
        IF :NEW.qty_on_hand <= (SELECT reorder_min FROM products WHERE product_id = :NEW.product_id) THEN
            v_cnt := v_cnt + 1;
            v_rows(v_cnt) := :NEW.ROWID;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_product_id   NUMBER;
        v_warehouse_id NUMBER;
        v_qty          NUMBER;
        v_suggested    NUMBER;
        v_already      NUMBER;
    BEGIN
        FOR i IN 1 .. v_cnt LOOP
            SELECT product_id, warehouse_id, qty_on_hand
            INTO v_product_id, v_warehouse_id, v_qty
            FROM product_stock
            WHERE ROWID = v_rows(i);

            -- avoid duplicate unresolved alerts for the same product/warehouse
            SELECT COUNT(*) INTO v_already
            FROM low_stock_alerts
            WHERE product_id = v_product_id
              AND warehouse_id = v_warehouse_id
              AND resolved_flag = 'N';

            IF v_already = 0 THEN
                v_suggested := pkg_inventory.forecast_reorder_qty(v_product_id, v_warehouse_id);

                INSERT INTO low_stock_alerts
                    (product_id, warehouse_id, qty_on_hand, suggested_qty)
                VALUES
                    (v_product_id, v_warehouse_id, v_qty, v_suggested);
            END IF;
        END LOOP;
    END AFTER STATEMENT;

END trg_stock_alert_check;
/

-- ---------------------------------------------------------------------
-- TRIGGER 2: Auto-restock on order cancellation
-- If a fulfilled order is cancelled, the reserved stock is returned
-- to product_stock automatically and the movement is audited.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_order_cancel_restock
AFTER UPDATE OF status ON orders
FOR EACH ROW
WHEN (NEW.status = 'CANCELLED' AND OLD.status = 'FULFILLED')
DECLARE
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    FOR item IN (SELECT product_id, qty_ordered FROM order_items WHERE order_id = :NEW.order_id) LOOP
        UPDATE product_stock
        SET qty_on_hand = qty_on_hand + item.qty_ordered, last_updated = SYSDATE
        WHERE product_id = item.product_id AND warehouse_id = :NEW.warehouse_id;

        INSERT INTO stock_txn_log (product_id, warehouse_id, txn_type, qty_change)
        VALUES (item.product_id, :NEW.warehouse_id, 'ADJUSTMENT', item.qty_ordered);
    END LOOP;
    COMMIT;
END trg_order_cancel_restock;
/

-- ---------------------------------------------------------------------
-- TRIGGER 3: Resolve alert automatically once stock is replenished
-- above the reorder point via a goods receipt.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_resolve_alert_on_receipt
AFTER UPDATE OF qty_on_hand ON product_stock
FOR EACH ROW
WHEN (NEW.qty_on_hand > OLD.qty_on_hand)
DECLARE
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_reorder_min NUMBER;
BEGIN
    SELECT reorder_min INTO v_reorder_min FROM products WHERE product_id = :NEW.product_id;

    IF :NEW.qty_on_hand > v_reorder_min THEN
        UPDATE low_stock_alerts
        SET resolved_flag = 'Y'
        WHERE product_id = :NEW.product_id
          AND warehouse_id = :NEW.warehouse_id
          AND resolved_flag = 'N';
    END IF;
    COMMIT;
END trg_resolve_alert_on_receipt;
/
