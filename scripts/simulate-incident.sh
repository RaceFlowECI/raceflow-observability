#!/usr/bin/env bash
# ============================================================
# Simulación de incidente RaceFlow — Tarea 7
# Pre-requisitos:
#   1. docker compose up -d
#   2. raceflow-realtime-service en :8083 (con feature/incident-simulation)
#   3. node scripts/webhook-receiver.js  (otro terminal)
#   4. jq instalado
# ============================================================
set -euo pipefail

REALTIME_URL="http://localhost:8083"
PROMETHEUS_URL="http://localhost:9090"
ALERTMANAGER_URL="http://localhost:9093"
DELAY_MS=1500
COUNT=30
EVIDENCE_DIR="evidence/$(date +%Y%m%d_%H%M%S)"

mkdir -p "$EVIDENCE_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }

query_prom() {
  curl -s "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$1" \
    | jq -r '.data.result[]? | "  \(.metric | to_entries | map("\(.key)=\(.value)") | join(" "))  value=\(.value[1])"' 2>/dev/null \
    || echo "  (sin datos aun)"
}

# ── 1. Estado inicial ────────────────────────────────────────────
log "=== ESTADO INICIAL ==="
log "Servicios activos:"
query_prom 'up{job=~"raceflow-.*"}'

log "Ranking p99 antes del incidente:"
query_prom 'histogram_quantile(0.99, rate(raceflow_ranking_update_duration_seconds_bucket[5m]))'

# ── 2. Disparar la simulación ────────────────────────────────────
log ""
log "=== INICIANDO SIMULACIÓN ==="
log "Parametros: delayMs=$DELAY_MS count=$COUNT"
log "Duracion estimada: $((COUNT * 3)) s (~$((COUNT * 3 / 60)) min)"

RESPONSE=$(curl -s -X POST \
  "$REALTIME_URL/api/simulate/slow-ranking?delayMs=$DELAY_MS&count=$COUNT")
echo "$RESPONSE" | jq . || echo "$RESPONSE"
echo "$RESPONSE" > "$EVIDENCE_DIR/01_simulation_start.json"
log "Respuesta guardada en $EVIDENCE_DIR/01_simulation_start.json"

# ── 3. Monitoreo cada 60 s ───────────────────────────────────────
log ""
log "=== MONITOREO (esperar ~3 min para que dispare la alerta) ==="

for i in 1 2 3 4 5; do
  log "--- Check $i/5 (t+${i}m) ---"
  sleep 60

  P99=$(curl -s "$PROMETHEUS_URL/api/v1/query" \
    --data-urlencode 'query=histogram_quantile(0.99, rate(raceflow_ranking_update_duration_seconds_bucket[5m]))' \
    | jq -r '.data.result[0]?.value[1] // "N/A"')
  log "ranking p99 = ${P99} s  (SLO = 1.0 s)"

  ALERTS=$(curl -s "$ALERTMANAGER_URL/api/v2/alerts?active=true" 2>/dev/null \
    | jq -r '.[]? | "  [\(.labels.severity)] \(.labels.alertname) — \(.annotations.summary)"' \
    || echo "  (Alertmanager no disponible)")
  log "Alertas activas:"
  echo "$ALERTS"

  curl -s "$PROMETHEUS_URL/api/v1/query" \
    --data-urlencode 'query=histogram_quantile(0.99, rate(raceflow_ranking_update_duration_seconds_bucket[5m]))' \
    > "$EVIDENCE_DIR/check_${i}_p99.json"

  curl -s "$ALERTMANAGER_URL/api/v2/alerts?active=true" \
    > "$EVIDENCE_DIR/check_${i}_alerts.json" 2>/dev/null || true
done

# ── 4. Evidencia final ───────────────────────────────────────────
log ""
log "=== CAPTURANDO EVIDENCIA FINAL ==="

for PERCENTILE in 50 95 99; do
  curl -s "$PROMETHEUS_URL/api/v1/query" \
    --data-urlencode "query=histogram_quantile(0.${PERCENTILE}, rate(raceflow_ranking_update_duration_seconds_bucket[5m]))" \
    > "$EVIDENCE_DIR/final_p${PERCENTILE}.json"
done

curl -s "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=ALERTS{alertname="RaceFlowRankingLatencyHigh"}' \
  > "$EVIDENCE_DIR/final_prometheus_alert.json"

curl -s "$ALERTMANAGER_URL/api/v2/alerts?active=true" \
  > "$EVIDENCE_DIR/final_alertmanager.json" 2>/dev/null || true

log "p50 = $(jq -r '.data.result[0]?.value[1] // "N/A"' "$EVIDENCE_DIR/final_p50.json") s"
log "p95 = $(jq -r '.data.result[0]?.value[1] // "N/A"' "$EVIDENCE_DIR/final_p95.json") s"
log "p99 = $(jq -r '.data.result[0]?.value[1] // "N/A"' "$EVIDENCE_DIR/final_p99.json") s  (SLO = 1.0 s)"

# ── 5. Detener simulación ────────────────────────────────────────
log ""
log "=== DETENIENDO SIMULACIÓN ==="
curl -s -X POST "$REALTIME_URL/api/simulate/stop" | jq . | tee "$EVIDENCE_DIR/final_stop.json"

log ""
log "Evidencia en: $EVIDENCE_DIR/"
ls -lh "$EVIDENCE_DIR/"

log ""
log "Grafana:"
log "  http://localhost:3000  → RaceFlow → panel Ranking latencia p99"
log "  http://localhost:3000/alerting/list → RaceFlowRankingLatencyHigh"
log "  http://localhost:9093  → Alertmanager → alertas activas"
log ""
log "=== SIMULACIÓN COMPLETA ==="
