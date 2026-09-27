#!/usr/bin/env bash
# =============================================================================
# 00-preflight.sh - verifica tudo que a campanha precisa ANTES de gastar tempo
#                   (e dinheiro) criando cluster.
#
# Uso:  bash scripts/00-preflight.sh
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh

AWS_PROFILE="${AWS_PROFILE:-psi5120}"
export AWS_PROFILE

falhas=0
verifica() {
  local rotulo="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [ ok ] %s\n' "$rotulo"
  else
    printf '  [FALHA] %s\n' "$rotulo"
    falhas=$(( falhas + 1 ))
  fi
}

echo "== Ferramentas =="
for c in kubectl minikube eksctl aws docker date sed awk; do
  verifica "$c" command -v "$c"
done

echo
echo "== Versoes =="
printf '  kubectl : %s\n' "$(kubectl version --client -o yaml 2>/dev/null | sed -n 's/.*gitVersion: //p' | head -1)"
printf '  minikube: %s\n' "$(minikube version --short 2>/dev/null)"
printf '  eksctl  : %s\n' "$(eksctl version 2>/dev/null)"
printf '  aws     : %s\n' "$(aws --version 2>&1 | head -1)"

echo
echo "== Docker (driver do Minikube) =="
if timeout 60 docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
  printf '  [ ok ] engine ativo: %s\n' "$(docker info --format '{{.ServerVersion}} | {{.NCPU}} vCPU | {{.MemTotal}} B' 2>/dev/null)"
else
  printf '  [FALHA] Docker Desktop nao esta respondendo (inicie-o antes da campanha local)\n'
  falhas=$(( falhas + 1 ))
fi

echo
echo "== Credenciais AWS (perfil ${AWS_PROFILE}) =="
if ident=$(timeout 60 aws sts get-caller-identity --output text --query '[Account,Arn]' 2>/dev/null); then
  printf '  [ ok ] %s\n' "$ident"
  printf '  regiao: %s\n' "$(aws configure get region)"
else
  printf '  [FALHA] credenciais AWS indisponiveis para o perfil %s\n' "$AWS_PROFILE"
  falhas=$(( falhas + 1 ))
fi

echo
echo "== Python (analise estatistica) =="
# A analise usa apenas a biblioteca padrao do Python -- sem numpy/scipy --
# justamente para nao depender de instalacao de pacotes na maquina do aluno.
# Atencao: no Windows existe um "python3" no PATH que e apenas o atalho da
# Microsoft Store -- ele responde a 'command -v' mas nao executa nada. Por isso
# o teste e executar codigo de verdade, nao apenas localizar o binario.
if python3 -c 'print("ok")' >/dev/null 2>&1; then
  printf '  [ ok ] python3 nativo: %s\n' "$(python3 --version 2>&1)"
elif wsl.exe -e python3 --version >/dev/null 2>&1; then
  printf '  [ ok ] python3 via WSL: %s\n' "$(wsl.exe -e python3 --version 2>&1 | tr -d '\0\r')"
else
  printf '  [FALHA] nenhum python3 disponivel (nativo ou WSL)\n'
  falhas=$(( falhas + 1 ))
fi

echo
if [ "$falhas" -eq 0 ]; then
  echo "TUDO PRONTO. Proximo passo: bash scripts/01-minikube-up.sh"
else
  echo "${falhas} verificacao(oes) falharam - corrija antes de iniciar a campanha."
  exit 1
fi
