# Atividade Prática 1 — Servidor Web com HPA no Kubernetes (Minikube + AWS EKS)

**Disciplina:** PSI512 – Tópicos em Computação em Nuvem (2026)

Projeto de implantação e teste de um servidor web em Kubernetes com **Horizontal Pod Autoscaler (HPA)**, em dois ambientes:

- **Implantação A (Local):** cluster Kubernetes com **Minikube**.
- **Implantação B (Nuvem):** cluster gerenciado **AWS EKS** (criado via `eksctl`).

A aplicação alvo é a imagem oficial `registry.k8s.io/hpa-example` (Apache + PHP que consome CPU sob carga), escalada de 1 a 10 réplicas com meta de 50% de CPU.

## Autores

- José Vitor Feitosa de Andrade — execução E1 (23/08/2026)
- Fernando Frederice Miqueletti — execução E2 (24/08/2026)


> **Nota sobre os scripts `.ps1`/`.cmd`:** são auxiliares específicos do Windows,
> usados para coletar as evidências. Em Linux/macOS basta abrir dois terminais e
> rodar `03b-monitor.sh` e `03-load-test.sh` diretamente.

## Início rápido

**Local (Minikube):**
```bash
bash scripts/01-minikube-setup.sh   # sobe o cluster e aplica tudo
bash scripts/03b-monitor.sh         # (terminal 2) monitora o HPA
bash scripts/03-load-test.sh        # (terminal 3) gera carga
bash scripts/05-cleanup-minikube.sh # limpeza
```

**Nuvem (AWS EKS):**
```bash
aws configure                       # credenciais AWS
bash scripts/02-eks-setup.sh        # cria o EKS e aplica tudo (~15-20 min)
bash scripts/03-load-test.sh        # gera carga
bash scripts/04-cleanup-eks.sh      # DESTRÓI o cluster (evita custos)
```

## Aviso de custos (AWS)

O cluster EKS e os nós EC2 são cobrados por hora. **Sempre** rode `scripts/04-cleanup-eks.sh` ao terminar e confirme no console da AWS (EKS, EC2, CloudFormation) que nada ficou órfão.

## Resultados obtidos

Duas execuções independentes, em máquinas e contas AWS distintas, com os mesmos
manifestos: **E1 (José, 23/08/2026)** e **E2 (Fernando, 24/08/2026)**.

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
lógico.

**O tempo de reação não se reproduziu entre as execuções.** Em E1 o EKS reagiu
~4× mais rápido que o Minikube; em E2 ocorreu o inverso. Como o protocolo foi o
mesmo, a diferença não é atribuível à plataforma — provavelmente é dominada pela
fase de amostragem do HPA, pela partida do Pod gerador e pela contenção no
hospedeiro local. A Seção 6.3 do artigo trata disso em detalhe.

## Referências

1. [Kubernetes — HPA Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
2. [AWS EKS — Horizontal Pod Autoscaler](https://docs.aws.amazon.com/eks/latest/userguide/horizontal-pod-autoscaler.html)
3. [eksctl](https://eksctl.io/)
4. [Metrics Server (SIG)](https://github.com/kubernetes-sigs/metrics-server)
