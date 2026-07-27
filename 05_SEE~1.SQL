-- =====================================================================
-- SMART INVENTORY & REORDER PREDICTION SYSTEM
-- Module: 05_seed_data_and_demo.sql
-- Purpose: Sample data + a demo script you can run and screenshot
-- for your resume/GitHub README.
-- =====================================================================

INSERT INTO suppliers (supplier_name, lead_time_days, contact_email)
VALUES ('Al-Noor Traders', 5, 'sales@alnoor-traders.example');

INSERT INTO suppliers (supplier_name, lead_time_days, contact_email)
VALUES ('Continental Parts Co.', 12, 'orders@continentalparts.example');

INSERT INTO warehouses (warehouse_name, location) VALUES ('Main Warehouse - Lahore', 'Lahore, PK');
INSERT INTO warehouses (warehouse_name, location) VALUES ('Regional Hub - Karachi', 'Karachi, PK');

INSERT INTO products (sku, product_name, unit_price, supplier_id, reorder_min)
VALUES ('SKU-1001', 'Hydraulic Seal Kit', 850.00, 1, 15);

INSERT INTO products (sku, product_name, unit_price, supplier_id, reorder_min)
VALUES ('SKU-1002', 'Bearing Assembly 6205', 420.50, 2, 20);

COMMIT;

-- Initial stock
INSERT INTO product_stock (product_id, warehouse_id, qty_on_hand) VALUES (1, 1, 100);
INSERT INTO product_stock (product_id, warehouse_id, qty_on_hand) VALUES (2, 1, 60);
COMMIT;

-- ---------------------------------------------------------------------
-- DEMO: simulate 10 days of orders to build consumption history,
-- then let the trigger + forecast engine react in real time.
-- ---------------------------------------------------------------------
DECLARE
    v_order_id NUMBER;
BEGIN
    FOR i IN 1..10 LOOP
        pkg_inventory.place_order(
            p_warehouse_id => 1,
            p_product_id   => 1,
            p_qty          => 8,          -- steady daily demand
            p_order_id     => v_order_id
        );
    END LOOP;
END;
/

-- Check what happened: stock should now be low, and an alert
-- should already exist thanks to trg_stock_alert_check.
SELECT * FROM vw_stock_health ORDER BY sku;
SELECT * FROM vw_open_reorder_alerts;

-- Run the batch scan too (covers products not touched by a trigger event)
BEGIN
    pkg_inventory.run_reorder_scan;
END;
/

-- Receive stock back in -> alert should auto-resolve
BEGIN
    pkg_inventory.receive_stock(p_product_id => 1, p_warehouse_id => 1, p_qty => 100);
END;
/

SELECT * FROM vw_open_reorder_alerts;   -- should now be empty for SKU-1001
SELECT * FROM vw_monthly_consumption ORDER BY sku, txn_month;
