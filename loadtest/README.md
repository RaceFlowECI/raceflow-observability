# Prueba de carga (k6)

`raceflow-load-test.js` ejercita el flujo real del producto -- registro,
login, creación de sala, lectura de estado -- a través del API Gateway, con
usuarios virtuales concurrentes en rampas (10 → 25 → 0 en 80s).

## Umbrales

| Umbral | Valor | Justificación |
|---|---|---|
| `http_req_failed` | < 5% | mismo presupuesto de error que la alerta `RaceFlowHighErrorRate` |
| `http_req_duration` (p95, general) | < 800ms | latencia aceptable end-to-end |
| `http_req_duration{endpoint:createRoom}` (p99) | < 1000ms | mismo SLO que `raceflow_ranking_update_duration_seconds` (p99 ≤ 1s) monitoreado en Grafana/Prometheus |

## Ejecutar

Contra la app desplegada en Azure:

```bash
BASE_URL=https://raceflow-gateway-g8csc0dfh0dxhcax.mexicocentral-01.azurewebsites.net \
  k6 run raceflow-load-test.js
```

Contra el stack local (`docker-compose.dev.yml` + los 6 servicios corriendo con `mvn spring-boot:run`):

```bash
BASE_URL=http://localhost:8080 k6 run raceflow-load-test.js
```

## Ver la corrida en vivo en Grafana

`docker-compose.yml` levanta Prometheus con `--web.enable-remote-write-receiver`,
así que k6 puede escribirle sus métricas directamente mientras corre la prueba
(VUs, `http_req_duration`, `http_req_failed`, `http_reqs`, en tiempo real, no
solo el resumen final de la terminal):

```bash
K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
BASE_URL=https://raceflow-gateway-g8csc0dfh0dxhcax.mexicocentral-01.azurewebsites.net \
  k6 run -o experimental-prometheus-rw raceflow-load-test.js
```

Luego, en Grafana (`http://localhost:3000`, `admin` / `raceflow2026`):

1. Importar el dashboard oficial de k6 para Prometheus: **Dashboards → New →
   Import**, ID `19665` (fuente de datos: `Prometheus`).
2. Abrirlo *antes* de lanzar `k6 run` -- los paneles se llenan en vivo con la
   rampa de VUs mientras corre.
3. Para correlacionar con el resto del sistema, tener also abierto "RaceFlow —
   Vista General" en otra pestaña: la subida de `Requests/s` y `Ranking
   latencia p99` en ese dashboard debe coincidir en el tiempo con la rampa de
   VUs del dashboard de k6 -- es la evidencia visual de que la carga generada
   realmente está llegando al sistema.

## Correlación con el dashboard de Grafana

Mientras corre la prueba, observar en el dashboard "RaceFlow — Vista General"
(`raceflow-observability`):

- **Requests/s (total)** y **Tasa de errores 5xx** deben reflejar la rampa de VUs.
- **Ranking latencia p99** es el panel que directamente valida el umbral
  `p(99)<1000` de este script -- si el script pasa pero este panel sube por
  encima de 1s, es evidencia de que la carga generada por k6 (que no incluye
  tráfico WebSocket real de posiciones GPS) no está ejercitando la misma ruta
  de código que la alerta protege; en ese caso hay que complementar con un
  script k6 sobre el endpoint WebSocket, no solo REST.
