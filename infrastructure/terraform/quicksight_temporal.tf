/**
 * Day/week/month/year dataset with prior-period comparatives.
 *
 * Kept separate from the line-level dataset on purpose: mixing grains in one
 * dataset double counts. One row per period here, one row per invoice line there.
 */

locals {
  comparativo_columns = {
    granularidad               = "STRING"
    periodo                    = "DATETIME"
    anio                       = "INTEGER"
    mes                        = "INTEGER"
    fin_periodo                = "DATETIME"
    es_periodo_completo        = "BIT"
    facturacion_total          = "DECIMAL"
    ventas_sin_iva             = "DECIMAL"
    iva                        = "DECIMAL"
    facturas                   = "INTEGER"
    unidades                   = "INTEGER"
    facturacion_total_anterior = "DECIMAL"
    ventas_sin_iva_anterior    = "DECIMAL"
    facturas_anterior          = "INTEGER"
    unidades_anterior          = "INTEGER"
    variacion_facturacion_pct  = "DECIMAL"
    variacion_facturas_pct     = "DECIMAL"
  }
}

resource "aws_quicksight_data_set" "comparativo" {
  aws_account_id = local.quicksight_account_id
  data_set_id    = "ventas-comparativo-dev"
  name           = "Ventas por periodo"
  import_mode    = "SPICE"

  physical_table_map {
    physical_table_map_id = "VentasComparativoView"

    relational_table {
      data_source_arn = aws_quicksight_data_source.sales_athena.arn
      catalog         = "AwsDataCatalog"
      schema          = aws_glue_catalog_database.sales.name
      name            = "vw_ventas_comparativo"

      dynamic "input_columns" {
        for_each = local.comparativo_columns
        content {
          name = input_columns.key
          type = input_columns.value
        }
      }
    }
  }

  logical_table_map {
    alias                = "Ventas por periodo"
    logical_table_map_id = "VentasComparativoLogical"

    source {
      physical_table_id = "VentasComparativoView"
    }
  }

  permissions {
    principal = local.quicksight_admin_principal
    actions = [
      "quicksight:DescribeDataSet",
      "quicksight:DescribeDataSetPermissions",
      "quicksight:PassDataSet",
      "quicksight:DescribeIngestion",
      "quicksight:ListIngestions",
      "quicksight:UpdateDataSet",
      "quicksight:DeleteDataSet",
      "quicksight:CreateIngestion",
      "quicksight:CancelIngestion",
      "quicksight:UpdateDataSetPermissions",
    ]
  }
}

resource "aws_quicksight_ingestion" "comparativo_initial" {
  aws_account_id = local.quicksight_account_id
  data_set_id    = aws_quicksight_data_set.comparativo.data_set_id
  ingestion_id   = "initial-comparativo-refresh"
  ingestion_type = "FULL_REFRESH"
}

/**
 * Scheduled refreshes of the lines dataset back up the event-driven one, which
 * already picks incremental or full per load:
 *   - daily incremental, in case a load event was missed
 *   - weekly full, to catch an annulment older than the window and to rebuild
 *     from scratch on a known schedule
 *
 * QuickSight does not allow an hourly schedule next to other schedules on the
 * same dataset, so the former hourly full refresh is replaced, not kept.
 */
moved {
  from = aws_quicksight_refresh_schedule.sales_hourly
  to   = aws_quicksight_refresh_schedule.sales_incremental_daily
}

resource "aws_quicksight_refresh_schedule" "sales_incremental_daily" {
  aws_account_id = local.quicksight_account_id
  data_set_id    = aws_quicksight_data_set.sales.data_set_id
  schedule_id    = "daily-incremental-refresh"

  schedule {
    refresh_type = "INCREMENTAL_REFRESH"

    schedule_frequency {
      interval        = "DAILY"
      time_of_the_day = "02:00"
      timezone        = "America/Guatemala"
    }
  }
}

resource "aws_quicksight_refresh_schedule" "sales_full_weekly" {
  aws_account_id = local.quicksight_account_id
  data_set_id    = aws_quicksight_data_set.sales.data_set_id
  schedule_id    = "weekly-full-refresh"

  schedule {
    refresh_type = "FULL_REFRESH"

    schedule_frequency {
      interval        = "WEEKLY"
      time_of_the_day = "03:00"
      timezone        = "America/Guatemala"

      refresh_on_day {
        day_of_week = "SUNDAY"
      }
    }
  }

  # Created after the hourly schedule is gone.
  depends_on = [aws_quicksight_refresh_schedule.sales_incremental_daily]
}

resource "aws_quicksight_refresh_schedule" "comparativo_hourly" {
  aws_account_id = local.quicksight_account_id
  data_set_id    = aws_quicksight_data_set.comparativo.data_set_id
  schedule_id    = "hourly-full-refresh"

  schedule {
    refresh_type = "FULL_REFRESH"

    schedule_frequency {
      interval = "HOURLY"
    }
  }
}
