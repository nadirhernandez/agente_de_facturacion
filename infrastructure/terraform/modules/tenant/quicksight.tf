/**
 * QuickSight for one tenant account, including the account subscription itself.
 *
 * This is what makes the model fully automatable: enabling QuickSight was the
 * only manual console step in the pilot, and aws_quicksight_account_subscription
 * removes it.
 */

locals {
  quicksight_admin_arn = "arn:aws:quicksight:${var.region}:${var.account_id}:user/default/${var.quicksight_admin_email}"

  # Dataset ids are fixed names, known at plan time. Permissions and Lambda
  # settings use these instead of the dataset resources: the datasets wait for
  # the model deployer, so referencing them from its side would be a cycle.
  sales_data_set_id   = "${local.prefix}-ventas"
  periods_data_set_id = "${local.prefix}-periodos"
}

resource "aws_quicksight_account_subscription" "tenant" {
  count = var.manage_quicksight_subscription ? 1 : 0

  aws_account_id        = var.account_id
  account_name          = "vi-${var.tenant_id}"
  authentication_method = "IAM_AND_QUICKSIGHT"
  edition               = var.quicksight_edition
  notification_email    = var.quicksight_admin_email
}

# QuickSight needs to read curated data and write Athena query results.
resource "aws_iam_role" "quicksight" {
  name = "${local.prefix}-quicksight"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "quicksight.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "quicksight" {
  name = "${local.prefix}-quicksight-data"
  role = aws_iam_role.quicksight.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # What QuickSight's Athena connector calls, on this workgroup only.
        Sid    = "RunAthenaQueries"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:StopQueryExecution",
          "athena:GetQueryExecution", "athena:GetQueryResults", "athena:GetQueryResultsStream",
          "athena:BatchGetQueryExecution", "athena:ListQueryExecutions",
          "athena:GetWorkGroup",
        ]
        Resource = aws_athena_workgroup.sales.arn
      },
      {
        # Catalog browsing in the data source; read-only metadata.
        Sid    = "BrowseAthenaCatalog"
        Effect = "Allow"
        Action = [
          "athena:ListWorkGroups", "athena:ListDataCatalogs", "athena:GetDataCatalog",
          "athena:ListDatabases", "athena:GetDatabase", "athena:ListTableMetadata", "athena:GetTableMetadata",
        ]
        Resource = "*"
      },
      {
        Sid    = "ReadCatalog"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetDatabases",
          "glue:GetTable", "glue:GetTables",
          "glue:GetPartition", "glue:GetPartitions",
        ]
        Resource = [
          "arn:aws:glue:${var.region}:${var.account_id}:catalog",
          "arn:aws:glue:${var.region}:${var.account_id}:database/${aws_glue_catalog_database.sales.name}",
          "arn:aws:glue:${var.region}:${var.account_id}:table/${aws_glue_catalog_database.sales.name}/*",
        ]
      },
      {
        Sid      = "ListDataBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = aws_s3_bucket.data.arn
      },
      {
        Sid      = "ReadCuratedData"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.data.arn}/${local.iceberg_prefix}*"
      },
      {
        Sid      = "ReadWriteQueryResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.data.arn}/athena-results/*"
      },
    ]
  })
}

resource "aws_quicksight_data_source" "athena" {
  aws_account_id = var.account_id
  data_source_id = "${local.prefix}-athena"
  name           = "Ventas comerciales - Athena"
  type           = "ATHENA"
  tags           = local.tags

  parameters {
    athena {
      role_arn   = aws_iam_role.quicksight.arn
      work_group = aws_athena_workgroup.sales.name
    }
  }

  permission {
    principal = local.quicksight_admin_arn
    actions = [
      "quicksight:DescribeDataSource",
      "quicksight:DescribeDataSourcePermissions",
      "quicksight:PassDataSource",
      "quicksight:UpdateDataSource",
      "quicksight:DeleteDataSource",
      "quicksight:UpdateDataSourcePermissions",
    ]
  }

  depends_on = [
    aws_iam_role_policy.quicksight,
    aws_quicksight_account_subscription.tenant,
  ]
}

locals {
  dataset_permissions = [
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

  sales_columns = {
    fecha                   = "DATETIME"
    anio                    = "INTEGER"
    mes                     = "INTEGER"
    codigo_moneda           = "STRING"
    region                  = "STRING"
    municipio               = "STRING"
    establecimiento         = "STRING"
    canal                   = "STRING"
    cliente                 = "STRING"
    nit_receptor            = "STRING"
    categoria               = "STRING"
    producto                = "STRING"
    codigo_producto         = "STRING"
    factura_id              = "STRING"
    unidades_vendidas       = "INTEGER"
    facturacion_total_linea = "DECIMAL"
    ventas_sin_iva_linea    = "DECIMAL"
    iva_linea               = "DECIMAL"
  }

  period_columns = {
    granularidad               = "STRING"
    periodo                    = "DATETIME"
    anio                       = "INTEGER"
    mes                        = "INTEGER"
    codigo_moneda              = "STRING"
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

resource "aws_quicksight_data_set" "sales" {
  aws_account_id = var.account_id
  data_set_id    = local.sales_data_set_id
  name           = "Ventas comerciales"
  import_mode    = "SPICE"
  tags           = local.tags

  physical_table_map {
    physical_table_map_id = "VentasComerciales"

    relational_table {
      data_source_arn = aws_quicksight_data_source.athena.arn
      catalog         = "AwsDataCatalog"
      schema          = aws_glue_catalog_database.sales.name
      name            = "vw_ventas_comerciales"

      dynamic "input_columns" {
        for_each = local.sales_columns
        content {
          name = input_columns.key
          type = input_columns.value
        }
      }
    }
  }

  logical_table_map {
    alias                = "Ventas comerciales"
    logical_table_map_id = "VentasComercialesLogical"

    source {
      physical_table_id = "VentasComerciales"
    }
  }

  # Incremental refresh replaces only the last days of SPICE. The fact table is
  # partitioned by day(fecha), so Athena reads only those days too.
  refresh_properties {
    refresh_configuration {
      incremental_refresh {
        lookback_window {
          column_name = "fecha"
          size        = var.spice_lookback_days
          size_unit   = "DAY"
        }
      }
    }
  }

  permissions {
    principal = local.quicksight_admin_arn
    actions   = local.dataset_permissions
  }

  # The view must exist before QuickSight can ingest from it.
  depends_on = [aws_lambda_invocation.deploy_views]
}

resource "aws_quicksight_data_set" "periods" {
  aws_account_id = var.account_id
  data_set_id    = local.periods_data_set_id
  name           = "Ventas por periodo"
  import_mode    = "SPICE"
  tags           = local.tags

  physical_table_map {
    physical_table_map_id = "VentasPorPeriodo"

    relational_table {
      data_source_arn = aws_quicksight_data_source.athena.arn
      catalog         = "AwsDataCatalog"
      schema          = aws_glue_catalog_database.sales.name
      name            = "vw_ventas_comparativo"

      dynamic "input_columns" {
        for_each = local.period_columns
        content {
          name = input_columns.key
          type = input_columns.value
        }
      }
    }
  }

  logical_table_map {
    alias                = "Ventas por periodo"
    logical_table_map_id = "VentasPorPeriodoLogical"

    source {
      physical_table_id = "VentasPorPeriodo"
    }
  }

  permissions {
    principal = local.quicksight_admin_arn
    actions   = local.dataset_permissions
  }

  depends_on = [aws_lambda_invocation.deploy_views]
}

/**
 * The lines dataset refreshes after every load, incremental or full as the load
 * requires. These schedules back that up:
 *   - daily incremental, in case a load event was missed
 *   - weekly full, to catch an annulment older than the window
 *
 * QuickSight does not allow an hourly schedule next to other schedules on the
 * same dataset, which is why the lines dataset has no hourly one.
 */
resource "aws_quicksight_refresh_schedule" "sales_incremental_daily" {
  aws_account_id = var.account_id
  data_set_id    = aws_quicksight_data_set.sales.data_set_id
  schedule_id    = "daily-incremental-refresh"

  schedule {
    refresh_type = "INCREMENTAL_REFRESH"

    schedule_frequency {
      interval        = "DAILY"
      time_of_the_day = "02:00"
      timezone        = var.timezone
    }
  }
}

resource "aws_quicksight_refresh_schedule" "sales_full_weekly" {
  aws_account_id = var.account_id
  data_set_id    = aws_quicksight_data_set.sales.data_set_id
  schedule_id    = "weekly-full-refresh"

  schedule {
    refresh_type = "FULL_REFRESH"

    schedule_frequency {
      interval        = "WEEKLY"
      time_of_the_day = "03:00"
      timezone        = var.timezone

      refresh_on_day {
        day_of_week = "SUNDAY"
      }
    }
  }

  depends_on = [aws_quicksight_refresh_schedule.sales_incremental_daily]
}

resource "aws_quicksight_refresh_schedule" "periods" {
  aws_account_id = var.account_id
  data_set_id    = aws_quicksight_data_set.periods.data_set_id
  schedule_id    = "scheduled-full-refresh"

  schedule {
    refresh_type = "FULL_REFRESH"

    schedule_frequency {
      interval = var.spice_refresh_interval
    }
  }
}
