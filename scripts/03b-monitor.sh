#!/usr/bin/env bash
# =============================================================================
# 03b-monitor.sh
# -----------------------------------------------------------------------------
# Painel de monitoramento para COLETAR EVIDÊNCIAS durante o teste de carga.
# Roda em loop mostrando HPA, Pods e uso de CPU (kubectl top) a cada 5s.
# Faça prints/gravação desta tela nas fases ANTES / DURANTE / DEPOIS.
#
# Uso (em um terminal separado):  bash scripts/03b-monitor.sh
# Encerrar: Ctrl+C
# =============================================================================
set -uo pipefail

while true; do
  clear
  echo "============================================================"
  echo " MONITOR HPA  -  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "============================================================"
  echo
  echo "### HorizontalPodAutoscaler ###"
  kubectl get hpa php-apache || true
  echo
  echo "### Pods (réplicas atuais) ###"
  kubectl get pods -l app=php-apache -o wide || true
  echo
  echo "### Uso de CPU/Memória por Pod (metrics-server) ###"
  kubectl top pods -l app=php-apache 2>/dev/null || echo "(metrics ainda coletando...)"
  echo
  echo "Atualiza a cada 5s. Ctrl+C para sair."
  sleep 5
done
