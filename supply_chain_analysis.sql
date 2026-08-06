/* =========================================================
PROJECT: End-to-End Supply Chain Performance & Delivery Risk Analysis
AUTHOR: Santosh Patra
DIALECT NOTE:
- MySQL 8.0+ compatible.
- Uses CTEs and window functions supported in MySQL 8.0+.
- Load the cleaned CSV into the active MySQL schema as `clean_supply_chain`.

TABLE ASSUMPTION:
- `clean_supply_chain` is the analysis-ready table produced in Python.
- Grain is expected to be order-line unless otherwise documented.
========================================================= */


-- 0.1 Record count
SELECT COUNT(*) AS total_rows
FROM clean_supply_chain;

-- 0.2 Null checks on critical fields
SELECT
    SUM(CASE WHEN order_id IS NULL THEN 1 ELSE 0 END) AS null_order_id,
    SUM(CASE WHEN order_item_total IS NULL THEN 1 ELSE 0 END) AS null_order_item_total,
    SUM(CASE WHEN sales IS NULL THEN 1 ELSE 0 END) AS null_sales,
    SUM(CASE WHEN profit_per_order IS NULL THEN 1 ELSE 0 END) AS null_profit,
    SUM(CASE WHEN delivery_delay IS NULL THEN 1 ELSE 0 END) AS null_delivery_delay
FROM clean_supply_chain;

-- 0.3 Invalid value checks
SELECT
    SUM(CASE WHEN order_item_total < 0 THEN 1 ELSE 0 END) AS negative_order_item_total,
    SUM(CASE WHEN sales < 0 THEN 1 ELSE 0 END) AS negative_sales,
    SUM(CASE WHEN is_late_delivery NOT IN (0,1) THEN 1 ELSE 0 END) AS invalid_late_flag
FROM clean_supply_chain;

-- 0.4 Duplicate behavior at order level (diagnostic)
SELECT
    order_id,
    COUNT(*) AS rows_per_order
FROM clean_supply_chain
GROUP BY order_id
HAVING COUNT(*) > 1
ORDER BY rows_per_order DESC;

-- 0.5 Delay range sanity check
SELECT
    MIN(delivery_delay) AS min_delay,
    MAX(delivery_delay) AS max_delay,
    AVG(delivery_delay) AS avg_delay
FROM clean_supply_chain;


/* =========================================================
SECTION 1: KPI SCORECARD
Purpose: Executive-level operating baseline.
========================================================= */

SELECT
    SUM(order_item_total) AS net_revenue,
    SUM(sales) AS gross_revenue,
    SUM(sales) - SUM(order_item_total) AS total_discount,
    SUM(profit_per_order) AS total_profit,
    ROUND(AVG(delivery_delay), 2) AS avg_delivery_delay,
    ROUND(100.0 * SUM(is_late_delivery) / NULLIF(COUNT(*), 0), 2) AS late_delivery_pct,
    ROUND(SUM(order_item_total) / NULLIF(COUNT(DISTINCT order_id), 0), 2) AS revenue_per_order
FROM clean_supply_chain;


/* =========================================================
SECTION 2: REVENUE AND PROFIT QUALITY
========================================================= */

-- 2.1 Category contribution and margin quality
SELECT
    category_name,
    SUM(order_item_total) AS net_revenue,
    SUM(profit_per_order) AS profit,
    ROUND(100.0 * SUM(order_item_total) / NULLIF(SUM(SUM(order_item_total)) OVER (), 0), 2) AS revenue_share_pct,
    ROUND(100.0 * SUM(profit_per_order) / NULLIF(SUM(order_item_total), 0), 2) AS profit_margin_pct
FROM clean_supply_chain
GROUP BY category_name
ORDER BY net_revenue DESC;

-- 2.2 Identify profit leakage categories
SELECT
    category_name,
    SUM(order_item_total) AS net_revenue,
    SUM(profit_per_order) AS profit,
    ROUND(100.0 * SUM(profit_per_order) / NULLIF(SUM(order_item_total), 0), 2) AS profit_margin_pct
FROM clean_supply_chain
GROUP BY category_name
ORDER BY profit_margin_pct ASC;


/* =========================================================
SECTION 3: DELIVERY RISK DIAGNOSTICS
========================================================= */

-- 3.1 Delivery performance by shipping mode
SELECT
    shipping_mode,
    COUNT(*) AS rows_count,
    ROUND(AVG(delivery_delay), 2) AS avg_delay,
    ROUND(100.0 * SUM(is_late_delivery) / NULLIF(COUNT(*), 0), 2) AS late_pct
FROM clean_supply_chain
GROUP BY shipping_mode
ORDER BY late_pct DESC;

-- 3.2 Delivery performance by region
SELECT
    order_region,
    COUNT(*) AS rows_count,
    ROUND(AVG(delivery_delay), 2) AS avg_delay,
    ROUND(100.0 * SUM(is_late_delivery) / NULLIF(COUNT(*), 0), 2) AS late_pct
FROM clean_supply_chain
GROUP BY order_region
ORDER BY late_pct DESC;

-- 3.3 Highest-risk shipping mode and region intersections
SELECT
    shipping_mode,
    order_region,
    COUNT(*) AS rows_count,
    ROUND(100.0 * SUM(is_late_delivery) / NULLIF(COUNT(*), 0), 2) AS late_pct,
    ROUND(SUM(order_item_total), 2) AS net_revenue
FROM clean_supply_chain
GROUP BY shipping_mode, order_region
ORDER BY late_pct DESC, net_revenue DESC;


/* =========================================================
SECTION 4: TIME SERIES PERFORMANCE
========================================================= */

-- 4.1 Monthly revenue trend
SELECT
    year_month,
    SUM(order_item_total) AS net_revenue,
    SUM(profit_per_order) AS profit
FROM clean_supply_chain
GROUP BY year_month
ORDER BY year_month;

-- 4.2 Month-over-month revenue growth
WITH monthly_sales AS (
    SELECT
        year_month,
        SUM(order_item_total) AS net_revenue
    FROM clean_supply_chain
    GROUP BY year_month
)
SELECT
    year_month,
    net_revenue,
    LAG(net_revenue) OVER (ORDER BY year_month) AS prev_month_revenue,
    ROUND(
        100.0 * (net_revenue - LAG(net_revenue) OVER (ORDER BY year_month))
        / NULLIF(LAG(net_revenue) OVER (ORDER BY year_month), 0),
        2
    ) AS mom_growth_pct
FROM monthly_sales
ORDER BY year_month;


/* =========================================================
SECTION 5: CUSTOMER CONCENTRATION AND SEGMENTS
========================================================= */

-- 5.1 Customer Pareto analysis
WITH customer_sales AS (
    SELECT
        customer_id,
        SUM(order_item_total) AS revenue
    FROM clean_supply_chain
    GROUP BY customer_id
),
ranked AS (
    SELECT
        customer_id,
        revenue,
        SUM(revenue) OVER (ORDER BY revenue DESC) AS cumulative_revenue,
        SUM(revenue) OVER () AS total_revenue
    FROM customer_sales
)
SELECT
    customer_id,
    revenue,
    ROUND(100.0 * cumulative_revenue / NULLIF(total_revenue, 0), 2) AS cumulative_revenue_pct
FROM ranked
ORDER BY revenue DESC;

-- 5.2 Spending-based customer segmentation
WITH customer_sales AS (
    SELECT
        customer_id,
        SUM(order_item_total) AS total_spent
    FROM clean_supply_chain
    GROUP BY customer_id
)
SELECT
    CASE
        WHEN total_spent > 10000 THEN 'High Value'
        WHEN total_spent BETWEEN 5000 AND 10000 THEN 'Medium Value'
        ELSE 'Low Value'
    END AS segment,
    COUNT(*) AS customers,
    ROUND(AVG(total_spent), 2) AS avg_spend
FROM customer_sales
GROUP BY segment
ORDER BY avg_spend DESC;


/* =========================================================
SECTION 6: RISK-TO-VALUE PRIORITIZATION
Purpose: Focus on segments where business value and service risk overlap.
========================================================= */

-- 6.1 Order value bucket vs delay risk
SELECT
    order_value_bucket,
    COUNT(*) AS rows_count,
    ROUND(AVG(delivery_delay), 2) AS avg_delay,
    ROUND(100.0 * SUM(is_late_delivery) / NULLIF(COUNT(*), 0), 2) AS late_pct,
    ROUND(SUM(order_item_total), 2) AS net_revenue
FROM clean_supply_chain
GROUP BY order_value_bucket
ORDER BY late_pct DESC;

-- 6.2 Discount level vs profit and delivery quality
SELECT
    discount_level,
    COUNT(*) AS rows_count,
    ROUND(AVG(delivery_delay), 2) AS avg_delay,
    ROUND(AVG(profit_per_order), 2) AS avg_profit,
    ROUND(100.0 * SUM(is_late_delivery) / NULLIF(COUNT(*), 0), 2) AS late_pct
FROM clean_supply_chain
GROUP BY discount_level
ORDER BY avg_profit ASC;

-- 6.3 Delay status vs profitability
SELECT
    CASE WHEN delivery_delay > 0 THEN 'Late' ELSE 'On Time' END AS delivery_status,
    COUNT(*) AS rows_count,
    ROUND(AVG(profit_per_order), 2) AS avg_profit,
    ROUND(AVG(order_item_total), 2) AS avg_order_value
FROM clean_supply_chain
GROUP BY CASE WHEN delivery_delay > 0 THEN 'Late' ELSE 'On Time' END;


/* =========================================================
SECTION 7: INSIGHTS AND RECOMMENDATIONS
Purpose: Return business-readable findings directly from MySQL.
========================================================= */

-- 7.1 Highest value-at-risk mode-region combinations
WITH mode_region_risk AS (
    SELECT
        shipping_mode,
        order_region,
        COUNT(*) AS rows_count,
        ROUND(AVG(delivery_delay), 2) AS avg_delay,
        ROUND(100.0 * SUM(is_late_delivery) / NULLIF(COUNT(*), 0), 2) AS late_pct,
        ROUND(SUM(order_item_total), 2) AS net_revenue,
        ROUND(
            SUM(order_item_total) * SUM(is_late_delivery) / NULLIF(COUNT(*), 0),
            2
        ) AS revenue_at_risk_proxy
    FROM clean_supply_chain
    GROUP BY shipping_mode, order_region
)
SELECT
    CONCAT('Mode-region risk: ', shipping_mode, ' / ', order_region) AS insight,
    CONCAT(
        'Prioritize SLA review and capacity planning for ', shipping_mode,
        ' in ', order_region,
        ' because it combines ', late_pct,
        '% late delivery with ', FORMAT(net_revenue, 2),
        ' net revenue exposure.'
    ) AS recommendation,
    rows_count,
    avg_delay,
    late_pct,
    net_revenue,
    revenue_at_risk_proxy
FROM mode_region_risk
WHERE rows_count >= 100
ORDER BY revenue_at_risk_proxy DESC, late_pct DESC
LIMIT 10;

-- 7.2 Category-level commercial exposure
WITH category_risk AS (
    SELECT
        category_name,
        COUNT(*) AS rows_count,
        ROUND(SUM(order_item_total), 2) AS net_revenue,
        ROUND(SUM(profit_per_order), 2) AS profit,
        ROUND(100.0 * SUM(profit_per_order) / NULLIF(SUM(order_item_total), 0), 2) AS profit_margin_pct,
        ROUND(100.0 * SUM(is_late_delivery) / NULLIF(COUNT(*), 0), 2) AS late_pct
    FROM clean_supply_chain
    GROUP BY category_name
)
SELECT
    CONCAT('Category exposure: ', category_name) AS insight,
    CASE
        WHEN profit_margin_pct < 0 AND late_pct >= 50 THEN
            'Reduce discount intensity and review fulfillment reliability before pushing more volume.'
        WHEN late_pct >= 50 THEN
            'Improve delivery reliability before scaling this category further.'
        WHEN profit_margin_pct < 0 THEN
            'Review pricing and discount policy because revenue is not converting into profit.'
        ELSE
            'Maintain monitoring; this category is not an immediate risk priority.'
    END AS recommendation,
    rows_count,
    net_revenue,
    profit,
    profit_margin_pct,
    late_pct
FROM category_risk
ORDER BY
    CASE
        WHEN profit_margin_pct < 0 AND late_pct >= 50 THEN 1
        WHEN late_pct >= 50 THEN 2
        WHEN profit_margin_pct < 0 THEN 3
        ELSE 4
    END,
    net_revenue DESC
LIMIT 15;

-- 7.3 Executive recommendation register
SELECT
    'High revenue plus high delay should drive prioritization' AS insight,
    'Rank interventions by revenue-at-risk, not by late percentage alone.' AS recommendation
UNION ALL
SELECT
    'Late delivery is tied to commercial quality' AS insight,
    'Track late delivery, profit margin, and discount leakage in one operating scorecard.' AS recommendation
UNION ALL
SELECT
    'Mode-region intersections are the clearest operational risk map' AS insight,
    'Use shipping_mode plus order_region cuts for SLA review and capacity planning.' AS recommendation
UNION ALL
SELECT
    'Discount-heavy segments can hide weak margin performance' AS insight,
    'Tighten discount policy where low margin and poor delivery quality overlap.' AS recommendation
UNION ALL
SELECT
    'High-value customer cohorts need extra protection' AS insight,
    'Add stronger fulfillment controls for top customer revenue contributors.' AS recommendation;


/* =========================================================
SECTION 8: OPTIONAL PERFORMANCE INDEXES
Uncomment based on your MySQL permissions.
========================================================= */

-- CREATE INDEX idx_clean_supply_chain_order_date ON clean_supply_chain(order_date_dateorders);
-- CREATE INDEX idx_clean_supply_chain_region ON clean_supply_chain(order_region);
-- CREATE INDEX idx_clean_supply_chain_shipping_mode ON clean_supply_chain(shipping_mode);


/* =========================================================
FINAL INSIGHTS AND RECOMMENDATIONS (BUSINESS)
- Prioritize high-revenue + high-delay segments first.
- Treat late delivery as a margin-protection metric, not only an SLA metric.
- Reduce discount intensity in segments with weak profit and weak service quality.
- Monitor mode-region intersections as the core risk map.
========================================================= */
