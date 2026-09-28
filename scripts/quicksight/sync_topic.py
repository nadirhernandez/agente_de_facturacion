#!/usr/bin/env python3
"""Create or update the QuickSight Topic from code, including both datasets.

Answers the "can this be IaC?" question: yes. The Terraform AWS provider has no
aws_quicksight_topic resource, but the QuickSight API does support topics, so
this script owns the semantic layer as version-controlled configuration.

Caveat: a Topic created from the Quick console with the new multi-dataset
experience is not returned by ListTopics and cannot be managed here. To have the
semantic layer fully as code, use this topic and retire the console one.

Usage:
    python3 scripts/quicksight/sync_topic.py           # create or update
    python3 scripts/quicksight/sync_topic.py --show    # print the definition
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

ACCOUNT_ID = "503561412084"
REGION = "us-east-1"
PROFILE = "dashboards-dev-infile"
TOPIC_ID = "ventas-inteligentes"
TOPIC_NAME = "Ventas Inteligentes"

SALES_DATASET_ARN = f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:dataset/ventas-comerciales-dev"
PERIOD_DATASET_ARN = f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:dataset/ventas-comparativo-dev"

# NUMBER with a "Q" prefix instead of CURRENCY: CURRENCY without a symbol makes
# Quick render dollars. Every amount in the model is GTQ.
CURRENCY = {
    "DisplayFormat": "NUMBER",
    "DisplayFormatOptions": {
        "Prefix": "Q",
        "DecimalSeparator": "DOT",
        "GroupingSeparator": ",",
        "UseGrouping": True,
        "FractionDigits": 2,
    },
}

PERCENT = {
    "DisplayFormat": "PERCENT",
    "DisplayFormatOptions": {"Suffix": "%", "FractionDigits": 1},
}

CUSTOM_INSTRUCTIONS = """
Responde siempre en español y muestra los montos en quetzales (Q) con dos decimales. Todos los montos están en quetzales guatemaltecos (GTQ): nunca uses el símbolo $ ni hables de dólares, tampoco en títulos, ejes ni etiquetas de los visuales. Indica el período, los filtros y la métrica usada. Si no hay datos suficientes, dilo y no inventes resultados.

Usa únicamente documentos emitidos; los anulados ya están excluidos.

Elige el dataset según la pregunta:
- Facturación por día, semana, mes o año, y cualquier comparativo entre períodos: usa "Ventas por periodo".
- Desglose por región, establecimiento, canal, cliente, categoría o producto: usa "Ventas comerciales".
- No sumes métricas de ambos datasets en un mismo resultado: tienen granularidad distinta.

En "Ventas por periodo" filtra por granularidad: dia, semana, mes o anio. La columna periodo es la fecha de inicio del período.

La semana va de lunes a domingo. Todas las fechas y horas están en hora de Guatemala (UTC-06:00): una factura emitida a las 19:30 pertenece a ese día.

El comparativo por defecto es contra el período anterior inmediato, no contra el año anterior. Usa las columnas *_anterior y variacion_*_pct en lugar de recalcular.

Excluye los períodos con es_periodo_completo = false de los comparativos y adviértelo si el usuario pregunta por el período en curso: un período a medias siempre parece una caída.

Definiciones: "facturación", "ingresos" y "ventas brutas" son facturación total con IVA; "ventas sin IVA" y "venta neta" son el monto gravable; "facturas" es el conteo de facturas distintas; "ticket promedio" es facturación entre facturas.

No existen costos, margen, inventario ni metas. No calcules margen, utilidad ni rentabilidad.

Para series de tiempo usa líneas; para comparar categorías usa barras ordenadas de mayor a menor; para un solo número usa KPI. Al mostrar una variación incluye el valor de ambos períodos, no solo el porcentaje.
""".strip()


def dimension(name: str, friendly: str, synonyms: list[str] | None = None, **extra) -> dict:
    column = {
        "ColumnName": name,
        "ColumnFriendlyName": friendly,
        "ColumnDataRole": "DIMENSION",
        "IsIncludedInTopic": True,
    }
    if synonyms:
        column["ColumnSynonyms"] = synonyms
    column.update(extra)
    return column


def measure(name: str, friendly: str, synonyms: list[str] | None = None, **extra) -> dict:
    column = {
        "ColumnName": name,
        "ColumnFriendlyName": friendly,
        "ColumnDataRole": "MEASURE",
        "Aggregation": "SUM",
        "IsIncludedInTopic": True,
        "DefaultFormatting": CURRENCY,
    }
    if synonyms:
        column["ColumnSynonyms"] = synonyms
    column.update(extra)
    return column


def build_topic() -> dict:
    sales_columns = [
        dimension("fecha", "Fecha", ["día"], TimeGranularity="DAY"),
        dimension("region", "Región", ["departamento", "zona", "territorio"]),
        dimension("municipio", "Municipio"),
        dimension("establecimiento", "Establecimiento", ["sucursal", "tienda"]),
        dimension("canal", "Canal"),
        dimension("cliente", "Cliente", ["comprador", "cuenta"]),
        dimension("nit_receptor", "NIT del cliente"),
        dimension("categoria", "Categoría", ["línea de producto"]),
        dimension("producto", "Producto"),
        dimension("codigo_producto", "Código de producto"),
        dimension(
            "factura_id",
            "Factura",
            ["documento", "dte"],
            AllowedAggregations=["DISTINCT_COUNT"],
        ),
        dimension("anio", "Año", NotAllowedAggregations=["SUM", "AVERAGE"]),
        # "mes" is numeric, so it already sorts chronologically. ComparativeOrder
        # only accepts GREATER/LESSER_IS_BETTER or an explicit SPECIFIED list.
        dimension("mes", "Mes", NotAllowedAggregations=["SUM", "AVERAGE"]),
        measure(
            "facturacion_total_linea",
            "Facturación total",
            ["facturación", "ingresos", "ventas brutas"],
            ColumnDescription="Monto facturado con IVA incluido",
        ),
        measure(
            "ventas_sin_iva_linea",
            "Ventas sin IVA",
            ["venta neta", "ventas netas", "monto gravable"],
        ),
        measure("iva_linea", "IVA", ["impuesto"]),
        measure(
            "unidades_vendidas",
            "Unidades vendidas",
            ["unidades", "cantidad"],
            DefaultFormatting=None,
        ),
    ]

    period_columns = [
        dimension(
            "granularidad",
            "Granularidad",
            ["nivel", "periodicidad"],
            ColumnDescription="dia, semana, mes o anio",
        ),
        dimension("periodo", "Período", ["inicio del período"], TimeGranularity="DAY"),
        dimension("fin_periodo", "Fin del período", TimeGranularity="DAY"),
        dimension(
            "es_periodo_completo",
            "Período completo",
            ["cerrado", "completo"],
            ColumnDescription="false indica un período en curso; excluirlo de comparativos",
        ),
        dimension("anio", "Año", NotAllowedAggregations=["SUM", "AVERAGE"]),
        dimension("mes", "Mes", NotAllowedAggregations=["SUM", "AVERAGE"]),
        measure("facturacion_total", "Facturación del período", ["facturación", "ingresos"]),
        measure("ventas_sin_iva", "Ventas sin IVA del período", ["venta neta"]),
        measure("iva", "IVA del período"),
        measure("facturas", "Facturas emitidas", ["documentos", "cantidad de facturas"], DefaultFormatting=None),
        measure("unidades", "Unidades del período", DefaultFormatting=None),
        measure("facturacion_total_anterior", "Facturación del período anterior"),
        measure("ventas_sin_iva_anterior", "Ventas sin IVA del período anterior"),
        measure("facturas_anterior", "Facturas del período anterior", DefaultFormatting=None),
        measure("unidades_anterior", "Unidades del período anterior", DefaultFormatting=None),
        # A percentage must never be summed, and averaging it unweighted lies.
        measure(
            "variacion_facturacion_pct",
            "Variación de facturación",
            ["variación", "crecimiento", "caída"],
            Aggregation="AVERAGE",
            AllowedAggregations=["AVERAGE", "MIN", "MAX"],
            NotAllowedAggregations=["SUM"],
            NonAdditive=True,
            DefaultFormatting=PERCENT,
        ),
        measure(
            "variacion_facturas_pct",
            "Variación de facturas",
            Aggregation="AVERAGE",
            AllowedAggregations=["AVERAGE", "MIN", "MAX"],
            NotAllowedAggregations=["SUM"],
            NonAdditive=True,
            DefaultFormatting=PERCENT,
        ),
    ]

    def clean(columns: list[dict]) -> list[dict]:
        return [{k: v for k, v in column.items() if v is not None} for column in columns]

    return {
        "AwsAccountId": ACCOUNT_ID,
        "TopicId": TOPIC_ID,
        "CustomInstructions": {"CustomInstructionsString": CUSTOM_INSTRUCTIONS},
        "Topic": {
            "Name": TOPIC_NAME,
            "Description": "Facturación y ventas de Guatemala. Documentos emitidos únicamente.",
            "UserExperienceVersion": "NEW_READER_EXPERIENCE",
            "DataSets": [
                {
                    "DatasetArn": SALES_DATASET_ARN,
                    "DatasetName": "Ventas comerciales",
                    "DatasetDescription": "Una fila por línea de factura emitida.",
                    "DataAggregation": {
                        "DatasetRowDateGranularity": "DAY",
                        "DefaultDateColumnName": "fecha",
                    },
                    "Columns": clean(sales_columns),
                },
                {
                    "DatasetArn": PERIOD_DATASET_ARN,
                    "DatasetName": "Ventas por periodo",
                    "DatasetDescription": (
                        "Una fila por período (día, semana, mes, año) con el período anterior "
                        "y la variación ya calculados. Semana de lunes a domingo."
                    ),
                    "DataAggregation": {
                        "DatasetRowDateGranularity": "DAY",
                        "DefaultDateColumnName": "periodo",
                    },
                    "Columns": clean(period_columns),
                },
            ],
        },
    }


def aws(*arguments: str, quiet: bool = False) -> str:
    result = subprocess.run(
        ["aws", *arguments, "--profile", PROFILE, "--region", REGION],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        if not quiet:
            print(result.stderr.strip())
        raise subprocess.CalledProcessError(
            result.returncode, result.args, output=result.stdout, stderr=result.stderr
        )
    return (result.stdout or "").strip()


def topic_exists() -> bool:
    """False solo si QuickSight dice que el topic no existe.

    Cualquier otro error (credenciales vencidas, permisos, región equivocada) se
    propaga: interpretarlo como "no existe" llevaría a un create-topic a ciegas.
    """
    try:
        aws("quicksight", "describe-topic", "--aws-account-id", ACCOUNT_ID, "--topic-id", TOPIC_ID,
            quiet=True)
        return True
    except subprocess.CalledProcessError as error:
        if "ResourceNotFoundException" in (error.stderr or ""):
            return False
        print((error.stderr or "").strip() or f"describe-topic falló con código {error.returncode}")
        raise


def configure(args: argparse.Namespace) -> None:
    global ACCOUNT_ID, REGION, PROFILE, TOPIC_ID, SALES_DATASET_ARN, PERIOD_DATASET_ARN
    ACCOUNT_ID, REGION, PROFILE, TOPIC_ID = args.account_id, args.region, args.profile, args.topic_id
    SALES_DATASET_ARN = f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:dataset/{args.sales_dataset_id}"
    PERIOD_DATASET_ARN = f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:dataset/{args.period_dataset_id}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--show", action="store_true", help="Solo imprimir la definición")
    parser.add_argument("--account-id", default=ACCOUNT_ID, help="Cuenta de QuickSight")
    parser.add_argument("--region", default=REGION, help="Región de QuickSight")
    parser.add_argument("--profile", default=PROFILE, help="Perfil de AWS CLI")
    parser.add_argument("--topic-id", default=TOPIC_ID, help="Id del topic")
    parser.add_argument("--sales-dataset-id", default="ventas-comerciales-dev",
                        help="Dataset de ventas comerciales")
    parser.add_argument("--period-dataset-id", default="ventas-comparativo-dev",
                        help="Dataset de ventas por periodo")
    args = parser.parse_args()
    configure(args)

    payload = build_topic()

    if args.show:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return

    handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    path = handle.name
    try:
        with handle:
            json.dump(payload, handle, ensure_ascii=False)
        sync(payload, path)
    finally:
        Path(path).unlink(missing_ok=True)
    print("Listo. Revisa el selector de datos en Amazon Quick chat.")


def sync(payload: dict, path: str) -> None:
    if topic_exists():
        print(f"Actualizando topic {TOPIC_ID}…")
        # UpdateTopic takes the definition and the custom instructions together.
        print(aws("quicksight", "update-topic", "--cli-input-json", f"file://{path}",
                  "--query", "TopicId", "--output", "text"))
        current = json.loads(aws("quicksight", "describe-topic", "--aws-account-id", ACCOUNT_ID,
                                 "--topic-id", TOPIC_ID, "--output", "json"))
        applied = (current.get("CustomInstructions") or {}).get("CustomInstructionsString", "")
        if applied.strip() == CUSTOM_INSTRUCTIONS:
            print("instrucciones actualizadas")
        else:
            print("aviso: las instrucciones del topic no coinciden con las del código; revísalas en la consola")
    else:
        print(f"Creando topic {TOPIC_ID}…")
        print(aws("quicksight", "create-topic", "--cli-input-json", f"file://{path}",
                  "--query", "TopicId", "--output", "text"))


if __name__ == "__main__":
    main()
