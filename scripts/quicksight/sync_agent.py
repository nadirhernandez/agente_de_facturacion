#!/usr/bin/env python3
"""Create or update the sales chat agent in Amazon Quick, bound to the sales data.

The default Quick agent ("SYSTEM") cannot be linked to spaces by design, so it
answers from general model knowledge plus whatever the user can see. This script
builds the agent the embedded chat should use instead:

    Space "Ventas Inteligentes"  <- Topic ventas-inteligentes + dashboard
    Agent "Analista de Ventas"   <- linked only to that space, with a persona

Idempotent: run it as many times as needed. Nothing that exists today is
modified; the Topic, datasets, SPICE and dashboard are only referenced by ARN.

Revert:
    python3 scripts/quicksight/sync_agent.py --delete

Usage:
    python3 scripts/quicksight/sync_agent.py            # create or update
    python3 scripts/quicksight/sync_agent.py --show     # print what would be sent
    python3 scripts/quicksight/sync_agent.py --delete   # remove agent and space

The CLI 2.36.3 installed here has no agent/space commands; boto3 does.
"""

from __future__ import annotations

import argparse
import json
import sys
import time

import boto3
from botocore.exceptions import ClientError

ACCOUNT_ID = "503561412084"
REGION = "us-east-1"
PROFILE = "dashboards-dev-infile"

SPACE_ID = "ventas-inteligentes"
SPACE_NAME = "Ventas Inteligentes"
SPACE_DESCRIPTION = "Facturación emitida en Guatemala: modelo semántico certificado y dashboard."

AGENT_ID = "ventas-inteligentes-analista"
AGENT_NAME = "Analista de Ventas"
AGENT_DESCRIPTION = "Responde preguntas sobre la facturación de la empresa usando solo sus datos de ventas."

# The QuickSight identity the app embeds with. The agent is private until shared.
APP_USER_ARN = (
    f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:user/default/"
    "AWSReservedSSO_AWSAdministratorAccess_2dfa29f98f589a40/rnhernandez"
)

# Only the curated layer. Raw datasets are left out on purpose: the Topic carries
# the synonyms, aggregation rules and instructions that make answers correct.
SPACE_RESOURCES = [
    ("TOPIC", f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:topic/ventas-inteligentes"),
    ("DASHBOARD", f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:dashboard/pulso-facturacion-dev"),
]

WELCOME_MESSAGE = (
    "Hola, soy tu analista de ventas. Pregúntame por tu facturación, tus clientes, "
    "tus productos o tus sucursales, y te respondo con tus datos."
)

# API limit: 3 prompts, 100 characters each.
STARTER_PROMPTS = [
    "¿Cómo va la facturación de esta semana contra la anterior?",
    "¿Qué región cayó más frente al mes pasado?",
    "¿Cuáles son mis 10 clientes con más facturación este mes?",
]

IDENTITY = """
Eres el Analista de Ventas de la empresa. Tu único trabajo es responder preguntas sobre la facturación y las ventas de la empresa usando sus datos: facturación, facturas, unidades, ticket promedio, clientes, productos, categorías, canales, establecimientos y regiones de Guatemala.
""".strip()

TONE = """
Español de Guatemala, profesional y cercano. Trata siempre de usted, nunca de vos ni de tú. Directo, como un analista que le reporta a gerencia. Sin rodeos, sin tecnicismos y sin frases de relleno.
""".strip()

OUTPUT_STYLE = """
Primero el número que responde la pregunta, después el contexto. Montos en quetzales con el prefijo Q y dos decimales. Indica siempre el período y los filtros usados. Cuando muestres una variación, incluye el valor de ambos períodos, no solo el porcentaje. Usa una gráfica cuando ayude: líneas para series de tiempo, barras ordenadas de mayor a menor para comparar, un KPI para un solo número. Cierra con una sola pregunta de seguimiento útil.
""".strip()

RESPONSE_LENGTH = """
Breve: de dos a cinco frases más la tabla o gráfica cuando aplique. Amplía solo si el usuario lo pide.
""".strip()

# Rules that must not bend. The Topic repeats the business definitions; these
# keep the agent inside the data.
CUSTOM_INSTRUCTIONS = """
Responde únicamente con base en los datos del espacio Ventas Inteligentes. Nunca uses conocimiento general para inventar, estimar o completar una cifra que no esté en los datos.

Si una pregunta no se puede responder con estos datos, dilo en una frase y sugiere una pregunta parecida que sí puedas responder.

Si te preguntan algo que no tiene que ver con las ventas de la empresa, responde con amabilidad que solo puedes ayudar con sus datos de ventas y ofrece un ejemplo de pregunta.

No existen costos, margen, utilidad, inventario ni metas en los datos. No los calcules ni los supongas; si los piden, explica que esos datos no están disponibles.

La semana va de lunes a domingo. El comparativo por defecto es contra el período anterior inmediato. Excluye de los comparativos los períodos incompletos y adviértelo cuando el usuario pregunte por el período en curso, porque un período a medias siempre parece una caída.

Solo cuentan documentos emitidos; los anulados ya están excluidos.

Responde siempre en español, aunque la pregunta llegue en otro idioma.
""".strip()

POLL_SECONDS = 5
POLL_LIMIT = 36  # three minutes


def client():
    return boto3.Session(profile_name=PROFILE, region_name=REGION).client("quicksight")


def not_found(error: ClientError) -> bool:
    return error.response["Error"]["Code"] == "ResourceNotFoundException"


def validate_limits() -> None:
    """Fail before calling AWS instead of halfway through."""
    problems = []
    if len(AGENT_NAME) > 50:
        problems.append("AGENT_NAME supera 50 caracteres")
    if len(WELCOME_MESSAGE) > 300:
        problems.append(f"WELCOME_MESSAGE tiene {len(WELCOME_MESSAGE)} caracteres, máximo 300")
    if len(STARTER_PROMPTS) > 3:
        problems.append("máximo 3 STARTER_PROMPTS")
    for prompt in STARTER_PROMPTS:
        if len(prompt) > 100:
            problems.append(f"prompt de {len(prompt)} caracteres, máximo 100: {prompt}")
    for name, value in [("IDENTITY", IDENTITY), ("TONE", TONE), ("OUTPUT_STYLE", OUTPUT_STYLE),
                        ("RESPONSE_LENGTH", RESPONSE_LENGTH), ("CUSTOM_INSTRUCTIONS", CUSTOM_INSTRUCTIONS)]:
        if len(value) < 5:
            problems.append(f"{name} necesita al menos 5 caracteres")
    if problems:
        sys.exit("Configuración inválida:\n  - " + "\n  - ".join(problems))


def prompt_input() -> dict:
    return {
        "NewPrompt": {
            "Identity": IDENTITY,
            "Tone": TONE,
            "OutputStyle": OUTPUT_STYLE,
            "ResponseLength": RESPONSE_LENGTH,
            "CustomInstructions": CUSTOM_INSTRUCTIONS,
        }
    }


# --- Space -----------------------------------------------------------------
def ensure_space(qs) -> str:
    try:
        space = qs.describe_space(AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID)
        print(f"space {SPACE_ID}: ya existe")
    except ClientError as error:
        if not not_found(error):
            raise
        qs.create_space(AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID,
                        Name=SPACE_NAME, Description=SPACE_DESCRIPTION)
        print(f"space {SPACE_ID}: creado")
        space = qs.describe_space(AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID)

    arn = space["spaceArn"]

    current = {
        (item["ResourceType"], item["ResourceDetails"]["resourceArn"])
        for item in qs.list_space_resources(AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID)["SpaceResources"]
    }
    missing = [resource for resource in SPACE_RESOURCES if resource not in current]

    if missing:
        response = qs.update_space_resources(
            AwsAccountId=ACCOUNT_ID,
            SpaceId=SPACE_ID,
            AddResources=[
                {"ResourceType": kind, "ResourceDetails": {"resourceArn": resource_arn}}
                for kind, resource_arn in missing
            ],
        )
        # A 200 can still carry per-resource failures.
        failures = response.get("FailedResourceOperations") or []
        if failures:
            detail = "\n  - ".join(f"{f['ResourceType']}: {f.get('ErrorMessage')}" for f in failures)
            sys.exit(f"No se pudieron agregar recursos al space:\n  - {detail}")
        for kind, resource_arn in missing:
            print(f"space {SPACE_ID}: agregado {kind} {resource_arn.rsplit('/', 1)[-1]}")
    else:
        print(f"space {SPACE_ID}: recursos al día")

    return arn


# --- Agent -----------------------------------------------------------------
def wait_until_active(qs) -> dict:
    for _ in range(POLL_LIMIT):
        agent = qs.describe_agent(AwsAccountId=ACCOUNT_ID, AgentId=AGENT_ID)["Agent"]
        status = agent["AgentStatus"]
        if status == "ACTIVE":
            return agent
        if status == "FAILED":
            sys.exit(f"El agente quedó en FAILED: {agent.get('ErrorMessage')}")
        time.sleep(POLL_SECONDS)
    sys.exit(f"El agente no llegó a ACTIVE en {POLL_SECONDS * POLL_LIMIT} s")


def ensure_agent(qs, space_arn: str) -> dict:
    common = {
        "AwsAccountId": ACCOUNT_ID,
        "AgentId": AGENT_ID,
        "Name": AGENT_NAME,
        "Description": AGENT_DESCRIPTION,
        "WelcomeMessage": WELCOME_MESSAGE,
        "StarterPrompts": STARTER_PROMPTS,
        "CustomPromptInput": prompt_input(),
    }

    try:
        existing = qs.describe_agent(AwsAccountId=ACCOUNT_ID, AgentId=AGENT_ID)["Agent"]
    except ClientError as error:
        if not not_found(error):
            raise
        existing = None

    if existing is None:
        qs.create_agent(**common, Spaces=[space_arn], AgentLifecycle="PUBLISHED")
        print(f"agente {AGENT_ID}: creado")
    else:
        linked = existing.get("Spaces") or []
        update = dict(common)
        if space_arn not in linked:
            update["SpacesToAdd"] = [space_arn]
        extra = [arn for arn in linked if arn != space_arn]
        if extra:
            # Exactly one knowledge source: the sales space.
            update["SpacesToRemove"] = extra
        qs.update_agent(**update)
        print(f"agente {AGENT_ID}: actualizado")

    agent = wait_until_active(qs)

    if agent.get("Spaces") != [space_arn]:
        sys.exit(f"El agente quedó ligado a {agent.get('Spaces')}, se esperaba solo {space_arn}")

    return agent


# --- Permissions -----------------------------------------------------------
# Owner actions, named as in the Service Authorization Reference for QuickSight.
# The API records the IAM session that ran this script as Creator, but the
# embedded chat runs as the QuickSight user, which gets nothing implicitly:
# without these grants Quick answers 401 when the chat loads the agent, and a
# space it cannot read shows up as "Resource unavailable".
# Agents only accept whole sets: DescribeAgent alone (viewer) or all five
# (owner). Adding them one by one fails with "The list of actions ... is not valid".
AGENT_OWNER_ACTIONS = [
    "quicksight:DescribeAgent",
    "quicksight:DescribeAgentPermissions",
    "quicksight:UpdateAgent",
    "quicksight:UpdateAgentPermissions",
    "quicksight:DeleteAgent",
]

# ListSpaceResources and UpdateSpaceResources are IAM actions, not resource
# permissions: UpdateSpacePermissions rejects them as "Invalid action".
SPACE_OWNER_ACTIONS = [
    "quicksight:DescribeSpace",
    "quicksight:DescribeSpacePermissions",
    "quicksight:UpdateSpace",
    "quicksight:UpdateSpacePermissions",
    "quicksight:DeleteSpace",
]


def ensure_grant(describe, grant, label: str, actions: list[str]) -> None:
    held = next((p["Actions"] for p in describe() if p["Principal"] == APP_USER_ARN), [])
    missing = sorted(set(actions) - set(held))
    if missing:
        grant([{"Principal": APP_USER_ARN, "Actions": sorted(actions)}])
        print(f"{label}: permisos de dueño concedidos al usuario de la app")

    # Confirm against the service, not against what was sent.
    held = next((p["Actions"] for p in describe() if p["Principal"] == APP_USER_ARN), [])
    still_missing = sorted(set(actions) - set(held))
    if still_missing:
        sys.exit(f"{label}: el usuario de la app sigue sin {still_missing}")
    if not missing:
        print(f"{label}: el usuario de la app ya es dueño")


def ensure_permissions(qs) -> None:
    ensure_grant(
        lambda: qs.describe_space_permissions(AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID).get("Permissions") or [],
        lambda grants: qs.update_space_permissions(AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID,
                                                   GrantPermissions=grants),
        f"space {SPACE_ID}",
        SPACE_OWNER_ACTIONS,
    )
    ensure_grant(
        lambda: qs.describe_agent_permissions(AwsAccountId=ACCOUNT_ID, AgentId=AGENT_ID).get("Permissions") or [],
        lambda grants: qs.update_agent_permissions(AwsAccountId=ACCOUNT_ID, AgentId=AGENT_ID,
                                                   GrantPermissions=grants),
        f"agente {AGENT_ID}",
        AGENT_OWNER_ACTIONS,
    )


# --- Delete ----------------------------------------------------------------
def delete_all(qs) -> None:
    for label, call in [
        (f"agente {AGENT_ID}", lambda: qs.delete_agent(AwsAccountId=ACCOUNT_ID, AgentId=AGENT_ID)),
        (f"space {SPACE_ID}", lambda: qs.delete_space(AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID)),
    ]:
        try:
            call()
            print(f"{label}: eliminado")
        except ClientError as error:
            if not_found(error):
                print(f"{label}: no existía")
            else:
                raise
    print("Quita quickChatAgentId de config.json para volver al chat por defecto.")


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--show", action="store_true", help="Solo imprimir la configuración")
    mode.add_argument("--delete", action="store_true", help="Eliminar el agente y el space")
    args = parser.parse_args()

    validate_limits()

    if args.show:
        print(json.dumps({
            "space": {"SpaceId": SPACE_ID, "Name": SPACE_NAME, "Resources": SPACE_RESOURCES},
            "agent": {
                "AgentId": AGENT_ID,
                "Name": AGENT_NAME,
                "WelcomeMessage": WELCOME_MESSAGE,
                "StarterPrompts": STARTER_PROMPTS,
                "CustomPromptInput": prompt_input(),
            },
            "grantTo": APP_USER_ARN,
        }, indent=2, ensure_ascii=False))
        return

    qs = client()

    if args.delete:
        delete_all(qs)
        return

    space_arn = ensure_space(qs)
    agent = ensure_agent(qs, space_arn)
    ensure_permissions(qs)

    print()
    print(f"Agente listo: {agent['Name']} ({agent['AgentLifecycle']}, {agent['AgentStatus']})")
    print(f"Space ligado: {space_arn}")
    print(f'Para la app, en config.json: "quickChatAgentId": "{AGENT_ID}"')


if __name__ == "__main__":
    main()
