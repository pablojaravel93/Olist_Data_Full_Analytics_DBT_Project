with source as (

    select * from {{ source('olist', 'product_category_name_translation') }}

),

renamed as (

    -- BigQuery autodetect couldn't read this file's header, so columns loaded
    -- as string_field_0/1. Alias them to their real names here.
    select
        string_field_0  as product_category_name,
        string_field_1  as product_category_name_english

    from source

)

select * from renamed
