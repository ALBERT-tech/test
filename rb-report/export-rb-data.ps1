# Выгрузчик данных из Bitrix для rb-report.html.
# Обходит direction.php?id= по всем направлениям (в ответе уже есть полные строки
# процессов и проектов) и пишет rb-data.js рядом со скриптом.
# Работает на встроенном Windows PowerShell 5.1 — Node.js не нужен.
#
# Запуск:
#   powershell -ExecutionPolicy Bypass -File .\export-rb-data.ps1 https://bitrix.rossilber.com/ПУТЬ/api КЛЮЧ
#   ... КЛЮЧ -Insecure                (самоподписанный сертификат)
#   ... КЛЮЧ 89.189.154.97 -Insecure  (через fallback-IP)
#
# После выгрузки откройте rb-report.html в браузере (он должен лежать в той же папке).

param(
  [Parameter(Mandatory = $true, Position = 0)][string]$BaseUrl,
  [Parameter(Mandatory = $true, Position = 1)][string]$Key,
  [Parameter(Position = 2)][string]$FallbackIp,
  [string]$OutFile,
  [switch]$Insecure
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
if ($Insecure) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }

$base = $BaseUrl.TrimEnd("/")
if (-not $OutFile) { $OutFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "rb-data.js" }

function Fetch-Json($endpoint, $id) {
  $qs = "k=" + [uri]::EscapeDataString($Key)
  if ($null -ne $id) { $qs += "&id=" + [uri]::EscapeDataString([string]$id) }
  $url = $base + "/" + $endpoint + "?" + $qs
  $hostName = ([uri]$url).Host
  if ($FallbackIp) { $url = $url.Replace("//" + $hostName, "//" + $FallbackIp) }

  $req = [Net.HttpWebRequest]::Create($url)
  $req.Method = "GET"
  $req.Accept = "application/json"
  $req.Timeout = 20000
  $req.ReadWriteTimeout = 20000
  if ($FallbackIp) { $req.Host = $hostName }

  try { $resp = $req.GetResponse() }
  catch [Net.WebException] {
    $msg = $_.Exception.Message
    if ($_.Exception.Response) {
      $r = $_.Exception.Response
      $body = (New-Object IO.StreamReader($r.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd()
      throw ("HTTP " + [int]$r.StatusCode + ": " + $body.Substring(0, [Math]::Min(150, $body.Length)))
    }
    if ($msg -match "довери|trust|SSL|TLS|сертификат|certificate") {
      throw ($msg + " — попробуйте флаг -Insecure")
    }
    throw $msg
  }
  $body = (New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd()
  $resp.Close()
  try {
    if ($PSVersionTable.PSVersion.Major -ge 6) { $parsed = ConvertFrom-Json -InputObject $body -NoEnumerate }
    else { $parsed = ConvertFrom-Json -InputObject $body }
  }
  catch { throw ("Не JSON. Начало ответа: " + $body.Substring(0, [Math]::Min(150, $body.Length))) }
  return ,$parsed
}

function Extract-Id($item) {
  if ($null -eq $item) { return $null }
  if ($item -is [string] -or $item -is [ValueType]) {
    $n = ([string]$item).Trim()
    if ($n -eq "") { return $null } else { return $n }
  }
  if ($item -is [Management.Automation.PSCustomObject]) {
    foreach ($k in @("id", "ID", "Id")) {
      $p = $item.PSObject.Properties[$k]
      if ($p -and $null -ne $p.Value) { return [string]$p.Value }
    }
  }
  return $null
}

Write-Host ("`nВыгрузка из " + $base + ($(if ($FallbackIp) { " (через IP $FallbackIp)" } else { "" })) + "`n")

$idsRaw = Fetch-Json "direction.php" $null
if ($idsRaw -isnot [array]) { throw "direction.php вернул не массив — проверьте URL и ключ (валидатором check-rb-api.ps1)" }
$ids = @($idsRaw | ForEach-Object { Extract-Id $_ } | Where-Object { $null -ne $_ })
Write-Host ("Направлений в списке: " + $ids.Count)

$directions = @()
$errors = @()
$i = 0
foreach ($id in $ids) {
  $i++
  try {
    $d = Fetch-Json "direction.php" $id
    if ($d -isnot [array]) { throw "ответ не массив" }
    $name = if ($d[0] -is [string] -and $d[0].Trim()) { $d[0].Trim() } else { "Без названия" }
    $processes = if ($d.Count -gt 1 -and $d[1] -is [array]) { @($d[1]) } else { @() }
    $projects  = if ($d.Count -gt 2 -and $d[2] -is [array]) { @($d[2]) } else { @() }
    $directions += [ordered]@{ id = $id; name = $name; processes = $processes; projects = $projects }
    Write-Host ("[{0,2}/{1}] id={2}  {3}  (процессов: {4}, проектов: {5})" -f $i, $ids.Count, $id, $name, $processes.Count, $projects.Count)
  } catch {
    $errors += [ordered]@{ id = $id; error = $_.Exception.Message }
    Write-Host ("[{0,2}/{1}] id={2}  ОШИБКА: {3}" -f $i, $ids.Count, $id, $_.Exception.Message) -ForegroundColor Red
  }
}

# JSON собираем вручную, сериализуя по одному объекту за раз. Это обходит сразу
# два дефекта ConvertTo-Json во встроенном PowerShell 5.1: лимит ~2 МБ на строку
# и баг, из-за которого массив из пайплайна превращается в {"value":[...],"Count":N}.
function Json-Str($v) { return (ConvertTo-Json -InputObject ([string]$v) -Compress) }
function Json-Rows($items) {
  $parts = @()
  foreach ($it in @($items)) { $parts += (ConvertTo-Json -InputObject $it -Depth 10 -Compress) }
  return "[" + ($parts -join ",") + "]"
}

$dirJsons = @()
foreach ($dir in $directions) {
  try {
    $dirJsons += ('{"id":' + (Json-Str $dir.id) + ',"name":' + (Json-Str $dir.name) +
                  ',"processes":' + (Json-Rows $dir.processes) +
                  ',"projects":' + (Json-Rows $dir.projects) + '}')
  } catch {
    $errors += [ordered]@{ id = $dir.id; error = ("сериализация: " + $_.Exception.Message) }
    Write-Host ("Направление id=" + $dir.id + " не сериализовалось: " + $_.Exception.Message) -ForegroundColor Red
  }
}
$json = '{"generated":' + (Json-Str ((Get-Date).ToString("yyyy-MM-dd HH:mm"))) +
        ',"source":' + (Json-Str $base) +
        ',"directions":[' + ($dirJsons -join ",") + '],"errors":' + (Json-Rows $errors) + "}"

[IO.File]::WriteAllText($OutFile, "window.RB_DATA = " + $json + ";", (New-Object Text.UTF8Encoding($true)))
if (-not (Test-Path $OutFile)) { throw ("Файл не записался: " + $OutFile) }
Write-Host ("Размер rb-data.js: " + [Math]::Round((Get-Item $OutFile).Length / 1MB, 1) + " МБ")

$totalProjects  = ($directions | ForEach-Object { $_.projects.Count }  | Measure-Object -Sum).Sum
$totalProcesses = ($directions | ForEach-Object { $_.processes.Count } | Measure-Object -Sum).Sum
Write-Host ("`nГотово: " + $OutFile)
Write-Host ("Направлений: " + $directions.Count + "  Процессов: " + $totalProcesses + "  Проектов: " + $totalProjects + $(if ($errors.Count) { "  Ошибок: " + $errors.Count } else { "" }))
Write-Host "Теперь откройте rb-report.html (в той же папке) в браузере."
