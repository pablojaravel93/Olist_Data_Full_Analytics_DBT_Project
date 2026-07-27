with source as (

    select * from {{ source('olist', 'olist_order_payments_dataset') }}

),

renamed as (

    select
        -- keys
        order_id,
        payment_sequential,

        -- attributes
        payment_type,
        payment_installments,

        -- measures
        payment_value

    from source

)

select * from renamed
