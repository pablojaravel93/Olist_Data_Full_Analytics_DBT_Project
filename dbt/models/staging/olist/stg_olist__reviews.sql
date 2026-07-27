with source as (

    select * from {{ source('olist', 'olist_order_reviews_dataset') }}

),

renamed as (

    select
        -- keys
        review_id,
        order_id,

        -- attributes
        review_score,
        review_comment_title,
        review_comment_message,

        -- timestamps
        cast(review_creation_date as timestamp)     as review_created_at,
        cast(review_answer_timestamp as timestamp)  as review_answered_at

    from source

),

deduped as (

    -- raw reviews contain duplicate review_id values (known Olist quirk);
    -- keep the most recently answered row per review_id.
    select *
    from renamed
    qualify row_number() over (
        partition by review_id
        order by review_answered_at desc
    ) = 1

)

select * from deduped
