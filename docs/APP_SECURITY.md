# Capa de aplicación segura

## Regla principal

El navegador no puede llamar a `GenerateEmbedUrlForRegisteredUser` ni recibir credenciales AWS. Solo una Lambda autenticada genera URLs temporales para QuickSight/Amazon Quick.

## Componentes

```text
Usuario → Cognito → CloudFront (React)
                       ↓
                API Gateway con JWT
                       ↓
              Lambda embedding API
                       ↓
       GenerateEmbedUrlForRegisteredUser
                       ↓
       QuickSight Dashboard / Amazon Quick chat
```

## Controles vigentes

Aplican tanto al piloto (`application.tf`) como al módulo por cliente (`modules/tenant/app.tf`):

- API Gateway exige JWT de Cognito (audiencia + emisor) en **todas** las rutas. No hay ruta anónima.
- La Lambda solo acepta un token con `email_verified = true` y permite exclusivamente las
  experiencias `dashboard` y `chat`.
- Cada URL de embedding dura 60 minutos y solo se abre desde los dominios de `ALLOWED_DOMAINS`.
- Bucket del frontend privado, servido solo por CloudFront con OAC, detrás de WAF
  (`waf.tf`: reglas administradas de AWS + límite de 1000 req/5 min por IP).
- Cabeceras HSTS, `X-Content-Type-Options`, `X-Frame-Options: DENY` y `Referrer-Policy`. La CSP
  está redactada pero no se entrega (`enforce_csp = false`); ver [`DEUDA_TECNICA.md`](DEUDA_TECNICA.md).
- Cognito en tier PLUS con threat protection `ENFORCED`, MFA TOTP opcional, contraseñas de 12+
  caracteres, protección contra borrado y revocación de tokens.
- Permisos de la Lambda acotados al namespace `default`, al dashboard y a los datasets del cliente.
- Throttling de etapa en API Gateway: 50 req/s con ráfaga de 20.
- Logs de acceso y de la Lambda identifican al usuario por `sub` o por hash del correo, nunca por
  el correo en claro.

Solo en el módulo por cliente:

- Registro público deshabilitado (`allow_admin_create_user_only = true`): solo usuarios invitados.
- Identidad de QuickSight por persona (`aws_quicksight_user` por cada correo de `app_users`).

## Identidad del usuario: la diferencia entre piloto y módulo

La Lambda resuelve la identidad de QuickSight por el claim `email` del token.

| | Piloto (`application.tf`) | Módulo (`modules/tenant/app.tf`) |
|---|---|---|
| Registro | Público: cualquier correo verificable (`ALLOW_ANY_EMAIL` en el trigger pre sign-up) | Solo invitados |
| Identidad de QuickSight | Compartida: todos embeben como `SHARED_QUICKSIGHT_USER_ARN` (el administrador) | Propia; sin usuario de QuickSight → 403 |
| Aprovisionamiento | Ninguno | `aws_quicksight_user` por cada correo de `app_users` |

En modo compartido la Lambda desactiva `StatePersistence` del dashboard y el chat se monta con
`enablePrivateMode` y `showChatHistory: false`, para que los filtros y conversaciones de una
persona no aparezcan a otra. El log `Embed URL issued` (con `sub` y hash del correo) es el único
registro de quién estuvo detrás de cada sesión.

### Riesgo aceptado para el piloto

> **Estado (2026-09-28):** el piloto queda con registro público e identidad compartida. El
> propietario del proyecto acepta este riesgo de forma explícita mientras la aplicación sirva
> solo para demostración con datos sintéticos.

Lo que implica:

- Cualquier persona que verifique un correo puede entrar y usar el dashboard y el chat con los
  permisos del administrador de QuickSight.
- No hay aislamiento entre personas más allá del modo privado del chat.
- Los datos expuestos son los sintéticos de `data/`, sin información real.

Condiciones para retirar el riesgo antes de cargar datos reales o abrir a usuarios externos:

1. En `cognito_signup.tf`, quitar `ALLOW_ANY_EMAIL` y poner los dominios permitidos en
   `ALLOWED_EMAIL_DOMAINS`; o pasar a `allow_admin_create_user_only = true`.
2. En `application.tf`, eliminar `SHARED_QUICKSIGHT_USER_ARN` y crear un `aws_quicksight_user`
   por persona (el módulo ya lo hace). El código de la Lambda no cambia: sin la variable resuelve
   la identidad por correo y devuelve 403 a quien no tenga usuario.
3. Volver a llenar `ALLOWED_EMAIL_DOMAINS` en la Lambda como segunda barrera.

`verify_tenant.sh` ya falla si un tenant tiene la variable compartida, así que el módulo no puede
heredar esta configuración por accidente.

## Antes de masificar

1. **Row-Level Security** por región, cartera o cliente. En el modelo de cuenta por cliente el
   aislamiento es la cuenta, así que solo hace falta si se comparte una cuenta entre áreas.
2. **CSP en modo enforce** tras una sesión de pruebas con login real (`enforce_csp = true` en el
   piloto, `content_security_policy_enforced` en el módulo). Detalle en `DEUDA_TECNICA.md`.
3. **Logs de acceso de S3 y CloudFront**, y políticas de retención.
4. **Dominio propio y certificado ACM.** Permite subir `minimum_protocol_version` de `TLSv1` a
   `TLSv1.2_2021`. Ya soportado por el módulo con `app_domain_aliases` y `app_certificate_arn`;
   falta ejercitarlo en una cuenta real.
5. **Quitar `localhost:5173`** de CORS, callbacks de Cognito y `AllowedDomains` en despliegues
   que no sean de desarrollo (`enable_local_dev_origin` en `identity.tf`).

## Experiencia de login

La app no implementa su propio formulario de contraseña. Usa el **Managed Login v2** de Cognito
(`managed_login_version = 2` en el dominio), que es la experiencia actual de AWS y reemplaza la
Hosted UI clásica.

```text
App (React) → /oauth2/authorize con PKCE → Managed Login → /oauth2/token → id_token
```

Ventajas de no construir el formulario nosotros:

- Las contraseñas nunca pasan por nuestro código ni por nuestro dominio.
- MFA, bloqueo por intentos, recuperación de contraseña y threat protection los gestiona Cognito.
- El cliente es público sin secreto; PKCE evita interceptación del código de autorización.

### Personalizar la marca

En el piloto, `aws_cognito_managed_login_branding` usa `use_cognito_provided_values = true`. En el
módulo se controla con `var.app_branding`: un documento `settings` de Managed Login más los archivos
en base64.

```hcl
app_branding = {
  settings_json = file("branding/managed-login.json")
  assets = [{
    category   = "FORM_LOGO"
    color_mode = "LIGHT"
    extension  = "PNG"
    bytes      = filebase64("branding/logo.png")
  }]
}
```

Sin esa variable, el login queda con los valores por defecto de AWS.

### Nota de costo

El pool está en tier **PLUS**, requerido por threat protection (`advanced_security_mode = "ENFORCED"`).
Managed Login solo necesita **ESSENTIALS**. Si se quiere reducir el costo por usuario activo,
`var.cognito_user_pool_tier = "ESSENTIALS"` implica desactivar threat protection. `LITE` no sirve:
no tiene Managed Login v2.

### Rol de QuickSight de los usuarios

El chat con los datos requiere un rol **Pro** (`READER_PRO` por defecto en `var.app_user_role`).
Con `READER` la app autentica y muestra el dashboard, pero la pestaña de chat no funciona.
