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

## Pre-requisitos

- Docker Desktop (Windows/Mac) con `host.docker.internal` habilitado
- Los seis microservicios corriendo en los puertos 8080-8085
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
    │   ├── prometheus.yml    # scrape 6 servicios via host.docker.internal
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

