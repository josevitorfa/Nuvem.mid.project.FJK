<#
=============================================================================
 capture-screen.ps1
-----------------------------------------------------------------------------
 Captura um screenshot e salva em evidencias/ com nome padronizado e carimbo
 de data/hora. Produz as "Evidencias Fotograficas" exigidas no item 3 do
 enunciado, nos momentos ANTES / DURANTE / DEPOIS do teste de estresse.

 Uso:
   # Captura APENAS a janela do monitor (recomendado):
   powershell -File scripts/capture-screen.ps1 -Nome "minikube-01-antes" -Janela "MONITOR-HPA"

   # Captura a area de trabalho inteira:
   powershell -File scripts/capture-screen.ps1 -Nome "eks-06-console-aws"

 Parametros:
   -Nome     Nome do arquivo (sem extensao). Obrigatorio.
   -Janela   Trecho do titulo da janela a capturar. Se omitido, captura a tela
             inteira. A janela e trazida para a frente antes do print.
   -Destino  Pasta de saida. Padrao: evidencias/
   -Atraso   Segundos de espera antes de capturar. Padrao: 1.

 PRIVACIDADE: sem -Janela a captura pega TODOS os monitores, incluindo janelas
 pessoais. Prefira sempre -Janela.
=============================================================================
#>
param(
    [Parameter(Mandatory = $true)][string]$Nome,
    [string]$Janela = "",
    [string]$Destino = "evidencias",
    [int]$Atraso = 1
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Interop Win32: precisamos de GetWindowRect (dimensoes reais da janela) e
# --- SetForegroundWindow/ShowWindow (trazer a janela para frente antes do print).
$sig = @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
if (-not ("Win32" -as [type])) { Add-Type -TypeDefinition $sig }

if (-not (Test-Path $Destino)) { New-Item -ItemType Directory -Force -Path $Destino | Out-Null }

# --- Decide a area a capturar -------------------------------------------------
$alvo = $null
if ($Janela -ne "") {
    $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "*$Janela*" } | Select-Object -First 1
    if ($null -eq $proc) {
        Write-Output "AVISO: nenhuma janela com titulo contendo '$Janela'. Capturando a tela inteira."
    } else {
        [Win32]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null   # 9 = SW_RESTORE
        [Win32]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 600
        $r = New-Object Win32+RECT
        if ([Win32]::GetWindowRect($proc.MainWindowHandle, [ref]$r)) {
            $alvo = New-Object System.Drawing.Rectangle($r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
        }
    }
}

if ($Atraso -gt 0) { Start-Sleep -Seconds $Atraso }

if ($null -eq $alvo) {
    # Fallback: area total (soma de todos os monitores)
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $alvo = New-Object System.Drawing.Rectangle($vs.X, $vs.Y, $vs.Width, $vs.Height)
}

$bmp = New-Object System.Drawing.Bitmap($alvo.Width, $alvo.Height)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.CopyFromScreen($alvo.X, $alvo.Y, 0, 0, $alvo.Size)

# Carimba data/hora (documenta o instante da coleta, usado para medir o tempo
# de reacao do HPA no artigo).
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$font = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
$gfx.FillRectangle([System.Drawing.Brushes]::Black, 0, 0, 240, 24)
$gfx.DrawString($stamp, $font, [System.Drawing.Brushes]::Lime, 3, 3)

$arquivo = Join-Path $Destino "$Nome.png"
$bmp.Save($arquivo, [System.Drawing.Imaging.ImageFormat]::Png)

$gfx.Dispose()
$bmp.Dispose()

Write-Output "Screenshot salvo: $arquivo  ($stamp)  [$($alvo.Width)x$($alvo.Height)]"
