#!/usr/bin/env bash
# =============================================================================
# 05-cleanup-minikube.sh
# -----------------------------------------------------------------------------
# Remove a aplicação e (opcionalmente) apaga o cluster Minikube local.
#
# Uso:  bash scripts/05-cleanup-minikube.sh
# =============================================================================
set -euo pipefail

echo ">> Removendo os objetos da aplicação..."
kubectl delete -f manifests/php-apache-hpa.yaml --ignore-not-found
kubectl delete -f manifests/php-apache-service.yaml --ignore-not-found
kubectl delete -f manifests/php-apache-deployment.yaml --ignore-not-found

echo ">> Deseja apagar TODO o cluster Minikube? (recursos locais não geram custo)"
echo "   Se quiser apagar, rode manualmente:  minikube delete"
echo ">> Limpeza da aplicação concluída."
