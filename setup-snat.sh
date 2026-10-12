#!/usr/bin/env bash
# setup-snat.sh
# Юзеры подключаются к IP входа, а в интернет выходят с IP выхода (SNAT).
# Для нод Remnawave (host network) и любых VPN-серверов на Linux.
#
# Запуск:
#   bash setup-snat.sh
#   bash setup-snat.sh IP_ВХОДА IP_ВЫХОДА
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup-snat.sh)

set -u

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "Запустите от root (sudo bash $0)"
  exit 1
fi

valid_ip() {
  local ip=$1 IFS=.
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for o in $ip; do [ "$o" -le 255 ] || return 1; done
  return 0
}

ask() {
  # ask "вопрос" переменная
  local prompt=$1 var=$2 val
  while true; do
    read -r -p "$prompt" val < /dev/tty
    if valid_ip "$val"; then
      printf -v "$var" '%s' "$val"
      return
    fi
    err "Некорректный IPv4, попробуйте ещё раз"
  done
}

IN_IP=${1:-}
OUT_IP=${2:-}

echo "=== Настройка SNAT: вход -> выход ==="
echo
ip -br a
echo

if [ -z "$IN_IP" ];  then ask "IP входа (на него подключаются юзеры, адрес в подписке): " IN_IP; fi
if [ -z "$OUT_IP" ]; then ask "IP выхода (с него юзеры выходят в интернет): " OUT_IP; fi

valid_ip "$IN_IP"  || { err "Некорректный IP входа: $IN_IP"; exit 1; }
valid_ip "$OUT_IP" || { err "Некорректный IP выхода: $OUT_IP"; exit 1; }
[ "$IN_IP" != "$OUT_IP" ] || { err "IP входа и выхода совпадают"; exit 1; }

# Интерфейс определяем по IP входа, иначе по маршруту по умолчанию
IFACE=$(ip -4 -o addr show | awk -v ip="$IN_IP" '$4 ~ "^"ip"/" {print $2; exit}')
if [ -z "$IFACE" ]; then
  IFACE=$(ip route | awk '/^default/ {print $5; exit}')
  warn "IP входа не найден на интерфейсах, беру интерфейс по умолчанию: $IFACE"
fi
[ -n "$IFACE" ] || { err "Не удалось определить сетевой интерфейс"; exit 1; }

echo
echo "Вход:      $IN_IP"
echo "Выход:     $OUT_IP"
echo "Интерфейс: $IFACE"
echo
read -r -p "Продолжить? [y/N] " yn < /dev/tty
case "$yn" in y|Y|yes|YES) ;; *) echo "Отменено"; exit 0;; esac

# Проверка, что IP выхода есть на интерфейсе
if ! ip -4 -o addr show dev "$IFACE" | grep -q " $OUT_IP/"; then
  warn "IP выхода $OUT_IP не найден на $IFACE"
  read -r -p "Добавить временно (ip addr add $OUT_IP/32)? [y/N] " yn < /dev/tty
  case "$yn" in
    y|Y|yes|YES) ip addr add "$OUT_IP/32" dev "$IFACE" && ok "Адрес добавлен (до перезагрузки, пропишите его в netplan/interfaces)";;
    *) err "Без адреса на интерфейсе правило работать не будет"; exit 1;;
  esac
fi

# Проверка, что оба адреса выпускают трафик
echo
echo "--- Проверка выхода в интернет с обоих адресов ---"
R_OUT=$(curl -s -m 10 --interface "$OUT_IP" https://ifconfig.me || true)
R_IN=$(curl -s -m 10 --interface "$IN_IP" https://ifconfig.me || true)
echo "С $OUT_IP: ${R_OUT:-нет ответа}"
echo "С $IN_IP:  ${R_IN:-нет ответа}"
if [ "$R_OUT" != "$OUT_IP" ]; then
  err "IP выхода не выпускает трафик (проблема на стороне хостера). Дальше идти нет смысла."
  exit 1
fi

# Правило SNAT (без дублей)
echo
echo "--- Добавление правила SNAT ---"
if iptables -t nat -C POSTROUTING -o "$IFACE" -s "$IN_IP" -j SNAT --to-source "$OUT_IP" 2>/dev/null; then
  warn "Правило уже существует, пропускаю"
else
  iptables -t nat -I POSTROUTING 1 -o "$IFACE" -s "$IN_IP" -j SNAT --to-source "$OUT_IP" \
    && ok "Правило добавлено" || { err "Не удалось добавить правило"; exit 1; }
fi

echo
echo "--- Проверка: внешний IP сервера ---"
EXT=$(curl -s -m 10 https://ifconfig.me || true)
echo "$EXT"
if [ "$EXT" = "$OUT_IP" ]; then ok "Сервер выходит с $OUT_IP"; else warn "Ожидался $OUT_IP, получено: ${EXT:-ничего}"; fi

echo
iptables -t nat -L POSTROUTING -n -v --line-numbers

# Сохранение правил
echo
echo "--- Сохранение правил после перезагрузки ---"
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 \
  && ok "iptables-persistent установлен" || warn "Не удалось установить iptables-persistent (проверьте apt)"
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save && ok "Правила сохранены"
  grep -n SNAT /etc/iptables/rules.v4 2>/dev/null
else
  err "netfilter-persistent не найден, правила после ребута пропадут"
fi

# conntrack
echo
echo "--- conntrack ---"
sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max 2>/dev/null \
  || warn "conntrack ещё не загружен"

echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200" > /etc/sysctl.d/99-conntrack.conf
sysctl --system >/dev/null 2>&1 && ok "Таймаут established = 7200 сек применён"

echo
ok "Готово. Проверьте: нода online в панели, а с клиента 2ip.ru показывает $OUT_IP"
warn "Если на панели/файрволах есть whitelist по IP ноды, добавьте туда $OUT_IP"
warn "Убедитесь, что $OUT_IP прописан в netplan/interfaces, чтобы не пропал после ребута"
