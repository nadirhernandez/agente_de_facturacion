locals {
  quicksight_account_id        = local.account_id
  quicksight_admin_principal   = "${local.arn_quicksight}:user/default/AWSReservedSSO_AWSAdministratorAccess_2dfa29f98f589a40/rnhernandez"
  quicksight_service_role_name = "aws-quicksight-service-role-v0"
  quicksight_service_role_arn  = "arn:${local.partition}:iam::${local.account_id}:role/service-role/aws-quicksight-service-role-v0"
}

# QuickSight must read the curated Parquet data and Athena query results.
# The policy is scoped to this project bucket only.
resource "aws_iam_role_policy" "quicksight_data_access" {
  name = "dashboards-dinamicos-quicksight-data-access-dev"
  role = local.quicksight_service_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListProjectDataBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = aws_s3_bucket.data.arn
      },
      {
        Sid    = "ReadCuratedSalesData"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${aws_s3_bucket.data.arn}/curated/*"
        ]
      },
      {
        Sid    = "ReadAndWriteAthenaResults"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = [
          "${aws_s3_bucket.data.arn}/athena-results/*"
        ]
      }
    ]
  })
}

resource "aws_quicksight_data_source" "sales_athena" {
  aws_account_id = local.quicksight_account_id
  data_source_id = "sales-athena-dev"
  name           = "Ventas comerciales - Athena"
  type           = "ATHENA"

  parameters {
    athena {
      role_arn   = local.quicksight_service_role_arn
      work_group = aws_athena_workgroup.sales.name
    }
  }

  permission {
    principal = local.quicksight_admin_principal
    actions = [
      "quicksight:DescribeDataSource",
      "quicksight:DescribeDataSourcePermissions",
      "quicksight:PassDataSource",
      "quicksight:UpdateDataSource",
      "quicksight:DeleteDataSource",
      "quicksight:UpdateDataSourcePermissions"
    ]
  }

  depends_on = [aws_iam_role_policy.quicksight_data_access]
}

resource "aws_quicksight_data_set" "sales" {
  aws_account_id = local.quicksight_account_id
  data_set_id    = "ventas-comerciales-dev"
  name           = "Ventas comerciales"
  import_mode    = "SPICE"

  physical_table_map {
    physical_table_map_id = "VentasComercialesView"

    relational_table {
      data_source_arn = aws_quicksight_data_source.sales_athena.arn
      catalog         = "AwsDataCatalog"
      schema          = aws_glue_catalog_database.sales.name
      name            = "vw_ventas_comerciales"

      input_columns {
        name = "fecha"
        type = "DATETIME"
      }
      input_columns {
        name = "anio"
        type = "INTEGER"
      }
      input_columns {
        name = "mes"
        type = "INTEGER"
      }
      input_columns {
        name = "region"
        type = "STRING"
      }
      input_columns {
        name = "municipio"
        type = "STRING"
      }
      input_columns {
        name = "establecimiento"
        type = "STRING"
      }
      input_columns {
        name = "canal"
        type = "STRING"
      }
      input_columns {
        name = "cliente"
        type = "STRING"
      }
      input_columns {
        name = "nit_receptor"
        type = "STRING"
      }
      input_columns {
        name = "categoria"
        type = "STRING"
      }
      input_columns {
        name = "producto"
        type = "STRING"
      }
      input_columns {
        name = "codigo_producto"
        type = "STRING"
      }
      input_columns {
        name = "factura_id"
        type = "STRING"
      }
      input_columns {
        name = "unidades_vendidas"
        type = "INTEGER"
      }
      input_columns {
        name = "facturacion_total_linea"
        type = "DECIMAL"
      }
      input_columns {
        name = "ventas_sin_iva_linea"
        type = "DECIMAL"
      }
      input_columns {
        name = "iva_linea"
        type = "DECIMAL"
      }
    }
  }

  logical_table_map {
    alias                = "Ventas comerciales"
    logical_table_map_id = "VentasComercialesLogical"

    source {
      physical_table_id = "VentasComercialesView"
    }
  }

  # Incremental refresh replaces only the last days of SPICE. The fact table is
  # partitioned by day(fecha), so Athena reads only those days too.
  refresh_properties {
    refresh_configuration {
      incremental_refresh {
        lookback_window {
          column_name = "fecha"
          size        = local.spice_lookback_days
          size_unit   = "DAY"
        }
      }
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
      "quicksight:UpdateDataSetPermissions"
    ]
  }
}

# This creates one full SPICE refresh when the QuickSight stack is applied.
resource "aws_quicksight_ingestion" "sales_initial" {
  aws_account_id = local.quicksight_account_id
  data_set_id    = aws_quicksight_data_set.sales.data_set_id
  ingestion_id   = "initial-sales-refresh"
  ingestion_type = "FULL_REFRESH"
}
