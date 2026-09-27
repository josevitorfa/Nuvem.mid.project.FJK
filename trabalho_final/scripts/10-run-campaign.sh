#!/usr/bin/env bash
# =============================================================================
# 10-run-campaign.sh - campanha de N execucoes repetidas do experimento de HPA
# -----------------------------------------------------------------------------
# POR QUE ESTE SCRIPT EXISTE
# O trabalho intermediario mediu o tempo de reacao do HPA em DUAS execucoes
# (uma por integrante) e descobriu que a diferenca entre Minikube e EKS nao se
# reproduziu: numa execucao o EKS foi ~4x mais rapido, na outra o Minikube foi
# ~2x. Com n=1 por ambiente nao ha media nem desvio -- so a constatacao de que
# o resultado nao e estavel. Este script repete o MESMO protocolo N vezes de
# forma nao supervisionada, produzindo uma amostra grande o bastante para
# caracterizar a DISTRIBUICAO do tempo de reacao em cada ambiente.
#
# O QUE MUDA EM RELACAO AO INTERMEDIARIO (e o que NAO muda)
#   NAO muda: manifestos, imagem, requests/limits, meta de 50%, behavior do HPA
#             e o gerador de carga (1 Pod busybox em laco sequencial). Manter a
#             carga identica e o que permite comparar as N repeticoes com as
#             execucoes E1/E2 ja publicadas.
#   Muda:     (a) a amostragem cai de 5s para 2s; (b) a metrica primaria passa a
#             ser derivada de instantes atribuidos pelo CLUSTER
#             (pod.startedAt e hpa.status.lastScaleTime) em vez do relogio do
#             cliente, eliminando jitter de rede e de polling; (c) o desvio
#             entre o relogio local e o do cluster e medido e registrado;
#             (d) o estado de base e verificado antes de cada repeticao.
#
# USO
#   bash scripts/10-run-campaign.sh <minikube|eks> [n_execucoes]
#
# VARIAVEIS DE AMBIENTE (opcionais)
#   LOAD_SECONDS=240      duracao da carga em cada repeticao
#   SAMPLE_INTERVAL=2     intervalo de amostragem do HPA
#   SCALEDOWN_RUNS=3      quantas repeticoes iniciais medem tambem o scale-down
#                         natural (as demais forcam o retorno a 1 replica para
#                         encurtar a campanha)
#
# SAIDA (em dados/<ambiente>/)
#   run-NN.csv        serie temporal da repeticao NN
#   runs.csv          uma linha por repeticao, com os instantes-chave
#   eventos-NN.log    eventos do HPA/Deployment na janela da repeticao
#   ambiente.txt      versoes, nos, capacidade e desvio de relogio
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib/common.sh
source scripts/lib/common.sh

APP_NAME="php-apache"
HPA_NAME="php-apache"
LOAD_POD="load-generator"

AMBIENTE="${1:-}"
N_RUNS="${2:-20}"
LOAD_SECONDS="${LOAD_SECONDS:-240}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-2}"
SCALEDOWN_RUNS="${SCALEDOWN_RUNS:-3}"
BASELINE_CPU_MAX="${BASELINE_CPU_MAX:-10}"   # % de CPU aceito como "repouso"
BASELINE_TIMEOUT="${BASELINE_TIMEOUT:-600}"
SCALEDOWN_TIMEOUT="${SCALEDOWN_TIMEOUT:-1200}"

case "$AMBIENTE" in
  minikube|eks) ;;
  *) die "uso: bash scripts/10-run-campaign.sh <minikube|eks> [n_execucoes]" ;;
esac

exigir_ferramentas kubectl date
DIR="dados/${AMBIENTE}"
mkdir -p "$DIR"
RUNS_CSV="${DIR}/runs.csv"
CTRL="${DIR}/.amostrando"
LOCK="${DIR}/.campanha.lock"

# -----------------------------------------------------------------------------
# TRAVA DE EXCLUSAO MUTUA
# -----------------------------------------------------------------------------
# Duas campanhas simultaneas no mesmo cluster invalidam as duas: ambas criam e
# apagam um Pod chamado "load-generator", ambas forcam a escala para 1 replica no
# meio da carga da outra, e ambas escrevem nos mesmos arquivos run-NN.csv. Como a
# campanha roda por horas em segundo plano, a condicao e facil de provocar por
# engano -- basta relancar o script acreditando que o anterior morreu.
#
# A trava guarda o PID e so cede se o processo dono tiver realmente terminado.
if [ -f "$LOCK" ]; then
  DONO=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$DONO" ] && kill -0 "$DONO" 2>/dev/null; then
    die "ja existe uma campanha '${AMBIENTE}' rodando (PID ${DONO}). Encerre-a antes: kill ${DONO}"
  fi
  warn "trava orfa encontrada (PID ${DONO:-?} nao existe mais); assumindo o controle"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" "$CTRL"' EXIT

# =============================================================================
# Amostrador: roda em subshell de fundo e registra o estado do HPA e do
# Deployment a cada SAMPLE_INTERVAL segundos. Compensa a deriva do proprio
# laco (cada consulta ao kubectl custa de 0,1 s a 1,5 s, e sem compensacao o
# intervalo efetivo cresceria ao longo da repeticao).
# =============================================================================
amostrar() {
  local arquivo="$1"
  echo "t_iso,t_epoch,hpa_current,hpa_desired,cpu_pct,hpa_last_scale_time,deploy_replicas,deploy_ready,deploy_available" > "$arquivo"
  local proximo
  proximo=$(date +%s)
  while [ -f "$CTRL" ]; do
    local cur des cpu lst rep rdy avl agora resto
    read -r cur des cpu lst <<<"$(hpa_snapshot)"
    read -r rep rdy avl     <<<"$(deploy_snapshot)"
    agora=$(date +%s)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(date -u -d "@${agora}" '+%Y-%m-%dT%H:%M:%SZ')" "$agora" \
      "$(nz "${cur:-}")" "$(nz "${des:-}")" "$(nz "${cpu:-}")" "$(nz "${lst:-}")" \
      "$(nz "${rep:-}")" "$(nz "${rdy:-}")" "$(nz "${avl:-}")" >> "$arquivo"
    proximo=$(( proximo + SAMPLE_INTERVAL ))
    resto=$(( proximo - $(date +%s) ))
    if [ "$resto" -gt 0 ]; then sleep "$resto"; else proximo=$(date +%s); fi
  done
}

# =============================================================================
# Estado de base: 1 replica pronta e CPU em repouso, estavel por tres amostras.
# Entre repeticoes o retorno a 1 replica e FORCADO (kubectl scale), mas o HPA
# pode desfaze-lo enquanto o Metrics Server ainda reporta a CPU alta da carga
# anterior -- a janela de estabilizacao de subida e zero. Por isso o laco
# reaplica a escala ate a CPU medida decair de fato.
# =============================================================================
aguardar_baseline() {
  local limite ok cur des cpu lst rep rdy avl
  limite=$(( $(date +%s) + BASELINE_TIMEOUT ))
  ok=0
  while [ "$(date +%s)" -lt "$limite" ]; do
    read -r cur des cpu lst <<<"$(hpa_snapshot)"
    read -r rep rdy avl     <<<"$(deploy_snapshot)"
    cur=$(nz "${cur:-}"); des=$(nz "${des:-}"); cpu=$(nz "${cpu:-}"); rdy=$(nz "${rdy:-}")
    if [ "${des:-9}" = "1" ] && [ "${rdy:-0}" = "1" ] && [ -n "$cpu" ] && [ "$cpu" -le "$BASELINE_CPU_MAX" ]; then
      ok=$(( ok + 1 ))
      if [ "$ok" -ge 3 ]; then
        log "   base atingida (cpu=${cpu}%, replicas=1)"
        return 0
      fi
    else
      ok=0
      if [ "${des:-1}" != "1" ]; then
        kubectl scale deployment "$APP_NAME" --replicas=1 >/dev/null 2>&1
      fi
    fi
    sleep 5
  done
  warn "estado de base nao atingido em ${BASELINE_TIMEOUT}s; seguindo assim mesmo"
  return 1
}

# =============================================================================
# Saude do cluster antes de cada repeticao.
# -----------------------------------------------------------------------------
# O control plane do ambiente local pode degradar sob contencao de E/S: o etcd
# passa a levar segundos por fdatasync e o apiserver fica inacessivel. Numa
# campanha de horas, sem supervisao, um episodio desses desperdicaria todas as
# repeticoes seguintes, que seriam registradas como falhas em vez de esperar a
# recuperacao. A funcao verifica os dois pre-requisitos minimos -- no pronto e
# Metrics API servindo dados -- e espera pela recuperacao ate um limite.
# =============================================================================
aguardar_cluster_saudavel() {
  local limite=$(( $(date +%s) + ${SAUDE_TIMEOUT:-900} )) pronto avisou=0
  while [ "$(date +%s)" -lt "$limite" ]; do
    pronto=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')
    if [ "${pronto:-0}" -ge 1 ] && kubectl top nodes >/dev/null 2>&1; then
      [ "$avisou" = "1" ] && log "   cluster recuperado"
      return 0
    fi
    if [ "$avisou" = "0" ]; then
      warn "   cluster degradado (no nao pronto ou Metrics API sem dados); aguardando..."
      avisou=1
    fi
    sleep 15
  done
  warn "   cluster nao se recuperou no prazo"
  return 1
}

# =============================================================================
# Uma repeticao completa do protocolo.
# =============================================================================
executar_repeticao() {
  local idx="$1" medir_scaledown="$2"
  local rotulo csv lst_pre pid_amostrador t_submit
  local t0_srv_iso t0_srv limite_start first_iso first_ep fim_carga
  local cur des cpu lst ep resto t_stop t_min dur_sd limite_sd lat_read lat_write

  rotulo=$(printf '%02d' "$idx")
  csv="${DIR}/run-${rotulo}.csv"

  log "== repeticao ${rotulo}/${N_RUNS} (${AMBIENTE}) =="

  if ! aguardar_cluster_saudavel; then
    # Registra a repeticao como perdida em vez de omiti-la: a taxa de perda e
    # um resultado do experimento, nao um detalhe a esconder.
    printf '%s,%s,,,,,,,,,,,,,%s\n' "$idx" "$AMBIENTE" "cluster_degradado" >> "$RUNS_CSV"
    return 1
  fi

  kubectl delete pod "$LOAD_POD" --now --ignore-not-found >/dev/null 2>&1
  kubectl scale deployment "$APP_NAME" --replicas=1 >/dev/null 2>&1
  log "   aguardando estado de base..."
  aguardar_baseline

  # lastScaleTime ANTES da carga: qualquer instante posterior a este e,
  # necessariamente, uma decisao provocada por esta repeticao.
  read -r _ _ _ lst_pre <<<"$(hpa_snapshot)"
  lst_pre=$(nz "${lst_pre:-}")

  # Latencia do control plane IMEDIATAMENTE antes da carga. Serve de covariavel:
  # permite testar se as repeticoes mais lentas sao justamente aquelas em que o
  # caminho de escrita do control plane estava degradado -- uma explicacao
  # mecanica para a dispersao, e nao apenas a constatacao dela.
  read -r lat_read lat_write <<<"$(medir_latencia_control_plane 7)"
  log "   latencia do control plane: leitura ${lat_read}ms | escrita ${lat_write}ms"

  touch "$CTRL"
  amostrar "$csv" &
  pid_amostrador=$!
  sleep 2

  # ---- T0: inicio da carga -------------------------------------------------
  t_submit=$(date +%s)
  kubectl run "$LOAD_POD" --image=busybox:1.28 --restart=Never \
    -- /bin/sh -c "while sleep 0.01; do wget -q -O- http://${APP_NAME}; done" >/dev/null 2>&1

  # Instante em que o container do gerador REALMENTE comecou a executar,
  # atribuido pelo kubelet. E este o T0 do estudo: o intervalo entre submeter o
  # Pod e ele comecar a rodar (agendamento, puxar imagem) varia entre os
  # ambientes e era um dos fatores de confusao apontados no intermediario.
  t0_srv_iso=""
  limite_start=$(( t_submit + 300 ))
  while [ "$(date +%s)" -lt "$limite_start" ]; do
    t0_srv_iso=$(kubectl get pod "$LOAD_POD" --no-headers \
      -o custom-columns='T:.status.containerStatuses[0].state.running.startedAt' 2>/dev/null | tr -d '[:space:]')
    t0_srv_iso=$(nz "$t0_srv_iso")
    [ -n "$t0_srv_iso" ] && break
    sleep 1
  done
  t0_srv=$(iso_to_epoch "$t0_srv_iso")
  if [ -z "$t0_srv" ]; then
    warn "   gerador de carga nao entrou em execucao; repeticao ${rotulo} descartada"
    rm -f "$CTRL"
    wait "$pid_amostrador" 2>/dev/null
    kubectl delete pod "$LOAD_POD" --now --ignore-not-found >/dev/null 2>&1
    printf '%s,%s,%s,,,,,,,,,,%s,%s,%s\n' "$idx" "$AMBIENTE" "$t_submit" \
      "${lat_read:-}" "${lat_write:-}" "gerador_nao_iniciou" >> "$RUNS_CSV"
    return 1
  fi
  log "   carga em execucao desde ${t0_srv_iso} (submissao->execucao: $(( t0_srv - t_submit ))s)"

  # ---- Deteccao da primeira decisao de escala ------------------------------
  # Fonte: hpa.status.lastScaleTime, carimbado pelo proprio controlador. Nao
  # depende do relogio local nem do instante em que o amostrador perguntou.
  first_iso=""
  first_ep=""
  fim_carga=$(( $(date +%s) + LOAD_SECONDS ))
  while [ "$(date +%s)" -lt "$fim_carga" ]; do
    read -r cur des cpu lst <<<"$(hpa_snapshot)"
    lst=$(nz "${lst:-}")
    if [ -n "$lst" ] && [ "$lst" != "$lst_pre" ]; then
      ep=$(iso_to_epoch "$lst")
      if [ -n "$ep" ] && [ "$ep" -ge "$t0_srv" ]; then
        first_iso="$lst"
        first_ep="$ep"
        log "   1a decisao de escala em ${first_iso} -> reacao = $(( first_ep - t0_srv ))s"
        break
      fi
    fi
    sleep 1
  done
  [ -z "$first_iso" ] && warn "   nenhuma decisao de escala observada durante a carga"

  # ---- Mantem a carga pelo tempo restante ----------------------------------
  resto=$(( fim_carga - $(date +%s) ))
  [ "$resto" -gt 0 ] && sleep "$resto"

  # ---- T1: fim da carga ----------------------------------------------------
  t_stop=$(date +%s)
  kubectl delete pod "$LOAD_POD" --now --ignore-not-found >/dev/null 2>&1
  log "   carga encerrada apos ${LOAD_SECONDS}s"

  # ---- Scale-down ----------------------------------------------------------
  t_min=""
  dur_sd=""
  if [ "$medir_scaledown" = "1" ]; then
    log "   medindo o scale-down natural (janela de estabilizacao de 300s)..."
    limite_sd=$(( t_stop + SCALEDOWN_TIMEOUT ))
    while [ "$(date +%s)" -lt "$limite_sd" ]; do
      read -r cur des cpu lst <<<"$(hpa_snapshot)"
      if [ "$(nz "${des:-}")" = "1" ] && [ "$(nz "${cur:-}")" = "1" ]; then
        t_min=$(date +%s)
        dur_sd=$(( t_min - t_stop ))
        log "   retorno a 1 replica em ${dur_sd}s"
        break
      fi
      sleep 5
    done
    [ -z "$t_min" ] && warn "   scale-down nao concluiu em ${SCALEDOWN_TIMEOUT}s"
  fi

  rm -f "$CTRL"
  wait "$pid_amostrador" 2>/dev/null

  kubectl get events --field-selector "involvedObject.name=${APP_NAME}" \
    --sort-by=.lastTimestamp > "${DIR}/eventos-${rotulo}.log" 2>/dev/null

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$idx" "$AMBIENTE" "$t_submit" "$t0_srv_iso" "$t0_srv" \
    "${lst_pre:-}" "${first_iso:-}" "${first_ep:-}" \
    "$( [ -n "$first_ep" ] && echo $(( first_ep - t0_srv )) )" \
    "$t_stop" "${t_min:-}" "${dur_sd:-}" \
    "${lat_read:-}" "${lat_write:-}" \
    "$( [ -n "$first_iso" ] && echo ok || echo sem_escala )" >> "$RUNS_CSV"

  log "   repeticao ${rotulo} concluida"
  return 0
}

# =============================================================================
# Registro do ambiente: tudo que a secao de metodologia do artigo precisa
# declarar e que so pode ser lido do cluster em execucao.
# =============================================================================
registrar_ambiente() {
  {
    echo "# Ambiente da campanha - ${AMBIENTE}"
    echo "data_inicio: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "contexto_kubectl: $(kubectl config current-context 2>/dev/null)"
    echo "n_execucoes: ${N_RUNS}"
    echo "load_seconds: ${LOAD_SECONDS}"
    echo "sample_interval: ${SAMPLE_INTERVAL}"
    echo "desvio_relogio_s: $(medir_desvio_relogio)"
    echo "latencia_control_plane_leitura_escrita_ms: $(medir_latencia_control_plane 9)"
    echo
    echo "## versoes"
    kubectl version 2>/dev/null | sed 's/^/  /'
    echo
    echo "## nos"
    kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /'
    echo
    echo "## capacidade alocavel"
    kubectl get nodes -o custom-columns='NO:.metadata.name,CPU_ALOC:.status.allocatable.cpu,MEM_ALOC:.status.allocatable.memory,INSTANCIA:.metadata.labels.node\.kubernetes\.io/instance-type,ZONA:.metadata.labels.topology\.kubernetes\.io/zone' 2>/dev/null | sed 's/^/  /'
    echo
    echo "## metrics api"
    kubectl get apiservice v1beta1.metrics.k8s.io --no-headers 2>/dev/null | sed 's/^/  /'
    echo
    echo "## objetos aplicados"
    kubectl get deploy,svc,hpa -o wide 2>/dev/null | sed 's/^/  /'
  } > "${DIR}/ambiente.txt"
  log "ambiente registrado em ${DIR}/ambiente.txt"
}

# =============================================================================
# Execucao da campanha
# =============================================================================
trap 'rm -f "$CTRL" "$LOCK" "${KUBECONFIG_RAPIDO:-/dev/null}" "${KUBECONFIG_RAPIDO:-/dev/null}.renovando"; kubectl delete pod "$LOAD_POD" --now --ignore-not-found >/dev/null 2>&1; die "campanha interrompida"' INT TERM

log "############################################################"
log "# Campanha ${AMBIENTE}: ${N_RUNS} repeticoes x ${LOAD_SECONDS}s de carga"
log "# Amostragem a cada ${SAMPLE_INTERVAL}s | scale-down natural nas ${SCALEDOWN_RUNS} primeiras"
log "############################################################"

# Trava de seguranca: o kubeconfig e compartilhado pelos dois ambientes e criar
# o cluster EKS troca o contexto ativo. Sem esta verificacao, um argumento
# errado faria a campanha "minikube" rodar dentro do EKS -- gerando dados
# rotulados errado e consumindo horas de cluster pago.
CONTEXTO_ESPERADO="minikube"
if [ "$AMBIENTE" = "eks" ]; then
  CONTEXTO_ESPERADO="${CLUSTER_NAME:-hpa-final}"
  # Troca o kubeconfig por um com token embutido, para que o kubectl nao pague
  # a partida da AWS CLI a cada chamada. Ver common.sh para a justificativa.
  export AWS_PROFILE="${AWS_PROFILE:-psi5120}"
  KUBECONFIG_RAPIDO="${DIR}/kubeconfig-token.yaml"
  touch "${KUBECONFIG_RAPIDO}.renovando"
  RENOVADOR_PID=""
  preparar_acesso_rapido_eks "${CLUSTER_NAME:-hpa-final}" "${REGION:-us-east-1}" \
    "$KUBECONFIG_RAPIDO" || rm -f "${KUBECONFIG_RAPIDO}.renovando"
fi
exigir_contexto "$CONTEXTO_ESPERADO"

kubectl get deploy "$APP_NAME" >/dev/null 2>&1 || die "Deployment ${APP_NAME} nao encontrado neste cluster"
kubectl get hpa "$HPA_NAME"    >/dev/null 2>&1 || die "HPA ${HPA_NAME} nao encontrado neste cluster"

# Aquecimento do cache de imagens em TODOS os nos. Ver o cabecalho de
# manifests/warmup-daemonset.yaml para a justificativa. O DaemonSet e removido
# antes da primeira repeticao para nao competir por recursos durante as medicoes.
aquecer_cache() {
  log "aquecendo o cache de imagens em todos os nos..."
  if ! kubectl apply -f manifests/warmup-daemonset.yaml >/dev/null 2>&1; then
    warn "nao foi possivel aplicar o DaemonSet de aquecimento; seguindo sem ele"
    return 0
  fi
  if kubectl rollout status daemonset/warmup --timeout=420s >/dev/null 2>&1; then
    log "   imagens em cache em todos os nos"
  else
    warn "   aquecimento nao concluiu no prazo; seguindo assim mesmo"
  fi
  kubectl delete -f manifests/warmup-daemonset.yaml --ignore-not-found >/dev/null 2>&1
  # Espera os Pods de aquecimento sumirem de fato antes de medir qualquer coisa.
  local limite=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$limite" ]; do
    [ "$(kubectl get pods -l app=warmup --no-headers 2>/dev/null | wc -l)" = "0" ] && break
    sleep 3
  done
}

registrar_ambiente
aquecer_cache
if [ ! -f "$RUNS_CSV" ]; then
  echo "run,ambiente,t_submit_epoch,t0_servidor_iso,t0_servidor_epoch,last_scale_time_pre,primeira_escala_iso,primeira_escala_epoch,reacao_s,t_stop_epoch,t_volta_min_epoch,scaledown_s,lat_leitura_ms,lat_escrita_ms,status" > "$RUNS_CSV"
fi

INICIO_CAMPANHA=$(date +%s)
for i in $(seq 1 "$N_RUNS"); do
  sd=0
  [ "$i" -le "$SCALEDOWN_RUNS" ] && sd=1
  executar_repeticao "$i" "$sd"
  decorrido=$(( $(date +%s) - INICIO_CAMPANHA ))
  log "   tempo total de campanha ate aqui: $(( decorrido / 60 ))min"
done

rm -f "$CTRL"
# Encerra o renovador de token e remove o kubeconfig com credencial embutida:
# ele contem um token valido e nao deve sobrar no disco nem ser versionado.
if [ -n "${KUBECONFIG_RAPIDO:-}" ]; then
  rm -f "${KUBECONFIG_RAPIDO}.renovando"
  [ -n "${RENOVADOR_PID:-}" ] && kill "$RENOVADOR_PID" 2>/dev/null
  rm -f "$KUBECONFIG_RAPIDO" "${KUBECONFIG_RAPIDO}.tmp"
fi

log "############################################################"
log "# Campanha ${AMBIENTE} concluida em $(( ( $(date +%s) - INICIO_CAMPANHA ) / 60 )) min"
log "# Dados em ${DIR}/"
log "############################################################"
