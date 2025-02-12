with dates as (
    {{dbt_utils.date_spine(
        start_date = "'2020-12-01'",
        end_date = 'current_date()',
        datepart = 'day'
    )}}
),

table_subscriber_first_country as (
    select
        dim_subscriptions.customer_id_recharge,
        dim_subscriptions.shipping_country as first_country_by_subscriber
    from {{ref('dim_subscriptions')}}
    qualify row_number() over (partition by customer_id_recharge order by dim_subscriptions.subscription_created_at asc) = 1
),



subscriptions_base AS (
select distinct

    -- ID's:
    --{{ dbt_utils.generate_surrogate_key(['subscriptions.subscription_id', 'dates.date_day']) }} as active_subscription_id,
    dim_subscriptions.subscription_id,
    dim_subscriptions.customer_id_recharge,

    -- Dates:
    dates.date_day as date,
    dim_subscriptions.subscription_created_at,
    dim_subscriptions.subscriber_created_at,
    
    -- Market and location Dimensions:
    table_subscriber_first_country.first_country_by_subscriber, --as country_name,

    -- Product attributes
    dim_subscriptions.product_type as product_type,
    dim_subscriptions.gender,
    dim_subscriptions.customer_segment,
    -- sergi 2024-12-09: Add internal grouped sku
    dim_subscriptions.sku_grouped_internal,

    -- Subscription status Dimensions:
    dim_subscriptions.is_reactivated_subscription,
    case when dates.date_day >= date_trunc(day, dim_subscriptions.subscription_created_at) 
        and dates.date_day < coalesce(date_trunc(day, dim_subscriptions.subscription_canceled_at), date_trunc(day, current_date()))  then 1 
        else false end as is_active_subscription,
    
    -- case when date_trunc(month, dates.date_day) >= date_trunc(month, dim_subscriptions.subscription_created_at) 
    --     and date_trunc(month, dates.date_day) < coalesce(date_trunc(month, dim_subscriptions.subscription_canceled_at), date_trunc(month, current_date())) then 1 
    --     else false end as is_active_subscription_monthly,
    
    -- case when date_trunc(month, dates.date_day) = date_trunc(month, dim_subscriptions.subscription_canceled_at) then 1
    --     else 0 end as has_canceled_subscription_monthly,
    
    case when dates.date_day = date_trunc(day, dim_subscriptions.subscription_canceled_at) then 1
        else 0 end as has_canceled_subscription,
    case when dates.date_day = date_trunc(day, dim_subscriptions.subscription_created_at) then 1
        else 0 end as has_created_subscription, 
    case when dates.date_day = date_trunc(day, dim_subscriptions.subscription_created_at) 
        and dim_subscriptions.is_reactivated_subscription = 1 then 1
        else 0 end as has_reactivated_subscription, 
    
    -- Subsciber status dimension: 
    -- case when max(is_active_subscription) over (partition by dim_subscriptions.customer_id_recharge, date order by date asc) = 1 then 1 else 0 end as is_active_subscriber,
    -- case when max(is_active_subscription_monthly) over (partition by dim_subscriptions.customer_id_recharge, date_trunc(month, dates.date_day), dim_subscriptions.product_type) = 1 then 1 else 0 end as is_active_subscriber_monthly,
    -- case when min(has_canceled_subscription_monthly) over (partition by dim_subscriptions.customer_id_recharge, date_trunc(month, dates.date_day), dim_subscriptions.product_type) = 1 then 1 else 0 end as has_canceled_subscriber
    -- Time Auxiliar Dimensions


    dim_dates.is_wtd,
    dim_dates.is_mtd,
    dim_dates.is_ytd,
    dim_dates.is_current_month, 
    dim_dates.is_previous_month, 
    dim_dates.is_previous_year,
    dim_dates.is_same_month_previous_year,
    dim_dates.day_of_month,
    dim_dates.mtd_window_type,
    dim_dates.day_of_week, 
    dim_dates.month_of_year, 
    dim_dates.is_current_year,
    dim_dates.is_last_13_months, 
    dim_dates.year_number, 
    dim_dates.month_name



from dates
inner join {{ref('dim_subscriptions')}} 
    on dates.date_day >= date_trunc(day, dim_subscriptions.subscription_created_at)
left join table_subscriber_first_country
    on dim_subscriptions.customer_id_recharge = table_subscriber_first_country.customer_id_recharge
left join {{ref('dim_dates')}}
    on dates.date_day = dim_dates.date_pk

)

 
    SELECT 
        w.*,

        -- 1️⃣ Cancelados: Cancelaron su suscripción y permanecen cancelados
        CASE 
            WHEN 
            product_type IN ('Monthly Subs', 'Quarterly Subs')
            AND customer_id_recharge IS NOT NULL
            AND EXISTS (
                SELECT 1 
                FROM subscriptions_base f
                WHERE f.CUSTOMER_ID_RECHARGE = w.CUSTOMER_ID_RECHARGE
                AND f.is_active_subscription = TRUE  
                AND f.date = DATEADD(DAY, -1, DATE_TRUNC('month', w.date)) -- Último día del mes anterior
            ) 
            AND EXISTS (
                SELECT 1 
                FROM subscriptions_base f3
                WHERE f3.customer_id_recharge = w.customer_id_recharge
                AND f3.has_canceled_subscription = TRUE
                AND DATE_TRUNC('month', f3.date) = DATE_TRUNC('month', w.date)
            )
            AND NOT EXISTS (
                SELECT 1 
                FROM subscriptions_base f4
                WHERE f4.customer_id_recharge = w.customer_id_recharge
                AND f4.date = DATEADD(DAY, -1, DATE_TRUNC('month', DATEADD(MONTH, 1, w.date))) 
                AND f4.is_active_subscription = TRUE
                AND DATE_TRUNC('month', f4.date) = DATE_TRUNC('month', w.date) 
            ) 
        THEN 1 ELSE 0 
        END AS is_cancelled_subscriber,

        -- 2️⃣ Reactivados: Estaban inactivos el último día del mes anterior, se reactivaron y terminaron el mes activos
        CASE 
            WHEN 
            product_type IN ('Monthly Subs', 'Quarterly Subs')
            AND customer_id_recharge IS NOT NULL
            AND NOT EXISTS (
                SELECT 1 
                FROM subscriptions_base f2
                WHERE f2.CUSTOMER_ID_RECHARGE = w.CUSTOMER_ID_RECHARGE
                AND f2.is_active_subscription = TRUE  
                AND f2.date = DATEADD(DAY, -1, DATE_TRUNC('month', w.date)) 
            )
            AND EXISTS (
                SELECT 1 
                FROM subscriptions_base f3
                WHERE f3.CUSTOMER_ID_RECHARGE = w.CUSTOMER_ID_RECHARGE
                AND f3.has_reactivated_subscription = TRUE  
                AND DATE_TRUNC('month', f3.date) = DATE_TRUNC('month', w.date) 
            )
            AND EXISTS (
                SELECT 1 
                FROM subscriptions_base f4
                WHERE f4.CUSTOMER_ID_RECHARGE = w.CUSTOMER_ID_RECHARGE
                AND f4.date = DATEADD(DAY, -1, DATE_TRUNC('month', DATEADD(MONTH, 1, w.date))) 
                AND f4.is_active_subscription = TRUE
                AND DATE_TRUNC('month', f4.date) = DATE_TRUNC('month', w.date) 
            )
        THEN 1 ELSE 0 
        END AS is_reactivated_subscriber,

        -- 3️⃣ Nuevos suscriptores: Se suscribieron este mes y no estaban activos el mes anterior
        CASE 
            WHEN 
            product_type IN ('Monthly Subs', 'Quarterly Subs')
            AND customer_id_recharge IS NOT NULL
            AND DATE_TRUNC('month', subscriber_created_at) = DATE_TRUNC('month', w.date) 
            AND NOT EXISTS (
                SELECT 1 
                FROM subscriptions_base f2
                WHERE f2.CUSTOMER_ID_RECHARGE = w.CUSTOMER_ID_RECHARGE
                AND f2.is_active_subscription = TRUE  
                AND f2.date = DATEADD(DAY, -1, DATE_TRUNC('month', w.date)) 
            )
        THEN 1 ELSE 0 
        END AS new_subscriber,

        -- 4️⃣ Nuevos suscriptores que cancelan en el mismo mes
        CASE 
            WHEN 
            product_type IN ('Monthly Subs', 'Quarterly Subs')
            AND customer_id_recharge IS NOT NULL
            AND DATE_TRUNC('month', subscriber_created_at) = DATE_TRUNC('month', w.date) 
            AND NOT EXISTS (
                SELECT 1 
                FROM subscriptions_base f2
                WHERE f2.CUSTOMER_ID_RECHARGE = w.CUSTOMER_ID_RECHARGE
                AND f2.is_active_subscription = TRUE  
                AND f2.date = DATEADD(DAY, -1, DATE_TRUNC('month', w.date)) 
            )
            AND EXISTS (
                SELECT 1 
                FROM subscriptions_base f4
                WHERE f4.CUSTOMER_ID_RECHARGE = w.CUSTOMER_ID_RECHARGE
                AND f4.has_canceled_subscription = TRUE  
                AND DATE_TRUNC('month', f4.date) = DATE_TRUNC('month', w.date) 
            )
            AND NOT EXISTS ( 
                SELECT 1 
                FROM subscriptions_base f5
                WHERE f5.CUSTOMER_ID_RECHARGE = w.CUSTOMER_ID_RECHARGE
                AND f5.is_active_subscription = TRUE 
                AND f5.date = DATEADD(DAY, -1, DATEADD(MONTH, 1, DATE_TRUNC('month', w.date))) -- Último día del mes
           )
        THEN 1 ELSE 0 
        END AS new_subscriber_cancelled,

                -- Suscriptores activos el ultimo dia del mes anterior
        CASE 
            WHEN EXISTS (
                SELECT 1
                FROM subscriptions_base b
                WHERE b.customer_id_recharge = w.customer_id_recharge
                AND b.date = date_trunc('month', w.date) - INTERVAL '1 day'
                AND b.is_active_subscription = TRUE
                AND b.product_type IN ('Monthly Subs', 'Quarterly Subs')
                AND b.product_type = w.product_type -- ✅ Asegurar que el `product_type` coincide
                AND b.first_country_by_subscriber = w.first_country_by_subscriber -- ✅ También asegurar el país
                AND b.gender=w.gender
                and b.customer_id_recharge is not null
            ) THEN 1
            ELSE 0
        END AS was_actived_last_month

    FROM 
        subscriptions_base w




