# raceflow-observability

Stack de observabilidad completo para RaceFlow usando Docker Compose.

## Componentes

| Servicio | Puerto | Rol |
|---|---|---|
| Prometheus | 9090 | Scraping de metricas (/actuator/prometheus) |
| Grafana | 3000 | Dashboards — admin / raceflow2026 |
| Loki | 3100 | Almacenamiento de logs |
| Promtail | — | Recoleccion de logs JSON desde los servicios |
| Tempo | 3200 / 4317 / 4318 | Backend de trazas OTLP |

## Alcance: local y produccion

Prometheus scrapea **dos copias de cada uno de los 6 servicios**:

- `raceflow-<servicio>` — instancia local (`host.docker.internal:8080-8085`),
  solo activa si corres los servicios con `mvn spring-boot:run`.
- `raceflow-<servicio>-prod` — la app real desplegada en Azure App
  Service, scrapeada directo por HTTPS (`/actuator/prometheus` es un
  endpoint publico en cada App Service, no requiere VNet). Se distinguen
  con el label `env="prod"`.

Las 3 alertas (`up{job=~"raceflow-.*"}`) cubren ambas automaticamente,
sin distincion — si la produccion cae, alerta igual que si cae tu local.

## Despliegue en la nube (Azure Container Instances)

Ademas de `docker compose up` en tu maquina, este stack se puede
desplegar como container group publico en ACI, apuntando unicamente a
los 6 servicios de produccion (sin necesitar nada corriendo en local).
Pensado para prender antes de una demo/sustentacion y borrar despues,
no para dejarlo corriendo 24/7 — ver **[`deploy/aci/README.md`](deploy/aci/README.md)**
para los comandos de despliegue, verificacion y limpieza.

## Pre-requisitos

- Docker Desktop (Windows/Mac) con `host.docker.internal` habilitado
- Los seis microservicios corriendo en los puertos 8080-8085 (opcional —
  solo necesario para ver datos en los jobs `-local`; los jobs `-prod`
  funcionan sin nada corriendo en tu maquina)
- Los repos clonados como **hermanos** de este directorio:

```
Proyecto/
├── raceflow-observability/   <- este repo
├── raceflow-api-gateway/
├── raceflow-auth-service/
├── raceflow-room-service/
├── raceflow-realtime-service/
├── raceflow-session-service/
└── raceflow-metrics-service/
```

## Levantar el stack

```bash
cd raceflow-observability
docker compose up -d
docker compose ps
```

## Acceso

| UI | URL | Credenciales |
|---|---|---|
| Grafana | http://localhost:3000 | admin / raceflow2026 |
| Prometheus | http://localhost:9090 | — |
| Loki (ready) | http://localhost:3100/ready | — |
| Tempo (ready) | http://localhost:3200/ready | — |

## Verificar metricas

```bash
# Targets activos
open http://localhost:9090/targets

# Query rapida
curl -s "http://localhost:9090/api/v1/query?query=up{job=~'raceflow-.*'}" | jq .
```

## Logs en Loki (LogQL)

```logql
{service="raceflow-realtime-service"} | json | level="ERROR"
{env="local"} |= "rankingUpdate"
```

## Alertas

| Alerta | Condicion | Severidad |
|---|---|---|
| RaceFlowServiceDown | up == 0 por 1 min | critical |
| RaceFlowHighErrorRate | HTTP 5xx > 5% por 2 min | warning |
| RaceFlowRankingLatencyHigh | ranking p99 > 1s por 3 min | critical |

## Estructura

```
raceflow-observability/
├── docker-compose.yml
└── observability/
    ├── prometheus/
    │   ├── prometheus.yml    # scrape 6 servicios local (host.docker.internal) + 6 prod (Azure HTTPS)
    │   └── rules.yml         # 3 alertas (ServiceDown, HighErrorRate, RankingLatencyHigh)
    ├── loki/
    │   └── loki-config.yml   # filesystem, tsdb v13
    ├── promtail/
    │   └── promtail-config.yml  # pipeline JSON LogstashEncoder, 6 servicios
    ├── tempo/
    │   └── tempo-config.yml  # OTLP gRPC :4317 + HTTP :4318, 72h retention
    └── grafana/
        └── provisioning/
            └── datasources/
                └── datasources.yml  # Prometheus + Loki + Tempo preconfigured
```

