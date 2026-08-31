#!/usr/bin/env bash
# =============================================================================
# 03-load-test.sh
# -----------------------------------------------------------------------------
# TESTE DE CARGA (STRESS): gera tráfego contínuo contra o Service php-apache
# para elevar a CPU e disparar o HPA. Funciona IGUAL no Minikube e no EKS.
#
# Como funciona: sobe um Pod "load-generator" (busybox) que faz um laço
# infinito de requisições HTTP ao Service interno http://php-apache.
#
# Uso:
#   bash scripts/03-load-test.sh          # inicia a carga (fica em primeiro plano)
#   (Ctrl+C encerra o gerador e o Pod é removido automaticamente por --rm)
#
# RECOMENDAÇÃO para coletar evidências:
#   Abra um SEGUNDO terminal e rode antes de iniciar a carga:
#       kubectl get hpa php-apache --watch
#       kubectl get pods -l app=php-apache --watch
#   Assim você filma/prints a escalada de 1 -> N réplicas.
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# COMPATIBILIDADE COM WINDOWS (Git Bash / MSYS2)
# -----------------------------------------------------------------------------
# No Git Bash, o MSYS converte automaticamente argumentos que "parecem" caminhos
# POSIX em caminhos do Windows. Isso QUEBRA este comando: o "/bin/sh" abaixo é o
# shell DE DENTRO do container busybox, mas o MSYS o reescreve para algo como
# "C:/Program Files/Git/usr/bin/sh", e o Pod falha com ContainerCannotRun:
#     exec: "C:/Program Files/Git/usr/bin/sh": no such file or directory
# As variáveis abaixo desligam essa conversão só para este script. Em Linux e
# macOS elas são simplesmente ignoradas, então o script continua portátil.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

echo ">> Iniciando gerador de carga contra http://php-apache ..."
echo ">> Pressione Ctrl+C para parar. Observe o HPA escalar em outro terminal."
echo

# -i --tty: interativo | --rm: remove o Pod ao sair | --restart=Never: Pod avulso
# O laço faz requisições o mais rápido possível para saturar a CPU.
kubectl run -i --tty load-generator \
  --rm \
  --image=busybox:1.28 \
  --restart=Never \
  -- /bin/sh -c "while sleep 0.01; do wget -q -O- http://php-apache; done"
