# Resultados da campanha de repeticoes -- HPA
Gerado por `scripts/11-analyze.py` (semente 20260927, B=20000 reamostragens, 50000 permutacoes).

## Amostra
- **Minikube (local)**: 20 repeticoes validas, 2849 amostras de serie temporal.
- **AWS EKS (nuvem)**: 20 repeticoes validas, 2988 amostras de serie temporal.

## Descritivas por ambiente

### Tempo de reacao do HPA (s)

| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |
|---|---|---|---|---|---|---|---|---|
| Minikube (local) | 20 | 40.8 | 18.5 | 0.45 | 19.0 | 33.5 | 87.0 | [33.5, 49.2] |
| AWS EKS (nuvem) | 20 | 24.7 | 5.9 | 0.24 | 14.0 | 24.5 | 36.0 | [22.1, 27.3] |

### Tempo ate o regime permanente (s)

| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |
|---|---|---|---|---|---|---|---|---|
| Minikube (local) | 20 | 197.6 | 23.1 | 0.12 | 155 | 204.5 | 225 | [187.6, 207.1] |
| AWS EKS (nuvem) | 20 | 83.0 | 46.7 | 0.56 | 47 | 69.5 | 241 | [65.8, 105.8] |

### Replicas no regime permanente

| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |
|---|---|---|---|---|---|---|---|---|
| Minikube (local) | 20 | 6.0 | 0.4 | 0.07 | 5 | 6.0 | 7 | [5.9, 6.2] |
| AWS EKS (nuvem) | 20 | 6.7 | 0.6 | 0.09 | 6 | 7.0 | 8 | [6.4, 6.9] |

### CPU de pico observada (%)

| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |
|---|---|---|---|---|---|---|---|---|
| Minikube (local) | 20 | 176.5 | 37.5 | 0.21 | 130.0 | 167.0 | 250.0 | [161.4, 193.6] |
| AWS EKS (nuvem) | 20 | 236.2 | 21.5 | 0.09 | 176.0 | 244.0 | 251.0 | [226.1, 244.2] |

### Partida do gerador de carga (s)

| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |
|---|---|---|---|---|---|---|---|---|
| Minikube (local) | 20 | 2.4 | 1.0 | 0.41 | 1 | 2.0 | 4 | [2.0, 2.8] |
| AWS EKS (nuvem) | 20 | 1.8 | 0.4 | 0.25 | 1 | 2.0 | 2 | [1.6, 1.9] |

### Retorno ao minimo apos a carga (s)

| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |
|---|---|---|---|---|---|---|---|---|
| Minikube (local) | 3 | 453.0 | 6.9 | 0.02 | 449.0 | 449.0 | 461.0 | [449.0, 461.0] |
| AWS EKS (nuvem) | 3 | 388.7 | 10.7 | 0.03 | 382.0 | 383.0 | 401.0 | [382.0, 401.0] |

### Latencia de leitura do apiserver (ms)

| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |
|---|---|---|---|---|---|---|---|---|
| Minikube (local) | 20 | 108.8 | 3.4 | 0.03 | 104.0 | 108.0 | 115.0 | [107.4, 110.3] |
| AWS EKS (nuvem) | 20 | 547.4 | 53.6 | 0.10 | 510.0 | 519.5 | 652.0 | [527.0, 571.7] |

### Latencia de escrita no control plane (ms)

| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |
|---|---|---|---|---|---|---|---|---|
| Minikube (local) | 20 | 464.8 | 575.5 | 1.24 | 114.0 | 197.5 | 2534.0 | [258.4, 743.6] |
| AWS EKS (nuvem) | 20 | 555.2 | 57.1 | 0.10 | 517.0 | 525.5 | 683.0 | [532.5, 581.0] |

### Parcela de armazenamento em ms (escrita menos leitura)

| Ambiente | n | media | dp | CV | min | mediana | max | IC95% da media |
|---|---|---|---|---|---|---|---|---|
| Minikube (local) | 20 | 355.9 | 576.1 | 1.62 | 8.0 | 92.0 | 2425.0 | [149.7, 630.2] |
| AWS EKS (nuvem) | 20 | 7.8 | 14.2 | 1.81 | -7.0 | 6.0 | 62.0 | [3.0, 14.8] |

## Teste de hipotese sobre o tempo de reacao

- **Mann-Whitney U** (bilateral, com correcao de empates): U = 52.0, z = -3.99, p = 0.0001
- **Cliff's delta** = 0.740 (grande); **A12** = 0.870
  - Leitura direta: uma repeticao sorteada do Minikube apresenta tempo de reacao maior que uma repeticao sorteada do EKS em **87.0%** dos pares possiveis.
- **Teste de permutacao da diferenca de medianas**: diferenca observada = 9.0 s, p = 0.0004
- **Teste de permutacao da razao de dispersoes** (MAD Minikube / MAD EKS): razao = 1.33, p = 0.4098

## Quao enganosa e uma execucao unica?

Sorteando UMA repeticao de cada ambiente (o desenho do trabalho intermediario), a probabilidade de cada conclusao possivel e:

| Conclusao a que o experimento levaria | Probabilidade |
|---|---|
| "o EKS reage mais rapido" | 87.0% |
| "o Minikube reage mais rapido" | 12.2% |
| empate exato | 1.5% |

## O que explica a dispersao?

Correlacao de Spearman entre o tempo de reacao de cada repeticao e cinco covariaveis medidas na mesma repeticao, cada uma representando uma explicacao candidata (p-valor por permutacao). A ausencia de correlacao com todas elas e, em si, um resultado: indica que a dispersao vem da fase em que a carga cai no ciclo periodico de coleta e sincronizacao, e nao de uma degradacao observavel do ambiente.

| Ambiente | covariavel | n | rho | p |
|---|---|---|---|---|
| Minikube (local) | latencia de escrita | 20 | -0.329 | 0.1592 |
| Minikube (local) | parcela de armazenamento | 20 | -0.334 | 0.1516 |
| Minikube (local) | partida do gerador | 20 | -0.325 | 0.1600 |
| Minikube (local) | CPU de pico | 20 | 0.083 | 0.7213 |
| Minikube (local) | indice da repeticao (deriva) | 20 | 0.284 | 0.2195 |
| AWS EKS (nuvem) | latencia de escrita | 20 | -0.767 | 0.0004 |
| AWS EKS (nuvem) | parcela de armazenamento | 20 | -0.142 | 0.5439 |
| AWS EKS (nuvem) | partida do gerador | 20 | -0.271 | 0.2539 |
| AWS EKS (nuvem) | CPU de pico | 20 | 0.687 | 0.0014 |
| AWS EKS (nuvem) | indice da repeticao (deriva) | 20 | 0.206 | 0.3882 |

## Onde caem as execucoes do trabalho intermediario?

Percentil empirico de cada valor relatado no trabalho anterior, dentro da distribuicao medida nesta campanha para o mesmo ambiente. (Aproximado: veja a ressalva de instrumentacao no codigo.)

| Execucao anterior | Ambiente | Valor relatado | Percentil na nova amostra |
|---|---|---|---|
| E1 (Jose) | Minikube (local) | 62 s | 82% |
| E1 (Jose) | AWS EKS (nuvem) | 15 s | 10% |
| E2 (Fernando) | Minikube (local) | 33 s | 45% |
| E2 (Fernando) | AWS EKS (nuvem) | 60 s | 100% |
