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
