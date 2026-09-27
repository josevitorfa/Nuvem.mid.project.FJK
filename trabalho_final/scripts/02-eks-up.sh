#!/usr/bin/env bash
# =============================================================================
# 02-eks-up.sh - AMBIENTE DE NUVEM: cria o cluster EKS e aplica os manifestos.
# -----------------------------------------------------------------------------
# Topologia identica a do trabalho intermediario (2 x t3.small, us-east-1,
# node group gerenciado) para que a comparacao entre as campanhas seja legitima.
#
# CUSTOS: control plane US$ 0,10/h + 2 x t3.small + NAT gateway. Uma campanha
# de 20 repeticoes mantem o cluster vivo por cerca de 2,5 h. DESTRUA ao final
# com scripts/90-cleanup-eks.sh.
#
# Uso:  bash scripts/02-eks-up.sh
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh

CLUSTER_NAME="${CLUSTER_NAME:-hpa-final}"
REGION="${REGION:-us-east-1}"
NODE_TYPE="${NODE_TYPE:-t3.small}"
NODES="${NODES:-2}"
AWS_PROFILE="${AWS_PROFILE:-psi5120}"
export AWS_PROFILE

log "[0/5] Identidade AWS (perfil ${AWS_PROFILE}) antes de criar recursos pagos:"
aws sts get-caller-identity

log "[1/5] Criando o cluster EKS '${CLUSTER_NAME}' (~15-20 min)..."
eksctl create cluster \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --nodegroup-name "workers" \
  --node-type "${NODE_TYPE}" \
  --nodes "${NODES}" \
  --managed

log "[2/5] Apontando o kubectl para o EKS..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

# -----------------------------------------------------------------------------
# Metrics Server: desde o eksctl 0.230 ele vem como ADDON GERENCIADO. Aplicar o
# manifesto do SIG por cima quebra o cluster de forma silenciosa (o Deployment e
# rejeitado por selector imutavel, mas o Service e sobrescrito com um seletor
# que nao casa com os Pods do addon, deixando a APIService sem endpoints e o HPA
# preso em <unknown>). Esse foi um dos achados do trabalho intermediario; aqui o
# script so instala o manifesto se o addon realmente nao existir.
# -----------------------------------------------------------------------------
log "[3/5] Garantindo o Metrics Server..."
if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  log "      addon gerenciado ja presente; o manifesto do SIG NAO sera aplicado."
else
  log "      addon ausente; aplicando o manifesto oficial do SIG..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
fi
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
log "      validando a Metrics API (verificacao que realmente importa):"
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
log "Cluster EKS pronto."
log "Proximo passo: bash scripts/10-run-campaign.sh eks 20"
log "LEMBRETE: ao terminar, bash scripts/90-cleanup-eks.sh (o cluster e cobrado por hora)."
