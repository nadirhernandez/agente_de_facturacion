# Terraform — ambiente de desarrollo

Esta configuración inicial está bloqueada intencionalmente para:

- Perfil AWS CLI: `dashboards-dev-infile`
- Cuenta AWS: `503561412084` (`dev-infile`)
- Región: `us-east-1`
- Terraform CLI: `1.16.4`
- AWS provider: `6.60.0`

No contiene recursos ni backend remoto todavía. El siguiente paso será inicializar el proveedor y verificar que Terraform rechace cualquier cuenta distinta a `dev-infile`.

## Comandos previstos

```bash
aws sso login --profile dashboards-dev-infile
terraform -chdir=infrastructure/terraform init
terraform -chdir=infrastructure/terraform plan
```

No ejecutar `apply` hasta que el plan haya sido revisado y aprobado.
