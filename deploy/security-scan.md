# Validación de infraestructura y seguridad (IaC)

Adaptación de la categoria "Infraestructura" del taller de pruebas (que
propone Terraform validate + Checkov) a como RaceFlow realmente despliega:
**no usa Terraform** -- el despliegue en Azure se hace con `az` CLI directo
(App Service, Container Instances) y manifiestos YAML (`deploy/aci/`,
`docker-compose.yml`). Checkov sí aplica igual: soporta escaneo de secretos
en cualquier tipo de archivo, independientemente del framework de IaC.

## Qué se corrió

```bash
pip install checkov
checkov -d . --framework secrets
```

`checkov -d deploy/aci` (los checks estructurales, no de secretos) no
reporta nada porque el formato de manifiesto de Azure Container Instances
no es un framework de IaC que Checkov reconozca (a diferencia de Terraform,
CloudFormation, ARM clásico o Kubernetes) -- el scanner de **secretos**, en
cambio, es agnóstico al formato y sí corre sobre estos archivos.

## Resultado real

```
secrets scan results:
Passed checks: 0, Failed checks: 1, Skipped checks: 0

Check: CKV_SECRET_6: "Base64 High Entropy String"
    FAILED for resource: c25dda7f1b017a3407edc343cbbb637a3e57275a
    File: /docker-compose.yml:45-46
```

## Análisis y decisión

El hallazgo es real: `docker-compose.yml` tiene `GF_SECURITY_ADMIN_PASSWORD:
raceflow2026` en texto plano. **Riesgo aceptado, no corregido**, porque:

- `docker-compose.yml` es exclusivamente para desarrollo local -- nunca se
  despliega a un entorno público, y Grafana ahí solo escucha en
  `localhost:3000` de la máquina del desarrollador.
- El manifiesto que **sí** se despliega públicamente
  (`deploy/aci/container-group.yml`) fue diseñado desde el principio sin
  este problema: `GF_SECURITY_ADMIN_PASSWORD` es un placeholder
  `<GRAFANA_ADMIN_PASSWORD>` sustituido en tiempo de despliegue, nunca
  comiteado (ver `deploy/aci/README.md`).

Esto es exactamente el tipo de decisión que una revisión de seguridad real
debe documentar: no todo hallazgo se corrige, pero todo hallazgo debe
quedar evaluado y con una razón explícita por la que se acepta o se
corrige -- no simplemente ignorado en silencio.

## CI

`.github/workflows/iac-security-scan.yml` corre este mismo escaneo de
secretos en cada push/PR a este repo, para que un nuevo secreto hardcodeado
(por ejemplo, en un futuro `deploy/gcp/` o `deploy/aws/`) se detecte antes
de mergear, no después.
