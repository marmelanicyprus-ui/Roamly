#!/usr/bin/env bash
# Установка «почты» Roamly offline на чистый Ubuntu-сервер.
# Запуск (на сервере, под root):  bash <(curl -fsSL https://raw.githubusercontent.com/marmelanicyprus-ui/Roamly/main/server/install.sh)
# Повторный запуск обновляет сервер до последней версии из GitHub; ключи спрашиваются только один раз.
set -euo pipefail
DIR=/opt/roamly
REPO=https://github.com/marmelanicyprus-ui/Roamly.git

echo "== Roamly: установка сервера =="
if ! command -v docker >/dev/null; then
  echo "-- ставлю Docker"
  curl -fsSL https://get.docker.com | sh
fi
command -v git >/dev/null || (apt-get update -qq && apt-get install -y -qq git)

if [ -d "$DIR/.git" ]; then
  git -C "$DIR" fetch -q origin main && git -C "$DIR" reset -q --hard origin/main
else
  git clone -q --depth 1 "$REPO" "$DIR"
fi
cd "$DIR/server"
mkdir -p data secrets

IP=$(curl -4 -fsS https://api.ipify.org || hostname -I | awk '{print $1}')
DOMAIN="${IP//./-}.sslip.io"

if [ ! -f .env ]; then
  echo
  echo "Ключи LiveKit (LiveKit Cloud → Settings → API keys). Секрет при вводе не показывается."
  read -rp "LiveKit API Key: " LK_KEY
  read -rsp "LiveKit API Secret: " LK_SECRET; echo
  read -rp "LiveKit URL [wss://roamly-4v5w8ej5.livekit.cloud]: " LK_URL
  LK_URL=${LK_URL:-wss://roamly-4v5w8ej5.livekit.cloud}
  umask 077
  cat > .env <<ENV
LIVEKIT_URL=$LK_URL
LIVEKIT_API_KEY=$LK_KEY
LIVEKIT_API_SECRET=$LK_SECRET
FCM_SERVICE_ACCOUNT=/secrets/fcm.json
ENV
  umask 022
fi
# Карта: ключ MapTiler (бесплатный тариф, maptiler.com → Account → API keys). Без ключа — OpenTopoMap.
if ! grep -q '^MAPTILER_KEY=.' .env; then
  echo
  read -rp "Ключ MapTiler для карты (Enter — пропустить, будет OpenTopoMap): " MT_KEY || MT_KEY=""
  sed -i '/^MAPTILER_KEY=/d' .env
  echo "MAPTILER_KEY=$MT_KEY" >> .env
fi
echo "DOMAIN=$DOMAIN" > compose.env

if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi

echo "-- запускаю (адрес: https://$DOMAIN)"
docker compose --env-file compose.env up -d --build
sleep 8
echo
if curl -fsS "https://$DOMAIN/health"; then
  echo; echo "== Готово: https://$DOMAIN работает =="
else
  echo; echo "Сервер запущен, сертификат HTTPS ещё получается. Проверьте через минуту: curl https://$DOMAIN/health"
fi
