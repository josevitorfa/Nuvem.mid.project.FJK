#!/usr/bin/env bash
# =============================================================================
# 03c-sampler.sh
# -----------------------------------------------------------------------------
# Amostrador de metricas do HPA. A cada 5 segundos registra em um arquivo CSV:
#   timestamp, segundos decorridos, replicas atuais, replicas desejadas,
#   utilizacao de CPU observada (%) e o alvo (%).
#
# POR QUE ISSO EXISTE: o enunciado pede o "tempo de reacao do HPA" como metrica
# de comparacao entre Minikube e EKS. Ler isso de um print de tela e impreciso;
# com o CSV da para calcular exatamente o intervalo entre o inicio da carga e a
# primeira replica adicional, e ainda plotar um grafico replicas-vs-tempo para
# o artigo.
#
# Uso:
#   bash scripts/03c-sampler.sh <ambiente> [duracao_segundos]
#     <ambiente>          rotulo do arquivo de saida: "minikube" ou "eks"
#     [duracao_segundos]  padrao 900 (15 min)
#
# Saida: evidencias/logs/hpa-samples-<ambiente>.csv
# =============================================================================
set -uo pipefail

AMBIENTE="${1:-minikube}"
DURACAO="${2:-900}"
SAIDA="evidencias/logs/hpa-samples-${AMBIENTE}.csv"

mkdir -p "$(dirname "$SAIDA")"
echo "timestamp,segundos,replicas_atuais,replicas_desejadas,cpu_observada_pct,cpu_alvo_pct,replicas_prontas" > "$SAIDA"

INICIO=$(date +%s)
echo ">> Amostrando o HPA a cada 5s por ${DURACAO}s -> ${SAIDA}"
echo ">> Ctrl+C para encerrar antes do tempo."

while true; do
  AGORA=$(date +%s)
  DECORRIDO=$(( AGORA - INICIO ))
  [ "$DECORRIDO" -ge "$DURACAO" ] && break

  # -o json traz os campos exatos do status do HPA (mais confiavel que parsear
  # a saida em tabela do "kubectl get hpa").
  JSON=$(kubectl get hpa php-apache -o json 2>/dev/null)

  if [ -n "$JSON" ]; then
    ATUAL=$(echo "$JSON"   | grep -o '"currentReplicas": *[0-9]*'  | head -1 | grep -o '[0-9]*$')
    DESEJADA=$(echo "$JSON"| grep -o '"desiredReplicas": *[0-9]*'  | head -1 | grep -o '[0-9]*$')
    # averageUtilization aparece tanto no alvo quanto no observado; o primeiro
    # bloco "currentMetrics" traz o observado.
    CPU=$(echo "$JSON"     | grep -o '"averageUtilization": *[0-9]*' | tail -1 | grep -o '[0-9]*$')
    ALVO=$(echo "$JSON"    | grep -o '"averageUtilization": *[0-9]*' | head -1 | grep -o '[0-9]*$')
    PRONTAS=$(kubectl get pods -l app=php-apache --no-headers 2>/dev/null | grep -c 'Running')
  fi

  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$DECORRIDO" \
    "${ATUAL:-}" "${DESEJADA:-}" "${CPU:-}" "${ALVO:-}" "${PRONTAS:-0}" >> "$SAIDA"

  sleep 5
done

echo ">> Amostragem concluida: ${SAIDA}"
