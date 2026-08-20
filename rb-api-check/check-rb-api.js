#!/usr/bin/env node
/**
 * Валидатор API для плагина rb-sync (Obsidian <- Bitrix).
 * Проверяет, что direction.php / project.php / process.php отдают данные
 * в структуре, которую ожидает main.js/templates.js плагина.
 *
 * Рассчитан на запуск с локального компа внутри сети, где живёт Bitrix:
 * поддерживает http:// и https://, самоподписанные сертификаты (--insecure)
 * и подмену DNS на заданный IP (как fallback в самом плагине).
 *
 * Запуск:
 *   node check-rb-api.js https://bitrix.rossilber.com КЛЮЧ
 *   node check-rb-api.js http://192.168.1.10 КЛЮЧ                (внутри локалки по IP)
 *   node check-rb-api.js https://bitrix.rossilber.com КЛЮЧ 89.189.154.97   (с fallback IP)
 *   node check-rb-api.js https://bitrix.rossilber.com КЛЮЧ --insecure     (самоподписанный серт)
 *
 * Ничего не пишет и не меняет — только читает и печатает отчёт.
 */

const https = require("https");
const http = require("http");
const { URL } = require("url");

const rawArgs = process.argv.slice(2);
const insecure = rawArgs.includes("--insecure");
const [baseUrlArg, key, fallbackIp] = rawArgs.filter((a) => !a.startsWith("--"));
if (!baseUrlArg || !key) {
  console.error("Использование: node check-rb-api.js <baseUrl> <key> [fallbackIp] [--insecure]");
  console.error("  baseUrl    — http://... или https://... (хост или IP в локальной сети)");
  console.error("  --insecure — не проверять TLS-сертификат (самоподписанный в локалке)");
  process.exit(1);
}
const baseUrl = baseUrlArg.replace(/\/+$/, "");

let ok = 0, warn = 0, fail = 0;
const P = (s) => console.log("  ✅ " + s) || ok++;
const W = (s) => console.log("  ⚠️  " + s) || warn++;
const F = (s) => console.log("  ❌ " + s) || fail++;

function fetchJson(endpoint, id) {
  const params = new URLSearchParams({ k: key });
  if (typeof id !== "undefined") params.set("id", String(id));
  const url = `${baseUrl}/${endpoint}?${params}`;
  const parsed = new URL(url);
  const isHttps = parsed.protocol === "https:";
  const transport = isHttps ? https : http;

  const options = {
    hostname: parsed.hostname,
    port: parsed.port || (isHttps ? 443 : 80),
    path: parsed.pathname + parsed.search,
    method: "GET",
    headers: { Accept: "application/json" },
    timeout: 15000,
  };
  if (isHttps) {
    options.servername = parsed.hostname;
    if (insecure) options.rejectUnauthorized = false;
  }
  if (fallbackIp) {
    options.lookup = (host, opts, cb) => {
      if (typeof opts === "function") { cb = opts; opts = {}; }
      opts && opts.all ? cb(null, [{ address: fallbackIp, family: 4 }]) : cb(null, fallbackIp, 4);
    };
  }

  return new Promise((resolve, reject) => {
    const req = transport.request(options, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        if (!res.statusCode || res.statusCode < 200 || res.statusCode >= 300) {
          return reject(new Error(`HTTP ${res.statusCode}: ${body.slice(0, 200)}`));
        }
        try { resolve(JSON.parse(body)); }
        catch (e) { reject(new Error(`Не JSON (${e.message}). Начало ответа: ${body.slice(0, 200)}`)); }
      });
    });
    req.on("timeout", () => req.destroy(new Error("Таймаут 15с")));
    req.on("error", (e) => {
      if (isHttps && /certificate|self.signed|unable to verify/i.test(e.message)) {
        reject(new Error(`${e.message} — если сертификат самоподписанный, добавьте флаг --insecure`));
      } else reject(e);
    });
    req.end();
  });
}

// --- копия extractId-логики: элемент списка может быть числом/строкой или объектом ---
function extractId(item) {
  if (item == null) return null;
  if (typeof item === "number" || typeof item === "string") {
    const n = String(item).trim();
    return n === "" ? null : n;
  }
  if (typeof item === "object") {
    for (const k of ["id", "ID", "Id"]) if (item[k] != null) return String(item[k]);
  }
  return null;
}

function checkFields(obj, fields, label) {
  const missing = fields.filter((f) => !(f in (obj || {})));
  const empty = fields.filter((f) => f in (obj || {}) && (obj[f] == null || String(obj[f]).trim() === ""));
  if (!missing.length) P(`${label}: все поля на месте (${fields.length})`);
  else W(`${label}: нет полей [${missing.join(", ")}] — в HTML будут пустые ячейки/undefined`);
  if (empty.length) console.log(`     (пустые, но присутствуют: ${empty.join(", ")})`);
}

const PROCESS_FIELDS = ["TITLE", "current_state", "target_state", "metrics", "kpi_2026",
  "january", "february", "march", "quarter_1", "april", "may", "june", "quarter_2"];
const PROJECT_FIELDS = ["TITLE", "place", "PRIORITY", "STATUS", "effect_plan", "effect_fact",
  "RESPONSIBLE", "DEADLINE", "strateg_target", "PROCESS_OF_PROJECT"];
const PROJECT_CARD_FIELDS = ["stage", "target", "place", "strateg_target", "effect_plan", "effect_fact",
  "kpi", "kpi_date", "kpi_fact", "questions"];

async function main() {
  console.log(`\nБаза: ${baseUrl}  ${fallbackIp ? "(через IP " + fallbackIp + ")" : "(обычный DNS)"}${insecure ? "  [TLS без проверки серта]" : ""}\n`);

  // ---------- Списки ID ----------
  const lists = {};
  for (const ep of ["direction.php", "project.php", "process.php"]) {
    console.log(`── ${ep} (список) ──`);
    try {
      const data = await fetchJson(ep);
      if (!Array.isArray(data)) { F(`ответ не массив, а ${typeof data} — refreshIds() увидит 0 элементов`); continue; }
      const ids = data.map(extractId).filter((x) => x !== null);
      if (!ids.length) F(`массив есть (${data.length} эл.), но ни одного распознанного id`);
      else P(`${data.length} элементов, извлечено id: ${ids.length}. Примеры: ${ids.slice(0, 5).join(", ")}`);
      lists[ep] = ids;
    } catch (e) { F(e.message); }
  }

  // ---------- direction.php?id ----------
  const dirId = lists["direction.php"]?.[0];
  if (dirId) {
    console.log(`\n── direction.php?id=${dirId} ──`);
    try {
      const d = await fetchJson("direction.php", dirId);
      if (!Array.isArray(d)) F("ответ не массив — плагин ждёт [название, процессы[], проекты[]]");
      else {
        typeof d[0] === "string" && d[0].trim()
          ? P(`[0] название: «${d[0]}»`)
          : W("[0] названия нет — в vault появится «Без названия»");
        Array.isArray(d[1]) ? P(`[1] процессы: ${d[1].length} шт.`) : W("[1] не массив — процессы будут пустыми (warning в логе плагина)");
        Array.isArray(d[2]) ? P(`[2] проекты: ${d[2].length} шт.`) : W("[2] не массив — проекты будут пустыми");
        if (Array.isArray(d[1]) && d[1][0]) checkFields(d[1][0], PROCESS_FIELDS, "процесс[0] для таблицы KPI");
        if (Array.isArray(d[2]) && d[2][0]) {
          checkFields(d[2][0], PROJECT_FIELDS, "проект[0] для таблицы портфеля");
          const dl = d[2][0].DEADLINE;
          if (dl && Number.isNaN(new Date(dl).getTime()))
            W(`DEADLINE «${dl}» не парсится new Date() — просрочка считаться не будет`);
          else if (dl) P(`DEADLINE «${dl}» парсится корректно`);
        }
      }
    } catch (e) { F(e.message); }
  }

  // ---------- project.php?id ----------
  const projId = lists["project.php"]?.[0];
  if (projId) {
    console.log(`\n── project.php?id=${projId} ──`);
    try {
      const p = await fetchJson("project.php", projId);
      if (!Array.isArray(p)) F("ответ не массив — плагин ждёт [title, direction, process, {карточка}, [], ...]");
      else {
        p[0] ? P(`[0] title: «${p[0]}»`) : W("[0] пуст → «Без названия»");
        p[1] ? P(`[1] direction: «${p[1]}»`) : W("[1] пуст → «Без направления» (сломает пути файлов!)");
        p[2] ? P(`[2] process: «${p[2]}»`) : W("[2] пуст → «Без процесса»");
        p[3] && typeof p[3] === "object"
          ? checkFields(p[3], PROJECT_CARD_FIELDS, "[3] карточка проекта")
          : W("[3] не объект — вся карточка уйдёт в дефолтные пустые значения");
        Array.isArray(p[4]) ? P(`[4] массив: ${p[4].length} эл.`) : W("[4] не массив — warning в логе плагина");
      }
    } catch (e) { F(e.message); }
  }

  // ---------- process.php?id ----------
  const procId = lists["process.php"]?.[0];
  if (procId) {
    console.log(`\n── process.php?id=${procId} ──`);
    try {
      const pr = await fetchJson("process.php", procId);
      const isArr = Array.isArray(pr);
      const payload = isArr ? (pr[2] && typeof pr[2] === "object" ? pr[2] : {}) : (pr || {});
      const title = isArr ? pr[0] : (pr?.TITLE ?? pr?.title);
      const direction = isArr ? pr[1] : (pr?.DIRECTION ?? pr?.direction);
      title ? P(`title: «${title}»`) : W("title не найден → «Без процесса»");
      direction ? P(`direction: «${direction}»`) : W("direction не найден → «Без направления»");
      const kpiKeys = ["current_state", "target_state", "metrics", "kpi_2026", "january", "quarter_1", "quarter_2"];
      const found = kpiKeys.filter((k) => (payload[k] != null) || (isArr && pr[2 + kpiKeys.indexOf(k)] != null));
      found.length >= 4
        ? P(`KPI-поля находятся (${found.length}/${kpiKeys.length}): ${found.join(", ")}`)
        : W(`KPI-полей мало (${found.length}/${kpiKeys.length}) — таблица процессов будет полупустой`);
    } catch (e) { F(e.message); }
  }

  console.log(`\n═══ Итог: ✅ ${ok}  ⚠️ ${warn}  ❌ ${fail} ═══`);
  if (fail) console.log("Красные пункты означают, что синхронизация упадёт или отработает вхолостую.");
  else if (warn) console.log("Жёлтые пункты — синхронизация пройдёт, но часть HTML-ячеек будет пустой.");
  else console.log("Контракт полностью соблюдён — можно запускать синхронизацию в Обсидиане.");
}

main().catch((e) => { console.error("Фатально:", e.message); process.exit(1); });
