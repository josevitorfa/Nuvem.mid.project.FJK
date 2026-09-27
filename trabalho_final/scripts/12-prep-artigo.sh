#!/usr/bin/env bash
# =============================================================================
# 12-prep-artigo.sh - deixa a pasta artigo/ autocontida para compilar.
# -----------------------------------------------------------------------------
# As figuras do artigo sao geradas pelo pgfplots lendo diretamente os CSVs da
# analise -- nao ha imagens intermediarias, entao um numero do artigo nunca
# discorda do dado medido. Para que a pasta artigo/ compile sozinha (inclusive
# ao ser enviada ao Overleaf como ZIP), os CSVs necessarios sao copiados para
# artigo/dados/.
#
# Uso:  bash scripts/12-prep-artigo.sh
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh

ORIGEM="dados/analise"
DESTINO="artigo/dados"

[ -d "$ORIGEM" ] || die "execute scripts/11-analyze.py antes (nao ha dados/analise/)"

mkdir -p "$DESTINO"
copiados=0
for f in "$ORIGEM"/serie-*.csv "$ORIGEM"/ecdf-*.csv "$ORIGEM"/reacao-*.csv \
         "$ORIGEM"/por-repeticao.csv "$ORIGEM"/estatisticas.csv "$ORIGEM"/tabelas-pt.tex "$ORIGEM"/tabelas-en.tex; do
  [ -f "$f" ] || continue
  cp "$f" "$DESTINO/"
  copiados=$(( copiados + 1 ))
done

log "${copiados} arquivo(s) copiado(s) para ${DESTINO}/"
log "A pasta artigo/ agora compila isolada:"
log "  cd artigo && pdflatex artigo-final.tex && pdflatex artigo-final.tex"
log "Ou envie a pasta artigo/ inteira ao Overleaf (template IEEE Conference)."
