#!/usr/bin/env bash
# Первичная настройка чистого VPS (Ubuntu 24.04). Запускается под root.
#
# Шаг 1, пока вход по паролю ещё работает:
#   bash bootstrap-server.sh setup "ssh-ed25519 AAAA... комментарий"
# Потом в ОТДЕЛЬНОМ терминале проверить, что пускает по ключу: ssh deploy@<ip>
# Шаг 2, только после успешной проверки:
#   bash bootstrap-server.sh harden-ssh
#
# Скрипт идемпотентный: повторный запуск ничего не ломает.
set -euo pipefail

DEPLOY_USER=deploy
APP_DIR=/opt/givemeanoffer
SWAP_SIZE=2G
TIMEZONE=Europe/Moscow

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "запускать под root"
. /etc/os-release
[[ "$ID" == ubuntu ]] || die "ожидается Ubuntu, а это $PRETTY_NAME"

# Отвечает ли адрес по HTTPS (любой HTTP-код, даже 401, значит «доступен»).
reachable() { curl -sS -o /dev/null -m 10 "$1" 2>/dev/null; }

setup_base() {
  log "Обновление системы и базовые пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get upgrade -yq
  apt-get install -yq ca-certificates curl ufw unattended-upgrades cron

  log "Часовой пояс $TIMEZONE"
  timedatectl set-timezone "$TIMEZONE"

  log "Автоматические обновления безопасности"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

setup_user() {
  local pubkey=$1
  log "Пользователь $DEPLOY_USER"
  id "$DEPLOY_USER" &>/dev/null || adduser --disabled-password --gecos "" "$DEPLOY_USER"
  install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
  local keys="/home/$DEPLOY_USER/.ssh/authorized_keys"
  touch "$keys"
  grep -qxF "$pubkey" "$keys" || echo "$pubkey" >>"$keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$keys"
  chmod 600 "$keys"
  # Пароля у deploy нет, поэтому sudo без пароля. Доступ к docker и так равен root.
  echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-$DEPLOY_USER"
  chmod 440 "/etc/sudoers.d/90-$DEPLOY_USER"
  visudo -cf "/etc/sudoers.d/90-$DEPLOY_USER" >/dev/null
}

setup_swap() {
  if swapon --show | grep -q .; then
    log "Swap уже есть: $(swapon --show --noheadings | awk '{print $1, $3}')"
    return
  fi
  log "Swap $SWAP_SIZE"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  echo 'vm.swappiness=10' >/etc/sysctl.d/90-swappiness.conf
  sysctl -q -p /etc/sysctl.d/90-swappiness.conf
}

install_docker() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    log "Docker уже установлен: $(docker --version)"
    return
  fi
  if reachable https://download.docker.com/linux/ubuntu/gpg; then
    log "Docker из официального репозитория"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -q
    apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    log "download.docker.com недоступен, ставлю Docker из пакетов Ubuntu"
    apt-get install -yq docker.io docker-compose-v2
  fi
  systemctl enable --now docker
}

configure_docker() {
  log "Настройка Docker: ротация логов, зеркало реестра при необходимости"
  local mirrors=""
  if reachable https://registry-1.docker.io/v2/; then
    echo "Docker Hub доступен напрямую"
  else
    echo "Docker Hub недоступен, подключаю зеркало mirror.gcr.io"
    mirrors='"registry-mirrors": ["https://mirror.gcr.io"],'
  fi
  cat >/etc/docker/daemon.json <<EOF
{
  ${mirrors}
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  systemctl restart docker
  usermod -aG docker "$DEPLOY_USER"
}

setup_firewall() {
  log "Firewall: 22, 80, 443"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 443/udp >/dev/null # HTTP/3 в Caddy
  ufw --force enable >/dev/null
  ufw status verbose | sed -n '1,12p'
}

setup_app_dir() {
  log "Каталог приложения $APP_DIR"
  install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_DIR"
}

check_registries() {
  log "Доступность реестров с сервера"
  for url in https://ghcr.io/v2/ https://registry-1.docker.io/v2/ https://mirror.gcr.io/v2/; do
    if reachable "$url"; then echo "  ok    $url"; else echo "  НЕТ   $url"; fi
  done
  log "Пробный pull образа с Docker Hub"
  docker pull -q hello-world >/dev/null && docker run --rm hello-world | sed -n '2p'
  docker image rm -f hello-world >/dev/null
}

harden_ssh() {
  local keys="/home/$DEPLOY_USER/.ssh/authorized_keys"
  [[ -s "$keys" ]] || die "у $DEPLOY_USER нет ключей, сначала setup"
  log "SSH: только по ключу, root по SSH запрещён"
  # Файлы в sshd_config.d читаются по алфавиту, побеждает первое значение,
  # поэтому префикс 00- перекрывает 50-cloud-init.conf с PasswordAuthentication yes.
  cat >/etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
EOF
  sshd -t || die "конфиг sshd не прошёл проверку, ничего не применено"
  systemctl reload ssh
  sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication) '
  echo "Готово. Текущая сессия не закрывается; новые входы только deploy по ключу."
}

case "${1:-}" in
  setup)
    [[ -n "${2:-}" ]] || die "передайте публичный ключ: setup \"ssh-ed25519 AAAA...\""
    [[ "$2" =~ ^ssh-(ed25519|rsa)\ [A-Za-z0-9+/=]+ ]] || die "это не похоже на публичный SSH-ключ"
    setup_base
    setup_user "$2"
    setup_swap
    install_docker
    configure_docker
    setup_firewall
    setup_app_dir
    check_registries
    log "Шаг 1 готов. Проверьте в новом терминале: ssh $DEPLOY_USER@<ip> 'docker ps'"
    log "Если пускает, запустите: bash $0 harden-ssh"
    ;;
  harden-ssh)
    harden_ssh
    ;;
  *)
    die "использование: $0 setup \"<публичный ключ>\" | $0 harden-ssh"
    ;;
esac
