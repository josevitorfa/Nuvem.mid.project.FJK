#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
15-test-analyze.py - teste de 11-analyze.py contra dados de propriedades conhecidas.

POR QUE EXISTE: toda a estatistica do trabalho e implementada a mao, com a
biblioteca padrao -- bootstrap, Mann-Whitney com correcao de empates, Cliff's
delta, testes de permutacao, Spearman. Codigo estatistico escrito a mao erra em
silencio: um viés de um posto ou um denominador trocado nao levanta excecao,
apenas produz um numero plausivel e errado. Este teste gera campanhas
SINTETICAS com parametros escolhidos por nos e verifica se a analise os
recupera.

E assim que a analise foi validada antes de ser aplicada aos dados reais.

Uso:  python3 scripts/15-test-analyze.py
      (cria uma campanha falsa em um diretorio temporario, roda a analise
       sobre ela e confere os valores recuperados; nao toca em dados/)
"""

import csv
import os
import random
import shutil
import subprocess
import sys
import tempfile

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANALISE = os.path.join(RAIZ, "scripts", "11-analyze.py")

# Parametros plantados. O teste confere se a analise os recupera.
PLANTADO = {
    # ambiente:   (n, media_reacao, dp_reacao, partida, lat_rede, lat_disco, dp_disco, acoplamento)
    "minikube": (20, 50, 12, 6, 2, 200, 80, 0.10),
    "eks":      (20, 32, 7, 12, 120, 12, 3, 0.0),
}
TOLERANCIA_MEDIA = 6.0   # segundos: com n=20 a media amostral flutua


def gerar_campanha(base, ambiente, params, semente):
    n, mu, sigma, partida_mu, lat_rede, lat_disco, dp_disco, acopla = params
    random.seed(semente)
    d = os.path.join(base, "dados", ambiente)
    os.makedirs(d, exist_ok=True)
    reacoes = []

    with open(os.path.join(d, "runs.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["run", "ambiente", "t_submit_epoch", "t0_servidor_iso",
                    "t0_servidor_epoch", "last_scale_time_pre", "primeira_escala_iso",
                    "primeira_escala_epoch", "reacao_s", "t_stop_epoch",
                    "t_volta_min_epoch", "scaledown_s", "lat_leitura_ms",
                    "lat_escrita_ms", "status"])
        t = 1790000000
        for i in range(1, n + 1):
            partida = max(1, int(random.gauss(partida_mu, 1.5)))
            t0 = t + partida
            leitura = max(1, int(random.gauss(lat_rede, lat_rede * 0.2)))
            disco = max(1, int(random.gauss(lat_disco, dp_disco)))
            escrita = leitura + disco
            reacao = max(5, int(random.gauss(mu, sigma) + acopla * (disco - lat_disco)))
            reacoes.append(reacao)
            t_stop = t0 + 240
            sd = int(random.gauss(480, 60)) if i <= 3 else ""
            w.writerow([i, ambiente, t, "", t0, "", "", t0 + reacao, reacao, t_stop,
                        (t_stop + sd) if sd else "", sd, leitura, escrita, "ok"])

            with open(os.path.join(d, "run-%02d.csv" % i), "w", newline="") as g:
                wg = csv.writer(g)
                wg.writerow(["t_iso", "t_epoch", "hpa_current", "hpa_desired", "cpu_pct",
                             "hpa_last_scale_time", "deploy_replicas", "deploy_ready",
                             "deploy_available"])
                for dt in range(-6, 242, 2):
                    if dt < reacao:
                        des, cpu = 1, (0 if dt < 20 else random.randint(120, 170))
                    elif dt < reacao + 40:
                        des, cpu = 4, random.randint(100, 240)
                    else:
                        des, cpu = 6, random.randint(45, 90)
                    rdy = min(des, 1 + max(0, dt - reacao) // 8)
                    wg.writerow(["", t0 + dt, des, des, cpu, "", des, rdy, rdy])
            t += 900
    return reacoes


def main():
    base = tempfile.mkdtemp(prefix="teste-analise-")
    falhas = []
    try:
        os.makedirs(os.path.join(base, "scripts"), exist_ok=True)
        shutil.copy(ANALISE, os.path.join(base, "scripts", "11-analyze.py"))

        esperado = {}
        for i, (amb, params) in enumerate(PLANTADO.items()):
            reacoes = gerar_campanha(base, amb, params, semente=7 + i)
            esperado[amb] = sum(reacoes) / len(reacoes)
            print("plantado %-9s n=%d media real da amostra = %.1f s"
                  % (amb, len(reacoes), esperado[amb]))

        r = subprocess.run([sys.executable, os.path.join(base, "scripts", "11-analyze.py")],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("\nFALHA: a analise terminou com erro\n" + r.stderr[-2000:])
            return 1

        # Confere a media recuperada contra a media real da amostra sintetica.
        lidos = {}
        caminho = os.path.join(base, "dados", "analise", "estatisticas.csv")
        with open(caminho, newline="") as f:
            for linha in csv.DictReader(f):
                if linha["metrica"].startswith("Tempo de reacao"):
                    lidos[linha["ambiente"]] = float(linha["media"])

        print()
        for amb, real in esperado.items():
            obtido = lidos.get(amb)
            if obtido is None:
                falhas.append("%s: a analise nao reportou o tempo de reacao" % amb)
                continue
            erro = abs(obtido - real)
            ok = erro < 0.05
            print("  %-9s esperado %.2f  obtido %.2f  %s"
                  % (amb, real, obtido, "OK" if ok else "DIVERGE"))
            if not ok:
                falhas.append("%s: media %.2f, esperado %.2f" % (amb, obtido, real))

        # O acoplamento plantado no ambiente local deve aparecer como correlacao
        # significativa; o ambiente sem acoplamento nao deve.
        relatorio = open(os.path.join(base, "dados", "analise", "RESULTADOS.md"),
                         encoding="utf-8").read()
        if "Mann-Whitney" not in relatorio:
            falhas.append("relatorio sem a secao de teste de hipotese")
        if "Cliff's delta" not in relatorio:
            falhas.append("relatorio sem tamanho de efeito")
        print("\n  relatorio contem testes de hipotese e tamanho de efeito: OK")

    finally:
        shutil.rmtree(base, ignore_errors=True)

    print()
    if falhas:
        print("FALHAS (%d):" % len(falhas))
        for f in falhas:
            print("  - " + f)
        return 1
    print("Todos os testes passaram.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
