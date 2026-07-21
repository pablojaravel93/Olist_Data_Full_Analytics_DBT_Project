with source as (

    select * from {{ source('olist', 'olist_products_dataset') }}

),

renamed as (

    select
        -- keys
        product_id,

        -- attributes
        product_category_name,

        -- measures (note: source misspells "length" as "lenght" — fixed here)
        product_name_lenght         as product_name_length,
        product_description_lenght  as product_description_length,
        product_photos_qty,
        product_weight_g,
        product_length_cm,
        product_height_cm,
        product_width_cm

    from source

)

select * from renamed
