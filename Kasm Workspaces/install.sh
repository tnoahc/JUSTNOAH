#!/usr/bin/env bash
SCRIPT_PATH="$( cd "$(dirname "$0")" ; pwd -P )"

set -e

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

TIMESTAMP=$(date +%s)
LOGFILE="./kasm_install_${TIMESTAMP}.log"
function notify_err() {
    echo "An error has occurred please review the log at ${LOGFILE}"
}
function cleanup_log() {
    rm -f ${LOGFILE}
}
trap notify_err ERR
exec &> >(tee ${LOGFILE})

KASM_VERSION="1.16.1"
KASM_INSTALL_BASE="/opt/kasm/${KASM_VERSION}"
NETWORK_PLUGIN_BRANCH="release/1.1"
DO_DATABASE_INIT='true'
VERBOSE='false'
ACCEPT_EULA='false'
API_INSTALL='false'
PUBLIC_HOSTNAME='false'
DEFAULT_PROXY_LISTENING_PORT='443'
DEFAULT_RDP_LISTENING_PORT='3389'
DATABASE_HOSTNAME='false'
DATABASE_PORT=5432
DATABASE_SSL='true'
DATABASE_USER='kasmapp'
DATABASE_NAME='kasm'
REDIS_HOSTNAME='false'
MANAGER_HOSTNAME='false'
API_SERVER_HOSTNAME='false'
SERVER_ZONE='default'
SERVER_ID='false'
PROVIDER='false'
bflag=''
files=''
START_SERVICES='true'
DEFAULT_ADMIN_PASSWORD="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13 )"
DEFAULT_USER_PASSWORD="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13 )"
DEFAULT_DATABASE_PASSWORD="false"
DEFAULT_REDIS_PASSWORD="false"
DEFAULT_MANAGER_TOKEN="false"
DEFAULT_RDP_GATEWAY_CONNECTION_PROXY_ID="$(cat /proc/sys/kernel/random/uuid)"
DEFAULT_RDP_HTTPS_GATEWAY_CONNECTION_PROXY_ID="$(cat /proc/sys/kernel/random/uuid)"
GUAC_CLUSTER_SIZE=$(nproc)
ROLE="all"
OFFLINE_INSTALL="false"
PULL_IMAGES="false"
SEED_IMAGES="false"
DATABASE_MASTER_USER='postgres'
SWAP_CHECK="true"
SWAP_CREATE="false"
ACTIVATION_FAILED="false"
USE_ROLLING="false"
CHECK_DISK="true"
CHECK_PORTS="true"
TEST_CONNECT="true"
ENABLE_LOSSLESS="false"
REGISTRATION_TOKEN="false"
DEFAULT_REGISTRY_URL="false"
SKIP_V4L2LOOPBACK="false"
SKIP_CUSTOM_RCLONE="false"
SKIP_DOCKER_RESTART_FLAG_FILE="/flags/NO_DOCKER_RESTART"
ROLLING_NGINX_TAG="1.25"
FORCE_DEPS_INSTALL="false"
SKIP_EGRESS="false"
ARGS=("$@")

SCRIPT_PATH="$( cd "$(dirname "$0")" ; pwd -P )"
KASM_RELEASE="$(realpath $SCRIPT_PATH)"
EULA_PATH=${KASM_RELEASE}/licenses/LICENSE.txt
ARCH=$(uname -m | sed 's/aarch64/arm64/g' | sed 's/x86_64/amd64/g')
DISK_SPACE=50000000000

function is_port_ok (){
    re='^[0-9]+$'
    if ! [[ ${DEFAULT_PROXY_LISTENING_PORT} =~ $re ]] ; then
       echo "error: DEFAULT_PROXY_LISTENING_PORT, (${DEFAULT_PROXY_LISTENING_PORT}) is not an integer" >&2
       cleanup_log
       exit 1
    fi

    if ((${DEFAULT_PROXY_LISTENING_PORT} <= 0 || ${DEFAULT_PROXY_LISTENING_PORT} > 65535 )); then
      echo "error: DEFAULT_PROXY_LISTENING_PORT, (${DEFAULT_PROXY_LISTENING_PORT}) is in the valid port range"
      cleanup_log
      exit 1
    fi

    echo "Checking if DEFAULT_PROXY_LISTENING_PORT (${DEFAULT_PROXY_LISTENING_PORT}) is free"
    if lsof -Pi :${DEFAULT_PROXY_LISTENING_PORT} -sTCP:LISTEN  ; then
        echo "Port (${DEFAULT_PROXY_LISTENING_PORT}) is in use. Installation cannot continue."
	cleanup_log
        exit -1
    else
        echo "Port (${DEFAULT_PROXY_LISTENING_PORT}) is not in use."
    fi

    if [ "${ROLE}" == "all" ] || [ "${ROLE}" == "guac" ];
    then
      re='^[0-9]+$'
      if ! [[ ${DEFAULT_RDP_LISTENING_PORT} =~ $re ]] ; then
        echo "error: DEFAULT_RDP_LISTENING_PORT, (${DEFAULT_RDP_LISTENING_PORT}) is not an integer" >&2
        cleanup_log
        exit 1
      fi

      if ((${DEFAULT_RDP_LISTENING_PORT} <= 0 || ${DEFAULT_RDP_LISTENING_PORT} > 65535 )); then
        echo "error: DEFAULT_RDP_LISTENING_PORT, (${DEFAULT_RDP_LISTENING_PORT}) is in the valid port range"
        cleanup_log
        exit 1
      fi

      echo "Checking if DEFAULT_RDP_LISTENING_PORT (${DEFAULT_RDP_LISTENING_PORT}) is free"
      if lsof -Pi :${DEFAULT_RDP_LISTENING_PORT} -sTCP:LISTEN  ; then
        echo "Port (${DEFAULT_RDP_LISTENING_PORT}) is in use. Installation cannot continue."
        cleanup_log
        exit -1
      else
        echo "Port (${DEFAULT_RDP_LISTENING_PORT}) is not in use."
      fi
    fi
}

function set_listening_port(){

    if [ "${DEFAULT_PROXY_LISTENING_PORT}" != "443" ] ;
    then
        echo "Updating configurations with custom DEFAULT_PROXY_LISTENING_PORT (${DEFAULT_PROXY_LISTENING_PORT})"

        FILE=${KASM_INSTALL_BASE}/conf/app/agent.app.config.yaml
        if [ -f "${FILE}" ]; then
            sed -i "s/public_port.*/public_port: ${DEFAULT_PROXY_LISTENING_PORT}/g" ${FILE}
        fi

        FILE=${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
        if [ -f "${FILE}" ]; then
            ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '.api.port = '${DEFAULT_PROXY_LISTENING_PORT}'' ${FILE}
        fi

        FILE=${KASM_INSTALL_BASE}/conf/nginx/orchestrator.conf
        if [ -f "${FILE}" ]; then
            sed -i "s/listen.*/listen ${DEFAULT_PROXY_LISTENING_PORT} ssl ;/g" ${FILE}
        fi

        grep -rl "443:443" ${KASM_INSTALL_BASE}/docker/ | xargs -I '{}' sed -i "s/- \"443:443\"/- \"${DEFAULT_PROXY_LISTENING_PORT}:${DEFAULT_PROXY_LISTENING_PORT}\"/g" {}

        FILE=${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
        if [ -f "${FILE}" ]; then
	    ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '(.zones.[] | select(.zone_name=="'${SERVER_ZONE}'")) .proxy_port = '${DEFAULT_PROXY_LISTENING_PORT}'' ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
	    ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '(.settings.[] | select(.name=="log_port") | select(.category == "logging")) .value = "'${DEFAULT_PROXY_LISTENING_PORT}'"' ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
        fi

    fi

}

function get_public_hostname (){

    if [ "${PUBLIC_HOSTNAME}" == "false" ] ;
    then
       _PUBLIC_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')
        read -p "Enter the network facing IP or hostname [${_PUBLIC_IP}]: " public_hostname_input
        if [ "${public_hostname_input}" == "" ] ;
        then
            PUBLIC_HOSTNAME=${_PUBLIC_IP}
        else
            PUBLIC_HOSTNAME=${public_hostname_input}
        fi
        echo "Using ip/hostname: [${PUBLIC_HOSTNAME}]"
    fi

}

function get_database_hostname (){

    if [ "${DATABASE_HOSTNAME}" == "false" ] ;
    then
        database_hostname_input=
        while [[ $database_hostname_input = "" ]]; do
            read -p "Enter the Kasm Database's hostname or IP : " database_hostname_input
        done

        DATABASE_HOSTNAME=${database_hostname_input}
        echo "Using database ip/hostname: [${DATABASE_HOSTNAME}]"
    fi

}

function set_random_database_password (){
    # Honor the default if its passed in
    if [ "${DEFAULT_DATABASE_PASSWORD}" == "false" ] ;
    then
        DEFAULT_DATABASE_PASSWORD="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20 )"
    fi

}

function set_random_redis_password (){
    # Honor the default if its passed in
    if [ "${DEFAULT_REDIS_PASSWORD}" == "false" ] ;
    then
        DEFAULT_REDIS_PASSWORD="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20 )"
    fi

}

function set_random_manager_token (){
    # Honor the default if its passed in
    if [ "${DEFAULT_MANAGER_TOKEN}" == "false" ] ;
    then
        DEFAULT_MANAGER_TOKEN="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20 )"
    fi

}

function set_random_registration_token(){
    # Honor the default if its passed in
    if [ "${REGISTRATION_TOKEN}" == "false" ] ;
    then
        REGISTRATION_TOKEN="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20 )"
    fi

}

function get_database_password (){

    if [ "${DEFAULT_DATABASE_PASSWORD}" == "false" ] ;
    then
        database_password_input=
        while [[ $database_password_input = "" ]]; do
            read -p "Enter the Kasm Database's password : " database_password_input
        done

        DEFAULT_DATABASE_PASSWORD=${database_password_input}
        echo "Using database password: [${DEFAULT_DATABASE_PASSWORD}]"
    fi

}

function get_redis_password (){

    if [ "${DEFAULT_REDIS_PASSWORD}" == "false" ] ;
    then
        redis_password_input=
        while [[ $redis_password_input = "" ]]; do
            read -p "Enter the Kasm Redis'password : " redis_password_input
        done

        DEFAULT_REDIS_PASSWORD=${redis_password_input}
        echo "Using redis password: [${DEFAULT_REDIS_PASSWORD}]"
    fi
}

function get_manager_hostname (){

    if [ "${MANAGER_HOSTNAME}" == "false" ] ;
    then
        manager_hostname_input=
        while [[ $manager_hostname_input = "" ]]; do
            read -p "Enter the Kasm manager's hostname or IP : " manager_hostname_input
        done

        MANAGER_HOSTNAME=${manager_hostname_input}
        echo "Using manager ip/hostname: [${MANAGER_HOSTNAME}]"
    fi

}

function get_manager_token (){

    if [ "${DEFAULT_MANAGER_TOKEN}" == "false" ] ;
    then
        manager_token_input=
        while [[ $manager_token_input = "" ]]; do
            read -p "Enter the Kasm manager token : " manager_token_input
        done

        DEFAULT_MANAGER_TOKEN=${manager_token_input}
        echo "Using manager token: [${DEFAULT_MANAGER_TOKEN}]"
    fi

}

function set_public_hostname() {
    sed -i "s/public_hostname.*/public_hostname: ${PUBLIC_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/agent.app.config.yaml
}

function set_default_user_passwords() {
    # Generate a salt and hash for the desired passwords. Update the yaml
    ADMIN_SALT=$(cat /proc/sys/kernel/random/uuid)
    ADMIN_HASH=$(printf ${DEFAULT_ADMIN_PASSWORD}${ADMIN_SALT} | sha256sum | cut -c-64)
    USER_SALT=$(cat /proc/sys/kernel/random/uuid)
    USER_HASH=$(printf ${DEFAULT_USER_PASSWORD}${USER_SALT} | sha256sum | cut -c-64)

  	${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i  '(.users.[] | select(.username=="admin@kasm.local") | .salt) = "'${ADMIN_SALT}'"'  ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
  	${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i  '(.users.[] | select(.username=="admin@kasm.local") | .pw_hash) = "'${ADMIN_HASH}'"'  ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml

  	${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i  '(.users.[] | select(.username=="user@kasm.local") | .salt) = "'${USER_SALT}'"'  ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
  	${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i  '(.users.[] | select(.username=="user@kasm.local") | .pw_hash) = "'${USER_HASH}'"'  ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml

}

function set_database_hostname() {
    if [ "${DATABASE_HOSTNAME}" != "false" ] ;
        then
        sed -i "s/host: db/host: ${DATABASE_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
    fi
}

function set_database_port() {
    sed -i "s/port: 5432/port: ${DATABASE_PORT}/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
}

function set_database_user() {
    ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '.database.username = "'${DATABASE_USER}'"' ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
    if [ "${ROLE}" == "all" ] || [ "${ROLE}" == "db" ];
    then
        ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '.services.db.environment.POSTGRES_USER = "'${DATABASE_USER}'"' ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
        sed -i "s/--username=kasmapp/--username=${DATABASE_USER}/g" ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    fi
}

function set_database_name() {
    ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '.database.name = "'${DATABASE_NAME}'"' ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
    if [ "${ROLE}" == "all" ] || [ "${ROLE}" == "db" ];
    then
        ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '.services.db.environment.POSTGRES_DB = "'${DATABASE_NAME}'"' ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    fi
}

function set_database_password() {
    sed -i "s/ password:.*/ password: \"${DEFAULT_DATABASE_PASSWORD}\"/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
    grep -rl POSTGRES_PASSWORD ${KASM_INSTALL_BASE}/docker/ | xargs -I '{}' sed -i "s/POSTGRES_PASSWORD:.*/POSTGRES_PASSWORD: \"${DEFAULT_DATABASE_PASSWORD}\"/g" {}
}

function set_database_ssl() {
    if [ "${DATABASE_SSL}" == "false" ] ; then
        sed -i 's/ssl: true/ssl: false/' ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
        sed -i 's# -c ssl=on -c ssl_cert_file=/etc/ssl/certs/db_server.crt -c ssl_key_file=/etc/ssl/certs/db_server.key##' ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    fi
    # if local db then generate certs
    if [ "${DATABASE_HOSTNAME}" == "false" ] ; then
        # On an interrupted install its possible for db_server.key and db_server.crt to not be created successfully
        # and when the containers start they will end up being mounted as a directory.
        # We want to clean them up if they are directories.
        if [[ -d "${KASM_INSTALL_BASE}/certs/db_server.key" ]]; then
            rmdir "${KASM_INSTALL_BASE}/certs/db_server.key"
        fi
        if [[ -d "${KASM_INSTALL_BASE}/certs/db_server.crt" ]]; then
            rmdir "${KASM_INSTALL_BASE}/certs/db_server.crt"
        fi
        sudo openssl req -x509 -nodes -days 1825 -newkey rsa:2048 -keyout ${KASM_INSTALL_BASE}/certs/db_server.key -out ${KASM_INSTALL_BASE}/certs/db_server.crt -subj "/C=US/ST=VA/L=None/O=None/OU=DoFu/CN=$(hostname)/emailAddress=none@none.none" 2> /dev/null
        # If there is no user with UID of 70 and no kasm_db user, we create kasm_db with UID of 70
        if ! id -nu 70 > /dev/null 2>&1; then
            if ! grep -q '^kasm_db:' /etc/passwd ; then
                sudo useradd -u 70 kasm_db &> /dev/null
            fi
        fi
        sudo chown 70:70 ${KASM_INSTALL_BASE}/certs/db_server.key
        sudo chown 70:70 ${KASM_INSTALL_BASE}/certs/db_server.crt
        sudo chmod 0600 ${KASM_INSTALL_BASE}/certs/db_server.crt
        sudo chmod 0600 ${KASM_INSTALL_BASE}/certs/db_server.key
    fi
}

function set_redis_hostname() {
	if [ "${REDIS_HOSTNAME}" != "false" ] ;
	then
        sed -i "s/host: kasm_redis/host: ${REDIS_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
    elif [ "${DATABASE_HOSTNAME}" != "false" ] ;
	then
        sed -i "s/host: kasm_redis/host: ${DATABASE_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
    fi
}

function set_redis_password() {
    sed -i "s/redis_password:.*/redis_password: \"${DEFAULT_REDIS_PASSWORD}\"/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
    grep -rl POSTGRES_PASSWORD ${KASM_INSTALL_BASE}/docker/ | xargs -I '{}' sed -i "s/REDIS_PASSWORD:.*/REDIS_PASSWORD: \"${DEFAULT_REDIS_PASSWORD}\"/g" {}
}

function set_manager_hostname() {
    sed -i "s/hostnames: \['proxy.*/hostnames: \['${MANAGER_HOSTNAME}'\]/g" ${KASM_INSTALL_BASE}/conf/app/agent.app.config.yaml
}

function set_manager_token() {
    sed -i "s/ token:.*/ token: \"${DEFAULT_MANAGER_TOKEN}\"/g" ${KASM_INSTALL_BASE}/conf/app/agent.app.config.yaml
    FILE=${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    if [ -f "${FILE}" ]; then
      ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i   '(.settings.[] | select(.name=="token") | select(.category == "manager")) .value = "'${DEFAULT_MANAGER_TOKEN}'"'   ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    fi
}

function set_registration_token() {
    FILE=${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    if [ -f "${FILE}" ]; then
      ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i   '(.settings.[] | select(.name=="registration_token") | select(.category == "auth")) .value = "'${REGISTRATION_TOKEN}'"'   ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    fi
}


function configure_guac_component() {
    if [ "${ROLE}" == "guac" ] ;
    then
        if [ "${API_SERVER_HOSTNAME}" != "false" ] && [ "${PUBLIC_HOSTNAME}" != "false" ] && [ "${REGISTRATION_TOKEN}" != "false" ] ;
        then
            FILE=${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
            if [ -f "${FILE}" ] ;
            then
                sed -i "s/APIHOSTNAME/${API_SERVER_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
                sed -i "s/ZONE/${SERVER_ZONE}/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
                sed -i "s/SERVER_ADDRESS/${PUBLIC_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
                sed -i "s/SERVER_PORT/${DEFAULT_PROXY_LISTENING_PORT}/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
                sed -i "s/REGISTRATION_TOKEN/${REGISTRATION_TOKEN}/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
                echo "Successfully updated kasm_guac.app.config.yaml"
            else
                echo "Failed to find kasmguac.app.config.yaml in the local deployment path."
                exit 1
            fi
        else
            echo "API Hostname (-n|--api-hostname) required for multi server installation."
            echo "Public Hostname (-p|--public-hostname) of this server is required for a multi-server installation."
            echo "A registration token (-k|--registration-token) is required for installation of this component."
            cleanup_log
            exit 1
        fi
    elif [ "${ROLE}" == "all" ] ;
    then
        sed -i "s/APIHOSTNAME/proxy/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
        sed -i "s/SERVER_ADDRESS/proxy/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
        sed -i "s/SERVER_PORT/${DEFAULT_PROXY_LISTENING_PORT}/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
        sed -i "s/ZONE/${SERVER_ZONE}/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
        sed -i "s/REGISTRATION_TOKEN/${REGISTRATION_TOKEN}/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
    fi
}

function configure_rdp_gateway_component() {
    if [ "${ROLE}" == "guac" ] ;
    then
        if [ "${API_SERVER_HOSTNAME}" != "false" ] && [ "${PUBLIC_HOSTNAME}" != "false" ] && [ "${REGISTRATION_TOKEN}" != "false" ] ;
        then
            FILE=${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
            if [ -f "${FILE}" ] ;
            then
                sed -i "s/00000000-0000-0000-0000-000000000000/${DEFAULT_RDP_GATEWAY_CONNECTION_PROXY_ID}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
                sed -i "s/APIHOSTNAME/${API_SERVER_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
                sed -i "s/ZONE/${SERVER_ZONE}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
                sed -i "s/SERVER_ADDRESS/${PUBLIC_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
                sed -i "s/SERVER_PORT/${DEFAULT_PROXY_LISTENING_PORT}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
                sed -i "s/REGISTRATION_TOKEN/${REGISTRATION_TOKEN}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
                echo "Successfully updated passthrough.app.config.yaml"
            else
                echo "Failed to find passthrough.app.config.yaml in the local deployment path."
                exit 1
            fi

            FILE=${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
            if [ -f "${FILE}" ] ;
            then
                sed -i "s/00000000-0000-0000-0000-000000000000/${DEFAULT_RDP_HTTPS_GATEWAY_CONNECTION_PROXY_ID}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
                sed -i "s/APIHOSTNAME/${API_SERVER_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
                sed -i "s/ZONE/${SERVER_ZONE}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
                sed -i "s/SERVER_ADDRESS/${PUBLIC_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
                sed -i "s/SERVER_PORT/${DEFAULT_PROXY_LISTENING_PORT}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
                sed -i "s/REGISTRATION_TOKEN/${REGISTRATION_TOKEN}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
                echo "Successfully updated rdp_https_gateway.app.config.yaml"
            else
                echo "Failed to find rdp_https_gateway.app.config.yaml in the local deployment path."
                exit 1
            fi
        else
            echo "API Hostname (-n|--api-hostname) required for multi server installation."
            echo "Public Hostname (-p|--public-hostname) of this server is required for a multi-server installation."
            echo "A registration token (-k|--registration-token) is required for installation of this component."
            cleanup_log
            exit 1
        fi
    elif [ "${ROLE}" == "all" ] ;
    then
        sed -i "s/00000000-0000-0000-0000-000000000000/${DEFAULT_RDP_GATEWAY_CONNECTION_PROXY_ID}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
        sed -i "s/APIHOSTNAME/proxy/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
        sed -i "s/SERVER_ADDRESS/proxy/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
        sed -i "s/SERVER_PORT/${DEFAULT_PROXY_LISTENING_PORT}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
        sed -i "s/ZONE/${SERVER_ZONE}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
        sed -i "s/REGISTRATION_TOKEN/${REGISTRATION_TOKEN}/g" ${KASM_INSTALL_BASE}/conf/app/passthrough.app.config.yaml
        echo "Successfully updated passthrough.app.config.yaml"
        sed -i "s/00000000-0000-0000-0000-000000000000/${DEFAULT_RDP_HTTPS_GATEWAY_CONNECTION_PROXY_ID}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
        sed -i "s/APIHOSTNAME/proxy/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
        sed -i "s/SERVER_ADDRESS/proxy/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
        sed -i "s/SERVER_PORT/${DEFAULT_PROXY_LISTENING_PORT}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
        sed -i "s/ZONE/${SERVER_ZONE}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
        sed -i "s/REGISTRATION_TOKEN/${REGISTRATION_TOKEN}/g" ${KASM_INSTALL_BASE}/conf/app/rdp_https_gateway.app.config.yaml
        echo "Successfully updated rdp_https_gateway.app.config.yaml"
    fi
}

function set_guac_cluster_size() {
    if [[ "$GUAC_CLUSTER_SIZE" -eq 0 ]]; then
        GUAC_CLUSTER_SIZE=$(nproc)
    fi

    sed -i "s/CLUSTER_SIZE/${GUAC_CLUSTER_SIZE}/g" ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml

    guac_nginx_config="upstream kasm_guac_backend {\n"

    for ((i=1; i<=$GUAC_CLUSTER_SIZE; i++)); do
        guac_nginx_config+="  server kasm_guac:$((3000 + $i));\n"
    done

    guac_nginx_config+="}"

    echo -e $guac_nginx_config > ${KASM_INSTALL_BASE}/conf/nginx/upstream_guac.conf
}

function set_upstream_auth() {
    FILE=${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    if [ -f "${FILE}" ]; then
      ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '(.zones.[] | select(.zone_name=="'${SERVER_ZONE}'")) .upstream_auth_address = "proxy"' ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    fi
}

function set_agent_server_id() {
    if [ "${SERVER_ID}" == "false" ] ;
    then
        SERVER_ID=$(cat /proc/sys/kernel/random/uuid)
    fi
    sed -i "s/server_id.*/server_id: ${SERVER_ID}/g" ${KASM_INSTALL_BASE}/conf/app/agent.app.config.yaml
    sed -i "s/00000000-0000-0000-0000-000000000000/${SERVER_ID}/g" ${KASM_INSTALL_BASE}/conf/database/seed_data/default_agents.yaml 
}

function set_server_zone() {
    ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '(.server.zone_name) = "'${SERVER_ZONE}'"' ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
    ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '(.zones.[0]) .zone_name = "'${SERVER_ZONE}'"' ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
}

function set_api_server_id() {
    API_SERVER_ID=$(cat /proc/sys/kernel/random/uuid)
    sed -i "s/server_id.*/server_id: ${API_SERVER_ID}/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
}

function set_manager_id() {
    MANAGER_ID=$(cat /proc/sys/kernel/random/uuid)
    sed -i "s/manager_id.*/manager_id: ${MANAGER_ID}/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
}

function set_share_id() {
    SHARE_ID=$(cat /proc/sys/kernel/random/uuid)
    sed -i "s/share_id.*/share_id: ${SHARE_ID}/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
}

function set_api_hostname() {
    if [ "${API_SERVER_HOSTNAME}" == "false" ] ;
    then
        API_SERVER_HOSTNAME=$(hostname)
    fi
    sed -i "s/server_hostname.*/server_hostname: ${API_SERVER_HOSTNAME}/g" ${KASM_INSTALL_BASE}/conf/app/api.app.config.yaml
}

function set_provider() {
    if [ "${PROVIDER}" != "false" ] ;
    then
        sed -i "s/provider.*/provider: ${PROVIDER}/g" ${KASM_INSTALL_BASE}/conf/app/agent.app.config.yaml
    fi
}

function copy_db_config() {
    cp ${KASM_RELEASE}/conf/database/pg_hba.conf ${KASM_INSTALL_BASE}/conf/database/
    cp ${KASM_RELEASE}/conf/database/postgresql.conf ${KASM_INSTALL_BASE}/conf/database/
    chmod 600 ${KASM_INSTALL_BASE}/conf/database/pg_hba.conf ${KASM_INSTALL_BASE}/conf/database/postgresql.conf

    mkdir -p ${KASM_INSTALL_BASE}/log/postgres/
}

function base_install() {
    chmod +x ${KASM_INSTALL_BASE}/bin/*
    chmod +x ${KASM_INSTALL_BASE}/bin/utils/*
    chown kasm:kasm -R ${KASM_INSTALL_BASE}
    if [ -f ${KASM_INSTALL_BASE}/conf/database/pg_hba.conf ]; then 
    	chown 70:70 ${KASM_INSTALL_BASE}/conf/database/pg_hba.conf
    fi
    if [ -f ${KASM_INSTALL_BASE}/conf/database/postgresql.conf ]; then 
    	chown 70:70 ${KASM_INSTALL_BASE}/conf/database/postgresql.conf
    fi
    if [ -d ${KASM_INSTALL_BASE}/log/postgres/ ]; then 
    	chown -R 70:70 ${KASM_INSTALL_BASE}/log/postgres/
    fi
    if [ -f ${KASM_INSTALL_BASE}/certs/db_server.key ]; then 
    	chown 70:70 ${KASM_INSTALL_BASE}/certs/db_server.key
    fi
    if [ -f ${KASM_INSTALL_BASE}/certs/db_server.crt ]; then 
    	chown 70:70 ${KASM_INSTALL_BASE}/certs/db_server.crt
    fi
    if [ -d "${KASM_RELEASE}/www/" ]; then
      cp -r ${KASM_RELEASE}/www/ ${KASM_INSTALL_BASE}/
      chmod -R 555 ${KASM_INSTALL_BASE}/www
    fi

    if [ "${DO_DATABASE_INIT}" == "true" ] ;
    then
        echo "Initializing Database"
        set_default_user_passwords
        ${KASM_INSTALL_BASE}/bin/utils/db_init -i -s "${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml" -q "${DATABASE_HOSTNAME}" -T "${DATABASE_PORT}" -Q "${DEFAULT_DATABASE_PASSWORD}" -t "${DATABASE_SSL}" -g "${DATABASE_MASTER_USER}" -G "${DATABASE_MASTER_PASSWORD}" -c "${DATABASE_USER}" -j "${DATABASE_NAME}"

        if [ "${SEED_IMAGES}" == "true" ]  ;
        then
            # If the user passes the path to the workspace images offline tarfile
            # we want to use the seedfile in there to seed the default images.
            if [ ! -z "${WORKSPACE_IMAGE_TARFILE}" ]; then
                tar xf "${WORKSPACE_IMAGE_TARFILE}" -C ${KASM_RELEASE} workspace_images/default_images_${ARCH}.yaml
                ${KASM_INSTALL_BASE}/bin/utils/db_init -s ${KASM_RELEASE}/workspace_images/default_images_${ARCH}.yaml -q ${DATABASE_HOSTNAME} -T ${DATABASE_PORT} -Q ${DEFAULT_DATABASE_PASSWORD} -t ${DATABASE_SSL}
            else
                ${KASM_INSTALL_BASE}/bin/utils/db_init -s ${KASM_INSTALL_BASE}/conf/database/seed_data/default_images_${ARCH}.yaml -q ${DATABASE_HOSTNAME} -T ${DATABASE_PORT} -Q ${DEFAULT_DATABASE_PASSWORD} -t ${DATABASE_SSL}
            fi
        else
            echo "Not seeding default Workspaces Images."
        fi

        if [ "${ROLE}" == "all" ] ;
        then
            ${KASM_INSTALL_BASE}/bin/utils/db_init -s ${KASM_INSTALL_BASE}/conf/database/seed_data/default_agents.yaml -q ${DATABASE_HOSTNAME} -T ${DATABASE_PORT} -Q ${DEFAULT_DATABASE_PASSWORD} -t ${DATABASE_SSL}
        fi

        rm ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    fi
}

function pull_images() {
    if [ ${OFFLINE_INSTALL} == "false" ] ; then
        echo "Pulling default Workspaces Images"
        sudo docker exec kasm_db psql -U ${DATABASE_USER} -d ${DATABASE_NAME} -t  -c "SELECT name FROM images WHERE enabled = true;" | xargs -L 1 sudo  docker pull
    fi
}

function copy_manager_configs() {
    cp -r ${KASM_RELEASE}/conf/nginx/upstream_manager.conf  ${KASM_INSTALL_BASE}/conf/nginx/upstream_manager.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/manager_api.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/manager_api.conf
    cp -r ${KASM_RELEASE}/conf/nginx/upstream_api.conf ${KASM_INSTALL_BASE}/conf/nginx/upstream_api.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/client_api.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/client_api.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/website.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/website.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/upstream_proxy.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/upstream_proxy.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/share_api.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/share_api.conf
    cp -r ${KASM_RELEASE}/conf/nginx/upstream_share.conf ${KASM_INSTALL_BASE}/conf/nginx/upstream_share.conf
}

function copy_api_configs() {
    cp -r ${KASM_RELEASE}/conf/nginx/upstream_api.conf ${KASM_INSTALL_BASE}/conf/nginx/upstream_api.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/admin_api.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/admin_api.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/client_api.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/client_api.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/subscription_api.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/subscription_api.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/upstream_proxy.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/upstream_proxy.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/website.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/website.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/share_api.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/share_api.conf
    cp -r ${KASM_RELEASE}/conf/nginx/upstream_share.conf ${KASM_INSTALL_BASE}/conf/nginx/upstream_share.conf
}


function copy_guac_configs() {
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/kasmguac.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/kasmguac.conf
    cp -r ${KASM_RELEASE}/conf/app/kasmguac.app.config.yaml ${KASM_INSTALL_BASE}/conf/app/kasmguac.app.config.yaml
}

function copy_rdpproxy_configs() {
  if [ "${ROLE}" == "guac" ] ;
  then
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/rdp_https_gateway_guac.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/rdp_https_gateway.conf
    cp -r ${KASM_RELEASE}/conf/nginx/upstream_rdp_https_gateway.conf ${KASM_INSTALL_BASE}/conf/nginx/upstream_rdp_https_gateway.conf
    if [ "${ARCH}" != 'arm64' ] ;
    then
        cp -r ${KASM_RELEASE}/conf/nginx/upstream_rdp_gateway.conf ${KASM_INSTALL_BASE}/conf/nginx/upstream_rdp_gateway.conf
        cp -r ${KASM_RELEASE}/conf/nginx/services.d/rdp_gateway.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/rdp_gateway.conf
        cp -r ${KASM_RELEASE}/conf/app/rdpproxy.ini ${KASM_INSTALL_BASE}/conf/app/rdpproxy.ini
    fi
    cp -r ${KASM_RELEASE}/conf/app/rdpgw.yaml ${KASM_INSTALL_BASE}/conf/app/rdpgw.yaml
  elif [ "${ROLE}" == "app" ] ;
  then
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/rdp_https_gateway_webapp.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/rdp_https_gateway.conf
  elif [ "${ROLE}" == "proxy" ] ;
  then
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/rdp_https_gateway_webapp.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/rdp_https_gateway.conf
    sed -i "s/kasm_api/${API_SERVER_HOSTNAME//./\\.}/g" ${KASM_INSTALL_BASE}/conf/nginx/services.d/rdp_https_gateway.conf
    sed -i '0,/http/ s/http/https/' ${KASM_INSTALL_BASE}/conf/nginx/services.d/rdp_https_gateway.conf
  elif [ "${ROLE}" == "all" ] ;
  then
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/rdp_https_gateway_webapp.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/rdp_https_gateway.conf
    if [ "${ARCH}" != 'arm64' ] ;
    then
        cp -r ${KASM_RELEASE}/conf/nginx/upstream_rdp_gateway.conf ${KASM_INSTALL_BASE}/conf/nginx/upstream_rdp_gateway.conf
        cp -r ${KASM_RELEASE}/conf/nginx/services.d/rdp_gateway.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/rdp_gateway.conf
        cp -r ${KASM_RELEASE}/conf/app/rdpproxy.ini ${KASM_INSTALL_BASE}/conf/app/rdpproxy.ini
    fi
    cp -r ${KASM_RELEASE}/conf/app/rdpgw.yaml ${KASM_INSTALL_BASE}/conf/app/rdpgw.yaml
  fi
}

function copy_proxy_configs() {
    if [ "${API_SERVER_HOSTNAME}" == "false" ]; then
        echo "FATAL: option -n|--api-hostname is required for the proxy role"
        cleanup_log
        exit 1
    fi
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/upstream_proxy.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/upstream_proxy.conf
    sed -i '0,/http/ s/http/https/' ${KASM_INSTALL_BASE}/conf/nginx/services.d/upstream_proxy.conf
    sed -i "s/kasm_api/${API_SERVER_HOSTNAME//./\\.}/g" ${KASM_INSTALL_BASE}/conf/nginx/services.d/upstream_proxy.conf
    sed -i "\#location /desktop/ {#a if (\$request_method = 'OPTIONS') {\n                    add_header 'Access-Control-Allow-Origin' 'https://${API_SERVER_HOSTNAME//./\\.}' always;\n                    add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';\n                    add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';\n                    add_header 'Access-Control-Allow-Credentials' 'true';\n                    \n                    return 204;\n                } " ${KASM_INSTALL_BASE}/conf/nginx/services.d/upstream_proxy.conf
    sed -i 's/^if/                if/g' ${KASM_INSTALL_BASE}/conf/nginx/services.d/upstream_proxy.conf
}

function activate_kasm() {
    if [ -z $ACTIVATION_KEY_FILE ]; then
        return
    fi 

    echo "Performing kasm activation"
    set +e
    ${KASM_INSTALL_BASE}/bin/utils/activate_kasm -a ${ACTIVATION_KEY_FILE} -q ${DATABASE_HOSTNAME} -T ${DATABASE_PORT} -Q ${DEFAULT_DATABASE_PASSWORD} -t ${DATABASE_SSL}
    ret=$?
    set -e
    if [ $ret -ne 0 ]; then
        echo "KASM Activation failed"
        ACTIVATION_FAILED="true"
    fi
}

function remove_network_sidecar_plugin() {
    # ensure there are no containers using the sidecar network/plugin
    CONTAINERS=$(sudo docker ps --filter "network=kasm_sidecar_network" --format "{{.Names}}")
    for CONTAINER in ${CONTAINERS}; do
        sudo docker stop ${CONTAINER}
    done

    # remove the network
    sudo docker network rm kasm_sidecar_network &> /dev/null || true

    # remove the plugin
    CURRENT_NETWORK_PLUGIN_NAME=$(sudo docker plugin ls | awk '/kasmweb\//{print $2}')
    if [ ! -z "${CURRENT_NETWORK_PLUGIN_NAME}" ]; then
        sudo docker plugin disable ${CURRENT_NETWORK_PLUGIN_NAME} &> /dev/null || true
        sudo docker plugin rm ${CURRENT_NETWORK_PLUGIN_NAME} &> /dev/null || true
    fi

    # clear iptables rules
    RULES=$(iptables -t filter -L FORWARD --line-numbers -n -v | awk '/br_kasm_sidecar/ {print $1}' | sort -rn)
    for RULE in ${RULES}; do
        sudo iptables -t "filter" -D "FORWARD" ${RULE}
    done

    # remove network interfaces
    ip link del br_kasm_sidecar &> /dev/null || true
    ip link show | awk -F: '/^[0-9]+: / {print $2}' | awk '{print $1}' | sed 's/@.*//' | grep k- | sudo xargs -I {} ip link del {}

    # remove temporary files
    rm -rf /var/run/kasm-sidecar
    rm -rf /var/log/kasm-sidecar
}

function install_network_sidecar_plugin() {
    if [ "${MANAGER_HOSTNAME}" != "false" ]; then
        mkdir -p /var/run/kasm-sidecar
        echo "$MANAGER_HOSTNAME:$DEFAULT_PROXY_LISTENING_PORT" > /var/run/kasm-sidecar/api_hostname
        echo "" > /var/run/kasm-sidecar/api_hostname_external
        echo "Installing docker sidecar network plugin using api hostname: $MANAGER_HOSTNAME:$DEFAULT_PROXY_LISTENING_PORT"
    else
        echo "Installing docker sidecar network plugin"
    fi

    SANITIZED_PLUGIN_BRANCH="$(echo $NETWORK_PLUGIN_BRANCH | sed -r 's#^release/##'  | sed 's/\//_/g')"

    if [[ "${NETWORK_PLUGIN_BRANCH}" == release/* ]] || [[ "${SANITIZED_PLUGIN_BRANCH}" == "develop" ]]; then
        NETWORK_PLUGIN_IMAGE="kasmweb/kasm-network-plugin:${ARCH}-${SANITIZED_PLUGIN_BRANCH}"
    else
        NETWORK_PLUGIN_IMAGE="kasmweb/kasm-network-plugin-private:${ARCH}-${SANITIZED_PLUGIN_BRANCH}"
    fi

    if [ ! -z "${NETWORK_PLUGIN_IMAGE_TARFILE}" ]; then
        tar -zxf $NETWORK_PLUGIN_IMAGE_TARFILE -C /var/lib/docker/plugins
        echo "Restarting docker engine"
        sudo service docker restart
        OFFLINE_NETWORK_PLUGIN_NAME=$(sudo docker plugin ls | awk '/kasmweb\//{print $2}')
        sudo docker plugin enable "${OFFLINE_NETWORK_PLUGIN_NAME}" &> /dev/null || true
    else
        sudo docker plugin install --alias "kasmweb/sidecar:${SANITIZED_PLUGIN_BRANCH}" $NETWORK_PLUGIN_IMAGE --grant-all-permissions
        sudo docker plugin enable "kasmweb/sidecar:${SANITIZED_PLUGIN_BRANCH}" &> /dev/null || true

        if [ ! -f "$SKIP_DOCKER_RESTART_FLAG_FILE" ]; then
            echo "Restarting docker engine"
            sudo service docker restart
        else
            echo "Skipping docker engine restart"
        fi
    fi

    # add firewalld rules
    if which firewall-cmd &> /dev/null && sudo systemctl is-active --quiet firewalld; then
        echo "Setting up firewalld rules for bridge interface \"br_kasm_sidecar\"."
        sudo firewall-cmd --permanent --zone=docker --add-interface=br_kasm_sidecar --permanent &> /dev/null
        sudo firewall-cmd --reload &> /dev/null
    fi
}

function create_docker_network() {
    kasm_network=kasm_default_network
    set +e
    sudo docker network inspect ${kasm_network} &> /dev/null
    ret=$?
    set -e
    if [ $ret -ne 0 ]; then
        echo "Creating docker network ${kasm_network}"
        sudo docker network create --driver=bridge kasm_default_network
    else
        echo "Docker network ${kasm_network} already exists. Will not create"
    fi
}

function create_sidecar_network() {

    if [ "${SKIP_EGRESS}" == "true" ]; then
        ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i 'del(.services.proxy.networks[1], .networks.kasm_sidecar_network)' ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
        return
    fi

    SANITIZED_NETWORK_PLUGIN_BRANCH="$(echo $NETWORK_PLUGIN_BRANCH | sed -r 's#^release/##'  | sed 's/\//_/g')"
    NETWORK_PLUGIN_NAME="kasmweb/sidecar:${SANITIZED_NETWORK_PLUGIN_BRANCH}"

    set +e
    sudo docker network inspect kasm_sidecar_network &> /dev/null
    ret=$?
    set -e

    if [ $ret -ne 0 ]; then
        NETWORK_PLUGIN_NAME=$(sudo docker plugin ls | awk '/kasmweb\//{print $2}')
        echo "Creating docker sidecar network \"kasm_sidecar_network\""
        sudo docker network create --driver=$NETWORK_PLUGIN_NAME kasm_sidecar_network &> /dev/null || true
    else
        echo "Docker sidecar network \"kasm_sidecar_network\" already exists. Will not create"
    fi
}

function connectivity_test() {
    if [ "${ROLE}" == "app" ];
    then
        if [ "${REDIS_HOSTNAME}" == "false" ];
        then
            TEST_REDIS_HOSTNAME=${DATABASE_HOSTNAME}
        else
            TEST_REDIS_HOSTNAME=${REDIS_HOSTNAME}
        fi
        echo "Checking connectivity to the databases"
        REDIS_CONNECTED="false"
        POSTGRES_CONNECTED="false"
        for i in {1..10};
        do
            echo "Trying ${DATABASE_HOSTNAME} on ${DATABASE_PORT} attempt:$i"
            DB_CHECK=$(nc -vz -w 3 ${DATABASE_HOSTNAME} ${DATABASE_PORT} 2>&1 || :)
            if [[ "${DB_CHECK}" =~ .*"succeeded".* ]] || [[ "${DB_CHECK}" =~ .*"Connected".* ]];
            then
              POSTGRES_CONNECTED="true"
              break
            fi
	    sleep 6
        done
        for i in {1..10};
        do
            echo "Trying ${TEST_REDIS_HOSTNAME} on 6379 attempt:$i"
            REDIS_CHECK=$(nc -vz -w 3 ${TEST_REDIS_HOSTNAME} 6379 2>&1 || :)
	    if [[ "${REDIS_CHECK}" =~ .*"succeeded".* ]] || [[ "${REDIS_CHECK}" =~ .*"Connected".* ]];
            then
              REDIS_CONNECTED="true"
              break
            fi
            sleep 3
        done
	if [ "${REDIS_CONNECTED}" == "true" ] && [ "${POSTGRES_CONNECTED}" == "true" ];
        then
            echo "Database connectivity passed ${TEST_REDIS_HOSTNAME} on port 6379 and ${DATABASE_HOSTNAME} on ${DATABASE_PORT}"
        else
            echo "Database connectivity failed please check your firewall configuration or database host settings"
            echo "Connection to Database at ${DATABASE_HOSTNAME} on ${DATABASE_PORT} ${POSTGRES_CONNECTED}"
            echo "Connection to Redis at ${TEST_REDIS_HOSTNAME} on 6379 ${REDIS_CONNECTED}"
	    echo "Installation will not continue"
            cleanup_log
	    exit 1
        fi
    elif [ "${ROLE}" == "agent" ];
    then
        WEB_CONNECTED="false"
	if [ "${API_SERVER_HOSTNAME}" == "false" ];
        then
            API_SERVER_HOSTNAME=${MANAGER_HOSTNAME}
        fi
        echo "Checking connectivity to the web application"
        for i in {1..10};
        do
            echo "Trying ${API_SERVER_HOSTNAME} healthcheck attempt:$i"
            WEB_CHECK=$(curl --max-time 5 -sLk "https://${API_SERVER_HOSTNAME}:${DEFAULT_PROXY_LISTENING_PORT}/api/__healthcheck" || :)
            if [[ "${WEB_CHECK}" =~ .*"true".* ]];
	        then
                WEB_CONNECTED="true"
                break
            fi
	    sleep 3
        done
	if [ "${WEB_CONNECTED}" == "true" ];
        then
            echo "Web application connectivity passed at https://${API_SERVER_HOSTNAME}:${DEFAULT_PROXY_LISTENING_PORT}/api/__healthcheck"
        else
            echo "Web application connectivity failed please check your firewall configuration or API server host settings"
            echo "Connection to https://${API_SERVER_HOSTNAME}:${DEFAULT_PROXY_LISTENING_PORT}/api/__healthcheck failed"
            echo "Installation will not continue"
            cleanup_log
            exit 1
        fi
    fi
}

function accept_eula() {
    printf "\n\n"
    echo "End User License Agreement"
    echo "__________________________"
    printf "\n\n"
    cat ${EULA_PATH}
    printf "\n\n"
    echo "A copy of the End User License Agreement is located at:"
    echo "${EULA_PATH}"
    printf "\n"
    read -p "I have read and accept End User License Agreement (y/n)? " choice
    case "$choice" in
      y|Y )
        ACCEPT_EULA="true"
        ;;
      n|N )
        echo "Installation cannot continue"
        cleanup_log
        exit 1
        ;;
      * )
        echo "Invalid Response"
        echo "Installation cannot continue"
        cleanup_log
        exit 1
        ;;
    esac

}

function check_role() {

if [ "${ROLE}" != "all" ] &&  [ "${ROLE}" != "agent" ]  &&  [ "${ROLE}" !=  "app" ] &&  [ "${ROLE}" != "db" ] && [ "${ROLE}" != "init_remote_db" ] && [ "${ROLE}" != "guac" ] &&  [ "${ROLE}" != "proxy" ];
then
    echo "Invalid Role Defined"
    display_help
    cleanup_log
    exit 1
fi
}

function set_registry_url() {
    if [ "${DEFAULT_REGISTRY_URL}" != "false" ]; then
        ${SCRIPT_PATH}/bin/utils/yq_$(uname -m) -i '(.registries.[])  .registry_url = "'${DEFAULT_REGISTRY_URL}'"' ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    elif [ ${OFFLINE_INSTALL} == "true" ]; then
      echo "Disabling Workspaces Registry for offline install."
      "${SCRIPT_PATH}/bin/utils/yq_$(uname -m)" -i '(.registries) = []' ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    fi
}

function set_update_check() {
  if [ ${OFFLINE_INSTALL} == "true" ]; then
      echo "Disabling Kasm Update check for offline install."
      "${SCRIPT_PATH}/bin/utils/yq_$(uname -m)" -i '(.settings[] | select(.name == "update_check") .value ) = "False"' ${KASM_INSTALL_BASE}/conf/database/seed_data/default_properties.yaml
    fi
}

function display_help() {
    CMD='\033[0;31m'
    NC='\033[0m'
    echo "Kasm Installer ${KASM_VERSION}" 
    echo "Usage IE:"
    echo "${0} --install-profile noninteractive --admin-password topsecret --proxy-port 8443"
    echo    ""
    echo    "Flag                                   Description"
    echo    "-----------------------------------------------------------------------------------------------"
    echo -e "| ${CMD}-h|--help${NC}                | Display this help menu                                           |"
    echo -e "| ${CMD}-v|--verbose${NC}             | Verbose output                                                   |"
    echo -e "| ${CMD}-V|--install-profile${NC}     | Installation profile to use (kasm_release/profiles)              |"
    echo -e "| ${CMD}-e|--accept-eula${NC}         | Accept End User License Agreement                                |"
    echo -e "| ${CMD}-S|--role${NC}                | Role to install: [all|app|db|agent|init_remote_db|guac|proxy]    |"
    echo -e "| ${CMD}-p|--public-hostname${NC}     | Agent/Component <IP/Hostname> used to register with deployment.  |"
    echo -e "| ${CMD}-d|--no-db-init${NC}          | Skip database initialization                                     |"
    echo -e "| ${CMD}-D|--no-start${NC}            | Don't start services at the end of installation                  |"
    echo -e "| ${CMD}-m|--manager-hostname${NC}    | Manager IP/Hostname                                              |"
    echo -e "| ${CMD}-U|--user-password${NC}       | Default User Password                                            |"
    echo -e "| ${CMD}-P|--admin-password${NC}      | Default Admin Password                                           |"
    echo -e "| ${CMD}-L|--proxy-port${NC}          | Default Proxy Listening Port                                     |"
    echo -e "| ${CMD}-z|--server-zone${NC}         | Server Zone                                                      |"
    echo -e "| ${CMD}-o|--redis-hostname${NC}      | Redis Hostname                                                   |"
    echo -e "| ${CMD}-R|--redis-password${NC}      | Redis Password                                                   |"
    echo -e "| ${CMD}-q|--db-hostname${NC}         | Database Hostname                                                |"
    echo -e "| ${CMD}-Q|--db-password${NC}         | Default Database Password                                        |"
    echo -e "| ${CMD}-c|--database-user${NC}       | Database user                                                    |"
    echo -e "| ${CMD}-j|--database-name${NC}       | Database name                                                    |"
    echo -e "| ${CMD}-t|--no-db-ssl${NC}           | Database, Disable SSL                                            |"
    echo -e "| ${CMD}-T|--db-port${NC}             | Database port (default 5432)                                     |"
    echo -e "| ${CMD}-M|--manager-token${NC}       | Manager Token                                                    |"
    echo -e "| ${CMD}-W|--default-images${NC}      | Seed and Download default Workspaces Images                      |"
    echo -e "| ${CMD}-w|--offline-workspaces${NC}  | Path to the tar.gz workspace images offline installer            |"
    echo -e "| ${CMD}-s|--offline-service${NC}     | Path to the tar.gz service images offline installer              |"
    echo -e "| ${CMD}-x|--offline-plugin${NC}      | Path to the tar.gz plugin images offline installer               |"
    echo -e "| ${CMD}-G|--db-master-password${NC}  | Database master password for database remote init                |"
    echo -e "| ${CMD}-g|--db-master-user${NC}      | Database master user for database remote init                    |"
    echo -e "| ${CMD}-H|--no-swap-check${NC}       | Disable check for swapfile                                       |"
    echo -e "| ${CMD}-J|--swap-size${NC}           | Create swap if none exists in megabytes (IE 4096)                |"
    echo -e "| ${CMD}-a|--activation-key-file${NC} | License Activation key file                                      |"
    echo -e "| ${CMD}-i|--agent-server-id${NC}     | Set Agent server ID                                              |"
    echo -e "| ${CMD}-n|--api-hostname${NC}        | Set API server hostname                                          |"
    echo -e "| ${CMD}-r|--agent-provider${NC}      | Set agent provider                                               |"
    echo -e "| ${CMD}-B|--no-check-ports${NC}      | Do not check for open ports                                      |"
    echo -e "| ${CMD}-b|--no-check-disk${NC}       | Do not check disk space                                          |"
    echo -e "| ${CMD}-O|--use-rolling-images${NC}  | Use rolling Workspaces images                                    |"
    echo -e "| ${CMD}-N|--skip-connection-test${NC}| Skip database connection tests                                   |"
    echo -e "| ${CMD}-A|--enable-lossless${NC}     | Enable lossless streaming option                                 |"
    echo -e "| ${CMD}-k|--registration-token${NC}  | Register a component with an existing deployment.                |"
    echo -e "| ${CMD}-y|--default-registry-url${NC}| Set the default Workspaces Registry URL.                         |"
    echo -e "| ${CMD}-X|--skip-v4l2loopback${NC}   | Skip v4l2loopback installation                                   |"
    echo -e "| ${CMD}--guac-cluster-size${NC}      | Set guac cluster size, 0 for automatic                           |"
    echo -e "| ${CMD}--skip-custom-rclone${NC}     | This will install the stock Rclone plugin without modification   |"
    echo -e "| ${CMD}--install-depends${NC}        | Force dependency installation regardless of other flags          |"
    echo -e "| ${CMD}--skip-egress${NC}            | Do not install egress network plugin or dependancies             |"
    echo    "----------------------------------------------------------------------------------------------------------"
    echo ""
    echo    "Profile                        Description"
    echo    "-----------------------------------------------------------------------------------------------"
    echo -e "| ${CMD}noninteractive${NC}   | no sanity checks automated bare install                                  |"
    echo -e "| ${CMD}hardened${NC}         | security hardened ro containers in usermode                              |"
    echo    "-----------------------------------------------------------------------------------------------"
}

function load_workspace_images () {
    if [ -z "$WORKSPACE_IMAGE_TARFILE" ]; then
        return
    fi 

    tar xf "${WORKSPACE_IMAGE_TARFILE}" -C "${KASM_RELEASE}"

    # install all kasm infrastructure images
    while IFS="" read -r image || [ -n "$image" ]; do
            echo "Loading image: $image"
            IMAGE_FILENAME=$(echo $image | sed -r 's#[:/]#_#g')
        docker load --input ${KASM_RELEASE}/workspace_images/${IMAGE_FILENAME}.tar
    done < ${KASM_RELEASE}/workspace_images/images.txt
}

function load_service_images () {
    if [ -z "$SERVICE_IMAGE_TARFILE" ]; then
        return
    fi

    tar xf "${SERVICE_IMAGE_TARFILE}" -C "${KASM_RELEASE}"

    # install all kasm infrastructure images
    while IFS="" read -r image || [ -n "$image" ]; do
            echo "Loading image: $image"
            IMAGE_FILENAME=$(echo $image | sed -r 's#[:/]#_#g')
        docker load --input ${KASM_RELEASE}/service_images/${IMAGE_FILENAME}.tar
    done < ${KASM_RELEASE}/service_images/images.txt
}

function enable_lossless () {
    if [ "${ROLE}" == "app" ] || [ "${ROLE}" == "all" ]; then
        sed -i "/X-Robots-Tag/a \        add_header      'Cross-Origin-Embedder-Policy' 'require-corp';\n        add_header      'Cross-Origin-Opener-Policy' 'same-origin';\n        add_header      'Cross-Origin-Resource-Policy' 'same-site';"  ${KASM_INSTALL_BASE}/conf/nginx/services.d/website.conf
        sed -i "/Cache-Control/a \                add_header              'Cross-Origin-Embedder-Policy' 'require-corp';\n                add_header              'Cross-Origin-Opener-Policy' 'same-origin';\n                add_header              'Cross-Origin-Resource-Policy' 'same-site';" ${KASM_INSTALL_BASE}/conf/nginx/services.d/kasmguac.conf
    fi
}

# Ingest settings from defined install profile
PROFILEARGS=()
for PROFILEARG in "${ARGS[@]}"; do
  case $PROFILEARG in
    -V|--install-profile)
        INSTALL_PROFILE="$2"
        echo "Loading install profile ${INSTALL_PROFILE}"
        VARS=('accept-eula'
              'verbose'
              'role'
              'public-hostname'
              'no-db-init'
              'no-start'
              'manager-hostname'
              'user-password'
              'admin-password'
              'proxy-port'
              'server-zone'
              'redis-hostname'
              'redis-password'
              'db-hostname'
              'db-password'
              'no-db-ssl'
              'db-port'
              'manager-token'
              'no-images'
              'no-pull-images'
              'offline-workspaces'
              'offline-service'
              'offline-plugin'
              'db-password'
              'db-user'
              'no-swap-check'
              'swap-size'
              'activation-key-file'
              'agent-server-id'
              'api-hostname'
              'agent-provider'
              'no-check-ports'
              'no-check-disk'
              'use-rolling-images'
              'skip-connection-test'
              'enable-lossless'
              'database-user'
              'database-name'
              'default-images'
              'default-registry-url'
              'skip-v4l2loopback'
              'skip-custom-rclone'
              'install-depends',
              'skip-egress')
        for VAR in ${VARS[@]}; do
            VALUE=$(${SCRIPT_PATH}/bin/utils/yq_$(uname -m) ".${VAR}" ${KASM_RELEASE}/profiles/${INSTALL_PROFILE}.yaml)
            if [ "${VALUE}" != "null" ];
            then
                if echo "${ARGS[*]}" | grep -q "\-\-${VAR}";
		then
                  echo "--${VAR} is set via CLI skipping install profile load"
                else
                    if [ "${VALUE}" == "true" ];
                    then
                        PROFILEARGS+=("--${VAR}")
                    else
                        PROFILEARGS+=("--${VAR}")
			PROFILEARGS+=("${VALUE}")
                    fi
                fi
            fi
        done
        ;;
  esac
done

# Ingest command line args
ARGSAPPEND=("${ARGS[@]}" "${PROFILEARGS[@]}")
for index in "${!ARGSAPPEND[@]}"; do
  case ${ARGSAPPEND[index]} in
    -V|--install-profile)
        ;;
    -e|--accept-eula)
        ACCEPT_EULA='true'
        ;;
    -d|--no-db-init)
        DO_DATABASE_INIT='false'
        ;;
    -h|--help)
        display_help
        cleanup_log
        exit 0
        ;;
    -i|--agent-server-id)
        SERVER_ID="${ARGSAPPEND[index+1]}"
        echo "Setting Agent Server ID as ${SERVER_ID}"
        ;;
    -p|--public-hostname)
        PUBLIC_HOSTNAME="${ARGSAPPEND[index+1]}"
        echo "Setting Public Hostname as ${PUBLIC_HOSTNAME}"
        ;;
    -P|--admin-password)
        DEFAULT_ADMIN_PASSWORD="${ARGSAPPEND[index+1]}"
        echo "Setting Default Admin Password from stdin -P"
        ;;
    -L|--proxy-port)
        DEFAULT_PROXY_LISTENING_PORT="${ARGSAPPEND[index+1]}"
        echo "Setting Default Listening Port as ${DEFAULT_PROXY_LISTENING_PORT}"
        ;;
    -U|--user-password)
        DEFAULT_USER_PASSWORD="${ARGSAPPEND[index+1]}"
        echo "Setting Default User Password from stdin -U"
        ;;
    -Q|--db-password)
        DEFAULT_DATABASE_PASSWORD="${ARGSAPPEND[index+1]}"
        echo "Setting Default Database Password from stdin -Q"
        ;;
    -R|--redis-password)
        DEFAULT_REDIS_PASSWORD="${ARGSAPPEND[index+1]}"
        echo "Setting Default Redis Password from stdin -R"
        ;;
    -S|--role)
        ROLE="${ARGSAPPEND[index+1]}"
        check_role
        echo "Setting Role as ${ROLE}"
        ;;
    -q|--db-hostname)
        DATABASE_HOSTNAME="${ARGSAPPEND[index+1]}"
        echo "Setting Database Hostname as ${DATABASE_HOSTNAME}"
        ;;
    -c|--database-user)
        DATABASE_USER="${ARGS[index+1]}"
        ;;
    -j|--database-name)
        DATABASE_NAME="${ARGS[index+1]}"
        ;;
    -m|--manager-hostname)
        MANAGER_HOSTNAME="${ARGSAPPEND[index+1]}"
        echo "Setting Manager Hostname as ${MANAGER_HOSTNAME}"
        ;;
    -M|--manager-token)
        DEFAULT_MANAGER_TOKEN="${ARGSAPPEND[index+1]}"
        echo "Setting Default Manager Token as ${DEFAULT_MANAGER_TOKEN}"
        ;;
    -n|--api-hostname)
        API_SERVER_HOSTNAME="${ARGSAPPEND[index+1]}"
        echo "Setting API Server Hostname as ${API_SERVER_HOSTNAME}"
        ;;
    -r|--agent-provider)
        PROVIDER="${ARGSAPPEND[index+1]}"
        echo "Setting Agent Provider as ${PROVIDER}"
        ;;
    -D|--no-start)
        START_SERVICES='false'
        ;;
    -v|--verbose)
        set -x
        ;;
    -z|--server-zone)
        SERVER_ZONE="${ARGSAPPEND[index+1]}"
        echo "Setting Server Zone as ${SERVER_ZONE}"
        ;;
    -t|--no-db-ssl)
        DATABASE_SSL='false'
        echo "Setting Database SSL to false"
        ;;
    -T|--db-port)
        DATABASE_PORT="${ARGSAPPEND[index+1]}"
        echo "Setting Database Port to ${DATABASE_PORT}"
        ;;
    -o|--redis-hostname)
        REDIS_HOSTNAME="${ARGSAPPEND[index+1]}"
        echo "Setting Redis Hostname to ${REDIS_HOSTNAME}"
        ;;
    -I|--no-images)
        SEED_IMAGES="false"
        PULL_IMAGES="false"
        ;;
    -u|--no-pull-images)
        PULL_IMAGES="false"
        ;;
    -W|--default-images)
        SEED_IMAGES="true"
        PULL_IMAGES="true"
        ;;
    -w|--offline-workspaces)
        WORKSPACE_IMAGE_TARFILE="${ARGSAPPEND[index+1]}"
        OFFLINE_INSTALL="true"
        SEED_IMAGES="true"

        if [ ! -f "$WORKSPACE_IMAGE_TARFILE" ]; then
            echo "FATAL: Workspace image tarfile does not exist: ${WORKSPACE_IMAGE_TARFILE}"
            cleanup_log
            exit 1
        fi

        echo "Setting workspace image tarfile to ${WORKSPACE_IMAGE_TARFILE}"
	    ;;
    -s|--offline-service)
        SERVICE_IMAGE_TARFILE="${ARGSAPPEND[index+1]}"
        OFFLINE_INSTALL="true"
        PULL_IMAGES="false"

        if [ ! -f "$SERVICE_IMAGE_TARFILE" ]; then
          echo "FATAL: Service image tarfile does not exist: ${SERVICE_IMAGE_TARFILE}"
          cleanup_log
          exit 1
        fi

        echo "Setting service image tarfile to ${SERVICE_IMAGE_TARFILE}"
        ;;
    -x|--offline-plugin)
        NETWORK_PLUGIN_IMAGE_TARFILE="${ARGSAPPEND[index+1]}"

        if [ ! -f "$NETWORK_PLUGIN_IMAGE_TARFILE" ]; then
          echo "FATAL: Plugin image tarfile does not exist: ${NETWORK_PLUGIN_IMAGE_TARFILE}"
          cleanup_log
          exit 1
        fi

        echo "Setting plugin image tarfile to ${NETWORK_PLUGIN_IMAGE_TARFILE}"
        ;;
    -g|--db-master-user)
        DATABASE_MASTER_USER="${ARGSAPPEND[index+1]}"
        echo "Using Database Master User ${DATABASE_MASTER_USER}"
        ;;
    -G|--db-master-password)
        DATABASE_MASTER_PASSWORD="${ARGSAPPEND[index+1]}"
        echo "Using Database Master Password from stdin -G"
        ;;
    -H|--no-swap-check)
        SWAP_CHECK="false"
        ;;
    -J|--swap-size)
        SWAP_SIZE="${ARGSAPPEND[index+1]}"
        SWAP_CHECK="false"
        SWAP_CREATE="true"
        ;;
    -a|--activation-key-file)
        ACTIVATION_KEY_FILE="${ARGSAPPEND[index+1]}"

        if [ ! -f "$ACTIVATION_KEY_FILE" ]; then
            echo "FATAL: Activation key file does not exist: ${ACTIVATION_KEY_FILE}"
            cleanup_log
            exit 1
        fi

        echo "Using activation key ${ACTIVATION_KEY_FILE}"
        ;;
    -B|--no-check-ports)
        CHECK_PORTS="false"
        ;;
    -b|--no-check-disk)
        CHECK_DISK="false"
        ;;
    -O|--use-rolling-images)
        USE_ROLLING="true"
        ;;
    -N|--skip-connection-test)
        TEST_CONNECT="false"
        ;;
    -A|--enable-lossless)
        ENABLE_LOSSLESS="true"
        ;;
    -k|--registration-token)
        REGISTRATION_TOKEN="${ARGSAPPEND[index+1]}"
        ;;
    -y|--default-registry-url)
        DEFAULT_REGISTRY_URL="${ARGSAPPEND[index+1]}"
        ;;
    --guac-cluster-size)
        GUAC_CLUSTER_SIZE="${ARGSAPPEND[index+1]}"
        ;;
    -X|--skip-v4l2loopback)
        SKIP_V4L2LOOPBACK="true"
        ;;
    --skip-custom-rclone)
        SKIP_CUSTOM_RCLONE="true"
        ;;
    --install-depends)
        FORCE_DEPS_INSTALL="true"
        ;;
    --skip-egress)
        SKIP_EGRESS="true"
        ;;
    -*|--*)
        echo "Unknown option ${ARGSAPPEND[index]}"
        display_help
        cleanup_log
	exit 1
        ;;
  esac
done

if [ "${ACCEPT_EULA}" == "false" ] ;
then
    accept_eula
fi

if [ ${OFFLINE_INSTALL} == "false" ] || [ ${FORCE_DEPS_INSTALL} == "true" ]; then
    bash ${KASM_RELEASE}/install_dependencies.sh ${SKIP_V4L2LOOPBACK} ${SKIP_CUSTOM_RCLONE} ${SKIP_EGRESS} ${ROLE}
fi

if [ "${CHECK_PORTS}" == "true" ] ;
then
    is_port_ok
fi

# Swap file management
if  ([ "${ROLE}" == "agent" ] || [ "${ROLE}" == "all" ]) && [ "${SWAP_CHECK}" == "true" ]; then
    if [[ $(sudo swapon --show) ]]; then
        echo 'Swap Exists'
    else
        printf "\n--------------------------------------------------------------------------------"
        printf "\n                             WARNING  "
        printf "\n--------------------------------------------------------------------------------\n\n"
        echo 'Your system does not have a Swap file or partition. Even with adequate RAM it is'
        echo 'imperative to a have a swap file for Kasm to be stable. You can add a swap file '
        echo 'at any time, see our documentations Resource Allocation Section for more details.'
        printf "\n"
        read -p "Do you want to create a swap partition on this system (y/n)? " choice
        case "$choice" in
          y|Y )
            SWAP_SET="true"
            ;;
          n|N )
            echo "Continuing Installation"
            ;;
          * )
            echo "Invalid Response"
            echo "Installation Exiting"
            cleanup_log
            exit 1
            ;;
        esac
        if [ "${SWAP_SET}" == "true" ]; then
            echo "You currently have $(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576))GB of memory on this system."
            echo "It is important to have a large swap file to reduce memory consumption with stopped"
            echo "Workspaces and to ensure processes are not killed in session when running many Workspaces."
            echo "Depending on configuration a normal Workspace will consume 2-4GB of memory."
            PS3="How large of a swap file would you like to create: "
            SIZES=("4GB", "8GB", "12GB", "16GB", "custom")
            selected=()
            select SIZE in "${SIZES[@]}" ; do
               for reply in $REPLY ; do
                 selected+=(${SIZES[reply - 1]})
               done
               [[ $selected ]] && break
            done
            echo Selected: "${selected[@]}"
            if [ "${selected[@]}" == "4GB," ];
            then
                echo "Proceeding with a 4GB swap file"
                SWAP_SIZE=4096
            elif [ "${selected[@]}" == "8GB," ]; then
                echo "Proceeding with a 8GB swap file"
                SWAP_SIZE=8192
            elif [ "${selected[@]}" == "12GB," ]; then
                echo "Proceeding with a 12GB swap file"
                SWAP_SIZE=12288
            elif [ "${selected[@]}" == "16GB," ]; then
                echo "Proceeding with a 16GB swap file"
                SWAP_SIZE=16384
            elif [ "${selected[@]}" == "custom" ]; then
                read -p "Please enter an integer value in Gigabytes for your desired swap size: " MANSIZE
                echo "Setting swap size to ${MANSIZE}GB"
                SWAP_SIZE=$(( ${MANSIZE} * 1024 ))
            fi
	    SWAP_CREATE="true"
        fi
    fi
fi

if [ "${SWAP_CREATE}" == "true" ];
then
    if [[ $(sudo swapon --show) ]]; then
      echo 'Swap Exists'
    else
        echo "Swap file not present creating a new swap file"
        fallocate -l ${SWAP_SIZE}M /mnt/Kasm.swap || dd if=/dev/zero bs=1M count=${SWAP_SIZE} of=/mnt/Kasm.swap
        chmod 600 /mnt/Kasm.swap
        mkswap /mnt/Kasm.swap
        swapon /mnt/Kasm.swap
        echo '/mnt/Kasm.swap swap swap defaults 0 0' | tee -a /etc/fstab
    fi
fi

# Check to ensure docker has enough disk space
if ([ "${ROLE}" == "all" ] || [ "${ROLE}" == "agent" ]) && [ "${CHECK_DISK}" == "true" ];
then
    DOCKER_DIR=$(docker info | awk -F': ' '/Docker Root Dir/ {print $2}')
    BYTES=$(df --output=avail -B 1 "${DOCKER_DIR}" | tail -n 1)
    if [ "${BYTES}" -lt "${DISK_SPACE}" ] && [ "${SEED_IMAGES}" == "true" ] && [ "${PULL_IMAGES}" == "true" ]; then
        echo "#############################################################"
        echo "# The installation has detected less than 50 Gigabytes free #"
        echo "# in the directory used for Docker storage: ${DOCKER_DIR} #"
        echo "#############################################################"
        df -h ${DOCKER_DIR}
        printf "\n"
        echo "Using the default image set for Workspaces we recommend at least"
        echo "50 Gigabytes of available space. This check can be disabled using"
        echo "the --no-check-disk install flag or alternatively installing"
        echo "without seeding images using the --no-images install flag."
        read -e -p "Proceed with installation anyway (n/y)? " -i "n" choice
        case "$choice" in
            y|Y )
                echo "Bypassing disk check"
                ;;
            n|N )
                echo "Installation cancelled by user"
                cleanup_log
                exit 1
                ;;
            * )
                echo "Invalid Response"
                echo "Installation cannot continue"
                cleanup_log
                exit 1
                ;;
            esac
    fi
fi

id -u kasm &>/dev/null || useradd kasm

# TODO Prompt the user, or accept a flag for automation
sudo rm -rf ${KASM_INSTALL_BASE}

mkdir -p ${KASM_INSTALL_BASE}/bin
mkdir -p ${KASM_INSTALL_BASE}/certs
mkdir -p ${KASM_INSTALL_BASE}/www
mkdir -p ${KASM_INSTALL_BASE}/file_mappings/common
mkdir -p ${KASM_INSTALL_BASE}/conf/nginx/services.d
mkdir -p ${KASM_INSTALL_BASE}/conf/nginx/containers.d
mkdir -p ${KASM_INSTALL_BASE}/conf/database/seed_data
mkdir -p ${KASM_INSTALL_BASE}/conf/app
mkdir -p ${KASM_INSTALL_BASE}/tmp/api
mkdir -p ${KASM_INSTALL_BASE}/tmp/manager
mkdir -p ${KASM_INSTALL_BASE}/tmp/guac
mkdir -p ${KASM_INSTALL_BASE}/tmp/rdpgw/var
mkdir -p ${KASM_INSTALL_BASE}/tmp/rdpgw/tmp

mkdir -p ${KASM_INSTALL_BASE}/log/nginx
mkdir -p ${KASM_INSTALL_BASE}/log/logrotate

chmod 777 ${KASM_INSTALL_BASE}/log
chmod 777 ${KASM_INSTALL_BASE}/log/nginx
chmod 777 ${KASM_INSTALL_BASE}/log/logrotate
chmod 777 ${KASM_INSTALL_BASE}/conf/nginx/containers.d

sudo openssl req -x509 -nodes -days 1825 -newkey rsa:2048 -keyout ${KASM_INSTALL_BASE}/certs/kasm_nginx.key -out ${KASM_INSTALL_BASE}/certs/kasm_nginx.crt -subj "/C=US/ST=VA/L=None/O=None/OU=DoFu/CN=$(hostname)/emailAddress=none@none.none" 2> /dev/null
chmod 600 ${KASM_INSTALL_BASE}/certs/kasm_nginx.crt

cp -r ${KASM_RELEASE}/conf/app/* ${KASM_INSTALL_BASE}/conf/app/

cp ${KASM_RELEASE}/conf/database/data.sql ${KASM_INSTALL_BASE}/conf/database/
cp ${KASM_RELEASE}/conf/database/seed_data/default_properties.yaml ${KASM_INSTALL_BASE}/conf/database/seed_data/
cp ${KASM_RELEASE}/conf/database/seed_data/default_images_amd64.yaml ${KASM_INSTALL_BASE}/conf/database/seed_data/
cp ${KASM_RELEASE}/conf/database/seed_data/default_images_arm64.yaml ${KASM_INSTALL_BASE}/conf/database/seed_data/
cp ${KASM_RELEASE}/conf/database/seed_data/default_agents.yaml ${KASM_INSTALL_BASE}/conf/database/seed_data/

chmod -R 444 ${KASM_INSTALL_BASE}/conf/database
cp -r ${KASM_RELEASE}/conf/nginx/orchestrator.conf ${KASM_INSTALL_BASE}/conf/nginx/orchestrator.conf
cp -r ${KASM_RELEASE}/conf/nginx/logging.conf ${KASM_INSTALL_BASE}/conf/nginx/logging.conf
cp -r ${KASM_RELEASE}/conf/nginx/compress.conf ${KASM_INSTALL_BASE}/conf/nginx/compress.conf

mkdir -p ${KASM_INSTALL_BASE}/docker/.conf
cp ${KASM_RELEASE}/docker/*.yaml ${KASM_INSTALL_BASE}/docker/.conf/
cp -r ${KASM_RELEASE}/bin/ ${KASM_INSTALL_BASE}/
cp -r ${KASM_RELEASE}/licenses/ ${KASM_INSTALL_BASE}/
cp  ${EULA_PATH} ${KASM_INSTALL_BASE}/

if [ "${USE_ROLLING}" == "true" ];
then
    sed -i '/ name:/ s/$/-rolling-daily/' ${KASM_INSTALL_BASE}/conf/database/seed_data/default_images_amd64.yaml
    sed -i '/ name:/ s/$/-rolling-daily/' ${KASM_INSTALL_BASE}/conf/database/seed_data/default_images_arm64.yaml
    sed -i '/ image:/ s/"$/-rolling"/' ${KASM_INSTALL_BASE}/docker/.conf/*.yaml
fi

if [ "${ROLE}" == "all" ] ;
then
    echo "Installing All Services"
    cp -r ${KASM_RELEASE}/conf/nginx/upstream_agent.conf ${KASM_INSTALL_BASE}/conf/nginx/upstream_agent.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/agent.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/agent.conf
    cp ${KASM_INSTALL_BASE}/docker/.conf/docker-compose-all.yaml ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    set_server_zone
    set_database_user
    set_database_name
    copy_db_config
    set_agent_server_id
    set_provider
    copy_manager_configs
    copy_api_configs
    copy_guac_configs
    copy_rdpproxy_configs
    set_api_hostname
    set_api_server_id
    set_share_id
    set_manager_id
    set_listening_port
    create_docker_network
    remove_network_sidecar_plugin
    if [ "${SKIP_EGRESS}" == "false" ] ;
    then
        install_network_sidecar_plugin
    fi
    create_sidecar_network
    set_random_database_password
    set_database_password
    set_random_redis_password
    set_redis_password
    set_database_hostname
    set_database_port
    set_database_ssl
    set_redis_hostname
    set_random_manager_token
    set_manager_token
    set_registry_url
    set_update_check
    set_random_registration_token
    set_registration_token
    configure_guac_component
    configure_rdp_gateway_component
    set_guac_cluster_size
    set_upstream_auth
    load_service_images
    load_workspace_images
    if [ "${ENABLE_LOSSLESS}" == "true" ] ;
    then
        enable_lossless
    fi
    base_install
    activate_kasm
elif [ "${ROLE}" == "app" ] ;
then
    echo "Installing App Role"
    cp ${KASM_INSTALL_BASE}/docker/.conf/docker-compose-app.yaml ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    set_server_zone
    set_database_user
    set_database_name
    copy_manager_configs
    copy_rdpproxy_configs
    get_database_hostname
    set_database_hostname
    get_database_password
    set_database_password
    set_database_ssl
    get_redis_password
    set_redis_password
    set_redis_hostname
    set_api_hostname
    set_api_server_id
    set_share_id
    set_manager_id
    set_listening_port
    create_docker_network
    DO_DATABASE_INIT='false'
    load_service_images
    if [ "${TEST_CONNECT}" == "true" ] ;
    then
        connectivity_test
    fi
    if [ "${ENABLE_LOSSLESS}" == "true" ] ;
    then
        enable_lossless
    fi
    base_install
elif [ "${ROLE}" == "agent" ] ;
then
    echo "Installing Agent Role"
    cp -r ${KASM_RELEASE}/conf/nginx/upstream_agent.conf ${KASM_INSTALL_BASE}/conf/nginx/upstream_agent.conf
    cp -r ${KASM_RELEASE}/conf/nginx/services.d/agent.conf ${KASM_INSTALL_BASE}/conf/nginx/services.d/agent.conf
    cp ${KASM_INSTALL_BASE}/docker/.conf/docker-compose-agent.yaml ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    get_manager_hostname
    set_manager_hostname
    get_public_hostname
    set_public_hostname
    get_manager_token
    set_manager_token
    set_agent_server_id
    set_provider
    set_listening_port
    create_docker_network
    remove_network_sidecar_plugin
    if [ "${SKIP_EGRESS}" == "false" ] ;
    then
        install_network_sidecar_plugin
    fi
    create_sidecar_network
    DO_DATABASE_INIT='false'
    load_service_images
    if [ "${TEST_CONNECT}" == "true" ] ;
    then
        connectivity_test
    fi
    load_workspace_images
elif [ "${ROLE}" == "db" ] ;
then
    echo "Installing Database Role"
    if [ "${DATABASE_HOSTNAME}" == 'false' ] && [ "${REDIS_HOSTNAME}" == 'false' ]; then
    	cp ${KASM_INSTALL_BASE}/docker/.conf/docker-compose-db-redis.yaml ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    elif [ "${DATABASE_HOSTNAME}" == 'false' ]; then
    	cp ${KASM_INSTALL_BASE}/docker/.conf/docker-compose-db.yaml ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    elif [ "${REDIS_HOSTNAME}" == 'false' ]; then
    	cp ${KASM_INSTALL_BASE}/docker/.conf/docker-compose-redis.yaml ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    fi
    set_database_user
    set_database_name
    copy_db_config
    create_docker_network
    set_random_database_password
    set_database_password
    set_database_hostname
    set_database_port
    set_database_ssl
    set_redis_hostname
    set_random_redis_password
    set_redis_password
    set_listening_port
    set_random_manager_token
    set_manager_token
    set_registry_url
    set_update_check
    set_random_registration_token
    set_registration_token
    load_service_images
    base_install
    activate_kasm
elif [ "${ROLE}" == "init_remote_db" ] ;
then
    echo "Initializing Remote database"
    cp ${KASM_INSTALL_BASE}/docker/.conf/docker-compose-app.yaml ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    set_server_zone
    set_database_user
    set_database_name
    get_database_hostname
    set_database_hostname
    get_database_password
    set_database_password
    set_database_ssl
    set_manager_id
    set_registry_url
    set_update_check
    create_docker_network
    DO_DATABASE_INIT='true'
    set_random_manager_token
    set_manager_token
    set_random_registration_token
    set_registration_token
    load_service_images
    base_install
    START_SERVICES='false'
    activate_kasm
elif [ "${ROLE}" == "guac" ] ;
then
    echo "Installing guac role"
    cp ${KASM_INSTALL_BASE}/docker/.conf/docker-compose-guac.yaml ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    copy_guac_configs
    copy_rdpproxy_configs
    set_listening_port
    create_docker_network
    DO_DATABASE_INIT='false'
    load_service_images
    get_public_hostname
    configure_guac_component
    configure_rdp_gateway_component
    set_guac_cluster_size
    base_install
elif [ "${ROLE}" == "proxy" ] ;
then
    echo "Installing Proxy Role"
    cp ${KASM_INSTALL_BASE}/docker/.conf/docker-compose-proxy.yaml ${KASM_INSTALL_BASE}/docker/docker-compose.yaml
    set_listening_port
    create_docker_network
    copy_proxy_configs
    copy_rdpproxy_configs
    DO_DATABASE_INIT='false'
    load_service_images
    base_install
else
    exit -1
fi


chmod +x ${KASM_INSTALL_BASE}/bin/*
chmod +x ${KASM_INSTALL_BASE}/bin/utils/*
chmod -R 777 ${KASM_INSTALL_BASE}/conf/nginx

if [ "${ROLE}" != "init_remote_db" ] ; then
    # Remove the symbolic links if they already exits
    rm -f /opt/kasm/current
    rm -f /opt/kasm/bin
    # Create symbolic links to the version just installed
    ln -sf ${KASM_INSTALL_BASE} /opt/kasm/current
    ln -sf /opt/kasm/current/bin /opt/kasm/bin
fi

if [ "${START_SERVICES}" == "true" ]  ;
then
    echo "Starting Kasm Services"
    ${KASM_INSTALL_BASE}/bin/start
    if [ "${ROLE}" == "all" ] ;
    then
        if [ "${PULL_IMAGES}" == "true" ]  ;
        then
          pull_images
        else
          echo "Not pulling default Workspaces Images."
        fi
    fi
else
    echo "Not starting Kasm Services"
fi



printf "\n\n"
echo "Installation Complete"
if [ "${DO_DATABASE_INIT}" == "true" ] ;
then
    printf "\n\n"
    echo "Kasm UI Login Credentials"
    printf "\n"
    echo "------------------------------------"
    echo "  username: admin@kasm.local"
    echo "  password: ${DEFAULT_ADMIN_PASSWORD}"
    echo "------------------------------------"
    echo "  username: user@kasm.local"
    echo "  password: ${DEFAULT_USER_PASSWORD}"
    echo "------------------------------------"
    printf "\n"
    echo "Kasm Database Credentials"
    echo "------------------------------------"
    echo "  username: ${DATABASE_USER}"
    echo "  password: ${DEFAULT_DATABASE_PASSWORD}"
    echo "------------------------------------"
    printf "\n"
    echo "Kasm Redis Credentials"
    echo "------------------------------------"
    echo "  password: ${DEFAULT_REDIS_PASSWORD}"
    echo "------------------------------------"
    printf "\n"
    echo "Kasm Manager Token"
    echo "------------------------------------"
    echo "  password: ${DEFAULT_MANAGER_TOKEN}"
    echo "------------------------------------"
    printf "\n"
    echo "Service Registration Token"
    echo "------------------------------------"
    echo "  password: ${REGISTRATION_TOKEN}"
    echo "------------------------------------"
    printf "\n\n"
fi

if [ "${ACTIVATION_FAILED}" == "true" ]; then
    echo ""
    echo "WARNING: Kasm install license activation failed."
    echo "Please activate your installation manually through the Admin UI"
fi

cleanup_log