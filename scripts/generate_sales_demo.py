#!/usr/bin/env python3
"""Generate deterministic, synthetic Guatemalan electronic-invoice demo data.

Outputs:
- data/raw/facturas_demo.jsonl: source-like nested invoice documents.
- data/curated/ventas_documentos_demo.csv: one record per invoice.
- data/curated/ventas_lineas_demo.csv: one record per invoice item, ready for Athena.

No external dependencies are required.
"""

from __future__ import annotations

import csv
import json
import random
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW_PATH = ROOT / "data/raw/facturas_demo.jsonl"
DOCUMENTS_PATH = ROOT / "data/curated/ventas_documentos_demo.csv"
LINES_PATH = ROOT / "data/curated/ventas_lineas_demo.csv"
RANDOM = random.Random(20260825)
GT_OFFSET = timezone(timedelta(hours=-6))
SUPPORTED_CURRENCIES = {"GTQ", "USD"}
GTQ_PER_USD = 7.7

PRODUCTS = [
    ("PROD-001", "Café en grano 500 g", "Alimentos", 68.00),
    ("PROD-002", "Café molido 500 g", "Alimentos", 62.00),
    ("PROD-003", "Té premium caja 25 unidades", "Alimentos", 45.00),
    ("PROD-004", "Termo corporativo 500 ml", "Accesorios", 95.00),
    ("PROD-005", "Taza cerámica corporativa", "Accesorios", 55.00),
    ("PROD-006", "Servicio de entrega local", "Servicios", 35.00),
    ("PROD-007", "Servicio de entrega departamental", "Servicios", 65.00),
    ("PROD-008", "Kit de bienvenida empresarial", "Corporativo", 180.00),
    ("PROD-009", "Suscripción mensual de café", "Suscripciones", 240.00),
    ("PROD-010", "Café descafeinado 500 g", "Alimentos", 70.00),
    ("PROD-011", "Galletas artesanales 12 unidades", "Alimentos", 42.00),
    ("PROD-012", "Caja regalo premium", "Corporativo", 320.00),
]

CUSTOMERS = [
    ("CF", "Consumidor Final"),
    ("4857291", "Comercial La Estrella, S.A."),
    ("6283947", "Distribuidora del Pacífico, S.A."),
    ("7812456", "Servicios Integrales Maya, S.A."),
    ("9037812", "Grupo Empresarial Centroamericano, S.A."),
    ("3561894", "Farmacias Vida, S.A."),
    ("5172948", "Restaurantes El Buen Sabor, S.A."),
    ("7492631", "Tecnología y Más, S.A."),
    ("8146293", "Hotel Vista Real, S.A."),
    ("4627185", "Supermercados del Valle, S.A."),
    ("5973814", "Constructora Horizonte, S.A."),
    ("7264519", "Transportes del Sur, S.A."),
]

BRANCHES = [
    ("1", "Sucursal Central", "Guatemala", "Guatemala", "Canal tienda"),
    ("2", "Sucursal Quetzaltenango", "Quetzaltenango", "Quetzaltenango", "Canal tienda"),
    ("3", "Sucursal Escuintla", "Escuintla", "Escuintla", "Canal tienda"),
    ("4", "Canal corporativo", "Guatemala", "Guatemala", "Canal corporativo"),
]


def money(value: float) -> float:
    return round(value + 1e-9, 2)


def weighted_branch() -> tuple[str, str, str, str, str]:
    return RANDOM.choices(BRANCHES, weights=[42, 22, 16, 20], k=1)[0]


def weighted_product() -> tuple[str, str, str, float]:
    return RANDOM.choices(
        PRODUCTS,
        weights=[16, 14, 8, 6, 7, 8, 6, 4, 7, 6, 7, 4],
        k=1,
    )[0]


def make_item(line_number: int, currency: str = "GTQ") -> tuple[dict, dict]:
    code, description, category, base_price = weighted_product()
    quantity = RANDOM.randint(1, 8)
    currency_base_price = base_price if currency == "GTQ" else base_price / GTQ_PER_USD
    price = money(currency_base_price * RANDOM.uniform(0.94, 1.08))
    amount = money(quantity * price)
    taxable_amount = money(amount / 1.12)
    vat = money(amount - taxable_amount)
    item = {
        "linea": line_number,
        "bien_o_servicio": "S" if category == "Servicios" else "B",
        "codigo_producto": code,
        "descripcion": description,
        "cantidad": quantity,
        "precio_unitario": price,
        "monto": amount,
        "impuestos": [
            {
                "nombre_corto": "IVA",
                "monto_gravable": taxable_amount,
                "monto_impuesto": vat,
            }
        ],
    }
    enriched = {
        "linea": line_number,
        "codigo_producto": code,
        "producto": description,
        "categoria": category,
        "cantidad": quantity,
        "precio_unitario": price,
        "monto_linea": amount,
        "monto_gravable": taxable_amount,
        "iva": vat,
    }
    return item, enriched


def create_invoice(
    number: int,
    issue_date: date,
    currency: str = "GTQ",
    cancel_rate: float = 0.025,
    doc_prefix: str = "GT-DEMO",
) -> tuple[dict, list[dict], dict]:
    """Create one invoice, preserving the legacy GTQ/cancellation defaults."""
    currency = currency.upper()
    if currency not in SUPPORTED_CURRENCIES:
        raise ValueError(f"Unsupported currency: {currency}")
    if not 0 <= cancel_rate <= 1:
        raise ValueError("cancel_rate must be between 0 and 1")

    branch_code, branch_name, department, municipality, channel = weighted_branch()
    nit, customer_name = RANDOM.choices(CUSTOMERS, weights=[20] + [8] * 11, k=1)[0]
    issued_at = datetime(
        issue_date.year,
        issue_date.month,
        issue_date.day,
        RANDOM.randint(8, 18),
        RANDOM.randint(0, 59),
        tzinfo=GT_OFFSET,
    )
    item_count = RANDOM.choices([1, 2, 3, 4], weights=[25, 42, 24, 9], k=1)[0]
    raw_items, enriched_items = [], []
    for line in range(1, item_count + 1):
        raw_item, enriched_item = make_item(line, currency)
        raw_items.append(raw_item)
        enriched_items.append(enriched_item)

    total = money(sum(item["monto"] for item in raw_items))
    total_taxable = money(sum(item["impuestos"][0]["monto_gravable"] for item in raw_items))
    total_vat = money(sum(item["impuestos"][0]["monto_impuesto"] for item in raw_items))
    state = "anulado" if RANDOM.random() < cancel_rate else "emitido"
    document_id = f"{doc_prefix}-{number:06d}"
    series = f"{chr(65 + ((number - 1) // 300))}{1 + ((number - 1) // 100) % 3}"

    invoice = {
        "doc_id": document_id,
        "country": "gt",
        "doc_type": "FACT",
        "fecha_emision": issued_at.isoformat(),
        "anio": issue_date.year,
        "mes": issue_date.month,
        "dia": issue_date.day,
        "estado": state,
        "codigo_moneda": currency,
        "nit_emisor": "12345678",
        "nit_receptor": nit,
        "gran_total": total,
        "serie": series,
        "establecimiento_codigo": branch_code,
        "establecimiento_nombre": branch_name,
        "items": raw_items,
        "clase_documento": "FACTURA",
        "dte_id": f"{doc_prefix}-DTE-{number:08d}",
        "datos_emision_id": f"{doc_prefix}-EMI-{number:08d}",
        "emision_ubicacion_temporal": "Guatemala",
        "exp": "N/A",
        "espectaculo": "N/A",
        "numero_acceso": number,
        "tipo_personeria": 1,
        "servicio": "N/A",
        "dispositivo": "WEB",
        "litoral": 0,
        "terminal": int(branch_code),
        "placa": "N/A",
        "licencia_transporte": "N/A",
        "numerodeviaje": "N/A",
        "direcciondeentrega": "Ciudad de Guatemala",
        "origendespacho": 1,
        "destinodespacho": 1,
        "procedencia": 1,
        "id_transportista": "N/A",
        "tipo_documento_identificacion": "NIT",
        "nombrepiloto": "N/A",
        "nombre_emisor": "Comercializadora Demo Guatemala, S.A.",
        "correo_emisor": "facturacion@demo.gt",
        "afiliacion_iva": "GEN",
        "clasificacion_emisor": 1,
        "direccion": "Avenida Reforma 10-25, Zona 10",
        "codigo_postal": 1010,
        "municipio": municipality,
        "departamento": department,
        "pais": "GT",
        "tipo_especial": "N/A",
        "nombre_receptor": customer_name,
        "correo_receptor": "compras@cliente.demo.gt",
        "destinodela_venta": "Nacional",
        "nit_certificador": "99999999",
        "nombre_certificador": "Certificador Demo, S.A.",
        "numero": number,
        "fecha_hora_certificacion": issued_at.date().isoformat(),
    }
    document_row = {
        "doc_id": document_id,
        "fecha_emision": issued_at.isoformat(),
        "fecha": issue_date.isoformat(),
        "anio": issue_date.year,
        "mes": issue_date.month,
        "estado": state,
        "codigo_moneda": currency,
        "serie": series,
        "nit_receptor": nit,
        "cliente": customer_name,
        "establecimiento_codigo": branch_code,
        "establecimiento": branch_name,
        "departamento": department,
        "municipio": municipality,
        "canal": channel,
        "gran_total": total,
        "monto_gravable": total_taxable,
        "iva": total_vat,
    }
    for enriched in enriched_items:
        enriched.update(document_row)
    return invoice, enriched_items, document_row


def main() -> None:
    RAW_PATH.parent.mkdir(parents=True, exist_ok=True)
    DOCUMENTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    start_date = date(2025, 9, 1)
    end_date = date(2026, 8, 31)
    invoice_count = 720
    invoices: list[dict] = []
    all_lines: list[dict] = []
    documents: list[dict] = []

    for number in range(1, invoice_count + 1):
        offset = RANDOM.randint(0, (end_date - start_date).days)
        invoice, lines, document = create_invoice(number, start_date + timedelta(days=offset))
        invoices.append(invoice)
        all_lines.extend(lines)
        documents.append(document)

    invoices.sort(key=lambda row: row["fecha_emision"])
    documents.sort(key=lambda row: row["fecha_emision"])
    all_lines.sort(key=lambda row: (row["fecha_emision"], row["doc_id"], row["linea"]))

    with RAW_PATH.open("w", encoding="utf-8") as output:
        for invoice in invoices:
            output.write(json.dumps(invoice, ensure_ascii=False) + "\n")

    document_fields = list(documents[0].keys())
    with DOCUMENTS_PATH.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=document_fields)
        writer.writeheader()
        writer.writerows(documents)

    line_fields = [
        "doc_id",
        "fecha_emision",
        "fecha",
        "anio",
        "mes",
        "estado",
        "codigo_moneda",
        "serie",
        "nit_receptor",
        "cliente",
        "establecimiento_codigo",
        "establecimiento",
        "departamento",
        "municipio",
        "canal",
        "gran_total",
        "linea",
        "codigo_producto",
        "producto",
        "categoria",
        "cantidad",
        "precio_unitario",
        "monto_linea",
        "monto_gravable",
        "iva",
    ]
    with LINES_PATH.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=line_fields)
        writer.writeheader()
        writer.writerows(all_lines)

    active_documents = [row for row in documents if row["estado"] == "emitido"]
    print(
        f"Generated {len(invoices)} invoices, {len(all_lines)} sales lines and {len(active_documents)} emitted invoices."
    )
    print(f"Raw JSONL: {RAW_PATH.relative_to(ROOT)}")
    print(f"Curated documents CSV: {DOCUMENTS_PATH.relative_to(ROOT)}")
    print(f"Curated sales lines CSV: {LINES_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
