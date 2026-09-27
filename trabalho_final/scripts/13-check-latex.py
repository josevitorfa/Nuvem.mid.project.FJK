#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
13-check-latex.py - verificacoes estruturais do .tex antes de compilar.

POR QUE EXISTE: a maquina de desenvolvimento nao tem uma distribuicao LaTeX
instalada -- o artigo e compilado no Overleaf. Sem um compilador local, erros
banais (um ambiente nao fechado, uma referencia a um rotulo inexistente, um
arquivo de dados ausente que o pgfplots vai procurar) so apareceriam no fim do
processo. Este script cobre as falhas mais comuns sem precisar de TeX.

O que NAO faz: nao valida sintaxe de LaTeX de verdade nem estima paginas. E uma
rede de seguranca, nao um substituto do compilador.

Uso:  python3 scripts/13-check-latex.py [caminho.tex]
"""

import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PADRAO = os.path.join(RAIZ, "artigo", "artigo-final.tex")

# Ambientes cujo desbalanceamento nao faz sentido verificar por contagem simples.
IGNORAR_AMBIENTES = set()


def sem_comentarios(texto):
    """Remove comentarios de LaTeX (% nao escapado ate o fim da linha)."""
    saida = []
    for linha in texto.split("\n"):
        pos = None
        for i, ch in enumerate(linha):
            if ch == "%" and (i == 0 or linha[i - 1] != "\\"):
                pos = i
                break
        saida.append(linha if pos is None else linha[:pos])
    return "\n".join(saida)


def main():
    caminho = sys.argv[1] if len(sys.argv) > 1 else PADRAO
    if not os.path.exists(caminho):
        print("ERRO: nao encontrei %s" % caminho)
        return 1

    bruto = open(caminho, "r", encoding="utf-8").read()
    texto = sem_comentarios(bruto)
    base = os.path.dirname(caminho)

    # Os rotulos das tabelas de dados vivem no arquivo gerado por
    # 11-analyze.py e trazido por \input. Sem concatenar esse conteudo, a
    # verificacao de referencias cruzadas acusaria falsos positivos.
    incluido = ""
    for arq in re.findall(r"\\input\{([^}]+)\}", texto):
        alvo = os.path.join(base, arq if arq.endswith(".tex") else arq + ".tex")
        if os.path.exists(alvo):
            incluido += "\n" + sem_comentarios(open(alvo, "r", encoding="utf-8").read())
    problemas = []
    avisos = []

    # --- 1. Ambientes balanceados -------------------------------------------
    abre = re.findall(r"\\begin\{([^}]+)\}", texto)
    fecha = re.findall(r"\\end\{([^}]+)\}", texto)
    for nome in set(abre) | set(fecha):
        if nome in IGNORAR_AMBIENTES:
            continue
        a, f = abre.count(nome), fecha.count(nome)
        if a != f:
            problemas.append("ambiente '%s': %d \\begin contra %d \\end" % (nome, a, f))

    # --- 2. Chaves balanceadas ----------------------------------------------
    saldo = 0
    for i, ch in enumerate(texto):
        if ch == "{" and (i == 0 or texto[i - 1] != "\\"):
            saldo += 1
        elif ch == "}" and (i == 0 or texto[i - 1] != "\\"):
            saldo -= 1
        if saldo < 0:
            problemas.append("chave '}' fechada a mais perto do caractere %d" % i)
            break
    if saldo > 0:
        problemas.append("faltam %d chaves '}' de fechamento" % saldo)

    # --- 3. Referencias cruzadas --------------------------------------------
    rotulos = set(re.findall(r"\\label\{([^}]+)\}", texto + incluido))
    for ref in set(re.findall(r"\\(?:ref|eqref)\{([^}]+)\}", texto)):
        if ref not in rotulos:
            problemas.append("\\ref{%s} nao tem \\label correspondente" % ref)

    citaveis = set(re.findall(r"\\bibitem\{([^}]+)\}", texto))
    citadas = set()
    for grupo in re.findall(r"\\cite\{([^}]+)\}", texto):
        citadas.update(c.strip() for c in grupo.split(","))
    for c in citadas - citaveis:
        problemas.append("\\cite{%s} nao tem \\bibitem correspondente" % c)
    for b in citaveis - citadas:
        avisos.append("\\bibitem{%s} nunca e citado" % b)

    # --- 4. Arquivos de dados que o pgfplots vai abrir -----------------------
    for arq in sorted(set(re.findall(r"\{(dados/[^}]+\.csv)\}", texto))):
        if not os.path.exists(os.path.join(base, arq)):
            problemas.append("arquivo de dados ausente: artigo/%s "
                             "(rode scripts/12-prep-artigo.sh)" % arq)
    for arq in sorted(set(re.findall(r"\\input\{([^}]+)\}", texto))):
        alvo = os.path.join(base, arq if arq.endswith(".tex") else arq + ".tex")
        if not os.path.exists(alvo):
            problemas.append("\\input ausente: artigo/%s" % arq)

    # --- 5. Marcadores deixados para tras ------------------------------------
    for n, linha in enumerate(bruto.split("\n"), start=1):
        if "TODO" in linha:
            avisos.append("linha %d ainda tem TODO: %s" % (n, linha.strip()[:70]))

    # --- 6. Secoes vazias -----------------------------------------------------
    for m in re.finditer(r"\\section\{([^}]+)\}", texto):
        trecho = texto[m.end():m.end() + 400]
        corpo = re.sub(r"\\label\{[^}]*\}", "", trecho).strip()
        if not corpo or corpo.startswith("\\section") or corpo.startswith("\\begin{thebibliography}"):
            avisos.append("secao '%s' parece vazia" % m.group(1))

    # --- Relatorio -----------------------------------------------------------
    print("Verificando %s" % os.path.relpath(caminho, RAIZ))
    print("  %d ambientes, %d rotulos, %d referencias bibliograficas"
          % (len(abre), len(rotulos), len(citaveis)))
    palavras = len(re.findall(r"\b\w+\b", texto))
    # Uma pagina de IEEE em duas colunas comporta ~900-1000 palavras de texto
    # corrido. E uma estimativa grosseira: figuras e tabelas deslocam muito.
    print("  ~%d palavras de corpo -> estimativa MUITO grosseira de %.1f a %.1f paginas"
          % (palavras, palavras / 1000.0, palavras / 750.0))
    print()

    if avisos:
        print("AVISOS (%d):" % len(avisos))
        for a in avisos:
            print("  - " + a)
        print()
    if problemas:
        print("PROBLEMAS (%d):" % len(problemas))
        for p in problemas:
            print("  - " + p)
        return 1
    print("Nenhum problema estrutural encontrado.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
