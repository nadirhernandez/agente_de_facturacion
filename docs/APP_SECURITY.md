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

Aplican tanto al piloto como al módulo por cliente (`modules/tenant/app.tf`):

- Registro público deshabilitado: solo usuarios invitados.
- API Gateway exige JWT de Cognito en **todas** las rutas. No hay ruta anónima.
- Lambda permite exclusivamente las experiencias `dashboard` y `chat`.
- Cada URL de embedding dura 60 minutos.
- Bucket del frontend privado, servido solo por CloudFront con OAC.
- Permisos de la Lambda acotados al namespace `default` y a los datasets del cliente.

## Identidad del usuario: la diferencia entre piloto y módulo

La Lambda resuelve la identidad de QuickSight por el claim `email` del token.

| | Piloto (`application.tf`) | Módulo (`modules/tenant/app.tf`) |
|---|---|---|
| Usuario sin identidad propia de QuickSight | Hereda `FALLBACK_QUICKSIGHT_USER_ARN`, que es el administrador | Recibe 403 |
| Aprovisionamiento | Manual | `aws_quicksight_user` por cada correo de `app_users` |

**La variable de reserva es un escalamiento de privilegios, no una comodidad.** En el piloto sigue
puesta y hay que quitarla antes de dar acceso a usuarios reales. En el módulo no existe, y
`verify_tenant.sh` falla si aparece.

## Antes de masificar

1. **Row-Level Security** por región, cartera o cliente. En el modelo de cuenta por cliente el
   aislamiento es la cuenta, así que solo hace falta si se comparte una cuenta entre áreas.
2. **Rate limits y WAF.** Hoy solo hay throttling de etapa en API Gateway: 50 req/s con ráfaga de 20.
3. **Auditoría de accesos y políticas de retención.**
4. **Dominio propio y certificado ACM.** Ya soportado por el módulo con `app_domain_aliases` y
   `app_certificate_arn`; falta ejercitarlo en una cuenta real.

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

El pool está en tier **PLUS**, requerido por threat protection (`AdvancedSecurityMode = AUDIT`).
Managed Login solo necesita **ESSENTIALS**. Si se quiere reducir el costo por usuario activo,
`var.cognito_user_pool_tier = "ESSENTIALS"` implica desactivar threat protection. `LITE` no sirve:
no tiene Managed Login v2.

### Rol de QuickSight de los usuarios

El chat con los datos requiere un rol **Pro** (`READER_PRO` por defecto en `var.app_user_role`).
Con `READER` la app autentica y muestra el dashboard, pero la pestaña de chat no funciona.
