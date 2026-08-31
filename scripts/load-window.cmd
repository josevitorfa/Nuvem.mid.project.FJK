@echo off
REM ============================================================================
REM  load-window.cmd
REM ----------------------------------------------------------------------------
REM  Abre uma janela de console dedicada (titulo "CARGA-HPA") rodando o gerador
REM  de carga 03-load-test.sh.
REM
REM  POR QUE UMA JANELA PROPRIA: o 03-load-test.sh usa "kubectl run -i --tty",
REM  que exige um terminal real. Executado de forma automatizada (sem TTY) o
REM  kubectl reclama e o comportamento fica imprevisivel. Aqui ele roda com um
REM  console de verdade, exatamente como o roteiro descreve.
REM
REM  Uso (a partir da raiz do projeto):
REM      start scripts\load-window.cmd
REM
REM  Encerrar: Ctrl+C na janela (o Pod e removido pelo --rm), ou de fora:
REM      kubectl delete pod load-generator --ignore-not-found
REM ============================================================================

title CARGA-HPA
mode con: cols=110 lines=34

REM O PATH inclui minikube (Implantacao A) e aws (Implantacao B, necessario para
REM o credential plugin "aws eks get-token" usado pelo kubeconfig do EKS).
"C:\Program Files\Git\bin\bash.exe" -lc "cd /c/Dev/Nuvem.FJK/enunciado && export PATH=\"$PATH:/c/Program Files/Kubernetes/Minikube:/c/Program Files/Amazon/AWSCLIV2\" && bash scripts/03-load-test.sh"

pause
