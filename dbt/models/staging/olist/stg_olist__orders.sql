with source as (

    select * from {{ source('olist', 'olist_orders_dataset') }}

),

renamed as (

    select
        -- ids
        order_id,
        customer_id,

        -- attributes
        order_status,

        -- timestamps
        cast(order_purchase_timestamp as timestamp)        as ordered_at,
        cast(order_approved_at as timestamp)               as approved_at,
        cast(order_delivered_customer_date as timestamp)   as delivered_at,
        cast(order_estimated_delivery_date as timestamp)   as estimated_delivery_at

    from source
    -- visibility cursor: simulates data "arriving" over time (see TUTORIAL section 4.12)
    where cast(order_purchase_timestamp as timestamp) <= timestamp('{{ var("as_of_date", "2018-12-31") }}')

)

select * from renamed