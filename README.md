# Autoescalamento Horizontal de Pods no Kubernetes — Minikube e AWS EKS

**Disciplina:** PSI5120 – Tópicos em Computação em Nuvem (2026)

Este repositório reúne os **dois trabalhos** da disciplina. O trabalho final é a
continuação direta do intermediário: mesma aplicação, mesmos manifestos, mesmo
protocolo de carga — muda o desenho experimental, e com ele a conclusão.

| Trabalho | Pasta | Em uma linha |
|---|---|---|
| **Intermediário** — Atividade Prática 1 | [`intermediario/`](intermediario/) | Servidor web com HPA implantado e testado em Minikube e AWS EKS, uma execução por integrante |
| **Final** — Proposta 2.2 (extensão) | [`final/`](final/) | O tempo de reação do HPA tratado como **variável aleatória**: 20 repetições por ambiente |

A aplicação alvo, nos dois trabalhos, é a imagem oficial
`registry.k8s.io/hpa-example` (Apache + PHP que consome CPU sob carga), escalada
de 1 a 10 réplicas com meta de 50% de CPU, em dois ambientes:

- **Implantação A (Local):** cluster Kubernetes com **Minikube**.
- **Implantação B (Nuvem):** cluster gerenciado **AWS EKS** (criado via `eksctl`).

## Autores

- José Vitor Feitosa de Andrade — NUSP 13682041
- Fernando Frederice Miqueletti — NUSP 12544340

## Estrutura

```
.
├── README.md                   # este arquivo
├── intermediario/              # Atividade Prática 1
│   ├── README.md               # documentação entregue no trabalho intermediário
│   ├── ROTEIRO.md              # passo a passo de implantação e testes
│   ├── manifests/              # Deployment, Service e HPA
│   ├── scripts/                # automações das duas implantações
│   ├── artigo/                 # artigo técnico (Markdown e LaTeX/IEEE)
│   └── evidencias/             # uma pasta por integrante: screenshots, logs e CSVs
└── final/                      # Trabalho Final
    ├── README.md               # documentação detalhada do trabalho final
    ├── manifests/              # idênticos aos do intermediário, mais o warmup
    ├── scripts/                # campanha de repetições, análise e compilação
    ├── artigo/                 # artigo em português e em inglês (.tex e .pdf)
    └── dados/                  # evidências medidas nas duas campanhas
```

## O trabalho intermediário

Implantação e teste de um servidor web com **Horizontal Pod Autoscaler (HPA)**
nos dois ambientes. Cada integrante executou o experimento completo de forma
independente, em máquinas e contas AWS distintas, com manifestos idênticos:
**E1 (José, 23/08/2026)** e **E2 (Fernando, 24/08/2026)**.

| Métrica | E1 Minikube | E1 EKS | E2 Minikube | E2 EKS |
|---|---|---|---|---|
| Réplicas: inicial → máxima | 1 → 6 | 1 → 6 | 1 → 6 | 1 → 7 |
| CPU de pico | 153% | 237% | 166% | ~70%* |
| **Tempo de reação do HPA** | 62 s | **15 s** | **~33 s** | ~60 s |
| Tempo de scale down | 7,6 min | 6,8 min | ~13–14 min | ~9–10 min |
| Custo | R$ 0 | ~US$ 0,15 | R$ 0 | ~US$ 0,10–0,15 |

<sub>\* O pico real não foi capturado em E2/EKS: as 7 réplicas absorveram a carga antes da primeira observação.</sub>

O HPA convergiu para **6–7 réplicas** nas quatro implantações, com a utilização
média estabilizando na meta de 50% — manifestos idênticos, mesmo resultado
lógico. **O tempo de reação, porém, não se reproduziu:** em E1 o EKS reagiu ~4×
mais rápido que o Minikube; em E2 ocorreu o inverso. Com uma execução por
ambiente, o trabalho concluiu que a diferença não era atribuível à plataforma.

Documentação completa em [`intermediario/README.md`](intermediario/README.md) e
[`intermediario/ROTEIRO.md`](intermediario/ROTEIRO.md).

## O trabalho final

Aquela conclusão foi tirada com n = 1 por ambiente: não havia média, desvio nem
teste — apenas a constatação de que o resultado era instável. O trabalho final
fecha essa lacuna. Mantém a implantação, a carga e o protocolo **inalterados**, e
muda apenas o desenho: **20 repetições por ambiente**, automatizadas e não
supervisionadas, com o tempo de reação tratado como variável aleatória.

Duas campanhas de 20 repetições, **sem nenhuma perda** (40/40 com status `ok`).

| Métrica | Minikube (local) | AWS EKS (nuvem) |
|---|---|---|
| **Tempo de reação** | 40,8 s ± 18,5 (CV **0,45**; 19–87) | 24,7 s ± 5,9 (CV **0,24**; 14–36) |
| Tempo até o regime permanente | 197,6 s ± 23,1 | 83,0 s ± 46,7 |
| Réplicas no regime | 6,0 (5–7) | 6,7 (6–8) |
| CPU de pico | 176,5% ± 37,5 | 236,2% ± 21,5 |
| Retorno ao mínimo (n = 3) | 453,0 s ± 6,9 | 388,7 s ± 10,7 |
| Latência de leitura do apiserver | 108,8 ms (CV 0,03) | 547,4 ms (CV 0,10) |
| Parcela de armazenamento | **355,9 ms** (mediana 92; máx. 2534) | **7,8 ms** (mediana 6) |

**1. Existe um efeito de plataforma — e o trabalho intermediário errou ao negá-lo.**
Mann-Whitney U = 52,0, p = 1×10⁻⁴, Cliff's δ = 0,74 (grande), A₁₂ = 0,87. O EKS
reage mais rápido. O que faltava ao trabalho anterior não era um argumento
melhor, era amostra.

**2. Uma execução única erra a direção do efeito 1 vez em 8.** Sorteando uma
repetição de cada ambiente, a ordenação correta aparece em apenas **87%** dos
casos. As quatro observações do trabalho intermediário caem nos percentis **82,
10, 45 e 100** das distribuições agora medidas — sorteios comuns que por acaso se
inverteram. Isso explica integralmente a irreprodutibilidade relatada antes.

**3. A dispersão não é explicada por nenhuma covariável medida.** No ambiente
local, nenhuma das cinco candidatas correlaciona com o tempo de reação (todos
p > 0,15), **apesar de** a latência de escrita local variar de 114 ms a 2534 ms.
O mecanismo compatível é a *fase*: a carga começa num ponto arbitrário do ciclo
periódico de coleta do Metrics Server e de sincronização do controlador.

**4. Tudo que é fixado por declaração se reproduz.** Convergência, meta de 50% e
descida assimétrica replicaram nos dois ambientes com variação de ~2%.

Análise completa em
[`final/dados/analise/RESULTADOS.md`](final/dados/analise/RESULTADOS.md);
documentação detalhada em [`final/README.md`](final/README.md).

### Artigo do trabalho final

| Arquivo | Conteúdo |
|---|---|
| [`final/artigo/artigo-final.pdf`](final/artigo/artigo-final.pdf) | Artigo em **português**, formato IEEE — 11 páginas |
| [`final/artigo/artigo-final-en.pdf`](final/artigo/artigo-final-en.pdf) | Artigo em **inglês**, formato IEEE — 10 páginas |

> As duas versões leem as **mesmas** tabelas geradas pela análise, de modo que
> não podem divergir numericamente. As figuras são geradas pelo pgfplots lendo
> diretamente os CSVs da análise — não há imagens intermediárias, então nenhum
> número do artigo pode discordar do dado medido.

### O que mudou do intermediário para o final

| | Intermediário | Final |
|---|---|---|
| Repetições por ambiente | 1 (por integrante) | 20 |
| Origem do tempo de reação | relógio do cliente + captura de tela | `hpa.status.lastScaleTime` e `pod.startedAt`, ambos carimbados pelo **cluster** |
| Intervalo de amostragem | 5 s | 2 s, igual nos dois ambientes |
| Estado inicial de cada execução | manual | verificado automaticamente |
| Desvio entre relógios | não medido | medido e registrado |
| Tratamento dos dados | tabelas descritivas | bootstrap, Mann-Whitney, Cliff's δ, testes de permutação, Spearman |

O que **não** mudou, de propósito: manifestos, imagem, `requests`/`limits`, meta
de 50%, `behavior` do HPA, gerador de carga e topologia do EKS (2 × `t3.small`,
`us-east-1`). Manter tudo isso idêntico é o que permite comparar as 20
repetições com as execuções E1 e E2.

## Início rápido

**Trabalho intermediário** (a partir de `intermediario/`):

```bash
bash scripts/01-minikube-setup.sh   # sobe o cluster e aplica tudo
bash scripts/03b-monitor.sh         # (terminal 2) monitora o HPA
bash scripts/03-load-test.sh        # (terminal 3) gera carga
bash scripts/05-cleanup-minikube.sh # limpeza

aws configure                       # credenciais AWS
bash scripts/02-eks-setup.sh        # cria o EKS e aplica tudo (~15-20 min)
bash scripts/04-cleanup-eks.sh      # DESTRÓI o cluster (evita custos)
```

> **Nota sobre os scripts `.ps1`/`.cmd`:** são auxiliares específicos do Windows,
> usados para coletar as evidências. Em Linux/macOS basta abrir dois terminais e
> rodar `03b-monitor.sh` e `03-load-test.sh` diretamente.

**Trabalho final** (a partir de `final/`):

```bash
bash scripts/00-preflight.sh                  # confere o ambiente

bash scripts/01-minikube-up.sh
bash scripts/10-run-campaign.sh minikube 20   # ~2,5 h, não supervisionado
bash scripts/91-cleanup-minikube.sh full

aws configure
bash scripts/02-eks-up.sh                     # inicia a cobrança por hora
bash scripts/10-run-campaign.sh eks 20        # ~2 h, não supervisionado
bash scripts/90-cleanup-eks.sh                # DESTRÓI o cluster e verifica

python3 scripts/11-analyze.py                 # análise (só biblioteca padrão)
bash scripts/12-prep-artigo.sh
bash scripts/17-compilar-artigo.sh            # compila e confere as páginas
```

## Aviso de custos (AWS)

O cluster EKS e os nós EC2 são cobrados por hora. **Sempre** destrua o cluster ao
terminar. No trabalho intermediário isso é `scripts/04-cleanup-eks.sh`, com
conferência manual no console da AWS. No trabalho final,
`scripts/90-cleanup-eks.sh` destrói **e verifica** automaticamente clusters EKS,
stacks do CloudFormation, instâncias EC2, NAT gateways, volumes EBS órfãos e IPs
elásticos remanescentes, salvando o resultado em `final/dados/limpeza/`.

Na campanha do trabalho final o cluster ficou ativo ~4,6 h. O custo **faturado**
apurado pelo Cost Explorer foi de **US$ 0,00** (a conta de laboratório utilizada
não é cobrada por EKS, EC2 nem VPC — ver `final/dados/custo/`); o equivalente **a
preço de tabela** seria de ~**US$ 0,90**, e é esse o número relevante para quem
reproduzir em conta própria.

## Referências

1. [Kubernetes — HPA Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
2. [Kubernetes — HPA Algorithm Details](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
3. [AWS EKS — Horizontal Pod Autoscaler](https://docs.aws.amazon.com/eks/latest/userguide/horizontal-pod-autoscaler.html)
4. [eksctl](https://eksctl.io/)
5. [Metrics Server (SIG)](https://github.com/kubernetes-sigs/metrics-server)
