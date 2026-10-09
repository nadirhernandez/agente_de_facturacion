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
    python3 scripts/quicksight/sync_agent.py --delete   # remove agent and space (asks first; --yes skips)

    --account-id, --region, --profile y --app-user-arn apuntan a otra cuenta;
    por defecto, el piloto.

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
SPACE_DESCRIPTION = "Facturación emitida en Guatemala en GTQ y USD: modelo semántico certificado y dashboard."

# Action connectors a ligar / desligar (se llenan desde la línea de comandos).
ACTION_CONNECTORS: list[str] = []
ACTION_CONNECTORS_TO_REMOVE: list[str] = []

AGENT_ID = "ventas-inteligentes-analista"
AGENT_NAME = "Analista de Ventas"
AGENT_DESCRIPTION = (
    "Analista de facturación electrónica (FEL) de Guatemala. Responde sobre las ventas de su empresa "
    "a partir de sus Documentos Tributarios Electrónicos certificados, usando solo sus propios datos."
)

# The QuickSight identity the app embeds with. The agent is private until shared.
APP_USER_ARN = (
    f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:user/default/"
    "AWSReservedSSO_AWSAdministratorAccess_2dfa29f98f589a40/rnhernandez"
)

# Only the curated layer. Raw datasets are left out on purpose: the Topic carries
# the synonyms, aggregation rules and instructions that make answers correct.
SPACE_RESOURCES = [
    ("TOPIC", f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:topic/ventas-inteligentes"),
    ("DASHBOARD", f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:dashboard/pulso-facturacion-real"),
]

WELCOME_MESSAGE = (
    "Hola, soy su analista de ventas sobre sus facturas electrónicas FEL. Analizo facturación en "
    "quetzales y dólares, facturas, unidades y promedio por factura; comparo períodos, desgloso por "
    "región, cliente o producto, y busco una factura por su número de autorización."
)

# API limit: 3 prompts, 100 characters each.
STARTER_PROMPTS = [
    "¿Cómo va la facturación de esta semana contra la anterior?",
    "¿Qué región cayó más frente al mes pasado?",
    "¿Cuáles son mis 10 clientes con más facturación este mes?",
]

IDENTITY = """
Eres el Analista de Ventas de su empresa, especialista en la facturación electrónica de Guatemala. Trabajas sobre los Documentos Tributarios Electrónicos (DTE) que su empresa emite bajo el Régimen de Factura Electrónica en Línea (FEL) de la SAT: documentos certificados, firmados electrónicamente y con número de autorización, que son la fuente legal y definitiva de sus ventas.

Tu único trabajo es responder preguntas sobre la facturación y las ventas de su empresa usando esos datos: facturación, facturas, unidades, promedio por factura, clientes, productos, categorías, canales, establecimientos y regiones de Guatemala. Entiendes que una factura FEL no es un PDF sino un documento tributario registrado ante la SAT, que el emisor es su empresa y el receptor es su cliente identificado por NIT, y que la facturación de un período es lo que esos documentos certifican.
""".strip()

TONE = """
Español de Guatemala, profesional y cercano. Trata siempre de usted, nunca de vos ni de tú. Directo, como un analista que le reporta a gerencia. Sin rodeos, sin tecnicismos y sin frases de relleno.
""".strip()

OUTPUT_STYLE = """
Primero el número que responde la pregunta, después el contexto. Muestra GTQ con el prefijo Q y USD con el prefijo US$, siempre con dos decimales. Indica siempre el período, los filtros y la moneda usados. Cuando muestres una variación, incluye el valor de ambos períodos, no solo el porcentaje. Usa una gráfica cuando ayude: líneas para series de tiempo, barras ordenadas de mayor a menor para comparar, un KPI para un solo número. Cierra con una sola pregunta de seguimiento útil.
""".strip()

RESPONSE_LENGTH = """
Breve: de dos a cinco frases más la tabla o gráfica cuando aplique. Amplía solo si el usuario lo pide.
""".strip()

# Rules that must not bend. The Topic repeats the business definitions; these
# keep the agent inside the data.
CUSTOM_INSTRUCTIONS = """
Responde únicamente con base en los datos del espacio Ventas Inteligentes. Nunca uses conocimiento general para inventar, estimar o completar una cifra que no esté en los datos.

Si una pregunta no se puede responder con estos datos, dilo en una frase y sugiere una pregunta parecida que sí puedas responder.

Si te preguntan algo que no tiene que ver con las ventas de su empresa, responde con amabilidad que solo puedes ayudar con sus datos de ventas y ofrece un ejemplo de pregunta.

No existen costos, margen, utilidad, inventario, metas ni tasas de cambio en los datos. No los calcules ni los supongas; si los piden, explica que esos datos no están disponibles.

Los importes están en su moneda original. Nunca sumes, promedies ni compares GTQ y USD. Si la pregunta no especifica moneda, responde con resultados separados por moneda. No conviertas importes: muestra GTQ con Q y USD con US$.

La semana va de lunes a domingo. El comparativo por defecto es contra el período anterior inmediato de la misma moneda. Excluye de los comparativos los períodos incompletos y adviértelo cuando el usuario pregunte por el período en curso, porque un período a medias siempre parece una caída.

Solo cuentan documentos emitidos; los anulados ya están excluidos.

Naturaleza de los datos (Régimen FEL de Guatemala): cada fila proviene de un Documento Tributario Electrónico certificado ante la SAT. Los tipos que puedes encontrar son factura (FACT, la venta principal), nota de crédito (NCRE, que corrige o anula total o parcialmente una factura previa y por tanto reduce la venta), nota de débito (NDEB, que aumenta el monto de una factura previa), y variantes como factura cambiaria o de pequeño contribuyente. FEL es inmutable: una factura emitida no se borra, se corrige con una nota de crédito. Por eso, cuando veas un documento con descripción de anulación, devolución o ajuste, trátalo como una corrección de otra factura y adviértelo, no lo presentes como una venta más ni lo sumes a ciegas con la factura original.

Una factura se identifica por su número de autorización (columna Factura), un identificador único que la SAT asigna al certificarla. Cuando el usuario pida una factura específica, filtra por ese número y muestra sus líneas en una tabla: producto, unidades, facturación total y moneda, con la fecha, el cliente y el establecimiento. En ese caso no sumes ni mezcles varias facturas; muestra el detalle de ese documento y su número de autorización completo, sin truncar.

Si tienes disponibles las acciones de documentos FEL, úsalas así: cuando el usuario pida ver, abrir, descargar o compartir una factura como PDF, llama a pdf_factura_fel con su número de autorización y entrega el enlace al PDF certificado. Cuando pida el detalle certificado de un documento o un dato que no esté en los datos de ventas (receptor completo, certificador, fecha de certificación, anulación, descuentos), llama a resumen_factura_fel y responde con esos datos. Solo llama a xml_factura_fel si el usuario pide expresamente el XML. Si una acción responde que el documento no existe, díselo tal cual y verifica con el usuario el número de autorización. Si no tienes esas acciones, indícale que puede consultar el documento certificado en el verificador público con ese mismo número de autorización.

El emisor de todos los documentos es su empresa; el receptor es el cliente, identificado por su NIT. Cuando hables de "clientes" te refieres a receptores de las facturas. Los importes con IVA son la facturación total; el monto gravable es la venta sin IVA.

Responde siempre en español, aunque la pregunta llegue en otro idioma.
""".strip()

POLL_SECONDS = 5
POLL_LIMIT = 36  # three minutes


def configure(
    account_id: str,
    region: str,
    profile: str,
    app_user_arn: str | None,
    *,
    space_id: str | None = None,
    space_name: str | None = None,
    agent_id: str | None = None,
    agent_name: str | None = None,
    topic_id: str | None = None,
    dashboard_id: str | None = None,
) -> None:
    """Apunta el script a otra cuenta/región y, opcionalmente, a otro juego
    space/agente/topic/dashboard. Sin argumentos, queda el piloto (datos reales)."""
    global ACCOUNT_ID, REGION, PROFILE, APP_USER_ARN, SPACE_RESOURCES
    global SPACE_ID, SPACE_NAME, AGENT_ID, AGENT_NAME
    old_account, old_region = ACCOUNT_ID, REGION
    ACCOUNT_ID, REGION, PROFILE = account_id, region, profile
    # Los ARN por defecto se reescriben con la cuenta y región elegidas.
    prefix_old = f"arn:aws:quicksight:{old_region}:{old_account}:"
    prefix_new = f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:"
    SPACE_RESOURCES = [(kind, arn.replace(prefix_old, prefix_new, 1)) for kind, arn in SPACE_RESOURCES]
    APP_USER_ARN = app_user_arn or APP_USER_ARN.replace(prefix_old, prefix_new, 1)

    # Un segundo juego (p. ej. el demo con datos sintéticos) reutiliza persona e
    # instrucciones, pero vive en su propio space con su propio topic/dashboard.
    SPACE_ID = space_id or SPACE_ID
    SPACE_NAME = space_name or SPACE_NAME
    AGENT_ID = agent_id or AGENT_ID
    AGENT_NAME = agent_name or AGENT_NAME
    if topic_id or dashboard_id:
        resources = []
        for kind, arn in SPACE_RESOURCES:
            if kind == "TOPIC" and topic_id:
                arn = f"{prefix_new}topic/{topic_id}"
            if kind == "DASHBOARD" and dashboard_id is not None:
                if dashboard_id == "":
                    # --dashboard-id "" : sin dashboard, el chat es la única superficie.
                    continue
                arn = f"{prefix_new}dashboard/{dashboard_id}"
            resources.append((kind, arn))
        SPACE_RESOURCES = resources


def client():
    return boto3.Session(profile_name=PROFILE, region_name=REGION).client("quicksight")


def connector_arn(value: str) -> str:
    """Acepta el id o el ARN de un Action Connector y devuelve siempre el ARN."""
    if value.startswith("arn:"):
        return value
    return f"arn:aws:quicksight:{REGION}:{ACCOUNT_ID}:action-connector/{value}"


def list_space_resources(qs) -> list[dict]:
    """Todas las páginas de ListSpaceResources, no solo la primera."""
    resources: list[dict] = []
    token = None
    while True:
        request = {"AwsAccountId": ACCOUNT_ID, "SpaceId": SPACE_ID}
        if token:
            request["NextToken"] = token
        page = qs.list_space_resources(**request)
        resources.extend(page.get("SpaceResources") or [])
        token = page.get("NextToken")
        if not token:
            return resources


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
    for name, value in [
        ("IDENTITY", IDENTITY),
        ("TONE", TONE),
        ("OUTPUT_STYLE", OUTPUT_STYLE),
        ("RESPONSE_LENGTH", RESPONSE_LENGTH),
        ("CUSTOM_INSTRUCTIONS", CUSTOM_INSTRUCTIONS),
    ]:
        if len(value) < 5:
            problems.append(f"{name} necesita al menos 5 caracteres")
    if problems:
        sys.exit("Configuración inválida:\n  - " + "\n  - ".join(problems))


def prompt_input() -> dict:
    # Las instrucciones nombran el space al que el agente debe limitarse; si el
    # juego usa otro space (p. ej. el demo), el nombre debe coincidir.
    instructions = CUSTOM_INSTRUCTIONS.replace("del espacio Ventas Inteligentes", f"del espacio {SPACE_NAME}")
    return {
        "NewPrompt": {
            "Identity": IDENTITY,
            "Tone": TONE,
            "OutputStyle": OUTPUT_STYLE,
            "ResponseLength": RESPONSE_LENGTH,
            "CustomInstructions": instructions,
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
        qs.create_space(
            AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID, Name=SPACE_NAME, Description=SPACE_DESCRIPTION
        )
        print(f"space {SPACE_ID}: creado")
        space = qs.describe_space(AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID)

    arn = space["spaceArn"]

    current = {
        (item["ResourceType"], item["ResourceDetails"]["resourceArn"]) for item in list_space_resources(qs)
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
        create = dict(common, Spaces=[space_arn], AgentLifecycle="PUBLISHED")
        if ACTION_CONNECTORS:
            create["ActionConnectors"] = [connector_arn(c) for c in ACTION_CONNECTORS]
        qs.create_agent(**create)
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
        # Action connectors (MCP y otros) se agregan sin quitar los que ya tenga:
        # la lista la administra quien los crea en la consola o por API.
        # UpdateAgent exige el ARN; se acepta el id y se construye el ARN.
        current_connectors = set(existing.get("ActionConnectors") or [])
        to_add = [
            arn for arn in (connector_arn(c) for c in ACTION_CONNECTORS) if arn not in current_connectors
        ]
        to_remove = [
            arn for arn in (connector_arn(c) for c in ACTION_CONNECTORS_TO_REMOVE) if arn in current_connectors
        ]
        if to_add:
            update["ActionConnectorsToAdd"] = to_add
        if to_remove:
            update["ActionConnectorsToRemove"] = to_remove
        # `common` siempre lleva CustomPromptInput completo: UpdateAgent lo
        # reemplaza entero y omitirlo deja al agente sin instrucciones.
        qs.update_agent(**update)
        detail = "".join(
            [f" (+{len(to_add)} action connector)" if to_add else "", f" (-{len(to_remove)} action connector)" if to_remove else ""]
        )
        print(f"agente {AGENT_ID}: actualizado{detail}")

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
        lambda: qs.describe_space_permissions(AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID).get("Permissions")
        or [],
        lambda grants: qs.update_space_permissions(
            AwsAccountId=ACCOUNT_ID, SpaceId=SPACE_ID, GrantPermissions=grants
        ),
        f"space {SPACE_ID}",
        SPACE_OWNER_ACTIONS,
    )
    ensure_grant(
        lambda: qs.describe_agent_permissions(AwsAccountId=ACCOUNT_ID, AgentId=AGENT_ID).get("Permissions")
        or [],
        lambda grants: qs.update_agent_permissions(
            AwsAccountId=ACCOUNT_ID, AgentId=AGENT_ID, GrantPermissions=grants
        ),
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
    parser.add_argument("--yes", action="store_true", help="No pedir confirmación en --delete")
    parser.add_argument("--account-id", default=ACCOUNT_ID, help="Cuenta de QuickSight")
    parser.add_argument("--region", default=REGION, help="Región de QuickSight")
    parser.add_argument("--profile", default=PROFILE, help="Perfil de AWS")
    parser.add_argument(
        "--app-user-arn",
        default=None,
        help="Usuario de QuickSight de la app (por defecto, el del piloto en esa cuenta)",
    )
    # Un segundo juego space/agente (p. ej. el demo sintético) con la misma persona.
    parser.add_argument("--space-id", default=None, help=f"Id del space (por defecto {SPACE_ID})")
    parser.add_argument("--space-name", default=None, help=f"Nombre del space (por defecto {SPACE_NAME!r})")
    parser.add_argument("--agent-id", default=None, help=f"Id del agente (por defecto {AGENT_ID})")
    parser.add_argument("--agent-name", default=None, help=f"Nombre del agente (por defecto {AGENT_NAME!r})")
    parser.add_argument("--topic-id", default=None, help="Topic a ligar al space (por defecto ventas-inteligentes)")
    parser.add_argument(
        "--dashboard-id",
        default=None,
        help='Dashboard a ligar al space (por defecto pulso-facturacion-real; "" para ninguno)',
    )
    parser.add_argument(
        "--action-connector",
        action="append",
        default=[],
        metavar="ACTION_CONNECTOR_ID",
        help=(
            "Id de un Action Connector (por ejemplo el MCP de documentos FEL creado en la consola) "
            "que debe quedar ligado al agente. Repetible. Ver docs/MCP_QUICK.md."
        ),
    )
    parser.add_argument(
        "--remove-action-connector",
        action="append",
        default=[],
        metavar="ACTION_CONNECTOR_ID",
        help=(
            "Id de un Action Connector a desligar del agente. Repetible. Usa siempre esta opción en "
            "lugar de un UpdateAgent a mano: UpdateAgent reemplaza CustomPromptInput completo y, si "
            "no se envía, deja al agente sin instrucciones."
        ),
    )
    args = parser.parse_args()

    global ACTION_CONNECTORS, ACTION_CONNECTORS_TO_REMOVE
    ACTION_CONNECTORS = list(args.action_connector)
    ACTION_CONNECTORS_TO_REMOVE = list(args.remove_action_connector)

    configure(
        args.account_id,
        args.region,
        args.profile,
        args.app_user_arn,
        space_id=args.space_id,
        space_name=args.space_name,
        agent_id=args.agent_id,
        agent_name=args.agent_name,
        topic_id=args.topic_id,
        dashboard_id=args.dashboard_id,
    )
    validate_limits()

    if args.show:
        print(
            json.dumps(
                {
                    "space": {"SpaceId": SPACE_ID, "Name": SPACE_NAME, "Resources": SPACE_RESOURCES},
                    "agent": {
                        "AgentId": AGENT_ID,
                        "Name": AGENT_NAME,
                        "WelcomeMessage": WELCOME_MESSAGE,
                        "StarterPrompts": STARTER_PROMPTS,
                        "CustomPromptInput": prompt_input(),
                    },
                    "grantTo": APP_USER_ARN,
                },
                indent=2,
                ensure_ascii=False,
            )
        )
        return

    qs = client()

    if args.delete:
        if not args.yes:
            if not sys.stdin.isatty():
                sys.exit("Sin terminal interactiva: usa --yes para confirmar --delete.")
            answer = input(
                f"Se eliminarán el agente {AGENT_ID} y el space {SPACE_ID} "
                f"en la cuenta {ACCOUNT_ID}. ¿Continuar? [s/N] "
            )
            if answer.strip().lower() not in {"s", "si", "sí"}:
                print("Cancelado. No se eliminó nada.")
                return
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
