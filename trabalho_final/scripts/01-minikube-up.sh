#!/usr/bin/env bash
# =============================================================================
# 01-minikube-up.sh - AMBIENTE LOCAL: sobe o Minikube e aplica os manifestos.
# -----------------------------------------------------------------------------
# Os parametros de criacao do cluster sao DELIBERADAMENTE identicos aos do
# trabalho intermediario (--cpus=2 --memory=4096), inclusive sabendo que o
# driver Docker Desktop NAO os aplica ao no. Manter o comando identico preserva
# a comparabilidade com as execucoes E1/E2 ja publicadas; a capacidade que o no
# de fato oferece e lida do cluster e registrada em dados/minikube/ambiente.txt.
#
# Uso:  bash scripts/01-minikube-up.sh
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh

log "[1/5] Iniciando o cluster Minikube..."
minikube start --driver=docker --cpus=2 --memory=4096

log "[2/5] Habilitando o addon metrics-server (o HPA depende dele)..."
minikube addons enable metrics-server

log "[3/5] Aguardando o metrics-server..."
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

# Verificacao que o trabalho intermediario mostrou ser a correta: o Deployment
# estar saudavel nao garante que a Metrics API esteja servindo dados.
log "      validando a Metrics API..."
kubectl get apiservice v1beta1.metrics.k8s.io

log "[4/5] Aplicando Deployment, Service e HPA..."
kubectl apply -f manifests/php-apache-deployment.yaml
kubectl apply -f manifests/php-apache-service.yaml
kubectl apply -f manifests/php-apache-hpa.yaml
kubectl rollout status deployment/php-apache --timeout=180s

log "[5/5] Estado inicial:"
kubectl get nodes -o wide
kubectl get deployment php-apache
kubectl get hpa php-apache

echo
log "Cluster local pronto."
log "O HPA leva ate ~4 min para sair de '<unknown>/50%' (primeira coleta do Metrics Server)."
log "Proximo passo: bash scripts/10-run-campaign.sh minikube 20"
