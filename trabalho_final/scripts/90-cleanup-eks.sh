#!/usr/bin/env bash
# =============================================================================
# 90-cleanup-eks.sh - DESTROI o cluster EKS e verifica se nao sobrou nada pago.
# -----------------------------------------------------------------------------
# Alem do 'eksctl delete cluster', este script CONFERE o resultado: lista
# clusters EKS, stacks do CloudFormation, instancias EC2 e NAT gateways que
# ainda existam na regiao. O trabalho intermediario mostrou que a verificacao
# explicita e necessaria -- o eksctl provisiona recursos cobrados a parte.
#
# Uso:  bash scripts/90-cleanup-eks.sh
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh

CLUSTER_NAME="${CLUSTER_NAME:-hpa-final}"
REGION="${REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-psi5120}"
export AWS_PROFILE

DIR="dados/limpeza"
mkdir -p "$DIR"
SAIDA="${DIR}/verificacao-$(date -u '+%Y%m%dT%H%M%SZ').log"

log "Removendo os objetos da aplicacao..."
kubectl delete -f manifests/php-apache-hpa.yaml --ignore-not-found 2>/dev/null
kubectl delete -f manifests/php-apache-service.yaml --ignore-not-found 2>/dev/null
kubectl delete -f manifests/php-apache-deployment.yaml --ignore-not-found 2>/dev/null
kubectl delete pod load-generator --now --ignore-not-found 2>/dev/null

log "Destruindo o cluster EKS '${CLUSTER_NAME}' (~10-15 min)..."
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${REGION}" --wait

log "Verificando o que restou na regiao ${REGION}..."
{
  echo "# Verificacao pos-destruicao - $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "perfil: ${AWS_PROFILE} | regiao: ${REGION} | cluster: ${CLUSTER_NAME}"
  echo
  echo "## clusters EKS remanescentes"
  aws eks list-clusters --region "$REGION" --output text 2>&1
  echo
  echo "## stacks CloudFormation com 'eksctl' no nome"
  aws cloudformation list-stacks --region "$REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED ROLLBACK_COMPLETE \
    --query "StackSummaries[?contains(StackName,'eksctl')].[StackName,StackStatus]" \
    --output text 2>&1
  echo
  echo "## instancias EC2 ativas"
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name]" \
    --output text 2>&1
  echo
  echo "## NAT gateways ativos"
  aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=state,Values=pending,available" \
    --query "NatGateways[].[NatGatewayId,State]" --output text 2>&1
  echo
  echo "## volumes EBS disponiveis (orfaos)"
  aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=status,Values=available" \
    --query "Volumes[].[VolumeId,Size,State]" --output text 2>&1
  echo
  echo "## enderecos IP elasticos alocados"
  aws ec2 describe-addresses --region "$REGION" \
    --query "Addresses[].[PublicIp,AssociationId]" --output text 2>&1
} | tee "$SAIDA"

echo
log "Verificacao salva em ${SAIDA}"
log "Saidas vazias (ou 'None') nas secoes acima significam que nada ficou orfao."
