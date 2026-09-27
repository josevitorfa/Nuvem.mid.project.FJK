#!/usr/bin/env bash
# =============================================================================
# 17-compilar-artigo.sh - compila o artigo e confere o que o enunciado exige.
# -----------------------------------------------------------------------------
# Faz duas passadas do pdflatex (a segunda resolve as referencias cruzadas),
# extrai do log a contagem de paginas e verifica a faixa exigida pelo enunciado:
# minimo 6, maximo 18 paginas.
#
# Usa o pdflatex nativo quando existe (Linux, macOS, ou Windows com MiKTeX no
# PATH). No Windows sem LaTeX nativo, recorre ao TeX Live instalado no WSL por
# scripts/16-instalar-latex-wsl.sh.
#
# Uso:  bash scripts/17-compilar-artigo.sh [nome-do-tex-sem-extensao]
#         (padrao: artigo-final, a versao em portugues)
#         artigo-final-en compila a versao em ingles
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh

MIN_PAGINAS=6
MAX_PAGINAS=18
TEX="${1:-artigo-final}"

[ -f "artigo/${TEX}.tex" ] || die "artigo/${TEX}.tex nao encontrado"

# Garante que os CSVs e as tabelas da analise estao dentro de artigo/.
bash scripts/12-prep-artigo.sh >/dev/null || die "falha ao preparar artigo/dados"

# --- Escolha do compilador ---------------------------------------------------
# O caminho e derivado do diretorio atual, nunca fixo no codigo: a pasta pode
# ser movida ou renomeada sem quebrar a compilacao.
compilar() {
  local passada="$1"
  if command -v pdflatex >/dev/null 2>&1; then
    ( cd artigo && pdflatex -interaction=nonstopmode -halt-on-error "${TEX}.tex" >/dev/null 2>&1 )
    return $?
  fi

  # Converte o caminho MSYS (/c/...) no caminho equivalente do WSL (/mnt/c/...).
  local dir_wsl
  dir_wsl=$(printf '%s' "$PWD/artigo" | sed 's|^/\([A-Za-z]\)/|/mnt/\1/|')
  wsl.exe -e bash -lc "
    export PATH=\"\$HOME/texlive/bin/x86_64-linux:\$PATH\"
    command -v pdflatex >/dev/null || exit 127
    cd '${dir_wsl}' || exit 1
    pdflatex -interaction=nonstopmode -halt-on-error '${TEX}.tex' >/dev/null 2>&1
  " >/dev/null 2>&1
  return $?
}

if ! command -v pdflatex >/dev/null 2>&1; then
  if ! wsl.exe -e bash -lc 'export PATH="$HOME/texlive/bin/x86_64-linux:$PATH"; command -v pdflatex >/dev/null' >/dev/null 2>&1; then
    die "pdflatex nao encontrado (nativo nem no WSL). Instale um LaTeX, ou rode scripts/16-instalar-latex-wsl.sh, ou compile artigo/ no Overleaf."
  fi
  log "usando o pdflatex do WSL"
fi

log "Compilando ${TEX}.tex (duas passadas)..."
for passada in 1 2; do
  log "   passada ${passada}"
  if ! compilar "$passada"; then
    warn "a passada ${passada} falhou; primeiros erros do log:"
    grep -A3 -E '^!' "artigo/${TEX}.log" 2>/dev/null | head -30
    exit 1
  fi
done

LOG="artigo/${TEX}.log"
[ -f "$LOG" ] || die "compilacao nao produziu log"

echo
log "Avisos que valem conferir:"
grep -iE 'undefined (control sequence|reference|citation)' "$LOG" | head -5
grep -cE 'Overfull \\hbox' "$LOG" | sed 's/^/   caixas extrapolando a margem: /'

PAGINAS=$(grep -oE 'Output written on .* \(([0-9]+) pages' "$LOG" \
  | grep -oE '\(([0-9]+)' | tr -d '(' | tail -1)

echo
if [ -z "${PAGINAS:-}" ]; then
  die "nao consegui extrair a contagem de paginas do log"
fi

log "PDF gerado: artigo/${TEX}.pdf com ${PAGINAS} paginas"
if [ "$PAGINAS" -lt "$MIN_PAGINAS" ]; then
  warn "ABAIXO do minimo exigido (${MIN_PAGINAS}) -- e preciso ampliar o artigo"
  exit 1
elif [ "$PAGINAS" -gt "$MAX_PAGINAS" ]; then
  warn "ACIMA do maximo permitido (${MAX_PAGINAS}) -- e preciso reduzir o artigo"
  exit 1
fi
log "Dentro da faixa exigida pelo enunciado (${MIN_PAGINAS}-${MAX_PAGINAS} paginas)."
