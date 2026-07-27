with source as (

    select * from {{ source('olist', 'olist_sellers_dataset') }}

),

renamed as (

    select
        -- keys
        seller_id,

        -- location
        seller_zip_code_prefix,
        seller_city,
        seller_state

    from source

)

select * from renamed
