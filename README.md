# MLP — Chat de facturación y ventas

> **Desplegado en `dev-infile` (503561412084) / us-east-1.**
> App: https://d3ocvrp9ma213b.cloudfront.net
> Guías: [`docs/RUNBOOK.md`](docs/RUNBOOK.md) · [`docs/MLP_OPERATIONS.md`](docs/MLP_OPERATIONS.md) · [`docs/APP_SECURITY.md`](docs/APP_SECURITY.md) · [`docs/DEUDA_TECNICA.md`](docs/DEUDA_TECNICA.md)
>
> **Modelo de despliegue (decisión fija):** cada cliente vive completo en su propia cuenta de AWS,
> el despliegue parte de los JSON que **ya están** en un bucket de esa cuenta, y nada de un cliente
> se acopla a la cuenta piloto de INFILE. Detalle en [`docs/PRINCIPIOS_DESPLIEGUE.md`](docs/PRINCIPIOS_DESPLIEGUE.md).
>
> **Demo rápida:** genera un link de acceso sin cuenta con `bash scripts/create_guest_link.sh`. Ver [`docs/ACCESO_INVITADOS.md`](docs/ACCESO_INVITADOS.md).

## Entregable final

El MLP se entrega como una **aplicación web mínima para usuarios comerciales**, no como la consola de administración de QuickSight.

La pantalla incluye:

1. **Analista de Ventas**: chat en lenguaje natural sobre el modelo de ventas, fijado a un agente
   de Amazon Quick, con preguntas sugeridas para arrancar.
2. **Pulso de Facturación**: el dashboard embebido con indicadores y evolución de la facturación.
   Los filtros de período, región, establecimiento, canal y categoría viven dentro del dashboard.
3. Indicador de frescura de datos (última carga a SPICE) visible en todo momento.

Guardar o compartir vistas filtradas quedó fuera del alcance mientras la identidad de QuickSight sea
compartida (ver [`docs/APP_SECURITY.md`](docs/APP_SECURITY.md)).

QuickSight es el motor analítico embebido. La consola de QuickSight queda para que un administrador gestione datasets, Topics, permisos y el dashboard base.

## Desarrollo local

```bash
npm install
npm run dev:web        # Vite en http://localhost:5173
npm run lint           # ESLint en apps/ y services/
npm run typecheck      # tsc --noEmit del frontend
npm test               # Vitest en todos los workspaces
npm run build          # build del frontend y bundles de Lambda
```

Los mismos comandos corren en CI (`.github/workflows/ci.yml`) junto con `terraform fmt -check` y
`terraform validate`.

## Flujo de demostración

1. El usuario abre la aplicación.
2. Ve los indicadores de facturación: ventas netas, facturas, unidades y tendencia.
3. Pregunta: `¿Qué departamento facturó más este mes?`.
4. El sistema responde usando el Topic/dataset y muestra el resultado en una visualización.
5. Pregunta: `Compáralo con el mes anterior y muestra las categorías.`
6. El usuario abre o guarda la vista resultante en el dashboard.

## Datos incluidos

Los archivos son **sintéticos** y no contienen información real de personas o empresas. Se generaron a partir de la estructura de factura electrónica proporcionada como referencia.

| Archivo | Nivel | Uso |
|---|---|---|
| `data/raw/facturas_demo.jsonl` | Documento/factura con `items` anidados | Simula la fuente original de emisión de DTE |
| `data/curated/ventas_documentos_demo.csv` | Una fila por factura | KPIs de cantidad de documentos e importe total |
| `data/curated/ventas_lineas_demo.csv` | Una fila por ítem facturado | Fuente recomendada para Athena y QuickSight |
| `sql/model/` | SQL | Única fuente de las tablas Iceberg y las vistas que consume QuickSight |

El generador es determinista: `python3 scripts/generate_sales_demo.py` reproduce los mismos datos.

## Modelo analítico del MLP

La tabla principal para BI es `ventas_lineas_demo.csv`.

| Métrica | Columna / cálculo |
|---|---|
| Ventas netas | `SUM(monto_linea)` para documentos `emitido` |
| Facturas | `COUNT(DISTINCT doc_id)` |
| Unidades vendidas | `SUM(cantidad)` |
| IVA | `SUM(iva)` |
| Ticket promedio | `SUM(monto_linea) / COUNT(DISTINCT doc_id)` |

Dimensiones: `fecha`, `departamento`, `municipio`, `establecimiento`, `canal`, `cliente`, `categoria` y `producto`.

> El JSON suministrado no incluye costos; por ello este MLP **no calcula margen bruto**. Esa métrica se añadirá al incorporar una fuente de costos por producto o inventario.

## Carga a AWS

Todo se despliega con Terraform; no hay pasos manuales en Athena. El flujo completo, desde el JSON
hasta SPICE, está en [`docs/HANDOFF.md`](docs/HANDOFF.md), sección "Modelo en Iceberg", y la
operación diaria en [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

Los CSV de `data/curated/` son el ejemplo aplanado del generador; el pipeline real parte del JSON
de `data/raw/`.

## Preguntas de aceptación de la demo

- ¿Cuál fue la facturación del mes actual?
- ¿Qué departamento vendió más?
- ¿Cómo varían las ventas mensuales?
- ¿Cuáles son las cinco categorías con mayor facturación?
- ¿Qué clientes realizaron más compras?
- ¿Qué establecimiento tiene menor facturación?
- ¿Cuál es el ticket promedio por canal?

## Alcance deliberadamente excluido

- Costos, margen e inventario.
- Facturación real o datos personales reales.
- Creación libre de dashboards por cualquier usuario.
- Integración definitiva con ERP/DTE; en el MLP se emula con los JSONL incluidos.
