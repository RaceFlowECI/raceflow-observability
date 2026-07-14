# Despliegue en Azure Container Instances

Corre el mismo stack de `../../observability/` (Prometheus, Grafana, Loki,
Tempo, Alertmanager) como un container group público en ACI, apuntando
Prometheus a los 6 microservicios reales desplegados en Azure App Service
(no a instancias locales).

**No corre 24/7 por diseño.** ACI cobra por segundo mientras el container
group exista. Créalo antes de necesitarlo (sustentación, demo) y bórralo
después — ver comandos abajo.

## Por qué esta carpeta y no `observability/` directamente

Tres archivos difieren de sus equivalentes en docker-compose porque ACI
no tiene DNS entre contenedores (todos comparten `localhost`, a
diferencia de docker-compose que resuelve por nombre de servicio):

| Archivo aquí | Reemplaza a | Diferencia |
|---|---|---|
| `prometheus.yml` | `../../observability/prometheus/prometheus.yml` | `alertmanager:9093` → `localhost:9093`; se quitan los jobs `-local` (`host.docker.internal` no existe en ACI) |
| `datasources.yml` | `../../observability/grafana/provisioning/datasources/datasources.yml` | `http://prometheus:9090` etc. → `http://localhost:9090` |
| `tempo-config.yml` | `../../observability/tempo/tempo-config.yml` | se quitan 2 campos que la imagen de Tempo en ACI rechazó (ver comentario en el archivo) |

El resto de la config (`rules.yml`, `alertmanager.yml`, `loki-config.yml`,
dashboards, provisioning de alerting) se reutiliza tal cual desde
`../../observability/`.

## Desplegar

Requiere Azure CLI logueado con acceso a la subscripción del curso.

```bash
RG=rg-raceflow-lab
LOCATION=mexicocentral
STORAGE=raceflowobsstorage

# 1. Registrar providers (solo la primera vez)
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.ContainerInstance

# 2. Storage account + file shares (solo la primera vez -- si ya existen, saltar)
az storage account create --name $STORAGE --resource-group $RG --location $LOCATION \
  --sku Standard_LRS --kind StorageV2 --https-only true

KEY=$(az storage account keys list --account-name $STORAGE --resource-group $RG --query "[0].value" -o tsv)

for share in prometheus-config loki-config tempo-config alertmanager-config \
             grafana-provisioning grafana-dashboards grafana-data \
             prometheus-data loki-data tempo-data; do
  az storage share create --name "$share" --account-name $STORAGE --account-key "$KEY"
done

az storage directory create --name alerting    --share-name grafana-provisioning --account-name $STORAGE --account-key "$KEY"
az storage directory create --name dashboards  --share-name grafana-provisioning --account-name $STORAGE --account-key "$KEY"
az storage directory create --name datasources --share-name grafana-provisioning --account-name $STORAGE --account-key "$KEY"

# 3. Subir configs (repetir cada vez que cambie algo en observability/ o deploy/aci/)
az storage file upload --share-name prometheus-config    --source ../../observability/prometheus/rules.yml       --path rules.yml                    --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name prometheus-config    --source prometheus.yml                                 --path prometheus.yml               --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name loki-config          --source ../../observability/loki/loki-config.yml       --path local-config.yaml            --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name tempo-config         --source tempo-config.yml                                --path tempo-config.yml             --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name alertmanager-config  --source ../../observability/alertmanager/alertmanager.yml --path alertmanager.yml           --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name grafana-provisioning --source ../../observability/grafana/provisioning/alerting/alert-rules.yml        --path alerting/alert-rules.yml        --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name grafana-provisioning --source ../../observability/grafana/provisioning/alerting/contact-points.yml     --path alerting/contact-points.yml     --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name grafana-provisioning --source ../../observability/grafana/provisioning/alerting/notification-policy.yml --path alerting/notification-policy.yml --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name grafana-provisioning --source ../../observability/grafana/provisioning/dashboards/dashboards.yml        --path dashboards/dashboards.yml       --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name grafana-provisioning --source datasources.yml                                                            --path datasources/datasources.yml     --account-name $STORAGE --account-key "$KEY"
az storage file upload --share-name grafana-dashboards   --source ../../observability/grafana/dashboards/raceflow-overview.json              --path raceflow-overview.json          --account-name $STORAGE --account-key "$KEY"

# 4. Elegir una contraseña de admin de Grafana (esta instancia es publica,
#    no reutilizar la de docker-compose/raceflow2026)
read -s -p "Grafana admin password: " GRAFANA_PASSWORD

# 5. Generar el manifest real (con la key y el password) sin commitear el resultado
sed -e "s/<STORAGE_ACCOUNT_KEY>/$KEY/g" -e "s/<GRAFANA_ADMIN_PASSWORD>/$GRAFANA_PASSWORD/g" \
  container-group.yml > /tmp/container-group-real.yml

# 6. Desplegar
az container create --resource-group $RG --file /tmp/container-group-real.yml

# 7. Borrar el manifest con las credenciales en texto plano
rm /tmp/container-group-real.yml
```

## Verificar

```bash
az container show --resource-group rg-raceflow-lab --name raceflow-observability \
  --query "containers[].{name:name, state:instanceView.currentState.state}" -o table

curl http://raceflow-observability.mexicocentral.azurecontainer.io:9090/api/v1/targets
```

## Acceso

| UI | URL | Credenciales |
|---|---|---|
| Grafana | http://raceflow-observability.mexicocentral.azurecontainer.io:3000 | admin / la que elegiste en el paso 4 |
| Prometheus | http://raceflow-observability.mexicocentral.azurecontainer.io:9090 | — |
| Alertmanager | http://raceflow-observability.mexicocentral.azurecontainer.io:9093 | — |

**Nota:** Prometheus y Alertmanager quedan expuestos sin autenticacion en
esta config (igual que en local). Aceptable para una demo de duracion
corta; si se deja el container group corriendo por mas tiempo, restringir
`ipAddress.ports` o ponerlos detras de un proxy con auth.

## Apagar / borrar

Solo el container group (mantiene los file shares con la config, barato dejarlos):

```bash
az container delete --resource-group rg-raceflow-lab --name raceflow-observability --yes
```

Para redesplegar después, repetir solo los pasos 4-5 (los shares y configs ya existen).

Para borrar todo, incluyendo el storage account:

```bash
az container delete --resource-group rg-raceflow-lab --name raceflow-observability --yes
az storage account delete --name raceflowobsstorage --resource-group rg-raceflow-lab --yes
```

## Nota sobre Alertmanager

El receiver de Alertmanager (`../../observability/alertmanager/alertmanager.yml`)
apunta a `http://host.docker.internal:5001/alert`, un webhook local de
`scripts/webhook-receiver.js` pensado solo para la demo local. En este
despliegue esa URL no es alcanzable, así que las notificaciones de alerta
fallarán en el log de Alertmanager (no afecta a Prometheus/Grafana/las
reglas en sí, que funcionan igual). No es necesario resolverlo para la
sustentación; si se quiere una notificación real en la nube, cambiar el
receiver por Slack/email/PagerDuty.
