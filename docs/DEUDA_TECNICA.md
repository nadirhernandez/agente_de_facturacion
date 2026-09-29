# Deuda técnica y pendientes

Registro de decisiones tomadas para avanzar con la demo que hay que revisar antes de tratar el
piloto como producto. Cada punto dice qué falta, por qué se pospuso y qué desbloquea resolverlo.

| # | Tema | Estado | Prioridad |
|---|---|---|---|
| 1 | Content-Security-Policy no se entrega | Redactada en Terraform, desactivada | Media |
| 2 | Terraform y la infraestructura difieren (drift controlado) | `config.json` y la política de cabeceras se actualizaron por CLI | Alta (fácil) |
| 3 | Login de Cognito con marca por defecto de AWS | Sin `settings` de Managed Login | Media |
| 4 | Registro público e identidad compartida de QuickSight | Riesgo aceptado para la demo | Alta antes de datos reales |
| 5 | Despliegue depende de una sesión SSO personal | CI valida pero no despliega | Media |
| 6 | Aviso de `npm audit` en `uuid` (transitiva del SDK de embedding) | Sin corrección disponible sin romper el SDK | Baja |
| 7 | Sin tope de tiempo en splash ni en el montaje del chat | Un arranque lento se ve como cuelgue | Baja |
| 8 | Cambios de formato Python/Terraform sin commitear | Residuo de `ruff format` y `terraform fmt` | Baja |

## 1. Content-Security-Policy

**Qué hay.** `infrastructure/terraform/application.tf` define una CSP completa (`local.content_security_policy`)
pero `enforce_csp = false`, así que no se entrega ninguna cabecera CSP. Hasta el 2026-09-29 se enviaba
como `Content-Security-Policy-Report-Only`; se retiró porque sin directiva `report-to` no protege ni
reporta nada y Chrome llena la consola con una advertencia por recurso.

**Por qué se pospuso.** Activarla en modo enforce sin probar puede romper el dashboard embebido o el
chat de Quick (el SDK inyecta un iframe de control y hace llamadas a dominios de QuickSight). No hay
forma de validarlo sin una sesión real de Cognito, que no se puede automatizar desde CI.

**Cómo cerrarlo.**

1. Sesión de pruebas con login real: dashboard, chat con agente, pregunta sugerida, nueva conversación.
2. Con la consola abierta, poner `enforce_csp = true`, `terraform apply`, repetir la prueba y corregir
   cada `Refused to load…` añadiendo el origen exacto a la directiva correspondiente.
3. Opcional: agregar `report-to` con un endpoint (por ejemplo un Lambda URL) para recibir violaciones
   futuras.
4. Replicar en el módulo tenant (`content_security_policy_enforced`).

## 2. Drift entre Terraform y la infraestructura

Dos objetos se modificaron con la CLI de AWS porque Terraform no pudo correr en la sesión (SSO vencido
y luego un candado huérfano en el estado). En ambos casos el `.tf` ya contiene el cambio equivalente,
así que el siguiente `terraform apply` mostrará una actualización **sin efecto real**:

- `aws_s3_object.web_runtime_config` (`config.json` del piloto): se agregó `clientName`; el `.tf` lo
  genera desde `var.app_client_name`. El plan mostrará un cambio de `etag`.
- `aws_cloudfront_response_headers_policy.web`: se eliminó `CustomHeadersConfig`; el `.tf` ya no lo
  declara. El plan debería salir limpio; si muestra algo, es solo el orden de atributos.

**Cómo cerrarlo.** `terraform plan` completo, confirmar que solo aparecen esos dos recursos (o nada) y
`apply`. Si aparece cualquier otro recurso, detenerse y revisar: sería drift no documentado.

## 3. Marca en el Managed Login de Cognito

La pantalla donde se escribe usuario y contraseña sigue con el estilo por defecto de AWS
(`use_cognito_provided_values = true`). La app ya tiene splash y landing con la marca INsight, así que
el salto de estilo se nota solo en esa pantalla.

**Cómo cerrarlo.** `aws_cognito_managed_login_branding` con un documento `settings` (colores, logo,
favicon en base64). El módulo tenant ya expone `var.app_branding` para esto. Requiere `terraform apply`
sobre Cognito: hacerlo en horario sin demos y con un usuario de prueba para validar que el login sigue
funcionando.

## 4. Registro público e identidad compartida

Documentado en detalle en [`APP_SECURITY.md`](APP_SECURITY.md), sección "Riesgo aceptado para el
piloto". Resumen: cualquier correo verificable puede crear cuenta y todos embeben QuickSight como el
administrador. Aceptado explícitamente el 2026-09-28 mientras los datos sean sintéticos. Tres pasos
para retirarlo están en ese documento.

## 5. Despliegue manual con SSO personal

Publicar el frontend y correr Terraform requieren el perfil `dashboards-dev-infile` de una persona.
La sesión SSO vence, Terraform falla con `InvalidGrantException` aunque la CLI siga funcionando con
credenciales en caché, y un `plan` interrumpido deja un candado en el estado.

**Cómo cerrarlo.** Job de despliegue en GitHub Actions con un rol OIDC (`aws-actions/configure-aws-credentials`)
acotado a: `s3:PutObject`/`DeleteObject` en el bucket web, `cloudfront:CreateInvalidation` en la
distribución. Terraform puede seguir siendo manual, pero con `-lock-timeout` y sin ejecuciones a medias.

## 6. Aviso de seguridad en `uuid`

`npm audit` reporta dos avisos moderados en `uuid < 11.1.1`, dependencia transitiva de
`amazon-quicksight-embedding-sdk`. La única corrección automática degrada el SDK a 2.0.0. La
vulnerabilidad (falta de comprobación de límites en `v3/v5/v6` con `buf`) no aplica al uso que hace el
SDK. Revisar cuando el SDK publique una versión con `uuid` actualizado.

## 7. Topes de tiempo en splash y chat

Si `resolveSession` o el montaje del chat de Quick tardan mucho (arranque en frío tras un despliegue,
red lenta), el usuario ve un spinner sin salida. Propuesta: 15 s en el splash para caer a la landing
con aviso, y 20 s en el chat para mostrar el estado de error con "Reintentar". Observado el
2026-09-28 en el primer login tras publicar; los logs del servidor mostraron el login completo, así
que fue percepción de cuelgue, no fallo.

## 8. Cambios de formato sin commitear

`ruff format` y `terraform fmt -recursive` reformatearon archivos que no eran parte de ningún cambio
funcional (`etl/glue/flatten_invoices.py`, `scripts/*.py`, `quicksight*.tf`, `.terraform.lock.hcl`).
Quedaron en el árbol de trabajo sin commit para no mezclarlos. Revisar el diff, confirmar que es solo
formato y commitearlos en un commit `style:` propio.
