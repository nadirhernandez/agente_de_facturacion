# Afinar el chat de datos

## Decisión de arquitectura: SPICE, no Direct Query

| | SPICE | Direct Query |
|---|---|---:|
| Latencia por pregunta | milisegundos | 3–15 s |
| Costo por pregunta | cero | escaneo de Athena |
| Concurrencia | alta | limitada |
| Frescura | la del último refresco | tiempo real |

El chat es exploratorio: una pregunta genera tres más. Con Direct Query cada repregunta paga y
espera. El dataset de líneas ocupa ~1 MB de un límite de 1 TB, así que no hay razón para ir en vivo.

La frescura se resuelve con refrescos, no con Direct Query:

```text
evento:    archivo nuevo en raw/ -> Glue -> refresco automático de SPICE
programado: incremental diario y completo semanal, por si se pierde un evento

La carga decide el tipo: si solo tocó los últimos días, incremental; si tocó algo más viejo, completo.
```

Direct Query solo valdría la pena si necesitas ver la factura emitida hace dos minutos.

## Modelo temporal

Dos datasets, a propósito con granularidad distinta. Mezclarlas en uno solo duplica conteos.

| Dataset | Grano | Para qué |
|---|---|---|
| `Ventas comerciales` | una fila por línea de factura | región, producto, cliente, canal |
| `Ventas por periodo` | una fila por período | facturación diaria, comparativos |

`Ventas por periodo` sale de `sales_demo.vw_ventas_comparativo` y contiene 639 filas:
541 días, 78 semanas, 18 meses y 2 años.

Reglas fijadas:

- **Semana de lunes a domingo.**
- **Comparativo contra el período anterior inmediato**, ya calculado en columnas `_anterior` y
  `variacion_*_pct`.
- **Días sin facturación valen cero**, gracias a `vw_calendario`. Sin eso, un promedio diario divide
  entre los días que vendieron y una caída total se ve como dato ausente.
- **`es_periodo_completo`** distingue un período en curso. La semana actual mostraba −36% solo por
  estar a medias; el chat debe excluirla de los comparativos.

## Paso pendiente en la consola

El Topic `Ventas Inteligentes GT` se creó desde la consola y no se administra por API, así que hay
que agregarle el dataset nuevo a mano:

```text
Datos -> Temas -> Ventas Inteligentes GT -> Datasets -> Add datasets
  -> Ventas por periodo -> Publish
```

## Instrucciones a reemplazar en el Topic

Sustituye el contenido de **Custom instructions** por este, que ya incluye las reglas temporales:

```text
Responde siempre en español y muestra los montos en quetzales (GTQ o Q) con dos decimales. Indica el período, filtros y métrica usada. Si no hay datos suficientes, dilo claramente y no inventes resultados.

Usa únicamente documentos emitidos; los documentos anulados ya están excluidos de los datos.

Elige el dataset según la pregunta:
- Para facturación por día, semana, mes o año, y para cualquier comparativo entre períodos, usa "Ventas por periodo".
- Para desglose por región, establecimiento, canal, cliente, categoría o producto, usa "Ventas comerciales".
- No sumes métricas de ambos datasets en un mismo resultado: tienen granularidad distinta.

En "Ventas por periodo" filtra siempre por granularidad: "dia" para días, "semana" para semanas, "mes" para meses, "anio" para años. La columna periodo es la fecha de inicio del período.

La semana va de lunes a domingo.

El comparativo por defecto es contra el período anterior inmediato, no contra el año anterior. Usa las columnas facturacion_total_anterior, facturas_anterior y variacion_facturacion_pct en lugar de recalcular.

Excluye los períodos con es_periodo_completo = false de cualquier comparativo, y adviértelo si el usuario pregunta por el período en curso: un período a medias siempre parece una caída.

Definiciones de negocio:
- "facturación", "facturación total", "ventas brutas" e "ingresos" significan facturación total e incluyen IVA.
- "ventas sin IVA" y "venta neta" significan el monto gravable.
- "facturas", "documentos" o "ventas realizadas" significan conteo de facturas distintas.
- "unidades" significa unidades vendidas.
- "ticket promedio" es facturación total dividida entre facturas.

Equivalencias:
- "región", "zona" y "departamento" se refieren a region.
- "sucursal" y "tienda" se refieren a establecimiento.
- "comprador" y "cuenta" se refieren a cliente.

No existen costos, margen, inventario ni metas. No calcules ni supongas margen, utilidad o rentabilidad.

Para series de tiempo usa gráficos de líneas. Para comparar categorías usa barras ordenadas de mayor a menor. Para un solo número usa KPI. Cuando muestres una variación, incluye el valor de ambos períodos, no solo el porcentaje.

En preguntas de desempeño, explica brevemente los factores principales detrás del cambio.
```

## Metadata por columna

En el Topic, para cada columna vale la pena configurar:

| Ajuste | Por qué |
|---|---|
| Nombre amigable | Que el usuario vea "Facturación total", no `facturacion_total_linea` |
| Tipo semántico moneda | Formatea en quetzales y habilita comparaciones monetarias |
| Sinónimos | "sucursal", "tienda", "zona", "territorio" |
| Agregación permitida | `factura_id` solo conteo distinto, nunca suma |
| Orden comparativo | `mes` ordena enero–diciembre, no alfabéticamente |
| No agregable | `variacion_facturacion_pct` es un porcentaje: sumarlo no significa nada |

Ese último punto es el que más errores evita. Un porcentaje promediado sin ponderar da resultados
falsos, así que conviene marcarlo como no agregable.

## Preguntas para validar

```text
¿Cómo va la facturación de esta semana comparada con la anterior?
Muéstrame la facturación diaria del último mes.
¿Qué día de la semana vendemos menos?
¿Hubo días sin facturación en agosto?
Compara este mes contra el mes anterior.
¿Cuántas facturas emitimos por semana en los últimos dos meses?
¿Qué región cayó más frente al mes pasado?
Dame el ticket promedio por mes del último trimestre.
```

Las dos del medio son la prueba real del calendario: sin fechas continuas, el chat no puede
responder qué días no hubo ventas.

## Agente de chat propio

El agente por defecto de Quick (`SYSTEM`) no se puede ligar a espacios, por diseño: responde con
conocimiento general más todo lo que el usuario pueda ver. Para que el chat hable de las ventas y
de nada más, la app se fija a un agente propio.

```text
Space  ventas-inteligentes           <- Topic ventas-inteligentes + dashboard pulso-facturacion-dev
Agente ventas-inteligentes-analista  <- "Analista de Ventas", ligado solo a ese space
```

Todo por API, con `scripts/quicksight/sync_agent.py` (boto3; la CLI 2.36.3 no trae estos comandos):

```bash
python3 scripts/quicksight/sync_agent.py           # crea o actualiza, idempotente
python3 scripts/quicksight/sync_agent.py --show    # imprime lo que enviaría
python3 scripts/quicksight/sync_agent.py --delete  # elimina agente y space
```

La personalidad, el mensaje de bienvenida y las tres preguntas sugeridas viven en ese script. Límites
de la API: nombre de 50 caracteres, bienvenida de 300, máximo 3 preguntas de 100.

Al space entran solo el Topic y el dashboard, no los datasets sueltos: el Topic es el que trae
sinónimos, reglas de agregación e instrucciones.

### En la app

`config.json` lleva `quickChatAgentId`. Con ese campo, `EmbeddingFrame.tsx` monta el chat con el SDK
de embedding, fijado al agente y sin búsqueda web, sin adjuntos y sin selector de fuente. Sin el
campo, el chat se monta con el iframe directo de antes y el agente por defecto.

Hoy solo lo tiene `apps/web/public/config.json`, que es el de desarrollo local. El `config.json` de
CloudFront lo publica Terraform y sigue sin el campo, así que la app desplegada no cambió.

### Permisos

Crear el agente por API no le da acceso al usuario de QuickSight: el API registra como creador a la
sesión IAM, y el chat embebido corre como el usuario de QuickSight. Sin permisos explícitos, el chat
carga en blanco y Quick responde 401 al pedir el agente. El script concede permisos de dueño y los
verifica contra el servicio. Estos son los sets que la API acepta, probados uno por uno:

| Recurso | Acciones aceptadas |
|---|---|
| Agente | Solo sets completos: `DescribeAgent` (lector) o las cinco de dueño: `DescribeAgent`, `DescribeAgentPermissions`, `UpdateAgent`, `UpdateAgentPermissions`, `DeleteAgent` |
| Space | `DescribeSpace`, `DescribeSpacePermissions`, `UpdateSpace`, `UpdateSpacePermissions`, `DeleteSpace` |

`ListSpaceResources` y `UpdateSpaceResources` son acciones IAM, no permisos de recurso: el space las
rechaza como "Invalid action".

### Verificado en navegador

Chrome sin interfaz, contra la cuenta dev, leyendo el DOM del iframe de Quick:

- Con `fixedAgentId`, el chat abre con "Analista de Ventas" y el mensaje de bienvenida en español.
- Desaparecen "All data" y el menú de adjuntos que sí aparecen en el chat por defecto.
- Los botones siguen en inglés ("Ask a question...", "History"): dependen de la preferencia del
  usuario en Quick, no del agente.
- Las tres preguntas sugeridas no aparecieron en el DOM durante la prueba. Quedan configuradas en el
  agente, pero no está confirmado que el chat embebido las muestre.

### Revertir

Quitar `quickChatAgentId` de `config.json` devuelve el chat de siempre. `--delete` elimina el agente
y el space; el Topic, los datasets, SPICE y el dashboard no se tocan en ningún caso.
