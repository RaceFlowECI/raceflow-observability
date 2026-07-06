# Laboratorio de Observabilidad — RaceFlow

> Documento maestro del stack de observabilidad implementado en los microservicios RaceFlow.
> Cubre las 8 tareas del laboratorio: métricas, logs, trazas, stack Docker, dashboard,
> alertas, simulación de incidente y esta documentación.

---

## Tabla de contenido

- [Arquitectura](#arquitectura)
- [Tarea 1 — Métricas de negocio (Micrometer)](#tarea-1--métricas-de-negocio-micrometer)
- [Tarea 2 — Logs estructurados (Logstash)](#tarea-2--logs-estructurados-logstash)
- [Tarea 3 — Trazas distribuidas (OpenTelemetry)](#tarea-3--trazas-distribuidas-opentelemetry)
- [Tarea 4 — Stack Docker Compose](#tarea-4--stack-docker-compose)
- [Tarea 5 — Dashboard Grafana](#tarea-5--dashboard-grafana)
- [Tarea 6 — Alertas](#tarea-6--alertas)
- [Tarea 7 — Simulación de incidente](#tarea-7--simulación-de-incidente)
- [Guía de uso rápido](#guía-de-uso-rápido)
- [Referencia de puertos](#referencia-de-puertos)

---

## Arquitectura

```
┌─────────────────────────────────────────────────────────────────────┐
│                        RaceFlow — Microservicios                    │
│                                                                     │
│  api-gateway :8080   auth-service :8081   room-service :8082        │
│  realtime :8083      session :8084        metrics :8085             │
│                                                                     │
│  Cada servicio expone:                                              │
│   • /actuator/prometheus  ← métricas Micrometer                    │
│   • logs/  (JSON via LogstashEncoder)                              │
│   • -javaagent: opentelemetry-javaagent.jar  (3 servicios)         │
└──────────────┬──────────────────────────┬───────────────┬──────────┘
               │ scrape /actuator/prom     │ tail logs/    │ OTLP gRPC
               ▼                          ▼               ▼
        ┌─────────────┐          ┌──────────────┐  ┌───────────┐
        │ Prometheus  │          │   Promtail   │  │   Tempo   │
        │  :9090      │          │              │  │  :4317    │
        └──────┬──────┘          └──────┬───────┘  └─────┬─────┘
               │ rules.yml               │ push           │
               ▼                          ▼               │
        ┌─────────────┐          ┌──────────────┐         │
        │Alertmanager │          │    Loki      │         │
        │  :9093      │          │   :3100      │         │
        └──────┬──────┘          └──────┬───────┘         │
               │ webhook                 │                 │
               ▼                         └────────┬────────┘
        localhost:5001                            ▼
        (webhook-receiver)               ┌──────────────┐
                                         │   Grafana    │
                                         │   :3000      │
                                         │  dashboard + │
                                         │  alerting    │
                                         └──────────────┘
```

### Repositorios

| Repositorio | Rama principal | Contenido |
|---|---|---|
| `raceflow-api-gateway` | develop | Spring Boot 3.2.5, puerto 8080 |
| `raceflow-auth-service` | develop | Spring Boot 3.2.5, puerto 8081 |
| `raceflow-room-service` | develop | Spring Boot 3.2.5, puerto 8082 |
| `raceflow-realtime-service` | develop | Spring Boot 3.2.5, puerto 8083 |
| `raceflow-session-service` | develop | Spring Boot 3.2.5, puerto 8084 |
| `raceflow-metrics-service` | develop | Spring Boot 3.2.5, puerto 8085 |
| `raceflow-observability` | develop | Este repo — stack Docker Compose |

---

## Tarea 1 — Métricas de negocio (Micrometer)

### Qué se hizo

Se agregó **Spring Boot Actuator** y **Micrometer** a los 6 microservicios para exponer
métricas en `/actuator/prometheus`. Cada servicio implementa una clase `*Metrics`
inyectada con `MeterRegistry` que registra métricas de dominio específicas.

### Dependencias añadidas (`pom.xml`)

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

### Configuración (`application.yml`)

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  endpoint:
    prometheus:
      enabled: true
  metrics:
    tags:
      application: ${spring.application.name}
      environment: local
```

### Métricas por servicio

#### `raceflow-realtime-service` (más crítico — SLO p99 ≤ 1 s)

| Métrica | Tipo | Descripción |
|---|---|---|
| `raceflow_websocket_connections_active` | Gauge | Conexiones WebSocket activas |
| `raceflow_positions_received_total` | Counter | Posiciones GPS procesadas |
| `raceflow_positions_rejected_total{reason}` | Counter | Rechazadas (invalid_jump / out_of_bounds / malformed) |
| `raceflow_ranking_updates_total` | Counter | Actualizaciones de ranking computadas |
| `raceflow_ranking_update_duration_seconds` | Timer (p50/p95/**p99**) | **SLO p99 ≤ 1 s** |
| `raceflow_reactions_sent_total` | Counter | Reacciones enviadas a clientes |
| `raceflow_redis_write_duration_seconds` | Timer | Latencia de escritura en Redis |

#### Otros servicios

| Servicio | Métrica clave |
|---|---|
| `auth-service` | `raceflow_auth_registrations_total`, `raceflow_auth_login_failures_total`, `raceflow_auth_active_tokens` |
| `room-service` | `raceflow_rooms_created_total`, `raceflow_rooms_active`, `raceflow_rooms_join_attempts_total{result}` |
| `session-service` | `raceflow_sessions_persisted_total`, `raceflow_sessions_persistence_lag_seconds` |
| `metrics-service` | `raceflow_events_consumed_total{event_type}`, `raceflow_kpi_computation_duration_seconds` |

### Verificación

```bash
curl -s http://localhost:8083/actuator/prometheus | grep raceflow_
```

---

## Tarea 2 — Logs estructurados (Logstash)

### Qué se hizo

Se configuró **`logstash-logback-encoder:7.4`** para emitir logs en formato JSON
tanto a consola como a archivo rotativo. Esto permite ingestión directa por Promtail → Loki.

### Dependencia (`pom.xml`)

```xml
<dependency>
    <groupId>net.logstash.logback</groupId>
    <artifactId>logstash-logback-encoder</artifactId>
    <version>7.4</version>
</dependency>
```

### Configuración (`logback-spring.xml`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <springProperty scope="local" name="appName"
                  source="spring.application.name"
                  defaultValue="raceflow-service"/>

  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LogstashEncoder"/>
  </appender>

  <appender name="FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
    <file>logs/${appName}.log</file>
    <encoder class="net.logstash.logback.encoder.LogstashEncoder"/>
    <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
      <fileNamePattern>logs/${appName}.%d{yyyy-MM-dd}.log</fileNamePattern>
      <maxHistory>7</maxHistory>
    </rollingPolicy>
  </appender>

  <root level="INFO">
    <appender-ref ref="CONSOLE"/>
    <appender-ref ref="FILE"/>
  </root>
</configuration>
```

### Estructura de un log entry

```json
{
  "@timestamp": "2026-07-06T10:00:00.000-05:00",
  "@version":   "1",
  "message":    "Ranking updated for race abc123",
  "logger_name":"edu.eci.arsw.raceflow.realtime.service.RankingService",
  "thread_name":"http-nio-8083-exec-3",
  "level":      "INFO",
  "level_value": 20000
}
```

### Archivos generados

```
logs/raceflow-realtime-service.log            ← activo
logs/raceflow-realtime-service.2026-07-06.log ← rotado por fecha
```

### Consulta en Loki

```logql
{service="raceflow-realtime-service"} | json | level="ERROR"
{env="local"} |= "rankingUpdate"
```

---

## Tarea 3 — Trazas distribuidas (OpenTelemetry)

### Qué se hizo

Se adjuntó el **OpenTelemetry Java Agent v2.3.0** a los 3 servicios del flujo crítico
de tiempo real mediante un Dockerfile multi-stage. No hubo cambios en el código fuente.

### Servicios instrumentados

| Servicio | Puerto | Motivo |
|---|---|---|
| `raceflow-api-gateway` | 8080 | Punto de entrada — todas las trazas empiezan aquí |
| `raceflow-room-service` | 8082 | Gestión de partidas — parte del flujo crítico |
| `raceflow-realtime-service` | 8083 | WebSocket + ranking — flujo más sensible a latencia |

> `auth-service`, `session-service` y `metrics-service` NO tienen el agente.

### Dockerfile (multi-stage)

```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn package -DskipTests

FROM eclipse-temurin:21-jre-jammy AS otel-agent
ARG OTEL_VERSION=2.3.0
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_VERSION}/opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
COPY --from=otel-agent /otel/opentelemetry-javaagent.jar opentelemetry-javaagent.jar
EXPOSE <port>
ENTRYPOINT ["java", "-javaagent:opentelemetry-javaagent.jar", "-jar", "app.jar"]
```

### Variables de entorno (`.env.example`)

```env
OTEL_SERVICE_NAME=raceflow-realtime-service
OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=none
OTEL_LOGS_EXPORTER=none
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=local
```

### Explorar trazas en Grafana

1. Grafana → **Explore** → datasource **Tempo**
2. Buscar por **Service Name**: `raceflow-api-gateway`
3. Seleccionar un trace → ver spans de servicios downstream
4. Desde un log en Loki con `traceId`, clic en el link → abre el trace en Tempo

---

## Tarea 4 — Stack Docker Compose

### Estructura del repo

```
raceflow-observability/
├── docker-compose.yml
└── observability/
    ├── prometheus/
    │   ├── prometheus.yml      # scrape 6 servicios via host.docker.internal
    │   └── rules.yml           # 3 reglas de alerta
    ├── loki/
    │   └── loki-config.yml     # tsdb v13, filesystem storage
    ├── promtail/
    │   └── promtail-config.yml # pipeline JSON, 6 jobs
    ├── tempo/
    │   └── tempo-config.yml    # OTLP gRPC :4317 + HTTP :4318
    ├── alertmanager/
    │   └── alertmanager.yml    # rutas critical/warning, webhook
    └── grafana/
        ├── provisioning/
        │   ├── datasources/    # Prometheus + Loki + Tempo
        │   ├── dashboards/     # provider config
        │   └── alerting/       # contact points, policy, rules
        └── dashboards/
            └── raceflow-overview.json
```

### Pre-requisitos de directorio

Los repos deben estar clonados como **hermanos**:

```
Proyecto/
├── raceflow-observability/    ← docker compose up -d desde aquí
├── raceflow-api-gateway/
├── raceflow-auth-service/
├── raceflow-room-service/
├── raceflow-realtime-service/
├── raceflow-session-service/
└── raceflow-metrics-service/
```

### Servicios y versiones

| Servicio | Imagen | Puerto(s) | Rol |
|---|---|---|---|
| Prometheus | `prom/prometheus:v2.51.0` | 9090 | Scraping y evaluación de reglas |
| Grafana | `grafana/grafana:10.4.0` | 3000 | Dashboards y alerting |
| Loki | `grafana/loki:2.9.4` | 3100 | Almacenamiento de logs |
| Promtail | `grafana/promtail:2.9.4` | — | Recolección de logs JSON |
| Tempo | `grafana/tempo:2.4.0` | 3200, 4317, 4318 | Backend de trazas OTLP |
| Alertmanager | `prom/alertmanager:v0.27.0` | 9093 | Enrutamiento de alertas |

---

## Tarea 5 — Dashboard Grafana

El dashboard **`RaceFlow — Vista General`** (uid: `raceflow-overview`) se provisiona
automáticamente en la carpeta **RaceFlow** al levantar el stack.

### Los 9 paneles

| # | Título | Tipo | Query principal |
|---|---|---|---|
| 1 | Servicios en línea | Stat 🟢/🔴 | `sum(up{job=~"raceflow-.*"})` |
| 2 | Requests / s total | Stat | `sum(rate(http_server_requests_seconds_count[5m]))` |
| 3 | Tasa de errores 5xx | Stat (rojo ≥5%) | ratio 5xx/total |
| 4 | Conexiones WebSocket | Stat (rojo ≥1000) | `raceflow_websocket_connections_active` |
| 5 | Posiciones GPS / s | Stat | `rate(raceflow_positions_received_total[5m])` |
| 6 | Ranking p99 (SLO) | Stat (rojo ≥1s) | `histogram_quantile(0.99, ...)` |
| 7 | Estado por servicio | TimeSeries | `up{job=~"raceflow-.*"}` por job |
| 8 | HTTP req/s por servicio | TimeSeries | rate agrupado por job |
| 9 | Latencia ranking p50·p95·p99 | TimeSeries | 3 quantiles + línea SLO 1s |

> El panel 6 usa umbrales de color: verde < 0.7 s · amarillo 0.7–1.0 s · rojo ≥ 1.0 s.
> El panel 9 muestra p99 en rojo grueso y la línea SLO en naranja punteado.

---

## Tarea 6 — Alertas

### Pipeline completo

```
Prometheus  ──►  Alertmanager :9093  ──►  webhook :5001
    │                                          │
    │  (rules.yml)                    scripts/webhook-receiver.js
    │
    └──►  Grafana Alerting  ──►  contact-points.yml  ──►  mismo webhook
```

### Las 3 reglas de alerta

#### 1. `RaceFlowServiceDown` — critical

```promql
up{job=~"raceflow-.*"} == 0
```

- **for:** 1 minuto
- **Significado:** un scrape fallido sostenido — el servicio está caído o inaccesible.
- **Acción:** verificar logs del contenedor, reiniciar el servicio.

#### 2. `RaceFlowHighErrorRate` — warning

```promql
sum by (job) (rate(http_server_requests_seconds_count{status=~"5..",job=~"raceflow-.*"}[5m]))
/ sum by (job) (rate(http_server_requests_seconds_count{job=~"raceflow-.*"}[5m]))
> 0.05
```

- **for:** 2 minutos
- **Significado:** más del 5% de respuestas son 5xx.
- **Acción:** revisar logs de errores en Loki, verificar dependencias (BD, Redis).

#### 3. `RaceFlowRankingLatencyHigh` — critical

```promql
histogram_quantile(0.99,
  rate(raceflow_ranking_update_duration_seconds_bucket[5m])) > 1.0
```

- **for:** 3 minutos
- **SLO:** p99 ≤ 1 segundo
- **Acción:** revisar latencia de Redis, saturación de CPU en realtime-service.

### Alertmanager — rutas

| Severidad | group_wait | repeat_interval | Receptor |
|---|---|---|---|
| critical | 10 s | 1 h | RaceFlow Webhook |
| warning | 30 s | 1 h | RaceFlow Webhook |

### Receptor de demo

```bash
# Terminal separado antes de levantar el stack
node scripts/webhook-receiver.js
# Escucha en http://localhost:5001/alert
# Loggea cada alerta recibida con status, severidad y summary
```

---

## Tarea 7 — Simulación de incidente

### Objetivo

Demostrar el ciclo completo de detección → notificación → resolución del SLO
`RaceFlowRankingLatencyHigh` usando el endpoint de simulación del servicio de tiempo real.

### Componentes

**`SimulationController`** en `raceflow-realtime-service`:

```
POST /api/simulate/slow-ranking?delayMs=1500&count=30
  → registra 30 observaciones con Thread.sleep(1500 ms)
  → el p99 supera 1 s en la primera ventana de 5 min
  → la alerta dispara a los 3 min sostenidos

POST /api/simulate/stop
GET  /api/simulate/status
```

### Ejecutar el drill completo

```bash
# Paso 1 — levantar el stack
docker compose up -d
bash scripts/verify-stack.sh

# Paso 2 — receptor de alertas (terminal separado)
node scripts/webhook-receiver.js

# Paso 3 — ejecutar simulación (~8 minutos total)
bash scripts/simulate-incident.sh
```

### Línea de tiempo esperada

| t | Evento |
|---|---|
| 0:00 | `simulate-incident.sh` inicia — llamada a `/api/simulate/slow-ranking` |
| 0:00 | `realtime-service` empieza a registrar observaciones de 1.5 s cada 3 s |
| ~1:00 | `histogram_quantile(0.99, ...)` supera 1.0 s en Prometheus |
| ~1:00 | Alerta pasa a estado **pending** (Prometheus + Grafana) |
| ~4:00 | Alerta **firing** — `for: 3m` cumplido |
| ~4:00 | Alertmanager envía webhook → `webhook-receiver.js` imprime la notificación |
| ~5:00 | `simulate-incident.sh` detiene la simulación |
| ~10:00 | p99 vuelve a < 1 s (ventana de 5 min se "limpia") |
| ~10:00 | Alerta **resolved** — segundo webhook recibido |

### Evidencia capturada

```
evidence/<timestamp>/
├── 01_simulation_start.json      ← respuesta del endpoint
├── check_1_p99.json  ..          ← p99 cada minuto
├── check_3_alerts.json           ← primer check con alerta firing
├── final_p50.json / p95 / p99    ← valores al final del incidente
├── final_prometheus_alert.json   ← ALERTS{alertname="..."} desde Prometheus
├── final_alertmanager.json       ← payload completo de Alertmanager
└── final_stop.json               ← confirmación de parada
```

Completar `evidence/INCIDENT_REPORT_TEMPLATE.md` con los valores reales obtenidos.

---

## Guía de uso rápido

### 1. Levantar el stack

```bash
cd raceflow-observability
docker compose up -d
docker compose ps          # verificar que todos estén "running"
bash scripts/verify-stack.sh
```

### 2. Acceder a las UIs

| Herramienta | URL | Credenciales |
|---|---|---|
| **Grafana** | http://localhost:3000 | admin / raceflow2026 |
| **Prometheus** | http://localhost:9090 | — |
| **Alertmanager** | http://localhost:9093 | — |
| **Loki** (ready) | http://localhost:3100/ready | — |
| **Tempo** (ready) | http://localhost:3200/ready | — |

### 3. Ver el dashboard

```
Grafana → Dashboards → carpeta "RaceFlow" → "RaceFlow — Vista General"
```

### 4. Consultar logs en Loki

```
Grafana → Explore → datasource: Loki
```

```logql
{service="raceflow-realtime-service"} | json | level="ERROR"
{env="local"} | json | message =~ "ranking.*"
```

### 5. Consultar trazas en Tempo

```
Grafana → Explore → datasource: Tempo → Search
Service Name: raceflow-api-gateway
```

### 6. Queries PromQL útiles

```promql
-- Servicios activos
sum(up{job=~"raceflow-.*"})

-- Ranking p99 en tiempo real
histogram_quantile(0.99, rate(raceflow_ranking_update_duration_seconds_bucket[5m]))

-- Error rate por servicio
sum by (job) (rate(http_server_requests_seconds_count{status=~"5..",job=~"raceflow-.*"}[5m]))
/ sum by (job) (rate(http_server_requests_seconds_count{job=~"raceflow-.*"}[5m]))

-- Conexiones WebSocket activas
sum(raceflow_websocket_connections_active)

-- Alertas actualmente disparadas
ALERTS{alertname=~"RaceFlow.*", alertstate="firing"}
```

### 7. Detener el stack

```bash
docker compose down          # detiene y elimina contenedores (datos persisten en volúmenes)
docker compose down -v       # además elimina volúmenes (reset completo)
```

---

## Referencia de puertos

| Servicio | Puerto host | Protocolo |
|---|---|---|
| raceflow-api-gateway | 8080 | HTTP |
| raceflow-auth-service | 8081 | HTTP |
| raceflow-room-service | 8082 | HTTP |
| raceflow-realtime-service | 8083 | HTTP + WebSocket |
| raceflow-session-service | 8084 | HTTP |
| raceflow-metrics-service | 8085 | HTTP |
| Prometheus | 9090 | HTTP |
| Grafana | 3000 | HTTP |
| Loki | 3100 | HTTP |
| Tempo HTTP API | 3200 | HTTP |
| Tempo OTLP gRPC | 4317 | gRPC |
| Tempo OTLP HTTP | 4318 | HTTP |
| Alertmanager | 9093 | HTTP |
| webhook-receiver (demo) | 5001 | HTTP |

---

*Generado el 2026-07-06. Laboratorio de Observabilidad — RaceFlow / ECI ARSW.*
