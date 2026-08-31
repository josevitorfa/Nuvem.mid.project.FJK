@echo off
REM ============================================================================
REM  monitor-window.cmd
REM ----------------------------------------------------------------------------
REM  Abre uma janela de console dedicada (titulo "MONITOR-HPA") rodando o painel
REM  de monitoramento 03b-monitor.sh. Existe para que a captura de tela das
REM  evidencias possa mirar UMA janela especifica, em vez da area de trabalho
REM  inteira (o que exporia conteudo pessoal e ficaria ilegivel no artigo).
REM
REM  Uso (a partir da raiz do projeto):
REM      start scripts\monitor-window.cmd
REM
REM  Encerrar: feche a janela ou pressione Ctrl+C dentro dela.
REM ============================================================================

title MONITOR-HPA

REM Janela larga e alta o suficiente para o painel caber inteiro no print.
mode con: cols=110 lines=34

REM Delega para o script bash original. O PATH precisa conter:
REM   - minikube  (Implantacao A)
REM   - aws       (Implantacao B: o kubeconfig do EKS chama "aws eks get-token"
REM                como credential plugin; sem ele o kubectl nao autentica)
"C:\Program Files\Git\bin\bash.exe" -lc "cd /c/Dev/Nuvem.FJK/enunciado && export PATH=\"$PATH:/c/Program Files/Kubernetes/Minikube:/c/Program Files/Amazon/AWSCLIV2\" && bash scripts/03b-monitor.sh"

pause
