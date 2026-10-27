[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($PSScriptRoot)
$Work = Join-Path $Root '.runtime'
$StateFile = Join-Path $Work 'state.json'
$Exe = Join-Path $Work 'bin\llama-server.exe'
try {
    if (-not (Test-Path -LiteralPath $StateFile)) { Write-Host '奇门当前没有已记录的运行服务。'; exit 0 }
    $State = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($State.root -ne $Root -or $State.exe -ne $Exe) { throw '运行记录不属于当前成品目录，未停止任何程序。' }
    $Process = Get-Process -Id ([int]$State.processId) -ErrorAction SilentlyContinue
    if ($Process) {
        if ($Process.Path -ne $Exe -or $Process.StartTime.ToUniversalTime().Ticks.ToString() -ne $State.startedUtcTicks) {
            throw '记录中的进程已变化，未停止其他程序。'
        }
        Stop-Process -Id $Process.Id -ErrorAction Stop
        try { $Process.WaitForExit(10000) | Out-Null } catch { }
        Write-Host '奇门模型服务已停止，内存和显存将释放。'
    }
    else { Write-Host '奇门模型服务已经停止。' }
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
}
catch { Write-Host ('停止失败：' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
