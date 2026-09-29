#!/usr/bin/env python3
"""Build a deterministic QuickSight dashboard definition from an existing analysis."""

from __future__ import annotations

import json
import subprocess
from datetime import UTC, datetime
from pathlib import Path

ACCOUNT_ID = "503561412084"
REGION = "us-east-1"
PROFILE = "dashboards-dev-infile"
ANALYSIS_ID = "1a340c35-223b-4a2c-b385-a60c28f771d8"
ANALYSIS_NAME = "Ventas Inteligentes GT analysis"
ROOT = Path(__file__).resolve().parents[2]
OUTPUT_DIR = ROOT / "infrastructure" / "quicksight" / "generated"


def aws_json(*arguments: str) -> dict:
    result = subprocess.run(
        ["aws", *arguments, "--profile", PROFILE, "--region", REGION, "--output", "json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def field_reference(column_name: str) -> dict:
    return {
        "DataSetIdentifier": "VentasComerciales",
        "ColumnName": column_name,
    }


def title(text: str) -> dict:
    return {
        "Visibility": "VISIBLE",
        "FormatText": {"RichText": f"<visual-title>{text}</visual-title>"},
    }


def subtitle(text: str) -> dict:
    return {
        "Visibility": "VISIBLE",
        "FormatText": {"RichText": f"<visual-subtitle>{text}</visual-subtitle>"},
    }


# Todos los montos son quetzales (codigo_moneda = GTQ). Sin formato explícito
# Quick muestra "$"; con prefijo "Q" nunca aparece otra moneda.
QUETZALES = {
    "FormatConfiguration": {
        "NumberDisplayFormatConfiguration": {
            "Prefix": "Q",
            "DecimalPlacesConfiguration": {"DecimalPlaces": 2},
            "NumberScale": "NONE",
            "SeparatorConfiguration": {
                "DecimalSeparator": "DOT",
                "ThousandsSeparator": {"Symbol": "COMMA", "Visibility": "VISIBLE"},
            },
            "NegativeValueConfiguration": {"DisplayMode": "NEGATIVE"},
        }
    }
}

ENTEROS = {
    "FormatConfiguration": {
        "NumberDisplayFormatConfiguration": {
            "DecimalPlacesConfiguration": {"DecimalPlaces": 0},
            "NumberScale": "NONE",
            "SeparatorConfiguration": {
                "DecimalSeparator": "DOT",
                "ThousandsSeparator": {"Symbol": "COMMA", "Visibility": "VISIBLE"},
            },
        }
    }
}

# Columnas que son cantidades, no dinero.
QUANTITY_COLUMNS = {"unidades_vendidas"}


def numeric_measure(column_name: str, field_id: str) -> dict:
    return {
        "NumericalMeasureField": {
            "FieldId": field_id,
            "Column": field_reference(column_name),
            "AggregationFunction": {"SimpleNumericalAggregation": "SUM"},
            "FormatConfiguration": ENTEROS if column_name in QUANTITY_COLUMNS else QUETZALES,
        }
    }


def count_distinct_measure(column_name: str, field_id: str) -> dict:
    return {
        "CategoricalMeasureField": {
            "FieldId": field_id,
            "Column": field_reference(column_name),
            "AggregationFunction": "DISTINCT_COUNT",
        }
    }


def categorical_dimension(column_name: str, field_id: str) -> dict:
    return {
        "CategoricalDimensionField": {
            "FieldId": field_id,
            "Column": field_reference(column_name),
        }
    }


def date_dimension(column_name: str, field_id: str) -> dict:
    return {
        "DateDimensionField": {
            "FieldId": field_id,
            "Column": field_reference(column_name),
            "DateGranularity": "MONTH",
            "HierarchyId": "tendencia-fecha-hierarchy",
        }
    }


def kpi(visual_id: str, visual_title: str, measure: dict) -> dict:
    return {
        "KPIVisual": {
            "VisualId": visual_id,
            "Title": title(visual_title),
            "Subtitle": subtitle("Acumulado del período visible"),
            "ChartConfiguration": {
                "FieldWells": {"Values": [measure], "TargetValues": [], "TrendGroups": []},
                "SortConfiguration": {},
                "KPIOptions": {
                    "PrimaryValueDisplayType": "ACTUAL",
                    "Sparkline": {"Visibility": "HIDDEN", "Type": "AREA"},
                    "VisualLayoutOptions": {"StandardLayout": {"Type": "VERTICAL"}},
                },
            },
            "Actions": [],
            "ColumnHierarchies": [],
        }
    }


def line_chart(visual_id: str, visual_title: str, category: dict, measure: dict) -> dict:
    return {
        "LineChartVisual": {
            "VisualId": visual_id,
            "Title": title(visual_title),
            "Subtitle": {"Visibility": "HIDDEN"},
            "ChartConfiguration": {
                "FieldWells": {
                    "LineChartAggregatedFieldWells": {
                        "Category": [category],
                        "Values": [measure],
                        "Colors": [],
                        "SmallMultiples": [],
                    }
                },
                "SortConfiguration": {},
                "Type": "LINE",
            },
            "Actions": [],
            "ColumnHierarchies": [
                {
                    "DateTimeHierarchy": {
                        "HierarchyId": "tendencia-fecha-hierarchy",
                        "DrillDownFilters": [],
                    }
                }
            ],
        }
    }


def bar_chart(visual_id: str, visual_title: str, category: dict, measure: dict) -> dict:
    measure_id = measure["NumericalMeasureField"]["FieldId"]
    return {
        "BarChartVisual": {
            "VisualId": visual_id,
            "Title": title(visual_title),
            "Subtitle": subtitle("Top 10 · ordenado de mayor a menor"),
            "ChartConfiguration": {
                "FieldWells": {
                    "BarChartAggregatedFieldWells": {
                        "Category": [category],
                        "Values": [measure],
                        "Colors": [],
                        "SmallMultiples": [],
                    }
                },
                "SortConfiguration": {
                    "CategorySort": [{"FieldSort": {"FieldId": measure_id, "Direction": "DESC"}}],
                    "CategoryItemsLimit": {"ItemsLimit": 10, "OtherCategories": "EXCLUDE"},
                },
                # Horizontal bars leave room for long region/product names.
                "Orientation": "HORIZONTAL",
            },
            "Actions": [],
            "ColumnHierarchies": [],
        }
    }


def layout(visual_id: str, column_index: int, row_index: int, column_span: int, row_span: int) -> dict:
    return {
        "ElementId": visual_id,
        "ElementType": "VISUAL",
        "ColumnIndex": column_index,
        "RowIndex": row_index,
        "ColumnSpan": column_span,
        "RowSpan": row_span,
    }


def dashboard_definition() -> dict:
    return {
        "DataSetIdentifierDeclarations": [
            {
                "DataSetArn": f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:dataset/ventas-comerciales-dev",
                "Identifier": "VentasComerciales",
            }
        ],
        "Sheets": [
            {
                "SheetId": "f4b7de62-f81d-48fa-b411-64faace12957",
                "Name": "Pulso de Facturación",
                "ContentType": "INTERACTIVE",
                "Visuals": [
                    kpi(
                        "kpi-facturacion-total",
                        "Facturación total",
                        numeric_measure("facturacion_total_linea", "kpi-total-value"),
                    ),
                    kpi(
                        "kpi-ventas-sin-iva",
                        "Ventas sin IVA",
                        numeric_measure("ventas_sin_iva_linea", "kpi-neto-value"),
                    ),
                    kpi(
                        "kpi-facturas",
                        "Facturas emitidas",
                        count_distinct_measure("factura_id", "kpi-facturas-value"),
                    ),
                    kpi(
                        "kpi-unidades",
                        "Unidades vendidas",
                        numeric_measure("unidades_vendidas", "kpi-unidades-value"),
                    ),
                    line_chart(
                        "linea-tendencia-mensual",
                        "Tendencia mensual de facturación",
                        date_dimension("fecha", "tendencia-fecha"),
                        numeric_measure("facturacion_total_linea", "tendencia-total"),
                    ),
                    bar_chart(
                        "barras-region",
                        "Regiones líderes por facturación",
                        categorical_dimension("region", "region-category"),
                        numeric_measure("facturacion_total_linea", "region-total"),
                    ),
                    bar_chart(
                        "barras-categoria",
                        "Categorías líderes por ventas sin IVA",
                        categorical_dimension("categoria", "categoria-category"),
                        numeric_measure("ventas_sin_iva_linea", "categoria-neto"),
                    ),
                    bar_chart(
                        "barras-producto",
                        "Productos líderes por facturación",
                        categorical_dimension("producto", "producto-category"),
                        numeric_measure("facturacion_total_linea", "producto-total"),
                    ),
                ],
                "Layouts": [
                    {
                        "Configuration": {
                            "GridLayout": {
                                "Elements": [
                                    layout("kpi-facturacion-total", 0, 0, 9, 6),
                                    layout("kpi-ventas-sin-iva", 9, 0, 9, 6),
                                    layout("kpi-facturas", 18, 0, 9, 6),
                                    layout("kpi-unidades", 27, 0, 9, 6),
                                    layout("linea-tendencia-mensual", 0, 6, 18, 12),
                                    layout("barras-region", 18, 6, 18, 12),
                                    layout("barras-categoria", 0, 18, 18, 12),
                                    layout("barras-producto", 18, 18, 18, 12),
                                ],
                                "CanvasSizeOptions": {
                                    "ScreenCanvasSizeOptions": {
                                        "ResizeOption": "RESPONSIVE",
                                    }
                                },
                            }
                        }
                    }
                ],
            }
        ],
        "CalculatedFields": [],
        "ParameterDeclarations": [],
        "FilterGroups": [
            {
                "FilterGroupId": "dashboard-moneda-gtq",
                "Filters": [
                    {
                        "CategoryFilter": {
                            "FilterId": "filtro-moneda-gtq",
                            "Column": field_reference("codigo_moneda"),
                            "Configuration": {
                                "FilterListConfiguration": {
                                    "MatchOperator": "EQUALS",
                                    "CategoryValues": ["GTQ"],
                                    "NullOption": "NON_NULLS_ONLY",
                                }
                            },
                        }
                    }
                ],
                "ScopeConfiguration": {
                    "SelectedSheets": {
                        "SheetVisualScopingConfigurations": [
                            {
                                "SheetId": "f4b7de62-f81d-48fa-b411-64faace12957",
                                "Scope": "ALL_VISUALS",
                            }
                        ]
                    }
                },
                "Status": "ENABLED",
                "CrossDataset": "SINGLE_DATASET",
            }
        ],
        "AnalysisDefaults": {
            "DefaultNewSheetConfiguration": {
                "InteractiveLayoutConfiguration": {
                    "Grid": {
                        "CanvasSizeOptions": {
                            "ScreenCanvasSizeOptions": {
                                "ResizeOption": "RESPONSIVE",
                            }
                        }
                    }
                },
                "SheetContentType": "INTERACTIVE",
            }
        },
        "Options": {
            # Igual que el Topic, el agente y el modelo SQL: semana de lunes a domingo.
            "WeekStart": "MONDAY",
            "QBusinessInsightsStatus": "DISABLED",
            "ExcludedDataSetArns": [],
            "CustomActionDefaults": {"highlightOperation": {"Trigger": "DATA_POINT_CLICK"}},
        },
        "QueryExecutionOptions": {"QueryExecutionMode": "AUTO"},
    }


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    current = aws_json(
        "quicksight",
        "describe-analysis-definition",
        "--aws-account-id",
        ACCOUNT_ID,
        "--analysis-id",
        ANALYSIS_ID,
    )
    # Un respaldo por ejecución: sobrescribirlo perdería la versión anterior a
    # la primera reconstrucción.
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    backup = OUTPUT_DIR / f"analysis-definition-before-rebuild-{stamp}.json"
    backup.write_text(json.dumps(current.get("Definition", {}), indent=2), encoding="utf-8")
    print(f"respaldo: {backup}")

    request = {
        "AwsAccountId": ACCOUNT_ID,
        "AnalysisId": ANALYSIS_ID,
        "Name": ANALYSIS_NAME,
        "Definition": dashboard_definition(),
    }
    (OUTPUT_DIR / "update-analysis.json").write_text(json.dumps(request, indent=2), encoding="utf-8")
    print(OUTPUT_DIR / "update-analysis.json")


if __name__ == "__main__":
    main()
