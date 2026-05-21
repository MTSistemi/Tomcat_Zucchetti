#!/bin/bash
# Script per l'installazione di Java e Tomcat con file di configurazione per AGO e HR
# Autore: Mattia Tadini
# Nome del file: install_tomcat.sh
# Revisione: 1.01 (fix download Temurin: usa "previous" invece di "latest")

# Variabili
ZUCC_DIR="/opt/infinity"

# --- Temurin 8 download mode ---
# JAVA_RELEASE_MODE:
#   - previous : scarica la release precedente alla latest (default)
#   - latest   : scarica la latest (sconsigliato se mancano asset)
#   - tag      : forza un tag preciso (es. jdk8u472-b08)
JAVA_RELEASE_MODE="${JAVA_RELEASE_MODE:-previous}"
JAVA_RELEASE_TAG="${JAVA_RELEASE_TAG:-jdk8u472-b08}"           # usato se JAVA_RELEASE_MODE=tag
JAVA_FALLBACK_TAG="${JAVA_FALLBACK_TAG:-jdk8u472-b08}"         # fallback se GitHub API/asset falliscono

API_URL_LATEST="https://api.github.com/repos/adoptium/temurin8-binaries/releases/latest"
API_URL_RELEASES="https://api.github.com/repos/adoptium/temurin8-binaries/releases?per_page=10"

TOMCAT_VERSION="9.0.97"
CONF_URL="https://dl.poloinformatico.it/assistenza/Scripts/conf"
LIB_URL="https://dl.poloinformatico.it/assistenza/Scripts/lib"
LOGROTATE_DIR="/etc/logrotate.d"
SYSTEMD_DIR="/etc/systemd/system"
TMP_DIR="/tmp"  # Directory temporanea
PSQL_LIB="postgresql-42.7.3.jar"
MSSQL_LIB="mssql-jdbc-12.8.1.jre8.jar"
LOG_FILE="/root/tomcat_installation.log"  # Percorso del file di log

# Variabili globali utili per cleanup
JAVA_TGZ=""
TOMCAT_TGZ="$TMP_DIR/apache-tomcat-$TOMCAT_VERSION.tar.gz"

# Funzione per il controllo degli errori
check_error() {
  if [ $? -ne 0 ]; then
    echo "Errore durante l'esecuzione: $1" | tee -a "$LOG_FILE"
    cleanup
    exit 1
  fi
}

# Funzione di pulizia in caso di interruzione o alla fine
cleanup() {
  echo "Esecuzione interrotta o completata. Pulizia in corso..." | tee -a "$LOG_FILE"

  # Rimuovi i file scaricati e non necessari (solo temporanei)
  [ -n "$JAVA_TGZ" ] && [ -f "$JAVA_TGZ" ] && rm -f "$JAVA_TGZ"
  [ -f "$TOMCAT_TGZ" ] && rm -f "$TOMCAT_TGZ"

  # In caso di vecchi nomi usati in precedenza
  rm -f "$TMP_DIR"/OpenJDK8-8u*.tar.gz 2>/dev/null || true

  echo "Pulizia completata." | tee -a "$LOG_FILE"
}

# Creazione Utente zucchetti solo se non esiste già
if id "zucchetti" &>/dev/null; then
    echo "L'utente 'zucchetti' esiste già. Procedo..." | tee -a "$LOG_FILE"
else
    useradd -r -s /sbin/nologin zucchetti
    check_error "Aggiunta Utente zucchetti fallita"
fi

# Modifica del valore di PermitRootLogin
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
check_error "Modifica di PermitRootLogin fallita"

# Imposta trap per gestire i segnali di interruzione e terminazione
trap cleanup INT TERM EXIT  # 'EXIT' per eseguire la pulizia alla fine

# --- Helper Temurin ---
detect_temurin_arch() {
  # Temurin asset naming: x64, aarch64, arm, x86-32
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armhf) echo "arm" ;;
    i386|i686) echo "x86-32" ;;
    *)
      echo "x64"  # fallback prudente
      ;;
  esac
}

format_temurin_build() {
  # jdk8u472-b08 -> 472b08
  echo "$1" | sed -E 's/^jdk8u//; s/-b/b/'
}

get_desired_java_tag() {
  local tag=""

  case "$JAVA_RELEASE_MODE" in
    previous)
      # seconda release stabile (0=latest, 1=previous)
      tag="$(curl -s "$API_URL_RELEASES" | jq -r '[.[] | select(.draft==false and .prerelease==false)] | .[1].tag_name' 2>/dev/null || true)"
      ;;
    latest)
      tag="$(curl -s "$API_URL_LATEST" | jq -r '.tag_name' 2>/dev/null || true)"
      ;;
    tag)
      tag="$JAVA_RELEASE_TAG"
      ;;
    *)
      tag="$JAVA_FALLBACK_TAG"
      ;;
  esac

  # Normalizza / fallback
  tag="$(echo "$tag" | grep -oP 'jdk8u\d+-b\d+' || true)"
  if [ -z "$tag" ]; then
    tag="$JAVA_FALLBACK_TAG"
  fi

  echo "$tag"
}

parse_temurin_tag() {
  # output: "update build"  (es. "472 08")
  local tag="$1"
  if [[ "$tag" =~ ^jdk8u([0-9]+)-b([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

version_gt() {
  # ritorna 0 se $1 > $2
  local u1 b1 u2 b2
  read -r u1 b1 < <(parse_temurin_tag "$1") || return 1
  read -r u2 b2 < <(parse_temurin_tag "$2") || return 0

  if [ "$u1" -gt "$u2" ]; then
    return 0
  elif [ "$u1" -eq "$u2" ] && [ "$b1" -gt "$b2" ]; then
    return 0
  fi
  return 1
}

# Funzione per controllare la versione di Java installata
check_java_version() {
  # Cerca una directory con nome jdk8u<version>-b<build> nella cartella $ZUCC_DIR
  local existing_version
  existing_version=$(ls "$ZUCC_DIR" 2>/dev/null | grep -oP 'jdk8u\d+-b\d+' | sort -rV | head -n 1)

  if [ -z "$existing_version" ]; then
    echo "Nessuna versione di Java trovata in $ZUCC_DIR. Procedo all'installazione." | tee -a "$LOG_FILE"
    return 2  # Nessuna versione di Java trovata
  fi

  echo "Versione attuale di Java installata: $existing_version" | tee -a "$LOG_FILE"

  local desired_tag
  desired_tag="$(get_desired_java_tag)"
  echo "Versione Java desiderata (mode=$JAVA_RELEASE_MODE): $desired_tag" | tee -a "$LOG_FILE"

  # Aggiorna solo se la desiderata è più nuova (mai downgrade)
  if version_gt "$desired_tag" "$existing_version"; then
    echo "È disponibile una versione più recente di Java (rispetto a quella installata): $desired_tag" | tee -a "$LOG_FILE"
    return 0  # Nuova versione disponibile
  else
    echo "La versione di Java è aggiornata (o più recente della desiderata)." | tee -a "$LOG_FILE"
    return 1  # Nessun aggiornamento necessario
  fi
}

# Funzione per installare Java
install_java() {
  mkdir -p "$ZUCC_DIR"

  local arch desired_tag build url out
  arch="$(detect_temurin_arch)"

  desired_tag="$(get_desired_java_tag)"
  build="$(format_temurin_build "$desired_tag")"

  url="https://github.com/adoptium/temurin8-binaries/releases/download/${desired_tag}/OpenJDK8U-jdk_${arch}_linux_hotspot_8u${build}.tar.gz"
  out="$TMP_DIR/OpenJDK8U-jdk_${arch}_linux_hotspot_8u${build}.tar.gz"
  JAVA_TGZ="$out"

  echo "Download Java da: $url" | tee -a "$LOG_FILE"

  if ! wget -O "$out" "$url"; then
    echo "Download fallito per $desired_tag. Provo fallback: $JAVA_FALLBACK_TAG" | tee -a "$LOG_FILE"

    desired_tag="$JAVA_FALLBACK_TAG"
    build="$(format_temurin_build "$desired_tag")"
    url="https://github.com/adoptium/temurin8-binaries/releases/download/${desired_tag}/OpenJDK8U-jdk_${arch}_linux_hotspot_8u${build}.tar.gz"
    out="$TMP_DIR/OpenJDK8U-jdk_${arch}_linux_hotspot_8u${build}.tar.gz"
    JAVA_TGZ="$out"

    wget -O "$out" "$url"
    check_error "Errore nel download di OpenJDK (anche in fallback)"
  fi

  tar xvfz "$out" -C "$ZUCC_DIR"
  check_error "Errore nell'estrazione di OpenJDK"

  # Aggiorna symlink in modo idempotente
  ln -sfn "$ZUCC_DIR/$desired_tag" "$ZUCC_DIR/java"
  check_error "Errore nell'installazione di Java (symlink)"
}

# Chiede all'utente quale servizio Tomcat installare
read -p "Quale servizio Tomcat desideri installare? (tomcat_a, tomcat_b, tomcat_c): " TOMCAT_SERVICE
case $TOMCAT_SERVICE in
    tomcat_a)
        TOMCAT_DIR="$ZUCC_DIR/tomcat_a"
        SERVER_FILE="server_a.xml"
        ;;
    tomcat_b)
        TOMCAT_DIR="$ZUCC_DIR/tomcat_b"
        SERVER_FILE="server_b.xml"
        ;;
    tomcat_c)
        TOMCAT_DIR="$ZUCC_DIR/tomcat_c"
        SERVER_FILE="server_c.xml"
        ;;
    *)
        echo "Servizio non valido. Uscita." | tee -a "$LOG_FILE"
        exit 1
        ;;
 esac

LOGROTATE_CONF="$LOGROTATE_DIR/$TOMCAT_SERVICE"

# Aggiornamento del sistema operativo
apt update && apt upgrade -y && apt dist-upgrade -y
check_error "Aggiornamento del sistema operativo fallito"

# Installazione dei pacchetti richiesti
apt install curl net-tools wget gnupg2 sudo rsync apt-transport-https ca-certificates software-properties-common locate wget gnupg2 libncurses5-dev libsasl2-dev libssl-dev jq -y
check_error "Installazione dei pacchetti fallita"

# Aggiunta Repository (compatibilità Debian/Ubuntu)
if command -v add-apt-repository >/dev/null 2>&1; then
  add-apt-repository contrib non-free -y
elif command -v apt-add-repository >/dev/null 2>&1; then
  apt-add-repository contrib non-free -y
else
  echo "ATTENZIONE: add-apt-repository non disponibile, salto aggiunta contrib/non-free" | tee -a "$LOG_FILE"
fi

apt update && apt install fontconfig ttf-mscorefonts-installer -y

# Installazione ZeroTier
curl -s https://install.zerotier.com | sudo bash

# Creazione della directory per Tomcat
mkdir -p "$TOMCAT_DIR"

cd "$ZUCC_DIR"

# Funzione per scaricare le librerie JDBC
download_libs() {
  echo "Scaricamento delle librerie JDBC..." | tee -a "$LOG_FILE"
  mkdir -p "$TOMCAT_DIR/lib"
  wget -O "$TOMCAT_DIR/lib/$PSQL_LIB" "$LIB_URL/$PSQL_LIB"
  check_error "Errore nel download di $PSQL_LIB"
  wget -O "$TOMCAT_DIR/lib/$MSSQL_LIB" "$LIB_URL/$MSSQL_LIB"
  check_error "Errore nel download di $MSSQL_LIB"
}

# Verifica la versione di Java attualmente installata e confronta con quella desiderata
check_java_version
java_status=$?

if [ "$java_status" -eq 2 ]; then
  # Se non trova nessuna versione di Java, installa la versione desiderata
  install_java
elif [ "$java_status" -eq 0 ]; then
  echo "Aggiornamento di Java necessario. Rimuovo la vecchia versione e installo la nuova." | tee -a "$LOG_FILE"

  # Rimuove tutte le vecchie versioni di Java trovate (mai /java symlink)
  existing_java_dirs=$(ls -1 "$ZUCC_DIR" 2>/dev/null | grep -E '^jdk8u[0-9]+-b[0-9]+$' || true)
  if [ -n "$existing_java_dirs" ]; then
    while IFS= read -r d; do
      rm -rf "$ZUCC_DIR/$d"
    done <<< "$existing_java_dirs"
  fi
  rm -f "$ZUCC_DIR/java"

  # Installazione nuova versione di Java
  install_java
fi

# Scarica e installa Tomcat
wget "https://archive.apache.org/dist/tomcat/tomcat-9/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz" -O "$TOMCAT_TGZ"
check_error "Errore nel download di Tomcat"

tar zxvf "$TOMCAT_TGZ" --strip-components=1 -C "$TOMCAT_DIR/"
check_error "Errore nell'estrazione di Tomcat"

# Ripristina le webapps se erano state salvate
if [ -d "$TOMCAT_DIR/webapps_backup" ]; then
  mv "$TOMCAT_DIR/webapps_backup" "$TOMCAT_DIR/webapps"
  echo "Webapps ripristinate." | tee -a "$LOG_FILE"
fi

# Scarica i file di configurazione
cd "$TOMCAT_DIR/conf/"
for file in context.xml tomcat-users.xml catalina.properties; do
  wget -O "$file" "$CONF_URL/$file"
  check_error "Errore nel download di $file"
done

# Scarica il file di configurazione del server corretto
wget -O server.xml "$CONF_URL/$SERVER_FILE"
check_error "Errore nel download di $SERVER_FILE"

# Scarica le librerie JDBC
download_libs

# Imposta proprietario e permessi
chown -R zucchetti:zucchetti "$TOMCAT_DIR"
chmod -R 755 "$TOMCAT_DIR"

# Scarica e abilita il servizio Tomcat selezionato
wget -O "$SYSTEMD_DIR/$TOMCAT_SERVICE.service" "$CONF_URL/$TOMCAT_SERVICE.service"
check_error "Errore nel download del file $TOMCAT_SERVICE.service"

systemctl daemon-reload
systemctl enable "$TOMCAT_SERVICE"
check_error "Errore nell'abilitazione del servizio"

# Avvia il servizio Tomcat
systemctl start "$TOMCAT_SERVICE"
check_error "Errore nell'avvio di Tomcat"

# Configura il logrotate
cat > "$LOGROTATE_CONF" <<EOF
$TOMCAT_DIR/logs/catalina.out {
    rotate 30
    daily
    missingok
    sharedscripts
    compress
    prerotate
        systemctl stop $TOMCAT_SERVICE || true
    endscript
    postrotate
        systemctl start $TOMCAT_SERVICE || true
    endscript
}
EOF

echo "Installazione completata con successo!" | tee -a "$LOG_FILE"
