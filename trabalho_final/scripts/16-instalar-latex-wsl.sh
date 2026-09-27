#!/usr/bin/env bash
# =============================================================================
# 16-instalar-latex-wsl.sh - instala um TeX Live minimo DENTRO do WSL, em modo
#                            usuario, apenas para compilar o artigo.
# -----------------------------------------------------------------------------
# POR QUE ASSIM
#   * Nao usa sudo nem toca em nada do Windows: tudo vai para ~/texlive dentro
#     do WSL. Para desfazer, apague essa pasta.
#   * Instala o esquema "basic" (~250 MB) e depois apenas os pacotes que este
#     artigo realmente usa, em vez de um esquema completo de vários GB.
#   * E idempotente: se o pdflatex já estiver instalado, nao baixa nada.
#
# Uso (a partir do Git Bash, na pasta trabalho-final/):
#   bash scripts/16-instalar-latex-wsl.sh
#
# Depois:  bash scripts/17-compilar-artigo.sh
# =============================================================================
set -uo pipefail

# Todo o trabalho acontece dentro do WSL; este script apenas o conduz.
wsl.exe -e bash -lc '
set -e
PREFIXO="$HOME/texlive"
BIN="$PREFIXO/bin/x86_64-linux"

if [ -x "$BIN/pdflatex" ]; then
  echo ">> pdflatex ja instalado em $BIN"
  "$BIN/pdflatex" --version | head -1
  exit 0
fi

echo ">> Baixando o instalador do TeX Live..."
cd /tmp
rm -rf install-tl-unx install-tl-unx.tar.gz
wget -q --show-progress https://mirror.ctan.org/systems/texlive/tlnet/install-tl-unx.tar.gz
mkdir -p install-tl-unx
tar -xzf install-tl-unx.tar.gz -C install-tl-unx --strip-components=1

echo ">> Escrevendo o perfil de instalacao (esquema basico, sem docs nem fontes)..."
cat > /tmp/texlive.profile <<PERFIL
selected_scheme scheme-basic
TEXDIR $PREFIXO
TEXMFLOCAL $PREFIXO/texmf-local
TEXMFSYSVAR $PREFIXO/texmf-var
TEXMFSYSCONFIG $PREFIXO/texmf-config
TEXMFVAR $HOME/.texlive-user/texmf-var
TEXMFCONFIG $HOME/.texlive-user/texmf-config
TEXMFHOME $HOME/texmf
instopt_adjustpath 0
instopt_letter 0
tlpdbopt_install_docfiles 0
tlpdbopt_install_srcfiles 0
PERFIL

echo ">> Instalando (isto baixa da ordem de 250 MB; pode levar bastante tempo)..."
cd /tmp/install-tl-unx
perl ./install-tl --profile=/tmp/texlive.profile --no-interaction

echo ">> Instalando os pacotes que o artigo usa..."
# IEEEtran: a classe do formato. pgfplots/pgfplotstable: as figuras lidas dos
# CSVs. booktabs: as regras das tabelas. Os demais sao dependencias comuns que
# o esquema basico nao traz.
"$BIN/tlmgr" install \
  ieeetran \
  pgf pgfplots \
  booktabs \
  caption \
  xcolor \
  babel-english \
  ec cm-super \
  psnfss \
  || echo "AVISO: algum pacote falhou; o compilador vai apontar o que falta"

echo
echo ">> Instalado:"
"$BIN/pdflatex" --version | head -1
' 2>&1 | tr -d '\0\r'
