

with source as (

    select * from {{ source('olist', 'olist_order_items_dataset') }}

),

renamed as (

    select
        order_id,
        order_item_id,
        product_id,
        seller_id,
        shipping_limit_date,
        price,
        freight_value

    from source

)

select * from renamed
