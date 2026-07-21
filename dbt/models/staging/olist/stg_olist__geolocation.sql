with source as (

    select * from {{ source('olist', 'olist_geolocation_dataset') }}

),

renamed as (

    -- note: geolocation has many rows per zip prefix (one per lat/lng point).
    -- staging keeps them all; dedup/aggregation happens downstream where needed.
    select
        geolocation_zip_code_prefix,
        geolocation_lat,
        geolocation_lng,
        geolocation_city,
        geolocation_state

    from source

)

select * from renamed
