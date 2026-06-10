#!/bin/bash
set -Eeuo pipefail

# Unattended Tomcat 9 installer for Zucchetti environments.
# CLIENT_PROFILE=polo installs under /zucchetti/infinity.
# CLIENT_PROFILE=hrsud installs under /opt/infinity.

DEFAULT_CLIENT_PROFILE="polo"
DEFAULT_TOMCAT_START_INDEX="1"
DEFAULT_TOMCAT_COUNT="1"

CLIENT_PROFILE="${CLIENT_PROFILE:-$DEFAULT_CLIENT_PROFILE}"
UNATTENDED="${UNATTENDED:-0}"
TIMEZONE="${TIMEZONE:-Europe/Rome}"
ENABLE_ROOT_SSH_PASSWORD="${ENABLE_ROOT_SSH_PASSWORD:-1}"
CREATE_DOCUMENTI="${CREATE_DOCUMENTI:-1}"
TOMCAT_COUNT="${TOMCAT_COUNT:-$DEFAULT_TOMCAT_COUNT}"
TOMCAT_START_INDEX="${TOMCAT_START_INDEX:-$DEFAULT_TOMCAT_START_INDEX}"
RUN_OS_UPGRADE="${RUN_OS_UPGRADE:-1}"
CONF_URL="${CONF_URL:-https://dl.poloinformatico.it/assistenza/Scripts/conf}"
LIB_URL="${LIB_URL:-https://dl.poloinformatico.it/assistenza/Scripts/lib}"
LOGROTATE_DIR="/etc/logrotate.d"
SYSTEMD_DIR="/etc/systemd/system"
TMP_DIR="/tmp"
PSQL_LIB="postgresql-42.7.3.jar"
MSSQL_LIB="mssql-jdbc-12.8.1.jre8.jar"
LOG_FILE="/root/tomcat_installation.log"
JAVA_API_URL="https://api.github.com/repos/adoptium/temurin8-binaries/releases/latest"
TOMCAT_VERSION="${TOMCAT_VERSION:-}"
TOMCAT_TGZ=""

case "$CLIENT_PROFILE" in
  polo) ZUCC_DIR="${ZUCC_DIR:-/zucchetti/infinity}" ;;
  hrsud) ZUCC_DIR="${ZUCC_DIR:-/opt/infinity}" ;;
  *) echo "CLIENT_PROFILE non valido: $CLIENT_PROFILE" >&2; exit 1 ;;
esac
ZUCC_DIR="${ZUCC_DIR%/}"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
fail() { log "ERRORE: $*"; exit 1; }

cleanup() {
  [ -n "${TOMCAT_TGZ:-}" ] && [ -f "$TOMCAT_TGZ" ] && rm -f "$TOMCAT_TGZ" || true
}
trap cleanup EXIT

require_root() {
  [ "$EUID" -eq 0 ] || fail "Lo script deve essere eseguito come root"
}

configure_timezone_and_ssh() {
  log "Configuro timezone $TIMEZONE e accesso SSH root/password"
  if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    ln -snf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
    timedatectl set-timezone "$TIMEZONE" >/dev/null 2>&1 || true
  fi
  if [ "$ENABLE_ROOT_SSH_PASSWORD" = "1" ] && [ -f /etc/ssh/sshd_config ]; then
    grep -Eq '^[#[:space:]]*PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config \
      && sed -ri 's|^[#[:space:]]*PermitRootLogin[[:space:]]+.*|PermitRootLogin yes|' /etc/ssh/sshd_config \
      || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
    grep -Eq '^[#[:space:]]*PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config \
      && sed -ri 's|^[#[:space:]]*PasswordAuthentication[[:space:]]+.*|PasswordAuthentication yes|' /etc/ssh/sshd_config \
      || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
    systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  fi
}

bootstrap_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Aggiorno pacchetti base"
  apt update -y
  if [ "$RUN_OS_UPGRADE" = "1" ]; then
    apt upgrade -y
    apt dist-upgrade -y
  fi
  # Installa solo i pacchetti effettivamente disponibili nella distribuzione
  # corrente: alcuni nomi storici (es. software-properties-common) non esistono
  # piu' su Debian 13 (trixie) e con "set -e" farebbero fallire l'intero deploy.
  local base_packages="curl net-tools ncdu wget gnupg2 sudo rsync apt-transport-https ca-certificates software-properties-common locate libncurses5-dev libsasl2-dev libssl-dev jq cron tzdata openssh-server fontconfig"
  local to_install=""
  local skipped=""
  for pkg in $base_packages; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      to_install="$to_install $pkg"
    else
      skipped="$skipped $pkg"
    fi
  done
  [ -n "$skipped" ] && log "Pacchetti non disponibili in questa distribuzione, ignorati:$skipped"
  # shellcheck disable=SC2086
  apt install -y $to_install
  apt-add-repository contrib non-free -y >/dev/null 2>&1 || true
  apt update -y
  echo 'msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true' | debconf-set-selections >/dev/null 2>&1 || true
  apt install -y ttf-mscorefonts-installer >/dev/null 2>&1 || true
}

ensure_user_and_dirs() {
  if ! id zucchetti >/dev/null 2>&1; then
    useradd -r -s /sbin/nologin zucchetti
  fi
  mkdir -p "$ZUCC_DIR"
  if [ "$CREATE_DOCUMENTI" = "1" ]; then
    mkdir -p "$ZUCC_DIR/Documenti"
    chown -R zucchetti:zucchetti "$ZUCC_DIR/Documenti"
    chmod 755 "$ZUCC_DIR/Documenti"
  fi
}

get_latest_java_tag() {
  local tag
  tag=$(curl -fsSL "$JAVA_API_URL" | jq -r '.tag_name // empty' | grep -oE 'jdk8u[0-9]+-b[0-9]+' || true)
  [ -n "$tag" ] || fail "Impossibile rilevare ultima release Temurin 8"
  echo "$tag"
}

java_asset_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) fail "Architettura Java non supportata: $(uname -m)" ;;
  esac
}

ensure_java() {
  local tag arch build asset url out
  tag=$(get_latest_java_tag)
  if [ -x "$ZUCC_DIR/$tag/bin/java" ]; then
    ln -sfn "$ZUCC_DIR/$tag" "$ZUCC_DIR/java"
    log "Java gia aggiornato: $tag"
    return
  fi
  arch=$(java_asset_arch)
  build=$(echo "$tag" | sed -E 's/^jdk8u([0-9]+)-b([0-9]+)$/\1b\2/')
  asset="OpenJDK8U-jdk_${arch}_linux_hotspot_8u${build}.tar.gz"
  url="https://github.com/adoptium/temurin8-binaries/releases/download/${tag}/${asset}"
  out="$TMP_DIR/$asset"
  log "Scarico Java $tag"
  wget -O "$out" "$url"
  tar xzf "$out" -C "$ZUCC_DIR"
  ln -sfn "$ZUCC_DIR/$tag" "$ZUCC_DIR/java"
  rm -f "$out"
}

get_latest_tomcat_version() {
  local version
  version=$(curl -fsSL 'https://dlcdn.apache.org/tomcat/tomcat-9/' | grep -oE 'v9\.0\.[0-9]+' | tr -d v | sort -V | tail -n 1 || true)
  if [ -z "$version" ]; then
    version=$(curl -fsSL 'https://archive.apache.org/dist/tomcat/tomcat-9/' | grep -oE 'v9\.0\.[0-9]+' | tr -d v | sort -V | tail -n 1 || true)
  fi
  echo "${version:-9.0.97}"
}

download_tomcat() {
  TOMCAT_VERSION="${TOMCAT_VERSION:-$(get_latest_tomcat_version)}"
  TOMCAT_TGZ="$TMP_DIR/apache-tomcat-$TOMCAT_VERSION.tar.gz"
  if [ -f "$TOMCAT_TGZ" ]; then
    return
  fi
  log "Scarico Tomcat $TOMCAT_VERSION"
  wget -O "$TOMCAT_TGZ" "https://dlcdn.apache.org/tomcat/tomcat-9/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz" \
    || wget -O "$TOMCAT_TGZ" "https://archive.apache.org/dist/tomcat/tomcat-9/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz"
}

tomcat_service_name() {
  local index="$1"
  [ "$index" -ge 1 ] && [ "$index" -le 26 ] || fail "Indice Tomcat non valido: $index"
  local letters=(a b c d e f g h i j k l m n o p q r s t u v w x y z)
  echo "tomcat_${letters[$((index - 1))]}"
}

configure_server_ports() {
  local file="$1" index="$2"
  local http_port=$((8080 + index - 1))
  local https_port=$((8443 + index - 1))
  local ajp_port=$((8009 + index - 1))
  sed -i "s/port=\"8080\"/port=\"$http_port\"/g" "$file"
  sed -i "s/port=\"8443\"/port=\"$https_port\"/g" "$file"
  sed -i "s/port=\"8009\"/port=\"$ajp_port\"/g" "$file"
}

write_systemd_service() {
  local service="$1" tomcat_dir="$2" index="$3"
  local after="network.target"
  if [ "$index" -gt 1 ]; then
    after="$after $(tomcat_service_name $((index - 1))).service"
  fi
  cat > "$SYSTEMD_DIR/$service.service" <<EOF
[Unit]
Description=$service
After=$after

[Service]
Type=forking
User=zucchetti
Group=zucchetti
PermissionsStartOnly=true
LimitNOFILE=10000
Environment=CATALINA_PID=$tomcat_dir/temp/tomcat.pid
Environment=JAVA_HOME=$ZUCC_DIR/java
Environment=CATALINA_HOME=$tomcat_dir
Environment=CATALINA_BASE=$tomcat_dir
Environment="JAVA_OPTS=-Duser.timezone=$TIMEZONE -Dfile.encoding=ISO-8859-15 -Djava.awt.headless=true -Duser.language=it -Dsun.zip.disableMemoryMapping=true -Xms3072m -Xmx4096m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=$tomcat_dir/logs -XX:MaxMetaspaceSize=1024m -XX:MetaspaceSize=768m -XX:ReservedCodeCacheSize=480m -Xss2m -XX:MaxJavaStackTraceDepth=50000 -XX:+UseG1GC -XX:MaxGCPauseMillis=500 -XX:+UseStringDeduplication -XX:+DisableExplicitGC -Xloggc:$tomcat_dir/logs/gc.log -XX:ErrorFile=$tomcat_dir/logs/java_error%p.log"
ExecStartPre=/usr/bin/rm -rf $tomcat_dir/work/Catalina
ExecStartPre=/usr/bin/chmod 755 -R $tomcat_dir/
ExecStartPre=/usr/bin/chown -R zucchetti:zucchetti $tomcat_dir/
ExecStartPre=/usr/bin/mkdir -p $ZUCC_DIR/Documenti
ExecStartPre=/usr/bin/chmod 755 -R $ZUCC_DIR/Documenti/
ExecStartPre=/usr/bin/chown -R zucchetti:zucchetti $ZUCC_DIR/Documenti/
ExecStart=/bin/sh $tomcat_dir/bin/startup.sh
ExecStop=/bin/kill -15 \$MAINPID
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF
}

RESTART_SCRIPT="/usr/local/sbin/tomcat-zucchetti-restart-all.sh"

# Riavvio sequenziale di TUTTI i Tomcat: stop di tutti, poi avvio in ordine
# (tomcat_a, tomcat_b, ...) attendendo che le webapp di ciascuno siano online
# (marker "Server startup in" in catalina.out) prima di avviare il successivo.
# Pianificato una sola volta in /etc/crontab.
setup_sequential_restart() {
  cat > "$RESTART_SCRIPT" <<'EOS'
#!/bin/bash
# Riavvio sequenziale dei Tomcat Zucchetti (stop di tutti, poi start ordinato
# attendendo che tutte le webapp del precedente siano online).
LOG=/var/log/tomcat-zucchetti-restart.log
exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T') riavvio sequenziale Tomcat ==="
services=$(systemctl list-unit-files 'tomcat_*.service' --no-legend 2>/dev/null | awk '{print $1}' | sed 's/\.service$//' | sort)
[ -n "$services" ] || { echo "nessun servizio tomcat_* trovato"; exit 0; }
for s in $services; do echo "stop $s"; systemctl stop "$s" || true; done
sleep 5
for s in $services; do
  dir=$(systemctl show -p Environment "$s" 2>/dev/null | tr ' ' '\n' | sed -n 's/^CATALINA_HOME=//p')
  log="$dir/logs/catalina.out"
  off=$( [ -n "$dir" ] && [ -f "$log" ] && wc -c < "$log" || echo 0 )
  echo "start $s (dir=${dir:-?})"
  systemctl start "$s"
  if [ -z "$dir" ]; then sleep 60; continue; fi
  online=0
  for i in $(seq 1 120); do
    sleep 5
    systemctl is-active --quiet "$s" || { echo "  $s non attivo"; break; }
    if tail -c +$((off+1)) "$log" 2>/dev/null | grep -q "Server startup in"; then online=1; break; fi
  done
  [ "$online" = 1 ] && echo "  $s: tutte le webapp online" || echo "  $s: timeout (proseguo col successivo)"
done
echo "=== fine ==="
EOS
  chmod 750 "$RESTART_SCRIPT"
  # Rimuove eventuali vecchie righe per-servizio e imposta un'unica esecuzione notturna
  sed -i '\#systemctl restart tomcat_#d' /etc/crontab 2>/dev/null || true
  local line="30 1 * * * root $RESTART_SCRIPT"
  grep -Fqx "$line" /etc/crontab || echo "$line" >> /etc/crontab
}

write_logrotate() {
  local service="$1" tomcat_dir="$2"
  cat > "$LOGROTATE_DIR/$service" <<EOF
$tomcat_dir/logs/catalina.out {
    rotate 30
    daily
    missingok
    sharedscripts
    compress
    prerotate
        systemctl stop $service || true
    endscript
    postrotate
        systemctl start $service || true
    endscript
}
EOF
}

download_libs() {
  local tomcat_dir="$1"
  mkdir -p "$tomcat_dir/lib"
  wget -O "$tomcat_dir/lib/$PSQL_LIB" "$LIB_URL/$PSQL_LIB"
  wget -O "$tomcat_dir/lib/$MSSQL_LIB" "$LIB_URL/$MSSQL_LIB"
}

install_tomcat_instance() {
  local index="$1"
  local service tomcat_dir
  service=$(tomcat_service_name "$index")
  tomcat_dir="$ZUCC_DIR/$service"
  log "Installo $service in $tomcat_dir"
  systemctl stop "$service" >/dev/null 2>&1 || true
  mkdir -p "$tomcat_dir"
  tar zxf "$TOMCAT_TGZ" --strip-components=1 -C "$tomcat_dir/"
  mkdir -p "$tomcat_dir/conf"
  for file in context.xml tomcat-users.xml catalina.properties; do
    wget -O "$tomcat_dir/conf/$file" "$CONF_URL/$file"
  done
  wget -O "$tomcat_dir/conf/server.xml" "$CONF_URL/server_a.xml"
  configure_server_ports "$tomcat_dir/conf/server.xml" "$index"
  download_libs "$tomcat_dir"
  chown -R zucchetti:zucchetti "$tomcat_dir"
  chmod -R 755 "$tomcat_dir"
  write_systemd_service "$service" "$tomcat_dir" "$index"
  write_logrotate "$service" "$tomcat_dir"
  systemctl daemon-reload
  systemctl enable "$service"
  systemctl start "$service"
}

main() {
  require_root
  bootstrap_packages
  configure_timezone_and_ssh
  ensure_user_and_dirs
  curl -s https://install.zerotier.com | sudo bash || true
  ensure_java
  download_tomcat
  local start count end index
  start="$TOMCAT_START_INDEX"
  count="$TOMCAT_COUNT"
  [[ "$start" =~ ^[0-9]+$ ]] || fail "TOMCAT_START_INDEX deve essere numerico"
  [[ "$count" =~ ^[0-9]+$ ]] || fail "TOMCAT_COUNT deve essere numerico"
  end=$((start + count - 1))
  [ "$end" -le 26 ] || fail "TOMCAT_COUNT supera il limite tomcat_z"
  for index in $(seq "$start" "$end"); do
    install_tomcat_instance "$index"
  done
  setup_sequential_restart
  log "Installazione completata: profilo=$CLIENT_PROFILE istanze=$count da indice=$start"
}

main "$@"