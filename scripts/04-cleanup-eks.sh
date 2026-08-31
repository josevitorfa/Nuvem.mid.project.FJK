#!/usr/bin/env bash
# =============================================================================
# 04-cleanup-eks.sh
# -----------------------------------------------------------------------------
# DESTRÓI o cluster EKS e todos os recursos criados pelo eksctl (VPC, node
# group, control plane). ESSENCIAL para não continuar sendo cobrado pela AWS.
#
# Uso:  bash scripts/04-cleanup-eks.sh
# =============================================================================
set -euo pipefail

CLUSTER_NAME="hpa-nuvem"
REGION="us-east-1"

# Mesmo perfil usado em 02-eks-setup.sh (veja o comentário lá).
AWS_PROFILE="${AWS_PROFILE:-}"
if [ -n "$AWS_PROFILE" ]; then
  export AWS_PROFILE
  echo ">> Usando o perfil AWS: ${AWS_PROFILE}"
fi

echo ">> Removendo os objetos da aplicação (opcional, o delete do cluster já apaga tudo)..."
kubectl delete -f manifests/php-apache-hpa.yaml --ignore-not-found
kubectl delete -f manifests/php-apache-service.yaml --ignore-not-found
kubectl delete -f manifests/php-apache-deployment.yaml --ignore-not-found

echo ">> Destruindo o cluster EKS '${CLUSTER_NAME}' (pode levar ~10-15 min)..."
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${REGION}"

echo ">> Cluster removido. Confira no console da AWS se não restou nenhum recurso (EC2/EKS/CloudFormation)."
