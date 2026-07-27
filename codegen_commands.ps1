# ============================================================================
# codegen_commands.ps1 — scaffold staging models with dbt-codegen
#
# Run from the dbt/ folder, with the profile pointed at your project:
#   cd dbt ; $env:DBT_PROFILES_DIR = "profiles" ; dbt deps ; .\..\codegen_commands.ps1
#
# generate_base_model PRINTS a starter `select` (import CTE -> renamed -> final);
# this script captures that output and writes each to its staging model file.
#
# IMPORTANT: codegen output is a STARTING POINT, not the finished model. After
# generating, edit each file to: cast data types, group/rename columns, and
# (orders only, already done) add the as_of_date visibility cursor.
# ============================================================================

# Force UTF-8 so dbt doesn't read project files with the Windows cp1252 codec
# (arrows/em-dashes/emoji in configs or package docs otherwise crash parsing).
$env:PYTHONUTF8 = "1"
$env:DBT_PROFILES_DIR = "profiles"

function New-StagingModel($table, $model) {
    $sql = dbt --quiet run-operation generate_base_model `
        --args "{source_name: olist, table_name: $table}"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "codegen failed for $table -- leaving $model.sql untouched"
        return
    }
    $path = "$PWD\models\staging\olist\$model.sql"
    [System.IO.File]::WriteAllText($path, ($sql -join "`n"))
    Write-Host "wrote $model.sql"
}

# orders: already built by hand (has the as_of_date cursor) — not regenerated.
New-StagingModel 'olist_customers_dataset'           'stg_olist__customers'
New-StagingModel 'olist_order_items_dataset'         'stg_olist__order_items'
New-StagingModel 'olist_order_payments_dataset'      'stg_olist__payments'
New-StagingModel 'olist_order_reviews_dataset'       'stg_olist__reviews'
New-StagingModel 'olist_products_dataset'            'stg_olist__products'
New-StagingModel 'olist_sellers_dataset'             'stg_olist__sellers'
New-StagingModel 'olist_geolocation_dataset'         'stg_olist__geolocation'
New-StagingModel 'product_category_name_translation' 'stg_olist__category_translation'
