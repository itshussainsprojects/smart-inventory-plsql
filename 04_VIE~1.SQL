-- =====================================================================
-- SMART INVENTORY & REORDER PREDICTION SYSTEM
-- Module: 04_views_reports.sql
-- Purpose: Reporting layer — the kind of views you'd expose through
-- Oracle Discoverer / OBI Suite dashboards (job spec explicitly
-- mentions this skill).
-- =====================================================================

-- Dashboard 1: Current stock health across all warehouses
CREATE OR REPLACE VIEW vw_stock_health AS
SELECT
    p.sku,
    p.product_name,
    w.warehouse_name,
    ps.qty_on_hand,
    p.reorder_min,
    CASE
        WHEN ps.qty_on_hand = 0 THEN 'OUT OF STOCK'
        WHEN ps.qty_on_hand <= p.reorder_min THEN 'LOW STOCK'
        ELSE 'HEALTHY'
    END AS stock_status,
    ps.last_updated
FROM product_stock ps
JOIN products p ON p.product_id = ps.product_id
JOIN warehouses w ON w.warehouse_id = ps.warehouse_id;

-- Dashboard 2: Open (unresolved) reorder alerts with supplier info
CREATE OR REPLACE VIEW vw_open_reorder_alerts AS
SELECT
    a.alert_id,
    p.sku,
    p.product_name,
    w.warehouse_name,
    a.qty_on_hand,
    a.suggested_qty,
    s.supplier_name,
    s.lead_time_days,
    a.raised_on
FROM low_stock_alerts a
JOIN products p ON p.product_id = a.product_id
JOIN warehouses w ON w.warehouse_id = a.warehouse_id
LEFT JOIN suppliers s ON s.supplier_id = p.supplier_id
WHERE a.resolved_flag = 'N';

-- Dashboard 3: Monthly consumption trend per product (for line charts)
CREATE OR REPLACE VIEW vw_monthly_consumption AS
SELECT
    p.sku,
    p.product_name,
    TO_CHAR(l.txn_time, 'YYYY-MM') AS txn_month,
    SUM(ABS(l.qty_change)) AS units_issued
FROM stock_txn_log l
JOIN products p ON p.product_id = l.product_id
WHERE l.txn_type = 'ISSUE'
GROUP BY p.sku, p.product_name, TO_CHAR(l.txn_time, 'YYYY-MM');

-- Dashboard 4: Top 10 fastest-moving products (last 30 days)
CREATE OR REPLACE VIEW vw_top_moving_products AS
SELECT * FROM (
    SELECT
        p.sku,
        p.product_name,
        SUM(ABS(l.qty_change)) AS units_issued_30d
    FROM stock_txn_log l
    JOIN products p ON p.product_id = l.product_id
    WHERE l.txn_type = 'ISSUE'
      AND l.txn_time >= SYSDATE - 30
    GROUP BY p.sku, p.product_name
    ORDER BY units_issued_30d DESC
) WHERE ROWNUM <= 10;
