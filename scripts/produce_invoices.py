#!/usr/bin/env python3
"""Produce synthetic DTE invoices and upload them to the raw zone in batches.

Designed for bulk loads: writes many small files instead of one huge object, so
Spark parallelises the read and a failed batch only affects its own file.

Examples
--------
    # 10,000 invoices in batches of 500, upload and then run the Glue job
    python3 scripts/produce_invoices.py --count 10000 --batch-size 500 --process

    # Generate locally without touching AWS
    python3 scripts/produce_invoices.py --count 1000 --dry-run

Destino configurable (por defecto, el piloto): --bucket/VI_BUCKET,
--glue-job/VI_GLUE_JOB, --profile/AWS_PROFILE, --region/AWS_REGION.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_sales_demo as factory  # noqa: E402

BUCKET = "dashboards-dinamicos-dev-503561412084"
RAW_PREFIX = "raw/dte/country=gt"
GLUE_JOB = "dashboards-dinamicos-flatten-invoices-dev"
PROFILE = "dashboards-dev-infile"
REGION = "us-east-1"
SAFE_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

GLUE_TERMINAL_STATES = {"SUCCEEDED", "FAILED", "STOPPED", "TIMEOUT", "ERROR", "EXPIRED"}
GLUE_ACTIVE_STATES = ["STARTING", "RUNNING", "STOPPING", "WAITING"]
GLUE_POLL_SECONDS = 20
GLUE_WAIT_TIMEOUT_SECONDS = 60 * 60

# Numeración automática: segundos UTC desde NUMBERING_EPOCH por RUN_CAPACITY.
# Cada ejecución reserva el bloque [segundo * RUN_CAPACITY, +RUN_CAPACITY), así que
# dos ejecuciones no se pisan mientras (a) cada una genere como máximo
# RUN_CAPACITY facturas, (b) no arranquen dos en el mismo segundo y (c) el reloj
# no retroceda. Los números resultantes (~10^11) quedan muy por encima de los que
# ya existen en el piloto (1 + 1000 * archivos) y del rango 900001-900200 que
# reserva verify_tenant.sh.
NUMBERING_EPOCH = datetime(2025, 1, 1, tzinfo=UTC)
RUN_CAPACITY = 10_000

# create_invoice deriva la serie con chr(65 + (numero - 1) // 300): pasado 7800
# sale de A-Z y con números grandes ni siquiera es un carácter válido. Por eso la
# serie se calcula sobre un número "de ciclo" y luego se ponen los campos que sí
# llevan el número real. Para números <= SERIES_CYCLE el resultado es idéntico
# al de llamar a create_invoice directamente.
SERIES_CYCLE = 26 * 300


def aws(*arguments: str, capture: bool = True) -> str:
    result = subprocess.run(
        ["aws", *arguments, "--profile", PROFILE, "--region", REGION],
        check=True,
        capture_output=capture,
        text=True,
    )
    return (result.stdout or "").strip()


def next_invoice_number() -> int:
    """Primer número de un bloque que no choca con ejecuciones anteriores."""
    elapsed = int((datetime.now(UTC) - NUMBERING_EPOCH).total_seconds())
    return max(1, elapsed) * RUN_CAPACITY + 1


def create_numbered_invoice(
    number: int,
    issue_date: date,
    currency: str,
    cancel_rate: float,
    doc_prefix: str,
) -> dict:
    cycle_number = (number - 1) % SERIES_CYCLE + 1
    invoice, _lines, _document = factory.create_invoice(
        cycle_number,
        issue_date,
        currency=currency,
        cancel_rate=cancel_rate,
        doc_prefix=doc_prefix,
    )
    if cycle_number != number:
        invoice.update(
            {
                "doc_id": f"{doc_prefix}-{number:06d}",
                "dte_id": f"{doc_prefix}-DTE-{number:08d}",
                "datos_emision_id": f"{doc_prefix}-EMI-{number:08d}",
                "numero_acceso": number,
                "numero": number,
            }
        )
    return invoice


def build_batch(
    start_number: int,
    size: int,
    start_date: date,
    end_date: date,
    global_offset: int,
    total_count: int,
    currency: str,
    cancel_rate: float,
    doc_prefix: str,
) -> list[dict]:
    """Generate a date-stratified batch using positions from the full load."""
    day_count = (end_date - start_date).days + 1
    invoices = []

    for offset in range(size):
        global_index = global_offset + offset
        day_offset = global_index * day_count // total_count
        issue_date = start_date + timedelta(days=day_offset)
        invoices.append(
            create_numbered_invoice(
                start_number + offset,
                issue_date,
                currency,
                cancel_rate,
                doc_prefix,
            )
        )

    invoices.sort(key=lambda row: row["fecha_emision"])
    return invoices


def object_exists(key: str) -> bool:
    try:
        aws("s3api", "head-object", "--bucket", BUCKET, "--key", key)
    except subprocess.CalledProcessError as error:
        detail = f"{error.stdout or ''}\n{error.stderr or ''}"
        if "404" in detail or "Not Found" in detail or "NoSuchKey" in detail:
            return False
        raise
    return True


def upload_batch(invoices: list[dict], key: str) -> None:
    if object_exists(key):
        raise SystemExit(f"El objeto s3://{BUCKET}/{key} ya existe; se aborta para no sobrescribirlo")

    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8") as handle:
        local_path = handle.name
        for invoice in invoices:
            handle.write(json.dumps(invoice, ensure_ascii=False) + "\n")

    try:
        aws("s3", "cp", local_path, f"s3://{BUCKET}/{key}", "--only-show-errors")
    finally:
        Path(local_path).unlink(missing_ok=True)


def active_glue_run() -> str | None:
    states = ",".join(f"'{state}'" for state in GLUE_ACTIVE_STATES)
    output = aws(
        "glue",
        "get-job-runs",
        "--job-name",
        GLUE_JOB,
        "--max-results",
        "5",
        "--query",
        f"JobRuns[?contains([{states}], JobRunState)].Id",
        "--output",
        "text",
    )
    return output.split()[0] if output else None


def wait_for_run(run_id: str, timeout: int = GLUE_WAIT_TIMEOUT_SECONDS) -> str:
    deadline = time.monotonic() + timeout
    while True:
        time.sleep(GLUE_POLL_SECONDS)
        state = aws(
            "glue",
            "get-job-run",
            "--job-name",
            GLUE_JOB,
            "--run-id",
            run_id,
            "--query",
            "JobRun.JobRunState",
            "--output",
            "text",
        )
        print(f"  glue {run_id[-8:]}: {state}")
        if state in GLUE_TERMINAL_STATES:
            return state
        if time.monotonic() >= deadline:
            raise SystemExit(
                f"La ejecución {run_id} de {GLUE_JOB} sigue en {state} tras {timeout // 60} min. "
                "Revísala en la consola de Glue antes de volver a lanzar el job."
            )


def run_glue_job() -> None:
    """Ensure every uploaded file gets processed.

    The first upload already triggers Glue through EventBridge, and the job only
    allows one run at a time. So wait for any in-flight run, then start a final
    run that sweeps up whatever files landed while it was busy.
    """
    running = active_glue_run()
    if running:
        print(f"\nYa hay una ejecución en curso ({running[-8:]}); esperando…")
        wait_for_run(running)

    print("\nLanzando carga incremental para los archivos restantes…")
    for attempt in range(1, 6):
        try:
            run_id = aws(
                "glue",
                "start-job-run",
                "--job-name",
                GLUE_JOB,
                "--arguments",
                '{"--REPROCESS_ALL":"false"}',
                "--query",
                "JobRunId",
                "--output",
                "text",
            )
            break
        except subprocess.CalledProcessError as error:
            detail = (error.stderr or "").strip() or f"código {error.returncode}"
            print(f"  no se pudo iniciar el job: {detail}")
            print(f"  reintento {attempt}/5 en 30s")
            time.sleep(30)
    else:
        raise SystemExit("No fue posible iniciar el job de Glue")

    state = wait_for_run(run_id)
    if state != "SUCCEEDED":
        raise SystemExit(f"El job de Glue terminó en estado {state}")

    print("Job completo. SPICE se refresca automáticamente por EventBridge.")


def safe_segment(value: str) -> str:
    if not SAFE_SEGMENT.fullmatch(value):
        raise argparse.ArgumentTypeError(
            "debe iniciar con un carácter alfanumérico y contener solo letras, números, _ o - "
            "(máximo 64 caracteres)"
        )
    return value


def iso_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("debe tener formato YYYY-MM-DD") from error


def main() -> None:
    global BUCKET, GLUE_JOB, PROFILE, REGION

    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--count", type=int, default=10_000, help="Total de facturas a generar")
    parser.add_argument("--batch-size", type=int, default=500, help="Facturas por archivo")
    parser.add_argument("--span-days", type=int, default=540, help="Ventana de fechas hacia atrás")
    parser.add_argument("--start-date", type=iso_date, help="Inicio inclusivo (YYYY-MM-DD)")
    parser.add_argument("--end-date", type=iso_date, help="Fin inclusivo (YYYY-MM-DD)")
    parser.add_argument("--currency", choices=["GTQ", "USD"], default="GTQ", help="Moneda de la carga")
    parser.add_argument("--cancel-rate", type=float, default=0.025, help="Proporción anulada entre 0 y 1")
    parser.add_argument(
        "--doc-prefix", type=safe_segment, default="GT-DEMO", help="Prefijo global de documentos"
    )
    parser.add_argument("--load-id", type=safe_segment, default=None, help="Identificador único de la carga")
    parser.add_argument("--pause", type=float, default=1.0, help="Segundos entre lotes")
    parser.add_argument("--seed", type=int, default=None, help="Semilla para datos reproducibles")
    parser.add_argument("--start-number", type=int, default=None, help="Número inicial de factura")
    parser.add_argument("--dry-run", action="store_true", help="Generar sin subir a S3")
    parser.add_argument("--process", action="store_true", help="Ejecutar Glue al terminar")
    parser.add_argument("--bucket", default=os.environ.get("VI_BUCKET", BUCKET), help="Bucket de datos")
    parser.add_argument("--glue-job", default=os.environ.get("VI_GLUE_JOB", GLUE_JOB), help="Job de Glue")
    parser.add_argument("--profile", default=os.environ.get("AWS_PROFILE", PROFILE), help="Perfil de AWS CLI")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", REGION), help="Región de AWS")
    args = parser.parse_args()

    if args.count < 1 or args.batch_size < 1:
        parser.error("--count y --batch-size deben ser mayores que cero")
    if args.span_days < 0:
        parser.error("--span-days no puede ser negativo")
    if not 0 <= args.cancel_rate <= 1:
        parser.error("--cancel-rate debe estar entre 0 y 1")
    if (args.start_date is None) != (args.end_date is None):
        parser.error("--start-date y --end-date deben indicarse juntos")

    if args.start_date is not None:
        start_date, end_date = args.start_date, args.end_date
        if start_date > end_date:
            parser.error("--start-date no puede ser posterior a --end-date")
        if start_date.year != end_date.year:
            parser.error("--start-date y --end-date deben pertenecer al mismo año")
    else:
        end_date = date.today()
        start_date = end_date - timedelta(days=args.span_days)

    BUCKET, GLUE_JOB, PROFILE, REGION = args.bucket, args.glue_job, args.profile, args.region

    rng = random.Random(args.seed) if args.seed is not None else random.Random()
    factory.RANDOM = rng

    if args.start_number is not None:
        if args.start_number < 1:
            parser.error("--start-number debe ser mayor que cero")
        start_number = args.start_number
    elif args.dry_run:
        # En dry-run no se consulta nada fuera de esta máquina.
        start_number = 1
        print("dry-run sin --start-number: numeración desde 1")
    else:
        if args.count > RUN_CAPACITY:
            parser.error(
                f"la numeración automática reserva {RUN_CAPACITY:,} números por ejecución; "
                "divide la carga o indica --start-number"
            )
        start_number = next_invoice_number()

    ingest_date = date.today().isoformat()
    load_id = args.load_id or f"load-{datetime.now(UTC):%Y%m%dT%H%M%S%f}-{uuid.uuid4().hex[:8]}"
    batches = (args.count + args.batch_size - 1) // args.batch_size

    print(
        f"Generando {args.count:,} facturas en {batches} lote(s) de hasta {args.batch_size}\n"
        f"Numeración desde {start_number} · moneda {args.currency} · rango {start_date} a {end_date}\n"
        f"Tasa de anulación {args.cancel_rate:.4f} · prefijo {args.doc_prefix} · load-id {load_id}"
    )
    if not args.dry_run:
        print(f"Destino s3://{BUCKET}/{RAW_PREFIX}/ · perfil {PROFILE} · región {REGION}")

    produced = 0
    part_number = 0
    for index in range(batches):
        size = min(args.batch_size, args.count - produced)
        invoices = build_batch(
            start_number + produced,
            size,
            start_date,
            end_date,
            produced,
            args.count,
            args.currency,
            args.cancel_rate,
            args.doc_prefix,
        )
        lines = sum(len(invoice["items"]) for invoice in invoices)

        if args.dry_run:
            print(f"  lote {index + 1}/{batches}: {size} facturas, {lines} líneas (dry-run)")
        else:
            invoices_by_year: dict[int, list[dict]] = {}
            for invoice in invoices:
                invoices_by_year.setdefault(invoice["anio"], []).append(invoice)

            uploaded_keys = []
            for business_year, year_invoices in invoices_by_year.items():
                part_number += 1
                key = (
                    f"{RAW_PREFIX}/currency={args.currency.lower()}/business_year={business_year}/"
                    f"ingest_date={ingest_date}/load_id={load_id}/part-{part_number:04d}.jsonl"
                )
                upload_batch(year_invoices, key)
                uploaded_keys.append(key)
            print(
                f"  lote {index + 1}/{batches}: {size} facturas, {lines} líneas -> "
                + ", ".join(uploaded_keys)
            )

        produced += size
        if index + 1 < batches and args.pause > 0:
            time.sleep(args.pause)

    print(f"\nListo: {produced:,} facturas generadas.")

    if args.dry_run:
        return

    if args.process:
        run_glue_job()
    else:
        print(
            "El primer lote ya disparó Glue por EventBridge. Para asegurar que todos los\n"
            "archivos queden procesados, ejecuta este script con --process o lanza el job:\n"
            f"  aws glue start-job-run --job-name {GLUE_JOB} --profile {PROFILE} --region {REGION}"
        )


if __name__ == "__main__":
    main()
