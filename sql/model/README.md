# Modelo analítico: única fuente

Todas las tablas y vistas del modelo viven aquí, una sentencia por archivo. Nadie más las define:
ni Terraform, ni el job de Glue, ni scripts sueltos.

```text
tables/      se crean solo si no existen (Iceberg, no se reemplazan)
migrations/  corren en cada despliegue, después de las tablas y antes de las vistas;
             deben ser idempotentes (no hacer nada cuando el dato ya está)
views/       se recrean siempre (CREATE OR REPLACE VIEW)
```

Las migraciones son para mover o rellenar datos cuando el modelo cambia (por ejemplo, poblar
`agg_ventas_diario_moneda` desde el detalle al pasar a multimoneda). Van con `INSERT … WHERE NOT
EXISTS` o `MERGE`, nunca con `DELETE`/`DROP`: si una tabla vieja deja de usarse, se documenta y se
retira a mano.

Se ejecutan en orden de nombre con `services/views-bootstrap/src/deploy_views.mjs`, que
`scripts/build_lambda_bundle.sh` empaqueta junto con estos archivos. La misma Lambda despliega el
piloto y cada cliente, así que un cambio aquí llega igual a todos.

Marcadores que reemplaza el despliegue:

| Marcador | Valor |
|---|---|
| `${db}` | Base de Glue del ambiente |
| `${warehouse}` | Prefijo S3 de las tablas Iceberg, sin `/` final |

Reglas de formato: comentarios solo en líneas completas que empiecen con `--`, y sin `;` final.

Cambiar el esquema de una tabla existente no se hace editando su `CREATE TABLE`: ese archivo solo
corre cuando la tabla no existe. Un cambio de esquema necesita su propio `ALTER TABLE`.
