#!/bin/bash
# Script per l'installazione di Java e Tomcat con file di configurazione per AGO e HR
# Autore: Mattia Tadini
# Nome del file: install_tomcat.sh
# Revisione: 1.00

# Variabili
ZUCC_DIR="/zucchetti/infinity"
API_URL="https://api.github.com/repos/adoptium/temurin8-binaries/releases/latest"
TOMCAT_VERSION="9.0.97"
CONF_URL="https://dl.poloinformatico.it/assistenza/Scripts/conf"
LIB_URL="https://dl.poloinformatico.it/assistenza/Scripts/lib"
LOGROTATE_DIR="/etc/logrotate.d"
SYSTEMD_DIR="/etc/systemd/system"
TMP_DIR="/tmp"  # Directory temporanea
PSQL_LIB="postgresql-42.7.3.jar"
MSSQL_LIB="mssql-jdbc-12.8.1.jre8.jar"
LOG_FILE="/root/tomcat_installation.log"  # Percorso del file di log

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
  
  # Rimuovi i file scaricati e non necessari
  [ -f "$TMP_DIR/OpenJDK8-${formatted_version}.tar.gz" ] && rm -f "$TMP_DIR/OpenJDK8-${formatted_version}.tar.gz"
  [ -f "$TMP_DIR/apache-tomcat-$TOMCAT_VERSION.tar.gz" ] && rm -f "$TMP_DIR/apache-tomcat-$TOMCAT_VERSION.tar.gz"
  
  echo "Pulizia completata." | tee -a "$LOG_FILE"
}


# Imposta trap per gestire i segnali di interruzione e terminazione
trap cleanup INT TERM EXIT  # 'EXIT' per eseguire la pulizia alla fine


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


# Creazione della directory per Tomcat

mkdir -p "$TOMCAT_DIR"

cd "$ZUCC_DIR"
# Funzione per scaricare le librerie JDBC
download_libs() {
  echo "Scaricamento delle librerie JDBC..." | tee -a "$LOG_FILE"
  wget -O "$TOMCAT_DIR/lib/$PSQL_LIB" "$LIB_URL/$PSQL_LIB"
  check_error "Errore nel download di $PSQL_LIB"
  wget -O "$TOMCAT_DIR/lib/$MSSQL_LIB" "$LIB_URL/$MSSQL_LIB"
  check_error "Errore nel download di $MSSQL_LIB"
}

# Scarica e installa Tomcat
wget https://archive.apache.org/dist/tomcat/tomcat-9/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz -P "$TMP_DIR/"
check_error "Errore nel download di Tomcat"
tar zxvf "$TMP_DIR/apache-tomcat-$TOMCAT_VERSION.tar.gz" --strip-components=1 -C "$TOMCAT_DIR/"
check_error "Errore nell'estrazione di Tomcat"

# Ripristina le webapps se erano state salvate
if [ -d "$TOMCAT_DIR/webapps_backup" ]; then
  mv "$TOMCAT_DIR/webapps_backup" "$TOMCAT_DIR/webapps"
  echo "Webapps ripristinate." | tee -a "$LOG_FILE"
fi

# Scarica i file di configurazione
cd "$TOMCAT_DIR/conf/"
for file in context.xml tomcat-users.xml catalina.properties; do
  wget -O $file "$CONF_URL/$file"
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
systemctl enable $TOMCAT_SERVICE
check_error "Errore nell'abilitazione del servizio"

# Avvia il servizio Tomcat
systemctl start $TOMCAT_SERVICE
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
