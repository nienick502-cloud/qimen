[CmdletBinding()]
param(
    [switch]$NoBrowser,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = [IO.Path]::GetFullPath($PSScriptRoot)
$Work = Join-Path $Root '.runtime'
$StateFile = Join-Path $Work 'state.json'
$CacheFile = Join-Path $Work 'verified.json'
$ServerUrl = 'http://127.0.0.1:8317'
$script:Verified = @{}
$script:StartedProcess = $null
$Lock = $null
$HasLock = $false

function Say([string]$Message) { Write-Host $Message }
function FullPath([string]$Relative) { return Join-Path $Root $Relative }
function Save-Json($Value, [string]$Path) {
    $Temp = $Path + '.tmp'
    $Json = $Value | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Temp, $Json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $Temp -Destination $Path -Force
}
function File-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Test-File($Spec, [switch]$NoCache) {
    $Path = FullPath $Spec.file
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $Info = Get-Item -LiteralPath $Path
    if ($Spec.size -and $Info.Length -ne [long]$Spec.size) { return $false }
    $Fingerprint = '{0}|{1}|{2}' -f $Spec.sha256, $Info.Length, $Info.LastWriteTimeUtc.Ticks
    if (-not $NoCache -and $script:Verified[$Spec.file] -eq $Fingerprint) { return $true }
    Say ('正在校验：' + $Info.Name)
    if ((File-Hash $Path) -ne $Spec.sha256) { return $false }
    $script:Verified[$Spec.file] = $Fingerprint
    Save-Json $script:Verified $CacheFile
    return $true
}
function Keep-BadFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $Backup = $Path + '.invalid-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
        Move-Item -LiteralPath $Path -Destination $Backup
        Say ('校验未通过的文件已保留为：' + $Backup)
    }
}
function Download-ModelFile($Spec) {
    if (Test-File $Spec) { return }
    $Path = FullPath $Spec.file
    if (Test-Path -LiteralPath $Path) { Keep-BadFile $Path }
    $Part = $Path + '.part'
    if ((Test-Path -LiteralPath $Part) -and (Get-Item -LiteralPath $Part).Length -gt [long]$Spec.size) {
        Keep-BadFile $Part
    }
    $Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $Curl)) { throw '未找到 Windows 自带的 curl.exe。请使用 Windows 10/11 并完成系统更新。' }
    foreach ($Url in $Spec.urls) {
        for ($Attempt = 1; $Attempt -le 2; $Attempt++) {
            Say ('正在下载 ' + [IO.Path]::GetFileName($Path) + '，支持断点续传。')
            & $Curl --location --fail --retry 3 --retry-delay 2 --connect-timeout 20 --speed-time 60 --speed-limit 1024 --continue-at - --output $Part $Url
            $CurlExit = $LASTEXITCODE
            if ((Test-Path -LiteralPath $Part) -and (Get-Item -LiteralPath $Part).Length -eq [long]$Spec.size) {
                Say '下载完成，正在校验模型完整性……'
                if ((File-Hash $Part) -eq $Spec.sha256) {
                    Move-Item -LiteralPath $Part -Destination $Path -Force
                    if (-not (Test-File $Spec)) { throw ('模型落盘后校验失败：' + $Path) }
                    return
                }
                Keep-BadFile $Part
            }
            elseif ($CurlExit -eq 33 -or $CurlExit -eq 36 -or $CurlExit -eq 22) {
                # 当前镜像不接受续传或链接失效；下一次请求从零开始。
                if ($CurlExit -ne 22) { Keep-BadFile $Part }
            }
            Say ('本次下载未完成（curl ' + $CurlExit + '），即将重试或切换官方来源。')
        }
    }
    throw ('模型下载未完成。已保留 .part，联网后再次双击即可续传。文件：' + $Path)
}
function Ensure-Runtime($Spec) {
    if (-not (Test-File $Spec)) { throw '随包提供的推理程序校验失败，请重新下载并完整解压仓库 ZIP。' }
    $Bin = Join-Path $Work 'bin'
    $Receipt = Join-Path $Bin 'runtime.sha256'
    $Required = @('llama-server.exe', 'llama-server-impl.dll', 'llama-common.dll', 'llama.dll', 'ggml.dll', 'ggml-base.dll', 'mtmd.dll', 'libomp140.x86_64.dll', 'ggml-vulkan.dll', 'ggml-cpu-x64.dll')
    $Complete = (Test-Path -LiteralPath $Receipt) -and ((Get-Content -LiteralPath $Receipt -Raw).Trim() -eq $Spec.sha256)
    foreach ($Name in $Required) { if (-not (Test-Path -LiteralPath (Join-Path $Bin $Name))) { $Complete = $false } }
    if ($Complete) { return $Bin }
    Say '正在准备便携推理程序……'
    $Extract = Join-Path $Work ('extract-' + [Guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath (FullPath $Spec.file) -DestinationPath $Extract
    foreach ($Name in $Required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Extract $Name))) { throw ('推理程序压缩包不完整：' + $Name) }
    }
    [IO.File]::WriteAllText((Join-Path $Extract 'runtime.sha256'), $Spec.sha256)
    if (Test-Path -LiteralPath $Bin) {
        Move-Item -LiteralPath $Bin -Destination ($Bin + '.previous-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    }
    Move-Item -LiteralPath $Extract -Destination $Bin
    return $Bin
}
function Quoted([string]$Value) {
    if ($Value.Contains('"')) { throw '路径中包含不支持的双引号。' }
    return '"' + $Value + '"'
}
function Microsoft-Signed([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $Signature = Get-AuthenticodeSignature -LiteralPath $Path
        return $Signature.Status -eq 'Valid' -and $Signature.SignerCertificate.Subject -match 'O=Microsoft Corporation'
    }
    catch { return $false }
}
function Install-Crt([string]$Url) {
    Say '本机缺少 Microsoft Visual C++ 运行库，正在准备安装。安装时可能弹出系统确认。'
    $Installer = Join-Path $Work 'vc_redist.x64.exe'
    if (Microsoft-Signed $Installer) {
        Say '正在使用已验证微软签名的安装包缓存。'
    }
    else {
        Say '正在从微软下载 Visual C++ 运行库……'
        $Download = $Installer + '.part'
        $Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        & $Curl --location --fail --retry 2 --connect-timeout 20 --output $Download $Url
        if ($LASTEXITCODE -ne 0) { throw ('微软运行库下载失败。原缓存未改动，请联网后重试，或手动安装：' + $Url) }
        if (-not (Microsoft-Signed $Download)) { throw '微软运行库安装包签名校验失败，已停止安装；原缓存未改动。' }
        Move-Item -LiteralPath $Download -Destination $Installer -Force
    }
    try {
        $Setup = Start-Process -FilePath $Installer -ArgumentList '/install /quiet /norestart' -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    }
    catch { throw '未能安装微软运行库。若取消了系统确认，请再次启动并允许安装；也可自行安装 Visual C++ x64 运行库。' }
    if ($Setup.ExitCode -notin @(0, 1638, 3010)) { throw ('微软运行库安装失败，退出码：' + $Setup.ExitCode) }
    if ($Setup.ExitCode -eq 3010) { Say '微软运行库提示需要重启；如稍后仍无法启动，请重启 Windows 后重试。' }
}
function Check-Crt([string]$Exe, [string]$Url) {
    $Missing = $false
    foreach ($Name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot ('System32\' + $Name)))) { $Missing = $true }
    }
    if ($Missing) { Install-Crt $Url }
    for ($Try = 0; $Try -lt 2; $Try++) {
        $Check = Start-Process -FilePath $Exe -ArgumentList '--version' -WorkingDirectory (Split-Path -Parent $Exe) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Work 'runtime-check.stdout.log') -RedirectStandardError (Join-Path $Work 'runtime-check.stderr.log') -PassThru
        # Windows PowerShell 5.1 必须先保留进程句柄，退出后才能可靠读取 ExitCode。
        $Check.Handle | Out-Null
        if (-not $Check.WaitForExit(20000)) { $Check.Kill(); throw '推理程序自检超时，请查看 .runtime 中的 runtime-check 日志。' }
        $Check.Refresh()
        if ($Check.ExitCode -eq 0) { return }
        if ($Try -eq 0 -and $Check.ExitCode -in @(-1073741515, -1073741511)) { Install-Crt $Url; continue }
        throw ('推理程序无法运行（退出码 ' + $Check.ExitCode + '）。请查看 .runtime/runtime-check.stderr.log，并确认系统为 Windows 10/11 x64。')
    }
}
function Port-Open {
    $Client = New-Object Net.Sockets.TcpClient
    try {
        $Task = $Client.BeginConnect('127.0.0.1', 8317, $null, $null)
        if (-not $Task.AsyncWaitHandle.WaitOne(500)) { return $false }
        $Client.EndConnect($Task)
        return $true
    }
    catch { return $false }
    finally { $Client.Dispose() }
}
function Our-Process([string]$Exe) {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try {
        $State = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($State.root -ne $Root -or $State.exe -ne $Exe) { return $null }
        $Process = Get-Process -Id ([int]$State.processId) -ErrorAction Stop
        if ($Process.Path -ne $Exe -or $Process.StartTime.ToUniversalTime().Ticks.ToString() -ne $State.startedUtcTicks) { return $null }
        return $Process
    }
    catch { return $null }
}
function Healthy {
    try {
        $Response = Invoke-WebRequest -UseBasicParsing -Uri ($ServerUrl + '/health') -TimeoutSec 2 -Proxy $null
        return $Response.StatusCode -eq 200 -and (($Response.Content | ConvertFrom-Json).status -eq 'ok')
    }
    catch { return $false }
}
function Our-Web([string]$Expected) {
    try {
        $Response = Invoke-WebRequest -UseBasicParsing -Uri ($ServerUrl + '/') -TimeoutSec 3 -Proxy $null
        $Bytes = $Response.RawContentStream.ToArray()
        $Sha = [Security.Cryptography.SHA256]::Create()
        try { $Actual = ([BitConverter]::ToString($Sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $Sha.Dispose() }
        return $Actual -eq $Expected
    }
    catch { return $false }
}
function Open-Page {
    if (-not $NoBrowser) { Start-Process -FilePath ($ServerUrl + '/#/') }
}
function Start-Server([string]$Exe, [string]$Model, [string]$Adapter, [string]$Web, [int]$Layers) {
    $Out = Join-Path $Work 'server.stdout.log'
    $Err = Join-Path $Work 'server.stderr.log'
    $Arguments = @('--model', $Model, '--lora', $Adapter, '--host', '127.0.0.1', '--port', '8317', '--path', $Web, '--ctx-size', '4096', '--batch-size', '128', '--ubatch-size', '128', '-np', '1', '-ngl', $Layers.ToString(), '--cors-origins', $ServerUrl)
    $ArgumentLine = ($Arguments | ForEach-Object { Quoted $_ }) -join ' '
    $script:StartedProcess = Start-Process -FilePath $Exe -ArgumentList $ArgumentLine -WorkingDirectory $Root -WindowStyle Hidden -RedirectStandardOutput $Out -RedirectStandardError $Err -PassThru
    $script:StartedProcess.Handle | Out-Null
    Save-Json @{ root = $Root; exe = $Exe; processId = $script:StartedProcess.Id; startedUtcTicks = $script:StartedProcess.StartTime.ToUniversalTime().Ticks.ToString(); url = $ServerUrl; webSha256 = $Manifest.webSha256 } $StateFile
    $Deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $Deadline) {
        $script:StartedProcess.Refresh()
        if ($script:StartedProcess.HasExited) { return $false }
        if (Healthy) { return $true }
        Start-Sleep -Milliseconds 600
    }
    $script:StartedProcess.Refresh()
    if (-not $script:StartedProcess.HasExited) { $script:StartedProcess.Kill(); $script:StartedProcess.WaitForExit() }
    throw '模型加载超时（180 秒）。请查看 .runtime/server.stderr.log；内存不足或机械硬盘可能导致加载缓慢。'
}

try {
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) { throw '本成品需要 Windows 10/11 x64 和 64 位 PowerShell。' }
    New-Item -ItemType Directory -Path $Work -Force | Out-Null
    $Sha = [Security.Cryptography.SHA256]::Create()
    try { $LockName = ([BitConverter]::ToString($Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant())))).Replace('-', '') }
    finally { $Sha.Dispose() }
    $Lock = New-Object Threading.Mutex($false, ('Local\QimenPortable-' + $LockName))
    try { $HasLock = $Lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $HasLock = $true }
    if (-not $HasLock) { Say '奇门正在准备或启动，请等待当前启动窗口完成。'; exit 0 }
    $Manifest = Get-Content -LiteralPath (FullPath 'runtime/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $Web = FullPath 'web'
    if (-not (Test-Path -LiteralPath (Join-Path $Web 'index.html'))) { throw '找不到网页成品。请先完整解压下载的 ZIP，再双击 BAT。' }
    if ((File-Hash (Join-Path $Web 'index.html')) -ne $Manifest.webSha256) { throw '网页成品校验失败，请重新下载并完整解压仓库 ZIP。' }
    if (Test-Path -LiteralPath $CacheFile) {
        try {
            $Saved = Get-Content -LiteralPath $CacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($Property in $Saved.PSObject.Properties) { $script:Verified[$Property.Name] = $Property.Value }
        }
        catch { $script:Verified = @{} }
    }
    $Exe = Join-Path $Work 'bin\llama-server.exe'
    $Existing = Our-Process $Exe
    if ($Existing) {
        if ((Healthy) -and (Our-Web $Manifest.webSha256)) {
            Say ('奇门已在运行：' + $ServerUrl + '/#/')
            Open-Page
            exit 0
        }
        throw '上次启动的服务尚未就绪或网页版本已变化。请先双击“停止-奇门遁甲.bat”，再重新启动。'
    }
    if (Port-Open) { throw '端口 8317 已被其他程序占用。请关闭占用该端口的程序后重试；本启动器不会停止其他程序。' }
    Say '奇门遁甲 · 便携版'
    Say '首次需联网下载约 4.7 GB 基础模型；完成后可离线使用，无需安装 Node.js 或 Python。'
    if (-not (Test-File $Manifest.adapter)) { throw '随包提供的断语适配模型校验失败，请重新下载并完整解压仓库 ZIP。' }
    $Bin = Ensure-Runtime $Manifest.runtime
    Check-Crt $Exe $Manifest.vcRuntimeUrl
    if (Test-File $Manifest.mergedModel) {
        $Model = FullPath $Manifest.mergedModel.file
    }
    else {
        if (Test-Path -LiteralPath (FullPath $Manifest.mergedModel.file)) { Keep-BadFile (FullPath $Manifest.mergedModel.file) }
        $MissingBytes = [long]0
        foreach ($Spec in $Manifest.modelFiles) {
            if (-not (Test-File $Spec)) {
                $PartPath = (FullPath $Spec.file) + '.part'
                $Already = [long]0
                if (Test-Path -LiteralPath $PartPath) { $Already = (Get-Item -LiteralPath $PartPath).Length }
                $MissingBytes += [Math]::Max([long]0, [long]$Spec.size - $Already)
            }
        }
        $Drive = (Get-Item -LiteralPath $Work).PSDrive
        if ($null -ne $Drive.Free -and $Drive.Free -lt ($MissingBytes + 512MB)) { throw '当前磁盘剩余空间不足。请将整个文件夹移至至少有 8 GB 空余的磁盘后重试。' }
        foreach ($Spec in $Manifest.modelFiles) { Download-ModelFile $Spec }
        $Model = FullPath $Manifest.modelFiles[0].file
    }
    if ($PrepareOnly) { Say '运行环境和模型已准备完成。'; exit 0 }
    Say '正在加载本地模型，首次加载可能需要稍等……'
    $Ready = Start-Server $Exe $Model (FullPath $Manifest.adapter.file) $Web 99
    if (-not $Ready) {
        $Failure = Get-Content -LiteralPath (Join-Path $Work 'server.stderr.log') -Raw -ErrorAction SilentlyContinue
        if ($Failure -match '(?im)(vulkan[^\r\n]*(error|fail|out of memory)|VK_ERROR_|failed to[^\r\n]*(device|allocate)|out of (device |GPU |video )?memory|not enough[^\r\n]*(VRAM|memory))') {
            Copy-Item -LiteralPath (Join-Path $Work 'server.stderr.log') -Destination (Join-Path $Work 'server.gpu-failed.log') -Force
            Say '显卡加速未能启动，正在改用 CPU。CPU 生成会较慢。'
            $Ready = Start-Server $Exe $Model (FullPath $Manifest.adapter.file) $Web 0
        }
    }
    if (-not $Ready) { throw '本地模型服务未能启动。请查看 .runtime/server.stderr.log；请确认内存充足、显卡驱动可用。' }
    if (-not (Our-Web $Manifest.webSha256)) { throw '模型已启动，但网页未正确提供。请查看 .runtime 中日志并重新解压成品。' }
    Say ('启动完成：' + $ServerUrl + '/#/')
    Say '关闭网页不会停止模型。用“停止-奇门遁甲.bat”释放内存和显存。'
    Open-Page
    $script:StartedProcess = $null
}
catch {
    if ($script:StartedProcess) {
        try { $script:StartedProcess.Refresh(); if (-not $script:StartedProcess.HasExited) { $script:StartedProcess.Kill() } } catch { }
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host ('启动失败：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('日志目录：' + $Work)
    exit 1
}
finally {
    if ($HasLock -and $Lock) { $Lock.ReleaseMutex() }
    if ($Lock) { $Lock.Dispose() }
}
