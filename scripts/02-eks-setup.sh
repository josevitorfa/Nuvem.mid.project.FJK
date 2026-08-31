#!/usr/bin/env bash
# =============================================================================
# 02-eks-setup.sh
# -----------------------------------------------------------------------------
# IMPLANTAÇÃO B (NUVEM): cria um cluster gerenciado na AWS EKS com eksctl,
# instala o Metrics Server e aplica os mesmos manifestos da implantação local.
#
# Pré-requisitos:
#   - Conta AWS com permissões para EKS/EC2/IAM/CloudFormation
#   - AWS CLI configurado:  aws configure   (access key, secret, região)
#   - eksctl e kubectl instalados
#
# ATENÇÃO / CUSTOS: um cluster EKS + nós EC2 GERA CUSTOS por hora. Ao terminar
# os testes e coletar as evidências, DESTRUA tudo com scripts/04-cleanup-eks.sh.
#
# Uso:  bash scripts/02-eks-setup.sh
# =============================================================================
set -euo pipefail

# ---- Parâmetros (ajuste se quiser) ------------------------------------------
CLUSTER_NAME="hpa-nuvem"
REGION="us-east-1"          # Região mais barata/comum para laboratório
NODE_TYPE="t3.small"        # Instância pequena e barata, suficiente para o teste
NODES=2                     # Nº de nós de trabalho (worker nodes)

# Perfil do AWS CLI (~/.aws/credentials). Deixe vazio para usar o perfil
# "default". Se suas credenciais estão em um perfil nomeado — por exemplo
# "[psi5120]" —, informe-o aqui ou exporte AWS_PROFILE antes de rodar o script.
# Tanto o aws-cli quanto o eksctl leem essa variável automaticamente.
AWS_PROFILE="${AWS_PROFILE:-}"
if [ -n "$AWS_PROFILE" ]; then
  export AWS_PROFILE
  echo ">> Usando o perfil AWS: ${AWS_PROFILE}"
fi
# -----------------------------------------------------------------------------

echo ">> [0/5] Conferindo a identidade AWS antes de criar recursos pagos..."
aws sts get-caller-identity

echo ">> [1/5] Criando o cluster EKS '${CLUSTER_NAME}' (pode levar ~15-20 min)..."
# O eksctl provisiona VPC, subnets, control plane gerenciado e um managed node group.
eksctl create cluster \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --nodegroup-name "workers" \
  --node-type "${NODE_TYPE}" \
  --nodes "${NODES}" \
  --managed

echo ">> [2/5] Configurando o kubectl para apontar para o EKS..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

echo ">> [3/5] Garantindo o Metrics Server..."
# -----------------------------------------------------------------------------
# ATENÇÃO — mudança de comportamento do EKS/eksctl.
# Historicamente o EKS não trazia o Metrics Server, e a instrução era aplicar o
# manifesto da comunidade (SIG). A partir do eksctl 0.230 o metrics-server é
# criado automaticamente como ADDON GERENCIADO do EKS, junto de vpc-cni,
# kube-proxy e coredns.
#
# Aplicar o manifesto do SIG por cima do addon QUEBRA o cluster: o Deployment é
# rejeitado ("spec.selector: field is immutable" e porta "https" duplicada),
# mas o Service É sobrescrito com o seletor "k8s-app: metrics-server", que não
# corresponde aos Pods do addon. O resultado é a Metrics API sem endpoints
# (APIService AVAILABLE=False / MissingEndpoints) e o HPA preso em <unknown>.
#
# Por isso: só instalamos o manifesto do SIG se o metrics-server NÃO existir.
# -----------------------------------------------------------------------------
if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  echo "   Metrics Server já presente (addon gerenciado do EKS). Pulando o manifesto do SIG."
else
  echo "   Metrics Server ausente. Aplicando o manifesto oficial do SIG..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
fi
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

# Confirma que a Metrics API está realmente servindo dados antes de seguir —
# sem isso o HPA sobe, mas fica eternamente em "<unknown>/50%".
echo ">> Validando a Metrics API..."
kubectl get apiservice v1beta1.metrics.k8s.io

echo ">> [4/5] Aplicando os manifestos (Deployment, Service e HPA)..."
kubectl apply -f manifests/php-apache-deployment.yaml
kubectl apply -f manifests/php-apache-service.yaml
kubectl apply -f manifests/php-apache-hpa.yaml
kubectl rollout status deployment/php-apache --timeout=180s

echo
echo ">> [5/5] Estado inicial na nuvem (EVIDÊNCIA 'ANTES'):"
kubectl get nodes -o wide
kubectl get deployment php-apache
kubectl get pods -l app=php-apache
kubectl get hpa php-apache
echo
echo ">> Pronto! Cluster EKS configurado."
echo ">> LEMBRETE: rode 'bash scripts/04-cleanup-eks.sh' ao final para não gerar custos."
