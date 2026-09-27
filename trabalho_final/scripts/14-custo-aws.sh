#!/usr/bin/env bash
# =============================================================================
# 14-custo-aws.sh - apura o custo REAL da campanha na AWS, por servico.
# -----------------------------------------------------------------------------
# POR QUE EXISTE: o trabalho intermediario reportou o custo do experimento como
# uma estimativa ("entre US$ 0,10 e US$ 0,15"), derivada da tabela de precos e
# do tempo de cluster ligado. Aqui o numero vem do proprio Cost Explorer da
# conta -- e, como a conta estava comprovadamente zerada antes da campanha
# (ver dados/limpeza/), o custo do periodo E o custo do experimento.
#
# ATENCAO: o Cost Explorer tem atraso de ate ~24 h para consolidar. Rodar este
# script logo apos destruir o cluster tende a subestimar; rode novamente no dia
# seguinte para o numero definitivo.
#
# Uso:  bash scripts/14-custo-aws.sh [data_inicio] [data_fim]
#       datas em AAAA-MM-DD; o padrao cobre de ontem ate amanha.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh

AWS_PROFILE="${AWS_PROFILE:-psi5120}"
export AWS_PROFILE

INICIO="${1:-$(date -u -d 'yesterday' '+%Y-%m-%d')}"
FIM="${2:-$(date -u -d 'tomorrow' '+%Y-%m-%d')}"

DIR="dados/custo"
mkdir -p "$DIR"
SAIDA="${DIR}/custo-${INICIO}_a_${FIM}.txt"

exigir_ferramentas aws

{
  echo "# Custo da campanha na AWS"
  echo "apurado_em: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "periodo: ${INICIO} ate ${FIM} (fim exclusivo)"
  echo "perfil: ${AWS_PROFILE}"
  echo "conta: $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  echo
  echo "## total do periodo"
  aws ce get-cost-and-usage \
    --time-period "Start=${INICIO},End=${FIM}" \
    --granularity MONTHLY --metrics UnblendedCost \
    --query "ResultsByTime[].Total.UnblendedCost.[Amount,Unit]" \
    --output text 2>&1
  echo
  echo "## por servico (apenas valores nao nulos)"
  aws ce get-cost-and-usage \
    --time-period "Start=${INICIO},End=${FIM}" \
    --granularity MONTHLY --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query "ResultsByTime[].Groups[?Metrics.UnblendedCost.Amount!='0'].[Keys[0],Metrics.UnblendedCost.Amount]" \
    --output text 2>&1
  echo
  echo "## por dia"
  aws ce get-cost-and-usage \
    --time-period "Start=${INICIO},End=${FIM}" \
    --granularity DAILY --metrics UnblendedCost \
    --query "ResultsByTime[].[TimePeriod.Start,Total.UnblendedCost.Amount]" \
    --output text 2>&1
} | tee "$SAIDA"

echo
log "Custo salvo em ${SAIDA}"
log "Lembre-se do atraso de consolidacao: reexecute amanha para o valor definitivo."
