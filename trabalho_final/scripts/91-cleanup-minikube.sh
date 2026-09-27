#!/usr/bin/env bash
# =============================================================================
# 91-cleanup-minikube.sh - remove os objetos e destroi o cluster local.
#
# Uso:  bash scripts/91-cleanup-minikube.sh        # so remove os objetos
#       bash scripts/91-cleanup-minikube.sh full   # destroi o cluster tambem
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh

MODO="${1:-objetos}"

log "Removendo o gerador de carga e os objetos da aplicacao..."
kubectl delete pod load-generator --now --ignore-not-found 2>/dev/null
kubectl delete -f manifests/php-apache-hpa.yaml --ignore-not-found 2>/dev/null
kubectl delete -f manifests/php-apache-service.yaml --ignore-not-found 2>/dev/null
kubectl delete -f manifests/php-apache-deployment.yaml --ignore-not-found 2>/dev/null

if [ "$MODO" = "full" ]; then
  log "Destruindo o cluster Minikube..."
  minikube delete
  log "Cluster local removido."
else
  log "Objetos removidos. O cluster continua de pe."
  log "Para destrui-lo tambem: bash scripts/91-cleanup-minikube.sh full"
fi
