#!/usr/bin/env bash
# =============================================================================
# lib/common.sh - funcoes compartilhadas pelos scripts da campanha experimental
# -----------------------------------------------------------------------------
# Este arquivo NAO deve ser executado diretamente; e carregado com "source".
#
# Convencoes adotadas em toda a campanha:
#   * Todo instante medido do lado do CLIENTE e epoch em segundos (date +%s).
#   * Todo instante vindo do CLUSTER e RFC3339/UTC (ex.: 2026-09-23T22:10:05Z)
#     e e convertido para epoch com iso_to_epoch().
#   * A metrica primaria do estudo (tempo de reacao) e calculada APENAS com
#     instantes do lado do cluster, para nao depender do relogio local.
# =============================================================================

# --- Saida padronizada -------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] AVISO: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] ERRO: %s\n'  "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

# --- Compatibilidade Windows/Git Bash ----------------------------------------
# O MSYS converte argumentos "parecidos com caminho" (ex.: /bin/sh) para
# caminhos do Windows antes de entrega-los ao kubectl, o que quebra o comando do
# gerador de carga. Em Linux/macOS estas variaveis sao simplesmente ignoradas.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# --- Conversao de timestamps -------------------------------------------------
# Converte RFC3339 (UTC, sufixo Z) em epoch segundos. Retorna vazio se a
# entrada for vazia, "<none>" ou "<no value>" (o que kubectl imprime para
# campos ausentes).
iso_to_epoch() {
  local iso="${1:-}"
  case "$iso" in
    ''|'<none>'|'<no value>'|'null') return 0 ;;
  esac
  date -u -d "$iso" +%s 2>/dev/null || true
}

# --- Consulta ao estado do HPA ----------------------------------------------
# custom-columns e preferido a jsonpath porque imprime "<none>" para campos
# ausentes em vez de falhar -- e no inicio do experimento currentMetrics ainda
# nao existe (o Metrics Server ainda nao coletou a primeira amostra).
# Saida: "<currentReplicas> <desiredReplicas> <cpu%> <lastScaleTime>"
hpa_snapshot() {
  kubectl get hpa "${HPA_NAME}" --no-headers -o custom-columns=\
'CUR:.status.currentReplicas,DES:.status.desiredReplicas,CPU:.status.currentMetrics[0].resource.current.averageUtilization,LST:.status.lastScaleTime' \
    2>/dev/null || true
}

# Saida: "<replicas> <readyReplicas> <availableReplicas>"
deploy_snapshot() {
  kubectl get deploy "${APP_NAME}" --no-headers -o custom-columns=\
'REP:.status.replicas,RDY:.status.readyReplicas,AVL:.status.availableReplicas' \
    2>/dev/null || true
}

# Normaliza os marcadores de campo ausente do kubectl para string vazia.
nz() { case "${1:-}" in '<none>'|'<no value>'|'null') printf '' ;; *) printf '%s' "${1:-}" ;; esac; }

# --- Desvio entre o relogio local e o do cluster -----------------------------
# Cria um ConfigMap descartavel e compara o creationTimestamp atribuido pelo
# servidor com o relogio local no mesmo instante. O resultado e registrado nos
# metadados de cada campanha: se o desvio for grande, as metricas derivadas de
# instantes do cliente perdem validade (as do cluster, nao).
medir_desvio_relogio() {
  local antes depois servidor nome="skew-probe-$$"
  antes=$(date +%s)
  kubectl create configmap "$nome" --from-literal=p=1 >/dev/null 2>&1 || { printf 'NA'; return 0; }
  depois=$(date +%s)
  servidor=$(kubectl get configmap "$nome" -o custom-columns='T:.metadata.creationTimestamp' --no-headers 2>/dev/null)
  kubectl delete configmap "$nome" --now >/dev/null 2>&1 || true
  local eps; eps=$(iso_to_epoch "$(nz "$servidor")")
  if [ -z "$eps" ]; then printf 'NA'; return 0; fi
  # Ponto medio do intervalo local em que a criacao ocorreu, menos o instante
  # atribuido pelo servidor. Positivo = relogio local adiantado.
  printf '%s' "$(( (antes + depois) / 2 - eps ))"
}

# --- Acesso rapido ao EKS ----------------------------------------------------
# PROBLEMA: o kubeconfig que o "aws eks update-kubeconfig" gera usa um exec
# credential plugin -- cada invocacao do kubectl executa "aws eks get-token",
# que sobe a AWS CLI inteira. No Windows isso custa de 1 a 3 segundos POR
# CHAMADA. Consequencia medida: o amostrador configurado para 2 s entregava, na
# pratica, uma amostra a cada 5 s no EKS, contra 2 s no Minikube.
#
# POR QUE ISSO IMPORTA: a metrica primaria (lastScaleTime - startedAt) nao e
# afetada, porque ambos os instantes sao carimbados pelo cluster. Mas as
# metricas derivadas da serie temporal -- CPU de pico e tempo ate o regime
# permanente -- degradam com a resolucao. Amostrar um ambiente a 2 s e o outro a
# 5 s reintroduziria exatamente a "instrumentacao heterogenea" que o trabalho
# intermediario apontou como ameaca a validade.
#
# SOLUCAO: gerar um kubeconfig com o token embutido (sem exec plugin) e
# reescreve-lo periodicamente em segundo plano, porque o token do EKS vale
# cerca de 15 minutos. O kubectl le o arquivo a cada invocacao, entao a
# renovacao e transparente.
preparar_acesso_rapido_eks() {
  local cluster="$1" regiao="$2" destino="$3"
  local endpoint ca

  read -r endpoint ca <<<"$(aws eks describe-cluster --name "$cluster" --region "$regiao" \
    --query 'cluster.[endpoint,certificateAuthority.data]' --output text 2>/dev/null)"
  if [ -z "${endpoint:-}" ] || [ "$endpoint" = "None" ]; then
    warn "nao foi possivel descrever o cluster ${cluster}; mantendo o kubeconfig padrao"
    return 1
  fi

  escrever_kubeconfig_token "$cluster" "$regiao" "$destino" "$endpoint" "$ca" || return 1

  # O kubectl aqui e um binario do Windows e nao interpreta caminhos no estilo
  # MSYS (/c/Dev/...). O arquivo continua sendo escrito pelo caminho POSIX; so
  # a variavel de ambiente precisa do formato nativo.
  if command -v cygpath >/dev/null 2>&1; then
    export KUBECONFIG="$(cygpath -w "$destino")"
  else
    export KUBECONFIG="$destino"
  fi

  if ! kubectl get --raw /version >/dev/null 2>&1; then
    warn "kubeconfig com token nao funcionou; revertendo para o padrao"
    unset KUBECONFIG
    return 1
  fi

  # Renovador em segundo plano. Encerra sozinho quando o arquivo de controle
  # some (mesmo mecanismo do amostrador).
  (
    while [ -f "${destino}.renovando" ]; do
      sleep 420
      [ -f "${destino}.renovando" ] || break
      escrever_kubeconfig_token "$cluster" "$regiao" "$destino" "$endpoint" "$ca" || true
    done
  ) &
  RENOVADOR_PID=$!
  log "acesso rapido ao EKS ativo (token embutido, renovacao a cada 7 min)"
  return 0
}

escrever_kubeconfig_token() {
  local cluster="$1" regiao="$2" destino="$3" endpoint="$4" ca="$5" token tmp
  token=$(aws eks get-token --cluster-name "$cluster" --region "$regiao" \
    --query 'status.token' --output text 2>/dev/null)
  [ -z "${token:-}" ] && { warn "falha ao obter token do EKS"; return 1; }

  # Escreve em arquivo temporario e move: evita que o kubectl leia um
  # kubeconfig pela metade durante a renovacao.
  tmp="${destino}.tmp"
  cat > "$tmp" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${cluster}
  cluster:
    server: ${endpoint}
    certificate-authority-data: ${ca}
contexts:
- name: ${cluster}
  context:
    cluster: ${cluster}
    user: ${cluster}
current-context: ${cluster}
users:
- name: ${cluster}
  user:
    token: ${token}
EOF
  mv -f "$tmp" "$destino"
  return 0
}

# --- Latencia do caminho de escrita do control plane -------------------------
# Mede duas coisas, em milissegundos:
#   LEITURA  GET /version -- servido pelo proprio apiserver, NAO toca o etcd.
#            Captura latencia de rede + processamento do apiserver.
#   ESCRITA  criar e apagar um ConfigMap -- passa por consenso e fsync do etcd.
#
# A DIFERENCA entre as duas isola o caminho de armazenamento do control plane.
# Isso importa porque a latencia de rede e brutalmente diferente entre um
# cluster local (loopback) e um cluster gerenciado na nuvem (internet): comparar
# apenas a latencia de escrita bruta mediria a distancia geografica, nao o
# armazenamento. A diferenca e comparavel entre os dois ambientes.
#
# Saida: "<mediana_leitura_ms> <mediana_escrita_ms>"
medir_latencia_control_plane() {
  local n="${1:-7}" i t0 t1 nome
  local leituras=() escritas=()

  for i in $(seq 1 "$n"); do
    t0=$(date +%s%3N)
    kubectl get --raw /version >/dev/null 2>&1
    t1=$(date +%s%3N)
    leituras+=( "$(( t1 - t0 ))" )

    nome="lat-probe-$$-${i}"
    t0=$(date +%s%3N)
    kubectl create configmap "$nome" --from-literal=p=1 >/dev/null 2>&1
    t1=$(date +%s%3N)
    escritas+=( "$(( t1 - t0 ))" )
    kubectl delete configmap "$nome" --now >/dev/null 2>&1
  done

  printf '%s %s' "$(mediana_de "${leituras[@]}")" "$(mediana_de "${escritas[@]}")"
}

# Mediana de uma lista de inteiros (usa o elemento inferior quando n e par:
# nao interpolamos porque o consumidor e um CSV de diagnostico, nao a analise).
mediana_de() {
  [ "$#" -eq 0 ] && { printf ''; return 0; }
  local ordenados
  ordenados=$(printf '%s\n' "$@" | sort -n)
  printf '%s' "$(echo "$ordenados" | sed -n "$(( ($# + 1) / 2 ))p")"
}

# --- Verificacao de pre-requisitos -------------------------------------------
exigir_ferramentas() {
  local faltando=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || faltando+=("$c"); done
  [ ${#faltando[@]} -eq 0 ] || die "ferramentas ausentes: ${faltando[*]}"
}

# Aborta se o kubectl estiver apontando para um contexto diferente do esperado.
# Salvaguarda contra o erro mais caro possivel: rodar a limpeza (ou a carga) no
# cluster errado.
exigir_contexto() {
  local esperado="$1" atual
  atual=$(kubectl config current-context 2>/dev/null) || die "nenhum contexto kubectl ativo"
  case "$atual" in
    *"$esperado"*) log "contexto kubectl: ${atual}" ;;
    *) die "contexto kubectl e '${atual}', esperado algo contendo '${esperado}'" ;;
  esac
}
