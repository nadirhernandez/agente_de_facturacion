#!/usr/bin/env python3
"""Concede (o audita) a una identidad de Quick exactamente lo que necesita para
usar UN chat: su agente, su space, su topic y los datasets de ese topic. Nada más.

Es la pieza de seguridad del modelo "dos identidades compartidas":

    app-demo-sintetico  ->  --set demo   (agente/space/topic/datasets sintéticos)
    app-infile-real     ->  --set real   (agente/space/topic/datasets de INFILE)

Cada identidad recibe permisos de LECTURA (viewer), nunca de dueño. Y lo más
importante: `--audit` comprueba que la identidad NO tenga permiso sobre nada del
otro juego. Si la identidad demo pudiera leer el agente real, un visitante que
cambie el agentId en el navegador vería datos de INFILE; la frontera debe estar
en Quick, no en la app.

Uso:
    python3 scripts/quicksight/grant_chat_access.py --set demo --principal <arn>
    python3 scripts/quicksight/grant_chat_access.py --set real --principal <arn>
    python3 scripts/quicksight/grant_chat_access.py --set demo --principal <arn> --audit
    python3 scripts/quicksight/grant_chat_access.py --set demo --principal <arn> --revoke

El principal puede ser el ARN completo o el user_name (se construye el ARN).
"""

from __future__ import annotations

import argparse
import sys

import boto3
from botocore.exceptions import ClientError

ACCOUNT_ID = "503561412084"
REGION = "us-east-1"
PROFILE = "dashboards-dev-infile"

# Un "juego" = todo lo que un chat necesita leer. Mantener alineado con
# sync_topic.py / sync_agent.py y con locals.app_chat en application.tf.
SETS: dict[str, dict] = {
    "demo": {
        "agent": "ventas-demo-analista",
        "space": "ventas-demo",
        "topic": "ventas-demo",
        "datasets": ["ventas-comerciales-dev", "ventas-comparativo-dev"],
        "dashboards": ["pulso-facturacion-dev"],
    },
    "real": {
        "agent": "ventas-inteligentes-analista",
        "space": "ventas-inteligentes",
        "topic": "ventas-inteligentes",
        "datasets": ["ventas-infile-real", "ventas-comparativo-real"],
        "dashboards": ["pulso-facturacion-real"],
    },
}

# Conjuntos de lectura que acepta cada tipo de recurso. Los agentes solo aceptan
# DescribeAgent solo (viewer) o los cinco de dueño; mezclar falla.
VIEW_ACTIONS = {
    "agent": ["quicksight:DescribeAgent"],
    "space": ["quicksight:DescribeSpace"],
    "topic": ["quicksight:DescribeTopic"],
    "dataset": [
        "quicksight:DescribeDataSet",
        "quicksight:DescribeDataSetPermissions",
        "quicksight:PassDataSet",
        "quicksight:DescribeIngestion",
        "quicksight:ListIngestions",
    ],
    "dashboard": [
        "quicksight:DescribeDashboard",
        "quicksight:ListDashboardVersions",
        "quicksight:QueryDashboard",
    ],
}


def arn(kind: str, resource_id: str) -> str:
    return f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:{kind}/{resource_id}"


def principal_arn(value: str) -> str:
    if value.startswith("arn:"):
        return value
    return f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:user/default/{value}"


def client():
    return boto3.Session(profile_name=PROFILE, region_name=REGION).client("quicksight")


# Cada recurso: (describe permisos, actualizar permisos). Todos devuelven/aceptan
# listas de {"Principal", "Actions"}.
def resource_ops(qs, kind: str, resource_id: str):
    a = {"AwsAccountId": ACCOUNT_ID}
    if kind == "agent":
        return (
            lambda: qs.describe_agent_permissions(**a, AgentId=resource_id).get("Permissions") or [],
            lambda g, r: qs.update_agent_permissions(**a, AgentId=resource_id, **g, **r),
        )
    if kind == "space":
        return (
            lambda: qs.describe_space_permissions(**a, SpaceId=resource_id).get("Permissions") or [],
            lambda g, r: qs.update_space_permissions(**a, SpaceId=resource_id, **g, **r),
        )
    if kind == "topic":
        return (
            lambda: qs.describe_topic_permissions(**a, TopicId=resource_id).get("Permissions") or [],
            lambda g, r: qs.update_topic_permissions(**a, TopicId=resource_id, **g, **r),
        )
    if kind == "dataset":
        return (
            lambda: qs.describe_data_set_permissions(**a, DataSetId=resource_id).get("Permissions") or [],
            lambda g, r: qs.update_data_set_permissions(**a, DataSetId=resource_id, **g, **r),
        )
    if kind == "dashboard":
        return (
            lambda: qs.describe_dashboard_permissions(**a, DashboardId=resource_id).get("Permissions") or [],
            lambda g, r: qs.update_dashboard_permissions(**a, DashboardId=resource_id, **g, **r),
        )
    raise ValueError(kind)


def resources_of(set_name: str) -> list[tuple[str, str]]:
    s = SETS[set_name]
    out = [("agent", s["agent"]), ("space", s["space"]), ("topic", s["topic"])]
    out += [("dataset", d) for d in s["datasets"]]
    out += [("dashboard", d) for d in s["dashboards"]]
    return out


def held_actions(describe, principal: str) -> list[str]:
    return next((p["Actions"] for p in describe() if p["Principal"] == principal), [])


def grant(qs, set_name: str, principal: str) -> None:
    for kind, rid in resources_of(set_name):
        describe, update = resource_ops(qs, kind, rid)
        want = VIEW_ACTIONS[kind]
        have = held_actions(describe, principal)
        if set(want) <= set(have):
            print(f"  {kind:9} {rid:32} ya tenía lectura")
            continue
        try:
            update({"GrantPermissions": [{"Principal": principal, "Actions": want}]}, {})
        except ClientError as error:
            sys.exit(f"{kind} {rid}: {error.response['Error']['Message']}")
        have = held_actions(describe, principal)
        if not set(want) <= set(have):
            sys.exit(f"{kind} {rid}: el servicio no registró los permisos ({have})")
        print(f"  {kind:9} {rid:32} lectura concedida")


def revoke(qs, set_name: str, principal: str) -> None:
    for kind, rid in resources_of(set_name):
        describe, update = resource_ops(qs, kind, rid)
        have = held_actions(describe, principal)
        if not have:
            print(f"  {kind:9} {rid:32} sin permisos (nada que revocar)")
            continue
        update({}, {"RevokePermissions": [{"Principal": principal, "Actions": have}]})
        print(f"  {kind:9} {rid:32} revocado {len(have)} permisos")


def audit(qs, set_name: str, principal: str) -> bool:
    """True si la identidad tiene lo suyo y NADA del otro juego."""
    ok = True
    print(f"  Debe tener (juego {set_name}):")
    for kind, rid in resources_of(set_name):
        describe, _ = resource_ops(qs, kind, rid)
        have = held_actions(describe, principal)
        good = set(VIEW_ACTIONS[kind]) <= set(have)
        ok &= good
        print(f"    {'OK ' if good else 'FALTA'} {kind:9} {rid}")

    others = [s for s in SETS if s != set_name]
    for other in others:
        print(f"  NO debe tener (juego {other}):")
        for kind, rid in resources_of(other):
            describe, _ = resource_ops(qs, kind, rid)
            try:
                have = held_actions(describe, principal)
            except ClientError as error:
                if error.response["Error"]["Code"] == "ResourceNotFoundException":
                    print(f"    --  {kind:9} {rid} (no existe)")
                    continue
                raise
            leak = bool(have)
            ok &= not leak
            print(f"    {'FUGA' if leak else 'OK '} {kind:9} {rid}" + (f"  <- {have}" if leak else ""))
    return ok


def main() -> None:
    global ACCOUNT_ID, REGION, PROFILE
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", required=True, choices=sorted(SETS), help="Juego de recursos")
    parser.add_argument("--principal", required=True, help="ARN o user_name de la identidad de Quick")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--audit", action="store_true", help="Solo comprobar, no cambiar")
    mode.add_argument("--revoke", action="store_true", help="Quitar todos los permisos del juego")
    parser.add_argument("--account-id", default=ACCOUNT_ID)
    parser.add_argument("--region", default=REGION)
    parser.add_argument("--profile", default=PROFILE)
    args = parser.parse_args()

    ACCOUNT_ID, REGION, PROFILE = args.account_id, args.region, args.profile

    principal = principal_arn(args.principal)
    qs = client()
    print(f"Identidad: {principal.rsplit('/default/', 1)[-1]}  | juego: {args.set}")

    if args.revoke:
        revoke(qs, args.set, principal)
        return
    if not args.audit:
        grant(qs, args.set, principal)
    print("Auditoría:")
    if not audit(qs, args.set, principal):
        sys.exit("\nFALLO: la identidad no tiene lo que debe o tiene algo del otro juego.")
    print("\nOK: la identidad ve solo su juego.")


if __name__ == "__main__":
    main()
