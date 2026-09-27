# Trabalho Final — O tempo de reação do autoescalamento é uma propriedade da plataforma?

**Disciplina:** PSI5120 – Tópicos em Computação em Nuvem (2026)

Extensão do trabalho intermediário (Proposta 2.2 do enunciado). O trabalho
intermediário comparou o **Horizontal Pod Autoscaler (HPA)** entre **Minikube** e
**AWS EKS** com uma execução por ambiente, e o resultado sobre o **tempo de
reação** não se reproduziu: numa execução o EKS reagiu ~4× mais rápido, na outra
o Minikube reagiu ~2×. Com n = 1 não havia média, desvio nem teste — apenas a
constatação de que o resultado era instável.

Este trabalho trata o tempo de reação como **variável aleatória**: repete o mesmo
protocolo 20 vezes por ambiente, de forma automatizada e não supervisionada, e
pergunta se a diferença observada numa execução isolada é efeito da plataforma ou
ruído de execução.

- **Implantação A (Local):** cluster Kubernetes com **Minikube**.
- **Implantação B (Nuvem):** cluster gerenciado **AWS EKS** (criado via `eksctl`).

A aplicação alvo, os manifestos, a meta de 50% de CPU e o gerador de carga são
**idênticos** aos do trabalho intermediário — é isso que permite comparar as 20
repetições com as execuções já publicadas.

## Autores

- José Vitor Feitosa de Andrade — NUSP 13682041
- Fernando Frederice Miqueletti — NUSP 12544340

## Artigo

| Arquivo | Conteúdo |
|---|---|
| [`artigo/artigo-final.pdf`](artigo/artigo-final.pdf) | Artigo em **português**, formato IEEE — 11 páginas |
| [`artigo/artigo-final-en.pdf`](artigo/artigo-final-en.pdf) | Artigo em **inglês**, formato IEEE — 10 páginas |

> As duas versões leem as **mesmas** tabelas geradas pela análise
> (`artigo/dados/tabelas-pt.tex` e `tabelas-en.tex` diferem apenas no idioma dos
> rótulos), de modo que não podem divergir numericamente. As figuras são geradas
> pelo pgfplots lendo diretamente os CSVs da análise — não há imagens
> intermediárias, então nenhum número do artigo pode discordar do dado medido.

## Estrutura

```
.
├── README.md
├── manifests/                  # manifestos Kubernetes (idênticos ao intermediário)
│   ├── php-apache-deployment.yaml
│   ├── php-apache-service.yaml
│   ├── php-apache-hpa.yaml
│   └── warmup-daemonset.yaml   # aquece o cache de imagens antes de medir
├── scripts/
│   ├── lib/common.sh           # funções compartilhadas
│   ├── 00-preflight.sh         # confere ferramentas, Docker e credenciais AWS
│   ├── 01-minikube-up.sh       # sobe o ambiente local
│   ├── 02-eks-up.sh            # cria o cluster EKS (~15-20 min)
│   ├── 10-run-campaign.sh      # campanha de N repetições
│   ├── 11-analyze.py           # estatística (só biblioteca padrão do Python)
│   ├── 12-prep-artigo.sh       # deixa artigo/ autocontido para compilar
│   ├── 13-check-latex.py       # verifica o .tex sem precisar compilar
│   ├── 14-custo-aws.sh         # apura o custo pelo Cost Explorer
│   ├── 15-test-analyze.py      # valida a estatística contra dados sintéticos
│   ├── 16-instalar-latex-wsl.sh  # TeX Live mínimo (auxiliar, ver nota)
│   ├── 17-compilar-artigo.sh   # compila e confere a faixa de páginas
│   ├── 90-cleanup-eks.sh       # destrói o EKS e verifica recursos órfãos
│   └── 91-cleanup-minikube.sh
├── artigo/                     # .tex, .pdf e os CSVs que as figuras leem
└── dados/                      # evidências medidas
    ├── minikube/               # runs.csv, run-NN.csv, eventos-NN.log, ambiente.txt
    ├── eks/                    # idem
    ├── analise/                # saídas de 11-analyze.py (inclui RESULTADOS.md)
    ├── limpeza/                # verificação pós-destruição da AWS
    ├── custo/                  # apuração do Cost Explorer
    └── logs/                   # logs de execução das campanhas
```

> **Nota sobre `16-instalar-latex-wsl.sh`:** é auxiliar e específico do ambiente
> Windows usado nas medições — instala um TeX Live mínimo dentro do WSL, em modo
> usuário, apenas para compilar o artigo. Em Linux/macOS com LaTeX instalado,
> basta `bash scripts/17-compilar-artigo.sh`. A pasta `artigo/` também é
> autocontida e pode ser enviada ao Overleaf com o template *IEEE Conference*.

## Início rápido

```bash
bash scripts/00-preflight.sh                  # confere o ambiente

# Local (Minikube)
bash scripts/01-minikube-up.sh
bash scripts/10-run-campaign.sh minikube 20   # ~2,5 h, não supervisionado
bash scripts/91-cleanup-minikube.sh full

# Nuvem (AWS EKS)
aws configure                                 # credenciais AWS
bash scripts/02-eks-up.sh                     # inicia a cobrança por hora
bash scripts/10-run-campaign.sh eks 20        # ~2 h, não supervisionado
bash scripts/90-cleanup-eks.sh                # DESTRÓI o cluster e verifica

# Análise e artigo
python3 scripts/11-analyze.py
bash scripts/12-prep-artigo.sh
bash scripts/17-compilar-artigo.sh
```

Parâmetros ajustáveis por variável de ambiente: `LOAD_SECONDS` (240),
`SAMPLE_INTERVAL` (2), `SCALEDOWN_RUNS` (3).

## Aviso de custos (AWS)

O cluster EKS e os nós EC2 são cobrados por hora. **Sempre** rode
`scripts/90-cleanup-eks.sh` ao terminar — ele destrói o cluster **e verifica**
clusters EKS, stacks do CloudFormation, instâncias EC2, NAT gateways, volumes EBS
órfãos e IPs elásticos remanescentes, salvando o resultado em `dados/limpeza/`.

Nesta campanha o cluster ficou ativo ~4,6 h. O custo **faturado** apurado pelo
Cost Explorer foi de **US$ 0,00** (a conta de laboratório utilizada não é cobrada
por EKS, EC2 nem VPC — ver `dados/custo/`); o equivalente **a preço de tabela**
seria de ~**US$ 0,90**, e é esse o número relevante para quem reproduzir em conta
própria.

## Metodologia de medição

O ponto central é **de onde vem cada instante medido**:

- **T₀ (início da carga)** = `pod.status.containerStatuses[0].state.running.startedAt`
  do gerador — carimbado pelo *kubelet*, não pelo cliente. No trabalho
  intermediário T₀ era o relógio do operador, o que embutia o agendamento e o
  *pull* do Pod gerador; aqui isso é medido à parte.
- **T₁ (primeira decisão de escala)** = `hpa.status.lastScaleTime` — carimbado
  pelo próprio controlador do HPA.
- **Tempo de reação** = T₁ − T₀, portanto uma diferença entre **dois instantes do
  mesmo cluster**: não depende do relógio local nem do instante em que o
  amostrador perguntou.
- O desvio entre o relógio local e o do cluster é medido de todo modo e fica
  registrado em `dados/<ambiente>/ambiente.txt`.
- A amostragem é de **2 s em ambos os ambientes**. Manter a mesma resolução nos
  dois exigiu substituir o *exec credential plugin* do kubeconfig do EKS por um
  token renovado em segundo plano: cada chamada do `kubectl` custava 2,8 s
  lançando a AWS CLI, o que degradava a amostragem do EKS para 5 s.

## Tratamento estatístico

Tudo em `scripts/11-analyze.py`, usando **apenas a biblioteca padrão** — sem
numpy e sem scipy — para que a análise reexecute sem instalar nada:

- descritivas (média, desvio, CV, quartis, MAD);
- **IC 95% por bootstrap percentil** (B = 20 000), em vez de IC-t: n é pequeno e o
  tempo de reação não é normal (é limitado em zero e quantizado pelo período de
  sincronização do HPA);
- **Mann-Whitney U** bilateral com correção de empates;
- **Cliff's δ** e **A₁₂** como tamanho de efeito;
- **testes de permutação** para a diferença de medianas e para a razão de
  dispersões (MAD);
- **correlação de Spearman** com p-valor por permutação, entre o tempo de reação e
  cinco covariáveis medidas na mesma repetição.

Semente fixa (`SEED = 20260927`): bootstrap e permutações são reprodutíveis.
`scripts/15-test-analyze.py` valida os estimadores contra campanhas sintéticas de
parâmetros conhecidos.

## Resultados obtidos

Duas campanhas de 20 repetições, **sem nenhuma perda** (40/40 com status `ok`).
Análise completa em [`dados/analise/RESULTADOS.md`](dados/analise/RESULTADOS.md).

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
melhor, era amostra: com uma observação por ambiente, um efeito desse tamanho não
é resolvível contra tanto ruído.

**2. Uma execução única erra a direção do efeito 1 vez em 8.** Sorteando uma
repetição de cada ambiente, a ordenação correta aparece em apenas **87%** dos
casos. As quatro observações do trabalho anterior caem nos percentis **82, 10, 45
e 100** das distribuições agora medidas — sorteios comuns que por acaso se
inverteram. Isso explica integralmente a irreprodutibilidade relatada antes.

**3. A dispersão não é explicada por nenhuma covariável medida.** No ambiente
local, nenhuma das cinco candidatas correlaciona com o tempo de reação (latência
de escrita ρ = −0,33; armazenamento ρ = −0,33; partida do gerador ρ = −0,33; CPU
de pico ρ = 0,08; deriva ao longo da campanha ρ = 0,28 — todos p > 0,15),
**apesar de** a latência de escrita local variar de 114 ms a 2534 ms. A
instabilidade do control plane não prediz quais repetições foram lentas. O
mecanismo compatível é a *fase*: a carga começa num ponto arbitrário do ciclo
periódico de coleta do Metrics Server e de sincronização do controlador.

**4. Tudo que é fixado por declaração se reproduz.** Convergência, meta de 50% e
descida assimétrica replicaram nos dois ambientes com variação de ~2%. A equação
do HPA não tem termo de infraestrutura, e as medidas se comportam assim.

## Referências

1. [Kubernetes — HPA Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
2. [Kubernetes — HPA Algorithm Details](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
3. [AWS EKS — Horizontal Pod Autoscaler](https://docs.aws.amazon.com/eks/latest/userguide/horizontal-pod-autoscaler.html)
4. [eksctl](https://eksctl.io/)
5. [Metrics Server (SIG)](https://github.com/kubernetes-sigs/metrics-server)
