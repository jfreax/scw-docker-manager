#!/bin/bash

##
# List all running docker container of all running servers
##
function ps {
  if [ $2 = '-a' ]; then
    show_all=true
  else
    show_all=false
  fi

  ids=`scw ps -q`
  for id in $ids; do
    scw inspect $id | jq ".[0].name"
    if [ $show_all = true ]; then
      scw exec --gateway="edge" $id docker ps -a
    else
      scw exec --gateway="edge" $id docker ps
    fi
  done
  exit 0
}

##
# Starts a new server and deploys a docker profile
#
# Arguments: <server-name> <deployment-profile>
##
function deploy {
  name=$2
  profile=$3

  if [ -z $name ]; then
    echo "Missing arguments"
  fi

  if [ -z $profile ]; then
    profile=$name
  fi

  echo "Starting new server"
  id=`scw run -d \
    --name="$name" \
    --gateway="edge" \
    --bootscript="4.1.6-docker #251" \
    user/minion`

  echo "Configure server"
  scw _patch ${id} tags="minion"
  scw exec --wait --gateway=edge ${id} \
  	"echo ${name} > /etc/hostname"
  scw exec --gateway=edge ${id} \
    "cd ~/docker; git pull" 
  scw cp --gateway=edge \
    server:repository:/etc/portage/package.accept_keywords ${id}:/etc/portage/package.accept_keywords

  echo "Starting container"
  scw exec --gateway=edge ${id} \
    "cd ~/docker/${profile}/; \
     if [ -f ./prepare.sh ]; then \
       ./prepare.sh; \
     fi; \
     docker-compose up -d; \
     echo \"${profile}\" > ~/.scw-docker.deploy"
  exit $?
}

##
# Show logs of profile on a given server
#
# Arguments: <server name or id>
##
function logs {
  id="server:$2"
  scw exec --gateway=edge ${id} \
    'if [ -f ~/.scw-docker.deploy ]; then cd ~/docker/$(cat ~/.scw-docker.deploy)/ && docker-compose logs; fi'
}

##
# List all available private images
##
function images {
  scw exec --gateway=edge repository "curl http://hub.jdsoft.de/v1/search" | jq '.results'
  exit $?
}

##
# List all available docker profiles
##
function profiles {
  scw exec --gateway=edge repository \
    "su - jens -c \"cd /home/jens/docker/; git pull > /dev/null 2> /dev/null \"; cd /home/jens/docker/; ls"
  exit 0
}

##
# Installs a new system package on a started server
#
# Arguments: <server-name or id> <package name>
## 
function install {
  id="server:$2"
  package=$3
  if [ -z $id ] || [ -z $package ]; then
    echo "Missing arguments"
  fi

  # Check if binary package is available
  scw exec --gateway=edge repository \
    "~/install_pkg.sh $package"

  if [ $? -eq 0 ]; then
    scw exec --gateway=edge $id \
      "emerge $package"
  else
  	echo "Error: Cannot install package."
  fi
}

##
#
##
function accept_keyword {
  package=$2

  ids=`scw ps -q`
  for id in $ids; do
    scw exec --gateway=edge ${id} \
      "echo ${package} ~arm >> /etc/portage/package.accept_keywords"
  done

  scw exec --gateway=edge server:repository \
    "echo ${package} ~arm >> /srv/gentoo-build/etc-portage/package.accept_keywords"
}

##
# Updates the system on all servers
##
function update {
  pid=$(scw exec --gateway=edge repository "docker exec gentoobuild_genoo-build_1 pgrep emerge")
  if [ ! -z "$pid" ]; then
  	echo "Update already in progress..."
  	scw exec --gateway=edge repository "docker exec gentoobuild_genoo-build_1 genlop -c"
  else
  	echo "Start emerging..."
    scw exec --gateway=edge repository \
      "docker exec gentoobuild_genoo-build_1 bash -c \"source ~/.bashrc; eix-sync\""
    scw exec --gateway=edge repository \
      "echo -------- $(date) -------- >> /var/log/emerge-update.log"
    scw exec --gateway=edge repository \
      "docker exec -d gentoobuild_genoo-build_1 emerge -uDN --with-bdeps=y --keep-going world >> /var/log/emerge-update.log"

    ids=`scw ps -q`
    for id in $ids; do
      echo "Starting update on $(scw inspect $id | jq ".[0].name") (~/.scw-docker/emerge-update.$id.log)"
      nohup scw exec --gateway=edge $id "eix-sync; emerge -uDN --with-bdeps=y --keep-going world" & >> ~/.scw-docker/emerge-update.$id.log
    done
  fi
}

##
# Start a ssh connection to a given server
#
# Arguments: <server name or id>
##
function ssh {
  name="server:$2"
  scw exec --gateway=edge $name /bin/bash
}

##
# Manage remote proxy configuration
##
function rproxy {
  case $2 in
    add)
      name=$3
      id="server:$name"
      port=$4
      fqdns=$5
      ssl=$6
      if [ -z $name ] || [ -z $port ] || [ -z $fqdns ]; then
      	echo "Missing arguments"
      	exit 2
      fi
      fqdn=$(echo $5 | sed 's/,/ /g')

      protocol="http"
      if [ "$ssl" = "true" ]; then
      	protocol="https"
      fi

      ip=$(scw inspect ${id} | jq ".[0].private_ip" | sed 's/"//g')

      (cat <<EOF
server {
   access_log /var/log/nginx/${name}.log;
   error_log /var/log/nginx/${name}.error.log;

   listen 80;
   server_name ${fqdn};
   return 301 https://\$server_name\$request_uri;  # enforce https
}

server {
    listen 443 ssl;
    server_name ${fqdn};
    ssl on;

    ssl_certificate             /opt/ssl/bundle.cer;
    ssl_certificate_key         /opt/ssl/privkey.pem;
    ssl_protocols               TLSv1 TLSv1.1 TLSv1.2;
    ssl_prefer_server_ciphers   on; 
    ssl_ciphers                 "EECDH+AESGCM EDH+AESGCM EECDH -RC4 EDH -CAMELLIA -SEED !aNULL !eNULL !LOW !3DES !MD5 !EXP !PSK !SRP !DSS !RC4";

    # Add HSTS
    add_header Strict-Transport-Security "max-age=31536000; includeSubdomains";

    access_log /var/log/nginx/${name}.log;
    error_log /var/log/nginx/${name}.error.log;

    location / {
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host   \$http_host;
        proxy_read_timeout      300;
        proxy_set_header        X-Forwarded-Proto https;
        proxy_set_header        Host \$http_host;
        add_header              Front-End-Https   on;

        proxy_pass ${protocol}://${ip}:${port};
    }
}
EOF
) > /tmp/scw-docker.$name.nginx.tmp
      #scw cp /tmp/scw-docker.$name.nginx.tmp edge:/etc/nginx/sites-available/${name}_${ip}
      scp /tmp/scw-docker.$name.nginx.tmp root@212.47.244.17:/etc/nginx/sites-available/${name}_${ip}
      scw exec server:edge "ln -s /etc/nginx/sites-available/${name}_${ip} /etc/nginx/sites-enabled/"
      scw exec server:edge "/etc/init.d/nginx reload"
      ;;
    *)
      echo "Unknown sub command"
      exit 1
  esac
}

case $1 in
  ps)
    ps $@
    ;;
  deploy)
    deploy $@
    ;;
  logs)
    logs $@
    ;;
  images)
    images $@
    ;;
  profiles)
    profiles $@
    ;;
  install)
    install $@
    ;;
  accept_keyword)
    accept_keyword $@
    ;;
  update)
    update $@
    ;;
  ssh)
    ssh $@
    ;;
  rproxy)
    rproxy $@
    ;;
  *)
    echo "Unknown command"
    exit 1
esac

