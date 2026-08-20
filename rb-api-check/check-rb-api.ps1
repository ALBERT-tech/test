# Валидатор API для плагина rb-sync (Obsidian <- Bitrix). Порт check-rb-api.js на PowerShell.
# Работает на встроенном Windows PowerShell 5.1 — Node.js не нужен.
#
# Запуск (из папки со скриптом):
#   powershell -ExecutionPolicy Bypass -File .\check-rb-api.ps1 https://bitrix.rossilber.com КЛЮЧ
#   powershell -ExecutionPolicy Bypass -File .\check-rb-api.ps1 http://192.168.1.10 КЛЮЧ
#   powershell -ExecutionPolicy Bypass -File .\check-rb-api.ps1 https://bitrix.rossilber.com КЛЮЧ -Insecure
#   powershell -ExecutionPolicy Bypass -File .\check-rb-api.ps1 https://bitrix.rossilber.com КЛЮЧ 89.189.154.97 -Insecure
#
# Ничего не пишет и не меняет — только читает и печатает отчёт.

param(
  [Parameter(Mandatory = $true, Position = 0)][string]$BaseUrl,
  [Parameter(Mandatory = $true, Position = 1)][string]$Key,
  [Parameter(Position = 2)][string]$FallbackIp,
  [switch]$Insecure
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
if ($Insecure) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }

$base = $BaseUrl.TrimEnd("/")
$script:ok = 0; $script:warn = 0; $script:fail = 0
function P($s) { Write-Host ("  [ OK ] " + $s) -ForegroundColor Green;  $script:ok++ }
function W($s) { Write-Host ("  [WARN] " + $s) -ForegroundColor Yellow; $script:warn++ }
function F($s) { Write-Host ("  [FAIL] " + $s) -ForegroundColor Red;    $script:fail++ }

function Fetch-Json($endpoint, $id) {
  $qs = "k=" + [uri]::EscapeDataString($Key)
  if ($null -ne $id) { $qs += "&id=" + [uri]::EscapeDataString([string]$id) }
  $url = $base + "/" + $endpoint + "?" + $qs
  $hostName = ([uri]$url).Host

  # подмена DNS: ходим на IP, имя хоста передаём в Host-заголовке (как fallback в плагине)
  if ($FallbackIp) { $url = $url.Replace("//" + $hostName, "//" + $FallbackIp) }

  $req = [Net.HttpWebRequest]::Create($url)
  $req.Method = "GET"
  $req.Accept = "application/json"
  $req.Timeout = 15000
  $req.ReadWriteTimeout = 15000
  if ($FallbackIp) { $req.Host = $hostName }

  try {
    $resp = $req.GetResponse()
  } catch [Net.WebException] {
    $msg = $_.Exception.Message
    if ($_.Exception.Response) {
      $r = $_.Exception.Response
      $body = (New-Object IO.StreamReader($r.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd()
      throw ("HTTP " + [int]$r.StatusCode + ": " + $body.Substring(0, [Math]::Min(200, $body.Length)))
    }
    if ($msg -match "довери|trust|SSL|TLS|сертификат|certificate") {
      throw ($msg + " — если сертификат самоподписанный (или идёте по fallback-IP), добавьте флаг -Insecure")
    }
    throw $msg
  }
  $body = (New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd()
  $resp.Close()
  try {
    if ($PSVersionTable.PSVersion.Major -ge 6) { $parsed = ConvertFrom-Json -InputObject $body -NoEnumerate }
    else { $parsed = ConvertFrom-Json -InputObject $body }
  }
  catch { throw ("Не JSON. Начало ответа: " + $body.Substring(0, [Math]::Min(200, $body.Length))) }
  return ,$parsed   # запятая сохраняет массив при возврате из функции
}

# --- копия extractId-логики: элемент списка может быть числом/строкой или объектом с id/ID/Id ---
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

function Check-Fields($obj, [string[]]$fields, $label) {
  $names = @()
  if ($obj -is [Management.Automation.PSCustomObject]) { $names = @($obj.PSObject.Properties.Name) }
  $missing = @($fields | Where-Object { $names -cnotcontains $_ })   # регистр важен, как в плагине
  $empty   = @($fields | Where-Object { $names -ccontains $_ -and ($null -eq $obj.$_ -or ([string]$obj.$_).Trim() -eq "") })
  if ($missing.Count -eq 0) { P ($label + ": все поля на месте (" + $fields.Count + ")") }
  else { W ($label + ": нет полей [" + ($missing -join ", ") + "] — в HTML будут пустые ячейки/undefined") }
  if ($empty.Count) { Write-Host ("     (пустые, но присутствуют: " + ($empty -join ", ") + ")") }
}

$PROCESS_FIELDS = @("TITLE", "current_state", "target_state", "metrics", "kpi_2026",
  "january", "february", "march", "quarter_1", "april", "may", "june", "quarter_2")
$PROJECT_FIELDS = @("TITLE", "place", "PRIORITY", "STATUS", "effect_plan", "effect_fact",
  "RESPONSIBLE", "DEADLINE", "strateg_target", "PROCESS_OF_PROJECT")
$PROJECT_CARD_FIELDS = @("stage", "target", "place", "strateg_target", "effect_plan", "effect_fact",
  "kpi", "kpi_date", "kpi_fact", "questions")

$mode = if ($FallbackIp) { "(через IP " + $FallbackIp + ")" } else { "(обычный DNS)" }
$tls  = if ($Insecure) { "  [TLS без проверки серта]" } else { "" }
Write-Host ("`nБаза: " + $base + "  " + $mode + $tls + "`n")

# ---------- Списки ID ----------
$lists = @{}
foreach ($ep in @("direction.php", "project.php", "process.php")) {
  Write-Host ("-- " + $ep + " (список) --")
  try {
    $data = Fetch-Json $ep $null
    if ($data -isnot [array]) { F ("ответ не массив — refreshIds() увидит 0 элементов"); continue }
    $ids = @($data | ForEach-Object { Extract-Id $_ } | Where-Object { $null -ne $_ })
    if ($ids.Count -eq 0) { F ("массив есть (" + $data.Count + " эл.), но ни одного распознанного id") }
    else { P ($data.Count.ToString() + " элементов, извлечено id: " + $ids.Count + ". Примеры: " + (($ids | Select-Object -First 5) -join ", ")) }
    $lists[$ep] = $ids
  } catch { F $_.Exception.Message }
}

# ---------- direction.php?id ----------
$dirId = if ($lists["direction.php"]) { $lists["direction.php"][0] } else { $null }
if ($dirId) {
  Write-Host ("`n-- direction.php?id=" + $dirId + " --")
  try {
    $d = Fetch-Json "direction.php" $dirId
    if ($d -isnot [array]) { F "ответ не массив — плагин ждёт [название, процессы[], проекты[]]" }
    else {
      if ($d[0] -is [string] -and $d[0].Trim()) { P ("[0] название: <" + $d[0] + ">") }
      else { W "[0] названия нет — в vault появится <Без названия>" }
      if ($d[1] -is [array]) { P ("[1] процессы: " + $d[1].Count + " шт.") } else { W "[1] не массив — процессы будут пустыми (warning в логе плагина)" }
      if ($d[2] -is [array]) { P ("[2] проекты: " + $d[2].Count + " шт.") } else { W "[2] не массив — проекты будут пустыми" }
      if ($d[1] -is [array] -and $d[1].Count -gt 0) { Check-Fields $d[1][0] $PROCESS_FIELDS "процесс[0] для таблицы KPI" }
      if ($d[2] -is [array] -and $d[2].Count -gt 0) {
        Check-Fields $d[2][0] $PROJECT_FIELDS "проект[0] для таблицы портфеля"
        $dl = $d[2][0].DEADLINE
        if ($dl) {
          $parsed = [datetime]::MinValue
          $isoOk = [datetime]::TryParse([string]$dl, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)
          if ($isoOk) { P ("DEADLINE <" + $dl + "> парсится корректно") }
          else { W ("DEADLINE <" + $dl + "> не парсится new Date() — просрочка считаться не будет (нужен ISO 2026-08-20)") }
        }
      }
    }
  } catch { F $_.Exception.Message }
}

# ---------- project.php?id ----------
$projId = if ($lists["project.php"]) { $lists["project.php"][0] } else { $null }
if ($projId) {
  Write-Host ("`n-- project.php?id=" + $projId + " --")
  try {
    $p = Fetch-Json "project.php" $projId
    if ($p -isnot [array]) { F "ответ не массив — плагин ждёт [title, direction, process, {карточка}, [], ...]" }
    else {
      if ($p[0]) { P ("[0] title: <" + $p[0] + ">") } else { W "[0] пуст -> <Без названия>" }
      if ($p[1]) { P ("[1] direction: <" + $p[1] + ">") } else { W "[1] пуст -> <Без направления> (сломает пути файлов!)" }
      if ($p[2]) { P ("[2] process: <" + $p[2] + ">") } else { W "[2] пуст -> <Без процесса>" }
      if ($p[3] -is [Management.Automation.PSCustomObject]) { Check-Fields $p[3] $PROJECT_CARD_FIELDS "[3] карточка проекта" }
      else { W "[3] не объект — вся карточка уйдёт в дефолтные пустые значения" }
      if ($p.Count -gt 4 -and $p[4] -is [array]) { P ("[4] массив: " + $p[4].Count + " эл.") } else { W "[4] не массив — warning в логе плагина" }
    }
  } catch { F $_.Exception.Message }
}

# ---------- process.php?id ----------
$procId = if ($lists["process.php"]) { $lists["process.php"][0] } else { $null }
if ($procId) {
  Write-Host ("`n-- process.php?id=" + $procId + " --")
  try {
    $pr = Fetch-Json "process.php" $procId
    $isArr = $pr -is [array]
    $payload = if ($isArr) { if ($pr.Count -gt 2 -and $pr[2] -is [Management.Automation.PSCustomObject]) { $pr[2] } else { $null } } else { $pr }
    # доступ к свойствам PSCustomObject регистронезависимый — TITLE найдёт и title
    $title = if ($isArr) { $pr[0] } else { $pr.TITLE }
    $direction = if ($isArr) { $pr[1] } else { $pr.DIRECTION }
    if ($title) { P ("title: <" + $title + ">") } else { W "title не найден -> <Без процесса>" }
    if ($direction) { P ("direction: <" + $direction + ">") } else { W "direction не найден -> <Без направления>" }
    $kpiKeys = @("current_state", "target_state", "metrics", "kpi_2026", "january", "quarter_1", "quarter_2")
    $found = @($kpiKeys | Where-Object {
      $k = $_
      ($payload -and $null -ne $payload.$k) -or ($isArr -and $pr.Count -gt (2 + [array]::IndexOf($kpiKeys, $k)) -and $null -ne $pr[2 + [array]::IndexOf($kpiKeys, $k)])
    })
    if ($found.Count -ge 4) { P ("KPI-поля находятся (" + $found.Count + "/" + $kpiKeys.Count + "): " + ($found -join ", ")) }
    else { W ("KPI-полей мало (" + $found.Count + "/" + $kpiKeys.Count + ") — таблица процессов будет полупустой") }
  } catch { F $_.Exception.Message }
}

Write-Host ("`n=== Итог: OK " + $script:ok + "  WARN " + $script:warn + "  FAIL " + $script:fail + " ===")
if ($script:fail) { Write-Host "Красные пункты означают, что синхронизация упадёт или отработает вхолостую." }
elseif ($script:warn) { Write-Host "Жёлтые пункты — синхронизация пройдёт, но часть HTML-ячеек будет пустой." }
else { Write-Host "Контракт полностью соблюдён — можно запускать синхронизацию в Обсидиане." }
