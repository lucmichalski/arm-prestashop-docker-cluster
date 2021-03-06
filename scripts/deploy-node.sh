#!/bin/bash -x
function usage()
{
    echo "INFO:"
    echo "Usage: deploy-node.sh index admin #nodes subnet vmname"
}

error_log()
{
    if [ "$?" != "0" ]; then
        log "$1"
        log "Deployment ends with an error" "1"
        exit 1
    fi
}

function log()
{

  mess="$(hostname): $1"

  logger -t "${BASH_SCRIPT}" "${mess}"

  echo "${BASH_SCRIPT}" "${mess}" >> /tmp/${BASH_SCRIPT}.log

}

function ssh_config()
{
  log "Configure ssh..."
  log "Create ssh configuration for ${ADMIN_USER}"

  printf "Host *\n  user %s\n  StrictHostKeyChecking no\n" "${ADMIN_USER}"  >> "${ADMIN_HOME}/.ssh/config"

  error_log "Unable to create ssh config file for user ${ADMIN_USER}"

  log "Copy generated keys..."

  cp id_rsa "${ADMIN_HOME}/.ssh/id_rsa"
  error_log "Unable to copy id_rsa key to $ADMIN_USER .ssh directory"

  cp id_rsa.pub "${ADMIN_HOME}/.ssh/id_rsa.pub"
  error_log "Unable to copy id_rsa.pub key to $ADMIN_USER .ssh directory"

  cat "${ADMIN_HOME}/.ssh/id_rsa.pub" >> "${ADMIN_HOME}/.ssh/authorized_keys"
  error_log "Unable to copy $ADMIN_USER id_rsa.pub to authorized_keys "

  chmod 700 "${ADMIN_HOME}/.ssh"
  error_log "Unable to chmod $ADMIN_USER .ssh directory"

  chown -R "${ADMIN_USER}:" "${ADMIN_HOME}/.ssh"
  error_log "Unable to chown to $ADMIN_USER .ssh directory"

  chmod 400 "${ADMIN_HOME}/.ssh/id_rsa"
  error_log "Unable to chmod $ADMIN_USER id_rsa file"

  chmod 644 "${ADMIN_HOME}/.ssh/id_rsa.pub"
  error_log "Unable to chmod $ADMIN_USER id_rsa.pub file"

  chmod 400 "${ADMIN_HOME}/.ssh/authorized_keys"
  error_log "Unable to chmod $ADMIN_USER authorized_keys file"
}

function ssh_config_root()
{

  log "Create ssh configuration for root"

  printf "Host *\n  user %s\n  StrictHostKeyChecking no\n" "root"  >> "/root/.ssh/config"

  error_log "Unable to create ssh config file for user root"

  log "Copy generated keys..."

  cp id_rsa "/root/.ssh/id_rsa"
  error_log "Unable to copy id_rsa key to root .ssh directory"

  cp id_rsa.pub "/root/.ssh/id_rsa.pub"
  error_log "Unable to copy id_rsa.pub key to root .ssh directory"

  cat "/root/.ssh/id_rsa.pub" >> "/root/.ssh/authorized_keys"
  error_log "Unable to copy root id_rsa.pub to authorized_keys "

  chmod 700 "/root/.ssh"
  error_log "Unable to chmod root .ssh directory"

  chown -R "root:" "/root/.ssh"
  error_log "Unable to chown to root .ssh directory"

  chmod 400 "/root/.ssh/id_rsa"
  error_log "Unable to chmod root id_rsa file"

  chmod 644 "/root/.ssh/id_rsa.pub"
  error_log "Unable to chmod root id_rsa.pub file"

  chmod 400 "/root/.ssh/authorized_keys"
  error_log "Unable to chmod root authorized_keys file"
}

function install_packages()
{
log "Update System ..."
    until apt-get --yes update
    do
      log "Lock detected on apt-get while install Try again..."
      sleep 2
    done

    log "Install software-properties-common ..."
    until apt-get --yes install apt-transport-https ca-certificates wget curl unzip jq pwgen
    do
      log "Lock detected on apt-get while install Try again..."
      sleep 2
    done
}


function install_docker()
{
    log "Install Docker ..."

    curl -fsSL https://test.docker.com/ | sh

    log "activate experimental flag"
    echo '{ "experimental": true }' > /etc/docker/daemon.json

    log "restarting service"
    service docker restart

    usermod -aG docker "${ADMIN_USER}"

}

function get_application()
{
  log "Download docker-compose for application"
  mkdir -p "${ADMIN_HOME}/env"
  url="https://raw.githubusercontent.com/alterway/arm-prestashop-docker-cluster/master/docker/prestashop"

  curl -L "${url}/docker-compose.yml" -o "${ADMIN_HOME}/docker-compose.yml"
  curl -L "${url}/env/apache.env" -o "${ADMIN_HOME}/env/apache.env"
  curl -L "${url}/env/mysql.env" -o "${ADMIN_HOME}/env/mysql.env"
  curl -L "${url}/env/php.env" -o "${ADMIN_HOME}/env/php.env"
  curl -L "${url}/env/php-fpm.env" -o "${ADMIN_HOME}/env/php-fpm.env"

  chown "${ADMIN_USER}" "${ADMIN_HOME}/docker-compose.yml"
  chown -R "${ADMIN_USER}" "${ADMIN_HOME}/env"

}

function start_application()
{
  # environment
  MYSQL_REPLICATION_PASSWORD=$(pwgen -1 12 1)

  log "replication password is : ${MYSQL_REPLICATION_PASSWORD}"

  export MYSQL_REPLICATION_PASSWORD

  if [ "${INDEX}" = "1" ];then
    NODE1=$(docker node ls | awk '/Leader/ { print $3; }')
    NODE2=$(docker node ls | grep -v $NODE1 | grep -v HOSTNAME | awk '{ print $2; }')

    if [ "x$NODE2" = "x" ];then
       sleep 60
       NODE2=$(docker node ls | grep -v $NODE1 | grep -v HOSTNAME | awk '{ print $2; }')
    fi

    export NODE1 NODE2
    set_env

    docker deploy --compose-file "${ADMIN_HOME}/docker-compose.yml" prestashop
  fi
}

function install_docker_compose()
{
  log "Install docker-compose ..."
  curl -L "https://github.com/docker/compose/releases/download/1.9.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  docker-compose --version
}


function register_node()
{
   log "register node to consul"
   curl -X PUT -d "${IP}" http://${IPhc}:8500/v1/kv/nodes/${INDEX}/ip
   curl -X PUT -d "0" http://${IPhc}:8500/v1/kv/nodes/${INDEX}/state
   curl -X PUT -d "${nodeVmName}" http://${IPhc}:8500/v1/kv/nodes/${INDEX}/hostname

   ip=$(curl -s "http://${IPhc}:8500/v1/kv/nodes/${INDEX}/ip" | jq -r '.[0].Value' | base64 --decode)
   log "ipnode =$ip"

   state=$(curl -s "http://${IPhc}:8500/v1/kv/nodes/${INDEX}/state" | jq -r '.[0].Value' | base64 --decode)
   log "state =$state"

   hostname=$(curl -s "http://${IPhc}:8500/v1/kv/nodes/${INDEX}/hostname" | jq -r '.[0].Value' | base64 --decode)
   log "hostname =$hostname"

}

function get_sshkeys()
 {
    log "Get ssh keys from Consul"
    curl -s "http://${IPhc}:8500/v1/kv/ssh/id_rsa" | jq -r '.[0].Value' | base64 --decode > id_rsa
    error_log "Fails to Get id_rsa"
    curl -s "http://${IPhc}:8500/v1/kv/ssh/id_rsa.pub" | jq -r '.[0].Value' | base64 --decode > id_rsa.pub
    error_log "Fails to Get id_rsa"
}

function fix_etc_hosts()
{
  log "Add hostame and ip in hosts file ..."
  #IP=$(ip addr show eth0 | grep inet | grep -v inet6 | awk '{ print $2; }' | sed 's?/.*$??')
  HOST=$(hostname)
  echo "${IP}" "${HOST}" >> "${HOST_FILE}"
}

function myip()
{
  IP=$(ip addr show eth0 | grep inet | grep -v inet6 | awk '{ print $2; }' | sed 's?/.*$??')
  echo "${IP}"
}

function get_var()
{
  pos="${1}"
  var=$(echo "${VARS}" |cut -f$pos -d';')
  echo "${var}"
}

function set_env()
{
cat << _EOF_ > "${ADMIN_HOME}/env.sh"
export IP="${IP}"
export ADMIN_HOME="${ADMIN_HOME}"
export HOSTNAME="${HOSTNAME}"
export ADMIN_USER="${ADMIN_USER}"
export INDEX="${INDEX}"
export numberOfNodes="${numberOfNodes}"
export nodeSubnetRoot="${nodeSubnetRoot}"
export IPhc="${IPhc}"
export VARS="${VARS}"
export SHOPNAME="${SHOPNAME}"
export PRESTASHOP_FIRSTNAME="${PRESTASHOP_FIRSTNAME}"
export PRESTASHOP_LASTNAME="${PRESTASHOP_LASTNAME}"
export PRESTASHOP_EMAIL="${PRESTASHOP_EMAIL}"
export PRESTASHOP_PASSWORD="${PRESTASHOP_PASSWORD}"
export MYSQL_DATABASE="${MYSQL_DATABASE}"
export MYSQL_USER="${MYSQL_USER}"
export MYSQL_PASSWORD="${MYSQL_PASSWORD}"
export MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}"
export MYSQL_REPLICATION_USER="${MYSQL_REPLICATION_USER}"
export MYSQL_REPLICATION_PASSWORD="${MYSQL_REPLICATION_PASSWORD}"
export NODE1="${NODE1}"
export NODE2="${NODE2}"
_EOF_
}


function activate_swarm()
{
  if [ "${INDEX}" = "1" ];then
    token=$(docker swarm init | awk '/--token/{print $2;}')
    curl -X PUT -d "${token}" http://${IPhc}:8500/v1/kv/swarm/token
  else
    c=0
    while :
    do
      token=$(curl -s "http://${IPhc}:8500/v1/kv/swarm/token" | jq -r '.[0].Value' | base64 --decode)
      ipmanager=$(curl -s "http://${IPhc}:8500/v1/kv/nodes/1/ip" | jq -r '.[0].Value' | base64 --decode)
      if [ "x$token" = "x" ]; then
         sleep 60
         let c=${c}+1
         if [ "${c}" -gt 9 ]; then
           log "[ERROR] : Timeout to get token exiting ..."
           exit 1
         fi
      else
         break
      fi
    done
    log "Join Swarm manager on ${ipmanager}:2377 with token ${token}"
    docker swarm join --token "${token}" "${ipmanager}:2377"
  fi
}

log "Execution of Install Script from CustomScript ..."

## Variables

BASH_SCRIPT="${0}"
INDEX="${1}"
ADMIN_USER="${2}"
numberOfNodes="${3}"
nodeSubnetRoot="${4}"
nodeVmName="${5}"
IPhc="${6}"
VARS="${7}"

TERM=xterm
IP=$(myip)
HOST_FILE="/etc/hosts"
CWD="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
HOSTNAME=$(hostname)

export ADMIN_USER ADMIN_HOME IP TERM INDEX numberOfNodes nodeSubnetRoot IPhc BASH_SCRIPT HOSTNAME VARS

SHOPNAME=$(get_var 1)
PRESTASHOP_FIRSTNAME=$(get_var 2)
PRESTASHOP_LASTNAME=$(get_var 3)
PRESTASHOP_EMAIL=$(get_var 4)
PRESTASHOP_PASSWORD=$(get_var 5)
MYSQL_DATABASE=$(get_var 6)
MYSQL_USER=$(get_var 7)
MYSQL_PASSWORD=$(get_var 8)
MYSQL_ROOT_PASSWORD=$(get_var 9)
MYSQL_REPLICATION_USER=$(get_var 10)

export SHOPNAME PRESTASHOP_FIRSTNAME PRESTASHOP_LASTNAME PRESTASHOP_EMAIL PRESTASHOP_PASSWORD
export MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD MYSQL_ROOT_PASSWORD  MYSQL_REPLICATION_USER

echo "1:$ADMIN_USER 2:$ADMIN_HOME 3:$IP 4:$TERM 5:$INDEX 6:$numberOfNodes 7:$nodeSubnetRoot 8:$IPhc 9:$BASH_SCRIPT"
log "1:$ADMIN_USER 2:$ADMIN_HOME 3:$IP 4:$TERM 5:$INDEX 6:$numberOfNodes 7:$nodeSubnetRoot 8:$IPhc 9:$BASH_SCRIPT"

log "CustomScript Directory is ${CWD}"

##
env 
##

fix_etc_hosts
install_packages
register_node
get_sshkeys
ssh_config
ssh_config_root
install_docker
install_docker_compose
activate_swarm
get_application
start_application
log "Success : End of Execution of Install Script from CustomScript"

exit 0
