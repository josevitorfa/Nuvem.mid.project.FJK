#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
11-analyze.py - analise estatistica da campanha de repeticoes do HPA.

POR QUE SO BIBLIOTECA PADRAO
Todo o tratamento estatistico (descritivas, bootstrap, Mann-Whitney, Cliff's
delta, testes de permutacao) e implementado aqui com a stdlib do Python. Nao ha
numpy nem scipy. O motivo e reprodutibilidade: qualquer avaliador consegue
rodar `python3 scripts/11-analyze.py` sem instalar nada, e cada estimador fica
explicito no codigo em vez de escondido atras de uma chamada de biblioteca.

ENTRADAS   dados/<ambiente>/runs.csv        (instantes-chave de cada repeticao)
           dados/<ambiente>/run-NN.csv      (serie temporal de cada repeticao)
SAIDAS     dados/analise/por-repeticao.csv  (metricas derivadas, uma linha/run)
           dados/analise/estatisticas.csv   (descritivas por ambiente)
           dados/analise/tabelas.tex        (tabelas prontas para o artigo)
           dados/analise/serie-<amb>.csv    (trajetoria mediana p/ pgfplots)
           dados/analise/ecdf-<amb>.csv     (ECDF do tempo de reacao)
           dados/analise/RESULTADOS.md      (relatorio legivel)

USO        python3 scripts/11-analyze.py
"""

import csv
import math
import os
import random
import re
import sys
from collections import defaultdict

SEED = 20260927          # semente fixa: bootstrap e permutacao reprodutiveis
random.seed(SEED)

B_BOOTSTRAP = 20000      # reamostragens para os intervalos de confianca
N_PERMUTACOES = 50000    # permutacoes dos testes de hipotese
AMBIENTES = ["minikube", "eks"]
ROTULO = {"minikube": "Minikube (local)", "eks": "AWS EKS (nuvem)"}

# Tempos de reacao relatados pelo TRABALHO INTERMEDIARIO, uma execucao por
# ambiente por integrante. Servem para localizar aquelas observacoes isoladas
# dentro da distribuicao agora medida: e a ligacao direta entre os dois
# trabalhos.
#
# RESSALVA DE COMPARABILIDADE: naquele estudo o T0 era o relogio do operador no
# momento de submeter o Pod gerador, e portanto INCLUIA o agendamento e a
# partida do container -- que aqui sao medidos a parte. Os valores antigos estao
# inflados por essa parcela (da ordem de poucos segundos), de modo que os
# percentis abaixo sao aproximados e tendem a superestimar levemente.
EXECUCOES_ANTERIORES = [
    ("E1 (Jose)", "minikube", 62.0),
    ("E1 (Jose)", "eks", 15.0),
    ("E2 (Fernando)", "minikube", 33.0),
    ("E2 (Fernando)", "eks", 60.0),
]

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR_DADOS = os.path.join(RAIZ, "dados")
DIR_SAIDA = os.path.join(DIR_DADOS, "analise")


# =============================================================================
# Utilitarios numericos
# =============================================================================
def media(xs):
    return sum(xs) / len(xs) if xs else float("nan")


def desvio_padrao(xs):
    """Desvio-padrao amostral (denominador n-1)."""
    n = len(xs)
    if n < 2:
        return float("nan")
    m = media(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1))


def quantil(xs, q):
    """Quantil por interpolacao linear (mesma convencao do numpy.percentile)."""
    if not xs:
        return float("nan")
    ys = sorted(xs)
    if len(ys) == 1:
        return float(ys[0])
    pos = (len(ys) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return float(ys[int(pos)])
    return ys[lo] * (hi - pos) + ys[hi] * (pos - lo)


def mediana(xs):
    return quantil(xs, 0.5)


def mad(xs):
    """Desvio absoluto mediano - dispersao robusta a valores extremos."""
    if not xs:
        return float("nan")
    med = mediana(xs)
    return mediana([abs(x - med) for x in xs])


def coef_variacao(xs):
    m = media(xs)
    return desvio_padrao(xs) / m if m else float("nan")


def phi(z):
    """Funcao de distribuicao acumulada da normal padrao."""
    return 0.5 * (1.0 + math.erf(z / math.sqrt(2.0)))


def ic_bootstrap(xs, estimador=media, b=B_BOOTSTRAP, alfa=0.05):
    """Intervalo de confianca percentil por bootstrap nao parametrico.

    Escolhido em vez do IC-t porque n e pequeno (~20) e nao ha razao para supor
    normalidade do tempo de reacao, que e limitado inferiormente por zero e
    quantizado pelo periodo de sincronizacao do HPA.
    """
    if len(xs) < 2:
        return (float("nan"), float("nan"))
    n = len(xs)
    reps = []
    for _ in range(b):
        amostra = [xs[random.randrange(n)] for _ in range(n)]
        reps.append(estimador(amostra))
    reps.sort()
    return (quantil(reps, alfa / 2), quantil(reps, 1 - alfa / 2))


def mann_whitney(x, y):
    """Mann-Whitney U bilateral, aproximacao normal com correcao de empates.

    Teste nao parametrico: compara as distribuicoes sem supor normalidade, o
    que e adequado a tempos de reacao quantizados em multiplos do periodo de
    sincronizacao do controlador.
    """
    n1, n2 = len(x), len(y)
    if n1 == 0 or n2 == 0:
        return (float("nan"), float("nan"), float("nan"))

    juntos = sorted([(v, 0) for v in x] + [(v, 1) for v in y])
    postos = [0.0] * len(juntos)
    grupos_empate = []
    i = 0
    while i < len(juntos):
        j = i
        while j + 1 < len(juntos) and juntos[j + 1][0] == juntos[i][0]:
            j += 1
        posto_medio = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            postos[k] = posto_medio
        grupos_empate.append(j - i + 1)
        i = j + 1

    r1 = sum(p for p, (_, g) in zip(postos, juntos) if g == 0)
    u1 = r1 - n1 * (n1 + 1) / 2.0
    u2 = n1 * n2 - u1
    u = min(u1, u2)

    mu = n1 * n2 / 2.0
    n = n1 + n2
    correcao = sum(t ** 3 - t for t in grupos_empate)
    var = (n1 * n2 / 12.0) * ((n + 1) - correcao / (n * (n - 1.0)))
    if var <= 0:
        return (u, float("nan"), float("nan"))
    z = (u - mu + 0.5) / math.sqrt(var)          # correcao de continuidade
    p = 2.0 * phi(z) if z < 0 else 2.0 * (1.0 - phi(z))
    return (u, z, min(1.0, p))


def cliffs_delta(x, y):
    """Tamanho de efeito de Cliff: (P(X>Y) - P(X<Y)).

    Interpretacao direta para este estudo: quao frequentemente uma repeticao
    sorteada de um ambiente supera uma repeticao sorteada do outro.
    """
    maior = menor = 0
    for a in x:
        for b in y:
            if a > b:
                maior += 1
            elif a < b:
                menor += 1
    total = len(x) * len(y)
    return (maior - menor) / total if total else float("nan")


def a12(x, y):
    """Vargha-Delaney A12 = P(X>Y) + 0.5*P(X=Y)."""
    maior = igual = 0
    for a in x:
        for b in y:
            if a > b:
                maior += 1
            elif a == b:
                igual += 1
    total = len(x) * len(y)
    return (maior + 0.5 * igual) / total if total else float("nan")


def magnitude_delta(d, ingles=False):
    """Classificacao de magnitude de Cliff's delta (limiares de Romano et al.).

    O parametro de idioma existe porque o mesmo valor aparece no relatorio em
    portugues (documentacao do repositorio) e nas tabelas geradas para o artigo,
    que o enunciado exige em ingles.
    """
    ad = abs(d)
    if ad < 0.147:
        return "negligible" if ingles else "desprezivel"
    if ad < 0.33:
        return "small" if ingles else "pequeno"
    if ad < 0.474:
        return "medium" if ingles else "medio"
    return "large" if ingles else "grande"


def teste_permutacao(x, y, estatistica, n=N_PERMUTACOES):
    """Teste de permutacao bilateral para qualquer estatistica de dois grupos.

    Usado aqui para (a) diferenca de medianas e (b) razao de dispersoes. A
    hipotese nula e a de permutabilidade: se o ambiente nao importa, qualquer
    reatribuicao dos rotulos e igualmente provavel.
    """
    obs = estatistica(x, y)
    if math.isnan(obs):
        return (obs, float("nan"))
    juntos = list(x) + list(y)
    n1 = len(x)
    extremos = 0
    for _ in range(n):
        random.shuffle(juntos)
        e = estatistica(juntos[:n1], juntos[n1:])
        if not math.isnan(e) and abs(e) >= abs(obs) - 1e-12:
            extremos += 1
    # Estimador com correcao (+1): nunca devolve p = 0 exato.
    return (obs, (extremos + 1) / (n + 1))


def dif_medianas(a, b):
    return mediana(a) - mediana(b)


def postos(xs):
    """Postos com media em caso de empate (convencao padrao de Spearman)."""
    indexado = sorted(range(len(xs)), key=lambda i: xs[i])
    r = [0.0] * len(xs)
    i = 0
    while i < len(indexado):
        j = i
        while j + 1 < len(indexado) and xs[indexado[j + 1]] == xs[indexado[i]]:
            j += 1
        posto_medio = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            r[indexado[k]] = posto_medio
        i = j + 1
    return r


def pearson(x, y):
    n = len(x)
    if n < 3:
        return float("nan")
    mx, my = media(x), media(y)
    num = sum((a - mx) * (b - my) for a, b in zip(x, y))
    dx = math.sqrt(sum((a - mx) ** 2 for a in x))
    dy = math.sqrt(sum((b - my) ** 2 for b in y))
    if dx == 0 or dy == 0:
        return float("nan")
    return num / (dx * dy)


def spearman(x, y, n_perm=10000):
    """Correlacao de postos de Spearman com p-valor por permutacao.

    Usada para responder se as repeticoes mais lentas sao justamente aquelas em
    que o caminho de escrita do control plane estava degradado. Spearman (e nao
    Pearson) porque nao supomos relacao linear, apenas monotonica; o p-valor vem
    de permutacao para nao depender de aproximacao assintotica com n pequeno.
    """
    if len(x) < 4 or len(x) != len(y):
        return (float("nan"), float("nan"))
    rho = pearson(postos(x), postos(y))
    if math.isnan(rho):
        return (rho, float("nan"))
    y_emb = list(y)
    extremos = 0
    for _ in range(n_perm):
        random.shuffle(y_emb)
        r = pearson(postos(x), postos(y_emb))
        if not math.isnan(r) and abs(r) >= abs(rho) - 1e-12:
            extremos += 1
    return (rho, (extremos + 1) / (n_perm + 1))


def log_razao_dispersao(a, b):
    """log da razao entre os MADs. Zero sob a hipotese de igual dispersao."""
    ma, mb = mad(a), mad(b)
    if ma <= 0 or mb <= 0:
        # Recorre ao desvio-padrao quando o MAD degenera (muitos empates).
        ma, mb = desvio_padrao(a), desvio_padrao(b)
    if not ma or not mb or math.isnan(ma) or math.isnan(mb) or ma <= 0 or mb <= 0:
        return float("nan")
    return math.log(ma / mb)


# =============================================================================
# Leitura dos dados brutos
# =============================================================================
def ler_csv(caminho):
    if not os.path.exists(caminho):
        return []
    with open(caminho, "r", encoding="utf-8", newline="") as f:
        return [{k: (v.strip() if isinstance(v, str) else v) for k, v in linha.items()}
                for linha in csv.DictReader(f)]


def num(valor, tipo=float):
    try:
        if valor is None or valor == "":
            return None
        return tipo(valor)
    except (TypeError, ValueError):
        return None


def derivar_metricas(ambiente):
    """Combina runs.csv com cada serie temporal e produz as metricas por
    repeticao usadas em todo o restante da analise."""
    dir_amb = os.path.join(DIR_DADOS, ambiente)
    runs = ler_csv(os.path.join(dir_amb, "runs.csv"))
    resultado = []

    for r in runs:
        idx = num(r.get("run"), int)
        if idx is None:
            continue
        t0 = num(r.get("t0_servidor_epoch"), int)
        t_submit = num(r.get("t_submit_epoch"), int)
        t_stop = num(r.get("t_stop_epoch"), int)
        reacao = num(r.get("reacao_s"), float)
        scaledown = num(r.get("scaledown_s"), float)
        lat_leitura = num(r.get("lat_leitura_ms"), float)
        lat_escrita = num(r.get("lat_escrita_ms"), float)
        # O caminho de armazenamento do control plane e o que sobra quando se
        # desconta a latencia de rede ate o apiserver (ver common.sh).
        lat_etcd = (lat_escrita - lat_leitura) if (
            lat_escrita is not None and lat_leitura is not None) else None

        serie = ler_csv(os.path.join(dir_amb, "run-%02d.csv" % idx))
        pontos = []
        for s in serie:
            te = num(s.get("t_epoch"), int)
            if te is None or t0 is None:
                continue
            pontos.append({
                "dt": te - t0,
                "cur": num(s.get("hpa_current"), int),
                "des": num(s.get("hpa_desired"), int),
                "cpu": num(s.get("cpu_pct"), float),
                "rdy": num(s.get("deploy_ready"), int),
            })
        pontos.sort(key=lambda p: p["dt"])

        janela_carga = [p for p in pontos if t_stop is not None and 0 <= p["dt"] <= (t_stop - t0)]
        desejadas = [p["des"] for p in janela_carga if p["des"] is not None]
        cpus = [p["cpu"] for p in janela_carga if p["cpu"] is not None]
        prontas = [p["rdy"] for p in janela_carga if p["rdy"] is not None]

        replicas_max = max(desejadas) if desejadas else None
        cpu_pico = max(cpus) if cpus else None

        # Reacao derivada do polling: primeira amostra com desired > 1.
        # Serve de verificacao cruzada da metrica primaria (lastScaleTime).
        reacao_polling = None
        for p in janela_carga:
            if p["des"] is not None and p["des"] > 1:
                reacao_polling = p["dt"]
                break

        # Tempo ate o regime permanente: primeiro instante em que o numero de
        # replicas PRONTAS atinge o maximo da repeticao e nao volta a cair.
        t_regime = None
        if prontas and replicas_max:
            alvo = max(prontas)
            for i, p in enumerate(janela_carga):
                if p["rdy"] == alvo and all(
                    q["rdy"] is None or q["rdy"] >= alvo for q in janela_carga[i:]
                ):
                    t_regime = p["dt"]
                    break

        # Latencia de partida do gerador: submissao -> container em execucao.
        partida_gerador = (t0 - t_submit) if (t0 and t_submit) else None

        resultado.append({
            "ambiente": ambiente,
            "run": idx,
            "reacao_s": reacao,
            "reacao_polling_s": reacao_polling,
            "replicas_max": replicas_max,
            "cpu_pico_pct": cpu_pico,
            "t_regime_s": t_regime,
            "partida_gerador_s": partida_gerador,
            "scaledown_s": scaledown,
            "lat_leitura_ms": lat_leitura,
            "lat_escrita_ms": lat_escrita,
            "lat_etcd_ms": lat_etcd,
            "amostras": len(pontos),
            "serie": pontos,
        })
    return resultado


# =============================================================================
# Descritivas
# =============================================================================
CAMPOS_METRICA = [
    ("reacao_s", "Tempo de reacao do HPA (s)"),
    ("t_regime_s", "Tempo ate o regime permanente (s)"),
    ("replicas_max", "Replicas no regime permanente"),
    ("cpu_pico_pct", "CPU de pico observada (%)"),
    ("partida_gerador_s", "Partida do gerador de carga (s)"),
    ("scaledown_s", "Retorno ao minimo apos a carga (s)"),
    ("lat_leitura_ms", "Latencia de leitura do apiserver (ms)"),
    ("lat_escrita_ms", "Latencia de escrita no control plane (ms)"),
    # Sem virgula no rotulo: estes CSVs sao evidencia e serao abertos com
    # ferramentas simples (awk, cut, planilha). Um campo entre aspas contendo
    # virgula e valido em CSV, mas faz qualquer parser ingenuo ler a linha
    # desalinhada -- e silenciosamente.
    ("lat_etcd_ms", "Parcela de armazenamento em ms (escrita menos leitura)"),
]

# O relatorio em Markdown e escrito em portugues (documentacao do repositorio),
# mas as tabelas geradas vao direto para o artigo, que o enunciado exige em
# ingles. Um unico mapa evita traduzir a mao e evita que as duas saidas
# divirjam quando uma metrica for adicionada.
# Rotulos em portugues PARA LATEX. Existem separados dos de CAMPOS_METRICA por
# duas razoes: (a) o "%" precisa ser escapado -- sem isso ele comenta o resto da
# linha e desalinha a tabela inteira; (b) o relatorio em Markdown e escrito sem
# acentos, mas o artigo os exige.
ROTULO_PT_TEX = {
    "reacao_s": "Tempo de reação do HPA (s)",
    "t_regime_s": "Tempo até o regime permanente (s)",
    "replicas_max": "Réplicas no regime permanente",
    "cpu_pico_pct": "CPU de pico observada (\\%)",
    "partida_gerador_s": "Partida do gerador de carga (s)",
    "scaledown_s": "Retorno ao mínimo após a carga (s)",
    "lat_leitura_ms": "Latência de leitura do \\emph{API server} (ms)",
    "lat_escrita_ms": "Latência de escrita no \\emph{control plane} (ms)",
    "lat_etcd_ms": "Parcela de armazenamento em ms (escrita $-$ leitura)",
}
ROTULO_EN = {
    "reacao_s": "HPA reaction time (s)",
    "t_regime_s": "Time to steady state (s)",
    "replicas_max": "Replicas at steady state",
    "cpu_pico_pct": "Peak observed CPU (\\%)",
    "partida_gerador_s": "Load generator start-up (s)",
    "scaledown_s": "Return to minimum after load (s)",
    "lat_leitura_ms": "API server read latency (ms)",
    "lat_escrita_ms": "Control-plane write latency (ms)",
    "lat_etcd_ms": "Storage component in ms (write $-$ read)",
}
AMBIENTE_EN = {"minikube": "Minikube", "eks": "EKS"}


def coletar(dados, campo):
    return [d[campo] for d in dados if d.get(campo) is not None]


def descritivas(xs):
    if not xs:
        return None
    ic = ic_bootstrap(xs)
    return {
        "n": len(xs),
        "media": media(xs),
        "dp": desvio_padrao(xs),
        "cv": coef_variacao(xs),
        "min": min(xs),
        "q1": quantil(xs, 0.25),
        "mediana": mediana(xs),
        "q3": quantil(xs, 0.75),
        "max": max(xs),
        "mad": mad(xs),
        "ic_baixo": ic[0],
        "ic_alto": ic[1],
    }


def fmt(v, casas=1):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "--"
    if isinstance(v, float):
        return ("%." + str(casas) + "f") % v
    return str(v)


# =============================================================================
# Escrita das saidas
# =============================================================================
def escrever_por_repeticao(todos):
    caminho = os.path.join(DIR_SAIDA, "por-repeticao.csv")
    campos = ["ambiente", "run", "reacao_s", "reacao_polling_s", "replicas_max",
              "cpu_pico_pct", "t_regime_s", "partida_gerador_s", "scaledown_s",
              "lat_leitura_ms", "lat_escrita_ms", "lat_etcd_ms", "amostras"]
    with open(caminho, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=campos)
        w.writeheader()
        for d in todos:
            w.writerow({c: d.get(c) for c in campos})
    return caminho


def escrever_estatisticas(stats):
    caminho = os.path.join(DIR_SAIDA, "estatisticas.csv")
    with open(caminho, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["metrica", "ambiente", "n", "media", "desvio_padrao", "cv",
                    "min", "q1", "mediana", "q3", "max", "mad",
                    "ic95_media_baixo", "ic95_media_alto"])
        for campo, rotulo in CAMPOS_METRICA:
            for amb in AMBIENTES:
                d = stats.get((campo, amb))
                if not d:
                    continue
                w.writerow([rotulo, amb, d["n"], "%.3f" % d["media"], "%.3f" % d["dp"],
                            "%.4f" % d["cv"], d["min"], d["q1"], d["mediana"], d["q3"],
                            d["max"], d["mad"], "%.3f" % d["ic_baixo"], "%.3f" % d["ic_alto"]])
    return caminho


def escrever_series(dados_por_amb):
    """Trajetoria agregada replicas-vs-tempo, em bins de 5 s, para o artigo.

    Publica mediana e quartis em vez de media e desvio: o numero de replicas e
    discreto e a mediana entre repeticoes e mais informativa que uma media
    fracionaria."""
    caminhos = []
    for amb, dados in dados_por_amb.items():
        baldes = defaultdict(lambda: {"des": [], "rdy": [], "cpu": []})
        for d in dados:
            for p in d["serie"]:
                if p["dt"] < -10 or p["dt"] > 300:
                    continue
                b = int(round(p["dt"] / 5.0)) * 5
                if p["des"] is not None:
                    baldes[b]["des"].append(p["des"])
                if p["rdy"] is not None:
                    baldes[b]["rdy"].append(p["rdy"])
                if p["cpu"] is not None:
                    baldes[b]["cpu"].append(p["cpu"])
        caminho = os.path.join(DIR_SAIDA, "serie-%s.csv" % amb)
        with open(caminho, "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(["t", "des_mediana", "des_q1", "des_q3",
                        "rdy_mediana", "cpu_mediana", "cpu_q1", "cpu_q3", "n"])
            for b in sorted(baldes):
                v = baldes[b]
                if not v["des"]:
                    continue
                w.writerow([b,
                            "%.2f" % mediana(v["des"]), "%.2f" % quantil(v["des"], 0.25),
                            "%.2f" % quantil(v["des"], 0.75),
                            "%.2f" % (mediana(v["rdy"]) if v["rdy"] else float("nan")),
                            "%.2f" % (mediana(v["cpu"]) if v["cpu"] else float("nan")),
                            "%.2f" % (quantil(v["cpu"], 0.25) if v["cpu"] else float("nan")),
                            "%.2f" % (quantil(v["cpu"], 0.75) if v["cpu"] else float("nan")),
                            len(v["des"])])
        caminhos.append(caminho)
    return caminhos


def escrever_reacao_por_ambiente(dados_por_amb):
    """Um CSV por ambiente com o tempo de reacao de cada repeticao.

    Existe para simplificar as figuras: o pgfplots le colunas numericas de um
    arquivo sem precisar filtrar linhas por um campo de texto."""
    caminhos = []
    for amb, dados in dados_por_amb.items():
        caminho = os.path.join(DIR_SAIDA, "reacao-%s.csv" % amb)
        with open(caminho, "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(["run", "reacao_s", "reacao_polling_s", "partida_gerador_s", "t_regime_s"])
            for d in sorted(dados, key=lambda r: r["run"]):
                w.writerow([d["run"],
                            d.get("reacao_s") if d.get("reacao_s") is not None else "",
                            d.get("reacao_polling_s") if d.get("reacao_polling_s") is not None else "",
                            d.get("partida_gerador_s") if d.get("partida_gerador_s") is not None else "",
                            d.get("t_regime_s") if d.get("t_regime_s") is not None else ""])
        caminhos.append(caminho)
    return caminhos


def escrever_ecdf(amostras_por_amb):
    caminhos = []
    for amb, xs in amostras_por_amb.items():
        if not xs:
            continue
        caminho = os.path.join(DIR_SAIDA, "ecdf-%s.csv" % amb)
        with open(caminho, "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(["reacao_s", "prob_acumulada"])
            ys = sorted(xs)
            for i, v in enumerate(ys, start=1):
                w.writerow(["%.1f" % v, "%.4f" % (i / len(ys))])
        caminhos.append(caminho)
    return caminhos


# Cabecalhos e legendas das tabelas nas duas linguas. O artigo entregue e em
# portugues; a versao em ingles e mantida compilavel porque o enunciado do
# trabalho pedia ingles. Gerar as duas a partir da MESMA analise garante que
# nunca divirjam numericamente.
TEXTO_TABELA = {
    "pt": {
        "cap1": "Estatísticas descritivas das repetições "
                "(IC de 95\\,\\%% da média por bootstrap, $B=%d$).",
        "cab1": "\\textbf{Métrica} & \\textbf{Ambiente} & $n$ & \\textbf{Média} & "
                "\\textbf{DP} & \\textbf{CV} & \\textbf{Mediana} & \\textbf{IIQ} & "
                "\\textbf{IC 95\\%}\\\\",
        "cap2": "Testes de hipótese, Minikube vs.\\ EKS.",
        "cab2": "\\textbf{Teste} & \\textbf{Estatística} & $p$ & "
                "\\textbf{Tamanho de efeito}\\\\",
        "amb": {"minikube": "Minikube", "eks": "EKS"},
    },
    "en": {
        "cap1": "Descriptive statistics over the repeated runs "
                "(95\\,\\%% bootstrap CI of the mean, $B=%d$).",
        "cab1": "\\textbf{Metric} & \\textbf{Environment} & $n$ & \\textbf{Mean} & "
                "\\textbf{SD} & \\textbf{CV} & \\textbf{Median} & \\textbf{IQR} & "
                "\\textbf{95\\% CI}\\\\",
        "cap2": "Hypothesis tests, Minikube vs.\\ EKS.",
        "cab2": "\\textbf{Test} & \\textbf{Statistic} & $p$ & \\textbf{Effect size}\\\\",
        "amb": AMBIENTE_EN,
    },
}


def escrever_tabelas_tex(stats, testes, idioma):
    t9 = TEXTO_TABELA[idioma]
    caminho = os.path.join(DIR_SAIDA, "tabelas-%s.tex" % idioma)
    linhas = []
    linhas.append("% Gerado por scripts/11-analyze.py -- nao editar a mao.")
    linhas.append("% Tabela 1: descritivas por ambiente.")
    linhas.append("\\begin{table*}[!t]")
    linhas.append("\\centering")
    linhas.append("\\caption{" + (t9["cap1"] % B_BOOTSTRAP) + "}")
    linhas.append("\\label{tab:descritivas}")
    linhas.append("\\footnotesize")
    linhas.append("\\begin{tabular}{@{}llrrrrrrr@{}}")
    linhas.append("\\toprule")
    linhas.append(t9["cab1"])
    linhas.append("\\midrule")
    for campo, rotulo in CAMPOS_METRICA:
        for amb in AMBIENTES:
            d = stats.get((campo, amb))
            if not d:
                continue
            mapa = ROTULO_PT_TEX if idioma == "pt" else ROTULO_EN
            nome = mapa.get(campo, rotulo)
            linhas.append("%s & %s & %d & %s & %s & %s & %s & %s--%s & [%s, %s]\\\\" % (
                nome, t9["amb"].get(amb, amb),
                d["n"], fmt(d["media"], 1),
                fmt(d["dp"], 1), fmt(d["cv"], 2), fmt(d["mediana"], 1),
                fmt(d["q1"], 1), fmt(d["q3"], 1),
                fmt(d["ic_baixo"], 1), fmt(d["ic_alto"], 1)))
        linhas.append("\\addlinespace")
    linhas.append("\\bottomrule")
    linhas.append("\\end{tabular}")
    linhas.append("\\end{table*}")
    linhas.append("")
    linhas.append("% Tabela 2: testes de hipotese.")
    # table* (largura das duas colunas): as celulas trazem estatistica e
    # tamanho de efeito em modo matematico e nao cabem em uma coluna de ~8,8 cm
    # -- em uma coluna o LaTeX reportava um overfull de 56 pt.
    linhas.append("\\begin{table*}[!t]")
    linhas.append("\\centering")
    linhas.append("\\caption{" + t9["cap2"] + "}")
    linhas.append("\\label{tab:testes}")
    linhas.append("\\footnotesize")
    linhas.append("\\begin{tabular}{@{}llll@{}}")
    linhas.append("\\toprule")
    linhas.append(t9["cab2"])
    linhas.append("\\midrule")
    for t in testes:
        linhas.append("%s & %s & %s & %s\\\\" % (
            t["nome_" + idioma],
            t.get("estatistica_" + idioma, t.get("estatistica", "--")),
            t["p"],
            t["efeito_" + idioma]))
    linhas.append("\\bottomrule")
    linhas.append("\\end{tabular}")
    linhas.append("\\end{table*}")
    # Rede de seguranca: um "%" nao escapado dentro de uma celula comenta o
    # resto da linha, engole o "\\" que termina a linha da tabela e faz o LaTeX
    # falhar com "Misplaced \noalign" varias linhas adiante -- longe da causa.
    # A verificacao custa nada e aponta a celula responsavel.
    for i, linha in enumerate(linhas, start=1):
        if linha.startswith("%"):
            continue  # comentario proposital do arquivo gerado
        sem_escape = re.sub(r"\\%", "", linha)
        if "%" in sem_escape:
            raise ValueError(
                "%s linha %d tem '%%' nao escapado (comentaria a linha em LaTeX): %s"
                % (os.path.basename(caminho), i, linha))

    with open(caminho, "w", encoding="utf-8") as f:
        f.write("\n".join(linhas) + "\n")
    return caminho


# =============================================================================
# Relatorio
# =============================================================================
def main():
    os.makedirs(DIR_SAIDA, exist_ok=True)

    dados_por_amb = {}
    for amb in AMBIENTES:
        d = derivar_metricas(amb)
        if d:
            dados_por_amb[amb] = d

    if not dados_por_amb:
        print("Nenhum dado encontrado em %s. Rode a campanha antes." % DIR_DADOS)
        return 1

    todos = [d for amb in AMBIENTES for d in dados_por_amb.get(amb, [])]

    stats = {}
    for campo, _ in CAMPOS_METRICA:
        for amb in AMBIENTES:
            xs = coletar(dados_por_amb.get(amb, []), campo)
            d = descritivas(xs)
            if d:
                stats[(campo, amb)] = d

    reacao = {amb: coletar(dados_por_amb.get(amb, []), "reacao_s") for amb in AMBIENTES}
    x, y = reacao.get("minikube", []), reacao.get("eks", [])

    testes = []
    relatorio = []
    relatorio.append("# Resultados da campanha de repeticoes -- HPA\n")
    relatorio.append("Gerado por `scripts/11-analyze.py` (semente %d, "
                     "B=%d reamostragens, %d permutacoes).\n" %
                     (SEED, B_BOOTSTRAP, N_PERMUTACOES))

    relatorio.append("\n## Amostra\n")
    for amb in AMBIENTES:
        d = dados_por_amb.get(amb, [])
        if d:
            relatorio.append("- **%s**: %d repeticoes validas, %d amostras de serie temporal.\n"
                             % (ROTULO[amb], len(d), sum(r["amostras"] for r in d)))

    relatorio.append("\n## Descritivas por ambiente\n")
    for campo, rotulo in CAMPOS_METRICA:
        tem = [amb for amb in AMBIENTES if (campo, amb) in stats]
        if not tem:
            continue
        relatorio.append("\n### %s\n\n" % rotulo)
        relatorio.append("| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |\n")
        relatorio.append("|---|---|---|---|---|---|---|---|---|\n")
        for amb in tem:
            d = stats[(campo, amb)]
            relatorio.append("| %s | %d | %s | %s | %s | %s | %s | %s | [%s, %s] |\n" % (
                ROTULO[amb], d["n"], fmt(d["media"]), fmt(d["dp"]), fmt(d["cv"], 2),
                fmt(d["min"]), fmt(d["mediana"]), fmt(d["max"]),
                fmt(d["ic_baixo"]), fmt(d["ic_alto"])))

    if x and y:
        relatorio.append("\n## Teste de hipotese sobre o tempo de reacao\n")

        u, z, p = mann_whitney(x, y)
        delta = cliffs_delta(x, y)
        a = a12(x, y)
        testes.append({
            "nome_pt": "Mann--Whitney $U$ (tempo de reação)",
            "nome_en": "Mann--Whitney $U$ (reaction time)",
            "estatistica": "$U=%s$, $z=%s$" % (fmt(u, 1), fmt(z, 2)),
            "p": fmt(p, 4),
            "efeito_pt": "$\\delta=%s$ (%s)" % (fmt(delta, 3), magnitude_delta(delta)),
            "efeito_en": "$\\delta=%s$ (%s)" % (fmt(delta, 3),
                                                magnitude_delta(delta, ingles=True)),
        })
        relatorio.append("\n- **Mann-Whitney U** (bilateral, com correcao de empates): "
                         "U = %s, z = %s, p = %s\n" % (fmt(u, 1), fmt(z, 2), fmt(p, 4)))
        relatorio.append("- **Cliff's delta** = %s (%s); **A12** = %s\n"
                         % (fmt(delta, 3), magnitude_delta(delta), fmt(a, 3)))
        relatorio.append("  - Leitura direta: uma repeticao sorteada do Minikube apresenta "
                         "tempo de reacao maior que uma repeticao sorteada do EKS em "
                         "**%s%%** dos pares possiveis.\n" % fmt(a * 100, 1))

        obs_med, p_med = teste_permutacao(x, y, dif_medianas)
        testes.append({
            "nome_pt": "Permutação (diferença de medianas)",
            "nome_en": "Permutation (median difference)",
            "estatistica": "$\\Delta=%s$\\,s" % fmt(obs_med, 1),
            "p": fmt(p_med, 4),
            "efeito_pt": "--",
            "efeito_en": "--",
        })
        relatorio.append("- **Teste de permutacao da diferenca de medianas**: "
                         "diferenca observada = %s s, p = %s\n" % (fmt(obs_med, 1), fmt(p_med, 4)))

        obs_disp, p_disp = teste_permutacao(x, y, log_razao_dispersao)
        razao = math.exp(obs_disp) if not math.isnan(obs_disp) else float("nan")
        testes.append({
            "nome_pt": "Permutação (razão de dispersões)",
            "nome_en": "Permutation (dispersion ratio)",
            "estatistica_pt": "razão de MAD $=%s$" % fmt(razao, 2),
            "estatistica_en": "MAD ratio $=%s$" % fmt(razao, 2),
            "p": fmt(p_disp, 4),
            "efeito_pt": "--",
            "efeito_en": "--",
        })
        relatorio.append("- **Teste de permutacao da razao de dispersoes** "
                         "(MAD Minikube / MAD EKS): razao = %s, p = %s\n"
                         % (fmt(razao, 2), fmt(p_disp, 4)))

        # ---------------------------------------------------------------
        # A pergunta central do trabalho: uma execucao unica por ambiente --
        # exatamente o desenho do trabalho intermediario -- teria produzido a
        # conclusao correta sobre qual ambiente reage mais rapido?
        # ---------------------------------------------------------------
        p_mini_maior = a
        p_empate = sum(1 for a_ in x for b_ in y if a_ == b_) / (len(x) * len(y))
        p_eks_maior = 1.0 - p_mini_maior - p_empate / 2.0
        relatorio.append("\n## Quao enganosa e uma execucao unica?\n\n")
        relatorio.append("Sorteando UMA repeticao de cada ambiente (o desenho do trabalho "
                         "intermediario), a probabilidade de cada conclusao possivel e:\n\n")
        relatorio.append("| Conclusao a que o experimento levaria | Probabilidade |\n")
        relatorio.append("|---|---|\n")
        relatorio.append("| \"o EKS reage mais rapido\" | %s%% |\n" % fmt(p_mini_maior * 100, 1))
        relatorio.append("| \"o Minikube reage mais rapido\" | %s%% |\n" % fmt(p_eks_maior * 100, 1))
        relatorio.append("| empate exato | %s%% |\n" % fmt(p_empate * 100, 1))

    # -------------------------------------------------------------------
    # As repeticoes mais lentas sao aquelas em que o control plane estava
    # degradado? Se sim, a dispersao do tempo de reacao tem uma explicacao
    # mecanica -- e nao e uma propriedade intrinseca do ambiente.
    # -------------------------------------------------------------------
    relatorio.append("\n## O que explica a dispersao?\n\n")
    relatorio.append("Correlacao de Spearman entre o tempo de reacao de cada repeticao e cinco "
                     "covariaveis medidas na mesma repeticao, cada uma representando uma "
                     "explicacao candidata (p-valor por permutacao). A ausencia de correlacao "
                     "com todas elas e, em si, um resultado: indica que a dispersao vem da fase "
                     "em que a carga cai no ciclo periodico de coleta e sincronizacao, e nao de "
                     "uma degradacao observavel do ambiente.\n\n")
    relatorio.append("| Ambiente | covariavel | n | rho | p |\n")
    relatorio.append("|---|---|---|---|---|\n")
    houve_correlacao = False
    # Cada covariavel corresponde a uma explicacao candidata para a dispersao:
    #   latencia de escrita / armazenamento -> control plane degradado
    #   partida do gerador                  -> custo de agendar e iniciar o Pod
    #   CPU de pico                         -> intensidade da carga naquela rodada
    #   indice da repeticao                 -> deriva ao longo da campanha
    #                                          (cache aquecendo, efeito termico)
    covariaveis = (("lat_escrita_ms", "latencia de escrita"),
                   ("lat_etcd_ms", "parcela de armazenamento"),
                   ("partida_gerador_s", "partida do gerador"),
                   ("cpu_pico_pct", "CPU de pico"),
                   ("run", "indice da repeticao (deriva)"))
    for amb in AMBIENTES:
        dados = dados_por_amb.get(amb, [])
        for campo, nome in covariaveis:
            pares = [(d["reacao_s"], d[campo]) for d in dados
                     if d.get("reacao_s") is not None and d.get(campo) is not None]
            if len(pares) < 4:
                continue
            houve_correlacao = True
            rho, p = spearman([a for a, _ in pares], [b for _, b in pares])
            relatorio.append("| %s | %s | %d | %s | %s |\n"
                             % (ROTULO[amb], nome, len(pares), fmt(rho, 3), fmt(p, 4)))
    if not houve_correlacao:
        relatorio.append("| -- | -- | -- | -- | -- |\n")
        relatorio.append("\n(Sem dados de latencia suficientes nesta campanha.)\n")

    # -------------------------------------------------------------------
    # Onde as observacoes isoladas do trabalho intermediario caem dentro da
    # distribuicao agora medida? Esta e a ponte entre os dois trabalhos: se
    # aqueles valores forem observacoes perfeitamente comuns da mesma
    # distribuicao, entao nao havia efeito de plataforma a explicar -- havia
    # apenas duas amostras de tamanho um.
    # -------------------------------------------------------------------
    relatorio.append("\n## Onde caem as execucoes do trabalho intermediario?\n\n")
    relatorio.append("Percentil empirico de cada valor relatado no trabalho anterior, "
                     "dentro da distribuicao medida nesta campanha para o mesmo ambiente. "
                     "(Aproximado: veja a ressalva de instrumentacao no codigo.)\n\n")
    relatorio.append("| Execucao anterior | Ambiente | Valor relatado | Percentil na nova amostra |\n")
    relatorio.append("|---|---|---|---|\n")
    for nome, amb, valor in EXECUCOES_ANTERIORES:
        xs = reacao.get(amb, [])
        if not xs:
            relatorio.append("| %s | %s | %s s | (sem campanha) |\n"
                             % (nome, ROTULO[amb], fmt(valor, 0)))
            continue
        abaixo = sum(1 for v in xs if v < valor)
        iguais = sum(1 for v in xs if v == valor)
        pct = 100.0 * (abaixo + 0.5 * iguais) / len(xs)
        relatorio.append("| %s | %s | %s s | %s%% |\n"
                         % (nome, ROTULO[amb], fmt(valor, 0), fmt(pct, 0)))

    caminhos = []
    caminhos.append(escrever_por_repeticao(todos))
    caminhos.append(escrever_estatisticas(stats))
    caminhos.extend(escrever_series(dados_por_amb))
    caminhos.extend(escrever_reacao_por_ambiente(dados_por_amb))
    caminhos.extend(escrever_ecdf(reacao))
    for idioma in ("pt", "en"):
        caminhos.append(escrever_tabelas_tex(stats, testes, idioma))

    caminho_md = os.path.join(DIR_SAIDA, "RESULTADOS.md")
    with open(caminho_md, "w", encoding="utf-8") as f:
        f.write("".join(relatorio))
    caminhos.append(caminho_md)

    print("".join(relatorio))
    print("\nArquivos gerados:")
    for c in caminhos:
        print("  " + os.path.relpath(c, RAIZ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
