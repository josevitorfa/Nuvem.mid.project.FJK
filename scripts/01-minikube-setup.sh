#!/usr/bin/env bash
# =============================================================================
# 01-minikube-setup.sh
# -----------------------------------------------------------------------------
# IMPLANTAÇÃO A (LOCAL): sobe o cluster Minikube, habilita o Metrics Server e
# aplica os manifestos (Deployment + Service + HPA).
#
# Pré-requisitos: docker (ou outro driver), minikube e kubectl instalados.
# Uso:  bash scripts/01-minikube-setup.sh
# =============================================================================
set -euo pipefail   # -e: aborta no primeiro erro | -u: erro em variável não definida | -o pipefail: erro em pipes

echo ">> [1/5] Iniciando o cluster Minikube..."
# --driver=docker é o mais portátil. Ajuste cpus/memória conforme sua máquina.
minikube start --driver=docker --cpus=2 --memory=4096

echo ">> [2/5] Habilitando o addon metrics-server (necessário para o HPA)..."
minikube addons enable metrics-server

echo ">> [3/5] Aguardando o metrics-server ficar pronto..."
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

echo ">> [4/5] Aplicando os manifestos (Deployment, Service e HPA)..."
kubectl apply -f manifests/php-apache-deployment.yaml
kubectl apply -f manifests/php-apache-service.yaml
kubectl apply -f manifests/php-apache-hpa.yaml

echo ">> [5/5] Aguardando o Deployment ficar disponível..."
kubectl rollout status deployment/php-apache --timeout=180s

echo
echo ">> Estado inicial do cluster (EVIDÊNCIA 'ANTES'):"
kubectl get deployment php-apache
kubectl get pods -l app=php-apache
kubectl get hpa php-apache
echo
echo ">> Pronto! Cluster Minikube configurado."
echo ">> Dica: em outro terminal rode 'kubectl get hpa php-apache --watch' antes do teste de carga."
