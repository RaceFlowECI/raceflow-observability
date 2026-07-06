# Reporte de Incidente — RaceFlowRankingLatencyHigh

**Fecha:**  YYYY-MM-DD
**Hora inicio:** HH:MM COT
**Duración:** ~X minutos
**Severidad:** Critical

---

## Resumen ejecutivo

El percentil 99 de `raceflow_ranking_update_duration_seconds` superó el SLO de
1 segundo durante X minutos, disparando la alerta `RaceFlowRankingLatencyHigh`.
Servicio afectado: **raceflow-realtime-service** (:8083).

---

## Línea de tiempo

| Hora | Evento |
|---|---|
| HH:MM | p99 supera 1 s por primera vez |
| HH:MM+1 | Alerta pasa a `pending` (Prometheus/Grafana) |
| HH:MM+4 | Alerta **firing** (`for: 3m` cumplido) |
| HH:MM+4 | Webhook recibe notificación |
| HH:MM+X | Simulación detenida — `POST /api/simulate/stop` |
| HH:MM+X+5 | p99 regresa a < 1 s |
| HH:MM+X+5 | Alerta **resolved** |

---

## Evidencia métrica

### Percentiles durante el incidente

```
p50  = X.XXX s
p95  = X.XXX s
p99  = X.XXX s  ← SLO BREACH (threshold: 1.000 s)
```

### PromQL

```promql
-- p99 en tiempo real
histogram_quantile(0.99, rate(raceflow_ranking_update_duration_seconds_bucket[5m]))

-- Alerta activa
ALERTS{alertname="RaceFlowRankingLatencyHigh"}

-- Histograma completo
raceflow_ranking_update_duration_seconds_bucket
```

---

## Causa raíz

**Simulada** — `POST /api/simulate/slow-ranking?delayMs=1500&count=30`
en `raceflow-realtime-service` → `Thread.sleep(1500)` en cada observación del timer.

**Causa real hipotética:** contención en Redis al procesar posiciones de múltiples
corredores en paralelo, incrementando la latencia de escritura más allá del budget de 1 s.

---

## Impacto

| Métrica | Normal | Durante incidente |
|---|---|---|
| ranking p99 | < 0.3 s | > 1.5 s |
| ranking p50 | < 0.1 s | ~1.5 s |
| Alertas disparadas | 0 | 1 critical |
| Servicio caído | No | No (latencia alta, no caída) |

---

## Remediación

1. Revisar slowlog de Redis (`redis-cli slowlog get 10`)
2. Implementar pipeline de escritura en Redis (batch updates)
3. Ajustar el pool de conexiones Redis
4. Considerar caching del ranking entre actualizaciones

---

## Archivos de evidencia

```
evidence/<timestamp>/
├── 01_simulation_start.json
├── check_1_p99.json  ..  check_5_p99.json
├── check_3_alerts.json   ← primer check con alerta activa
├── final_p50.json
├── final_p95.json
├── final_p99.json
├── final_prometheus_alert.json
├── final_alertmanager.json
└── final_stop.json
```

> Adjuntar screenshots de Grafana: panel "Ranking latencia p99" y
> sección Alerting → RaceFlowRankingLatencyHigh en estado Firing.