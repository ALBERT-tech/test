# rb-api-check

Валидатор API-контракта для плагина rb-sync (Obsidian ← Bitrix, bitrix.rossilber.com).
Один файл, без зависимостей — нужен только Node.js (любой современный, 14+). Ничего не пишет — читает и печатает отчёт.

Рассчитан на запуск **с локального компа внутри сети**, где доступен Bitrix.

## Как получить на локальный комп

Достаточно одного файла `check-rb-api.js` — скачайте его из репозитория (GitHub → Raw → сохранить) или склонируйте:

```bash
git clone https://github.com/albert-tech/test.git
cd test/rb-api-check
```

## Запуск

```bash
# обычный запуск (внутренний DNS резолвит имя сам)
node check-rb-api.js https://bitrix.rossilber.com КЛЮЧ

# сервер в локалке доступен по IP и без TLS
node check-rb-api.js http://192.168.1.10 КЛЮЧ

# самоподписанный сертификат в локалке
node check-rb-api.js https://bitrix.rossilber.com КЛЮЧ --insecure

# с проверкой fallback IP (подмена DNS, как делает плагин)
node check-rb-api.js https://bitrix.rossilber.com КЛЮЧ 89.189.154.97
```

- `http://` и `https://` поддерживаются оба, порт можно указать явно (`http://192.168.1.10:8080`).
- `--insecure` — не проверять TLS-сертификат (для самоподписанных в локальной сети). Скрипт сам подскажет этот флаг, если упрётся в ошибку сертификата.
- Третий позиционный аргумент — IP для подмены DNS: имитирует fallback-механизм плагина, SNI при этом остаётся правильным.

## Что проверяет

1. **Списки**: `direction.php?k=`, `project.php?k=`, `process.php?k=` — ответ массив, id извлекаются.
2. **direction.php?k=&id=N**: `[0]` название (строка), `[1]` процессы (массив), `[2]` проекты (массив), `[3]` опц. объект с task_id.
3. **project.php?k=&id=N**: `[0]` title, `[1]` direction, `[2]` process, `[3]` объект карточки (stage, target, place, strateg_target, effect_plan/fact, kpi..., questions), `[4]` массив.
4. **process.php?k=&id=N**: title/direction + KPI-поля (current_state, target_state, metrics, kpi_2026, january..june, quarter_1/2) — позиционно или по ключам.

## Поля для HTML-таблиц (регистр важен!)

- Процессы: `TITLE`, `current_state`, `target_state`, `metrics`, `kpi_2026`, `january`…`june`, `quarter_1`, `quarter_2`
- Проекты: `TITLE`, `place`, `PRIORITY` (2=топ 🔥), `STATUS` (5=завершено), `effect_plan`, `effect_fact`, `RESPONSIBLE`, `DEADLINE`, `strateg_target`, `PROCESS_OF_PROJECT`

## Известные хрупкие места плагина

- `DEADLINE` парсится через `new Date()` — нужен ISO-формат `2026-08-20`, русский `20.08.2026` сломает подсчёт просрочки.
- Пустой `[1]` (direction) в project.php → файл уедет в папку «Без направления», ссылки из таблиц направления будут битые.
- `PRIORITY`/`STATUS` сравниваются нестрого (`== 2`, `== 5`) — строки из PHP допустимы.

## Легенда отчёта

- ✅ контракт соблюдён
- ⚠️ синхронизация пройдёт, но ячейки HTML будут пустые / значения по умолчанию
- ❌ синхронизация упадёт или отработает вхолостую
