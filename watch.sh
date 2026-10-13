#!/usr/bin/env bash
# КОПИЯ scripts/watch.sh из закрытого репозитория сайта. Здесь не править: правка — в источнике,
# копия обновляется командой из его README → «Наблюдение».
# Наблюдение за сайтом снаружи (бриф 22): жив ли сервер, отвечает ли база, та ли страница.
# Запускает GitHub Actions по расписанию (.github/workflows/watch.yml); руками:
#   bash scripts/watch.sh https://<домен>
#   WATCH_SITEMAP=1 bash scripts/watch.sh https://<домен>     # ещё и карта сайта
#
# Проверки: /api/health — 200 и «ok»; главная — 200 и название магазина; оба ответа быстрее
# WATCH_MAX_SECONDS. С WATCH_SITEMAP=1 — /sitemap.xml: 200 и не меньше WATCH_SITEMAP_MIN адресов.
# Тревога — только когда проверка не прошла два раза подряд с паузой WATCH_RETRY_SECONDS:
# одиночный сбой сети письма не стоит. Код выхода 1 — GitHub пишет на почту об упавшем
# workflow; с TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID сообщение уходит ещё и в Telegram.
# Что делать по тревоге — README → «По тревоге».
set -uo pipefail

base="${1:-${SITE_URL:-}}"
base="${base%/}"
if [ -z "$base" ]; then
  echo "Нужен адрес сайта: bash scripts/watch.sh https://<домен>" >&2
  exit 2
fi

MAX_SECONDS="${WATCH_MAX_SECONDS:-3}"
RETRY_SECONDS="${WATCH_RETRY_SECONDS:-60}"
SITEMAP_MIN="${WATCH_SITEMAP_MIN:-140}"
MARKER="${WATCH_MARKER:-Mondial Flowers}"

body=$(mktemp)
trap 'rm -f "$body" "$body.err"' EXIT

# check <путь> <что должно быть в ответе>: печатает строку итога, код 1 — не прошла
check() {
  local path="$1" needle="$2" meta code seconds
  # со сжатием, как браузер: время ответа — то, что ждёт покупатель.
  # WATCH_CURL_OPTS — для машины разработки (--ssl-no-revoke)
  # shellcheck disable=SC2086
  meta=$(curl -sS ${WATCH_CURL_OPTS:-} --compressed --max-time 15 -o "$body" \
    -w '%{http_code} %{time_total}' "$base$path" 2>"$body.err") || {
    echo "СБОЙ $path: нет ответа — $(sed 's/^curl: //' "$body.err" | head -1)"
    return 1
  }
  code="${meta%% *}"
  seconds="${meta##* }"
  if [ "$code" != 200 ]; then
    echo "СБОЙ $path: код $code"
    return 1
  fi
  if ! grep -q -- "$needle" "$body"; then
    echo "СБОЙ $path: в ответе нет «$needle»"
    return 1
  fi
  if ! awk -v t="$seconds" -v max="$MAX_SECONDS" 'BEGIN { exit !(t < max) }'; then
    echo "СБОЙ $path: ответ за $seconds с, норма — быстрее $MAX_SECONDS с"
    return 1
  fi
  echo "ок   $path: 200 за $seconds с"
}

sitemap() {
  local count
  check /sitemap.xml '<urlset' || return 1
  count=$(grep -o '<loc>' "$body" | wc -l | tr -d ' ')
  if [ "$count" -lt "$SITEMAP_MIN" ]; then
    echo "СБОЙ /sitemap.xml: адресов $count, должно быть не меньше $SITEMAP_MIN"
    return 1
  fi
  echo "ок   /sitemap.xml: адресов $count"
}

run() {
  local failed=0
  check /api/health '"status":"ok"' || failed=1
  check / "$MARKER" || failed=1
  if [ "${WATCH_SITEMAP:-}" = 1 ]; then sitemap || failed=1; fi
  return $failed
}

if report=$(run); then
  echo "$report"
  exit 0
fi
echo "$report"
echo "Первая проверка не прошла — повтор через $RETRY_SECONDS с"
sleep "$RETRY_SECONDS"
if report=$(run); then
  echo "$report"
  echo "Повтор прошёл: одиночный сбой, тревоги нет"
  exit 0
fi
echo "$report"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  text="Сайт $base не проходит проверку два раза подряд:
$(echo "$report" | grep '^СБОЙ')
Что делать: README → «По тревоге»."
  curl -sS --max-time 15 -o /dev/null \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$text" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" ||
    echo "Сообщение в Telegram не ушло"
fi
echo "ТРЕВОГА: проверка не прошла два раза подряд"
exit 1
