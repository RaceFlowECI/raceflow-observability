#!/usr/bin/env bash
# Verificación rápida del stack — ejecutar tras docker compose up -d
set -euo pipefail

PROM="http://localhost:9090"
GRAF="http://localhost:3000"
LOKI="http://localhost:3100"
TEMPO="http://localhost:3200"
AM="http://localhost:9093"

ok()  { echo "  [OK]   $*"; }
fail(){ echo "  [FAIL] $*"; }
chk() { curl -sf "$1" > /dev/null 2>&1 && ok "$2" || fail "$2"; }

echo ""
echo "=== Stack RaceFlow Observabilidad ==="
echo ""
echo "Servicios:"
chk "$PROM/-/healthy"   "Prometheus"
chk "$GRAF/api/health"  "Grafana"
chk "$LOKI/ready"       "Loki"
chk "$TEMPO/ready"      "Tempo"
chk "$AM/-/healthy"     "Alertmanager"

echo ""
echo "Datasources Grafana:"
curl -sf -u admin:raceflow2026 "$GRAF/api/datasources" 2>/dev/null \
  | jq -r '.[].name | "  " + .' || echo "  (no disponible)"

echo ""
echo "Targets Prometheus:"
curl -sf "$PROM/api/v1/targets" 2>/dev/null \
  | jq -r '.data.activeTargets[] | "  [\(.health)] \(.labels.job) \(.scrapeUrl)"' \
  || echo "  (no disponible)"

echo ""
echo "=== Listo ===" 
