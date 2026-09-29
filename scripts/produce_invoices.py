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
import subprocess
import sys
import tempfile
import time
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_sales_demo as factory  # noqa: E402

BUCKET = "dashboards-dinamicos-dev-503561412084"
RAW_PREFIX = "raw/dte/country=gt"
GLUE_JOB = "dashboards-dinamicos-flatten-invoices-dev"
PROFILE = "dashboards-dev-infile"
REGION = "us-east-1"

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


def create_numbered_invoice(number: int, issue_date: date) -> dict:
    cycle_number = (number - 1) % SERIES_CYCLE + 1
    invoice, _lines, _document = factory.create_invoice(cycle_number, issue_date)
    if cycle_number != number:
        invoice.update(
            {
                "doc_id": f"GT-DEMO-{number:06d}",
                "dte_id": f"DTE-{number:08d}",
                "datos_emision_id": f"EMI-{number:08d}",
                "numero_acceso": number,
                "numero": number,
            }
        )
    return invoice


def build_batch(start_number: int, size: int, span_days: int, rng: random.Random) -> list[dict]:
    """Generate one batch of invoice documents spread over the requested window."""
    today = date.today()
    start_date = today - timedelta(days=span_days)
    invoices = []

    for offset in range(size):
        issue_date = start_date + timedelta(days=rng.randint(0, span_days))
        invoices.append(create_numbered_invoice(start_number + offset, issue_date))

    invoices.sort(key=lambda row: row["fecha_emision"])
    return invoices


def upload_batch(invoices: list[dict], batch_id: str, ingest_date: str) -> str:
    key = f"{RAW_PREFIX}/ingest_date={ingest_date}/{batch_id}.jsonl"

    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8") as handle:
        local_path = handle.name
        for invoice in invoices:
            handle.write(json.dumps(invoice, ensure_ascii=False) + "\n")

    try:
        aws("s3", "cp", local_path, f"s3://{BUCKET}/{key}", "--only-show-errors")
    finally:
        Path(local_path).unlink(missing_ok=True)
    return key


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


def main() -> None:
    global BUCKET, GLUE_JOB, PROFILE, REGION

    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--count", type=int, default=10_000, help="Total de facturas a generar")
    parser.add_argument("--batch-size", type=int, default=500, help="Facturas por archivo")
    parser.add_argument("--span-days", type=int, default=540, help="Ventana de fechas hacia atrás")
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

    BUCKET, GLUE_JOB, PROFILE, REGION = args.bucket, args.glue_job, args.profile, args.region

    rng = random.Random(args.seed) if args.seed is not None else random.Random()
    factory.RANDOM = rng

    if args.start_number is not None:
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
    batches = (args.count + args.batch_size - 1) // args.batch_size
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")

    print(
        f"Generando {args.count:,} facturas en {batches} lote(s) de hasta {args.batch_size}\n"
        f"Numeración desde {start_number} · ventana de {args.span_days} días"
    )
    if not args.dry_run:
        print(f"Destino s3://{BUCKET}/{RAW_PREFIX}/ · perfil {PROFILE} · región {REGION}")

    produced = 0
    for index in range(batches):
        size = min(args.batch_size, args.count - produced)
        invoices = build_batch(start_number + produced, size, args.span_days, rng)
        lines = sum(len(invoice["items"]) for invoice in invoices)

        if args.dry_run:
            print(f"  lote {index + 1}/{batches}: {size} facturas, {lines} líneas (dry-run)")
        else:
            key = upload_batch(invoices, f"batch-{stamp}-{index + 1:04d}", ingest_date)
            print(f"  lote {index + 1}/{batches}: {size} facturas, {lines} líneas -> {key}")

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
