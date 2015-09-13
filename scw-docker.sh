#!/bin/bash

ps_help="List all running docker container of all running servers"
function ps_usage {
  echo -e "$0 ps [OPTIONS]"
  #echo -e "## List all running docker container of all running servers"
  echo -e "  Optional arguments"
  echo -e "    -a\t\tshow also inactive docker containers"
}
function ps {
  if [ -z $2 ] && [ $2 = '-a' ]; then
    show_all=true
  else
    show_all=false
  fi

  ids=`scw ps -q`
  for id in $ids; do
    scw inspect server:${id} | jq ".[0].name"
    if [ ${show_all} = true ]; then
      scw exec --gateway="edge" $id docker ps -a
    else
      scw exec --gateway="edge" $id docker ps
    fi
  done
  exit 0
}

##############

ip_help="List private ip of a server instance"
function ip_usage {
  echo -e "$0 ip SERVER"
}
function ip {
  id="server:$2"
  scw inspect sever:${id} | jq ".[0].private_ip" | sed 's/"//g'
}

##############

start_help="Starts a new server"
function start_usage {
  echo -e "$0 start SERVER"
}
function start {
  name=$2

  scw run -d \
    --name="$name" \
    --gateway="edge" \
    --bootscript="4.1.6-docker #251" \
    user/minion
}

##############

run_help="Deploys a docker profile"
function run_usage {
  echo -e "$0 run SERVER PROFILE"
}
function run {
  id=$2
  profile=$3

  if [ -z $id ]; then
    echo "Missing arguments"
    exit 2
  fi

  if [ -z $profile ]; then
    profile=$id
  fi

  echo "Update repo infos"
  scw exec --gateway=edge ${id} \
    "cd ~/docker; git pull"
  scw exec --gateway=edge ${id} \
    "scp binpkguser@aafeac30-7cb2-4b13-9991-c63ce4bcbc10.priv.cloud.scaleway.com:/etc/portage/package.accept_keywords /etc/portage/package.accept_keywords"

  echo "Starting container"
  scw exec --gateway=edge ${id} \
    "cd ~/docker/${profile}/; \
     if [ -f ./prepare.sh ]; then \
       ./prepare.sh; \
     fi; \
     docker-compose up -d; \
     echo \"${profile}\" > ~/.scw-docker.deploy; \
     if [ -f ./post.sh ]; then \
       ./post.sh; \
     fi; "

  echo "Update metadata"
  tags=$(scw inspect server:${id} | jq -c ".[0].tags" | sed 's/"//g' | sed 's/,/ /g')
  tags=${tags:1:${#tags}-2}
  count=$(echo $tags | grep -c "profile=${profile}")
  if [ $count -eq 0 ]; then
    scw _patch server:${id} tags="${tags} profile=${profile}"
  fi
}

##############

deploy_help="Starts a new server and deploys a docker profile"
function deploy_usage { 
  echo -e "$0 deploy SERVER PROFILE [OPTIONS]"
  echo -e "  Optional arguments"
  echo -e "    -m\t\tUse mini image"
}
function deploy {
  name=$2
  profile=$3
  mini=${4:-false}

  if [ -z $name ]; then
    echo "Missing arguments"
    exit 2
  fi

  if [ -z $profile ]; then
    profile=$name
  fi

  image="user/minion"
  if [ $mini = "-m" ]; then
    image="user/mini-minion"
  fi

  # check if server with this name already exists
  check=$(scw ps -f name=${name} -q)
  if [ "$check" == "" ]; then # does not exist
    echo "Starting new server"
    id=`scw run -d \
      --name="$name" \
      --gateway="edge" \
      --bootscript="4.1.6-docker #251" \
      ${image}`

    echo "Configure server"
    echo -n "ID: "
    scw _patch ${id} tags="minion"

    # set hostname
    scw exec --wait --gateway=edge ${id} \
      "echo ${name} > /etc/hostname"
    # we have to reboot to actually load the hostname
    echo "Rebooting..."
    scw exec --gateway=edge ${id} "reboot"
    scw exec --wait --gateway=edge ${id} "echo \"Server up and running\"; uname -a" 2> /dev/null
    while [ $? -ne 0 ]; do # hack, because wait does not work on reboot
        scw exec --wait --gateway=edge ${id} "echo \"Server up and running\"; uname -a" 2> /dev/null
    done

  else # already exists
    echo -n "Server already exists. Redeploy? (y/n) "
    read yn
    if [ "$yn" != "y" ]; then
      exit 0
    fi 
  fi
  run _ ${id} ${profile}
}

##############

logs_help="Show logs of profile on a given server"
function logs_usage {
  echo -e "$0 logs SERVER"
}
function logs {
  id="server:$2"
  scw exec --gateway=edge ${id} \
    'if [ -f ~/.scw-docker.deploy ]; then cd ~/docker/$(cat ~/.scw-docker.deploy)/ && docker-compose logs; fi'
}

##############

images_help="List all available private images"
function images_usage {
  echo -e "$0 images"
}
function images {
  scw exec --gateway=edge repository "curl http://hub.jdsoft.de/v1/search" | jq '.results'
  exit $?
}

##############

profiles_help="List all available docker profiles"
function profiles_usage {
  echo -e "$0 profiles"
}
function profiles {
  scw exec --gateway=edge repository \
    "su - jens -c \"cd /home/jens/docker/; git pull > /dev/null 2> /dev/null \"; cd /home/jens/docker/; ls"
  exit 0
}

##############

install_help="Installs a new system package on a started server"
function install_usage {
  echo -e "$0 install SERVER PACKAGE"
}
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

##############

accept_keyword_help="Accept portage ~arm keyword for a given package"
function accept_keyword_usage {
  echo -e "$0 accept_keyword PACKAGE"
}
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

##############

update_help="Updates the repository server and distributes the update to all minion servers"
function update_usage {
  echo -e "$0 update"
}
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
      echo "Starting update on $(scw inspect server:$id | jq ".[0].name") (~/.scw-docker/emerge-update.$id.log)"
      nohup scw exec --gateway=edge $id "eix-sync; emerge -uDN --with-bdeps=y --keep-going world" & >> ~/.scw-docker/emerge-update.$id.log
    done
  fi
}

##############

ssh_help="Login to a given server via ssh"
function ssh_usage {
  echo -e "$0 ssh SERVER"
}
function ssh {
  name="server:$2"
  scw exec --gateway=edge $name /bin/bash
}

##############

rproxy_help="Manage remote proxy configuration"
function rproxy_usage { 
  echo -e "$0 rproxy [add|del|activate|deactivate] [OPTIONS]"
  echo -e "  Mandatory arguments"
  echo -e "    -n NAME\tname or ID of server"
  echo -e "    -p PORT\tlistening port"
  echo -e "    -d FQDN\tfully qualified domain name"
  echo -e "  Optional arguments"
  echo -e "    -f FOLDER\tsubfolder for remote connection"
  echo -e "    -s\t\tuse if remote connection uses ssl"
  echo -e "    -i\t\tuse plain http"
}
function rproxy {
  case $1 in
    add)
      shift
      while getopts "n:p:d:sf:i" o; do
        case "${o}" in
          n)
            name=${OPTARG}
            ;;
          p)
            port=${OPTARG}
            ;;
          d)
            fqdn=${OPTARG}
            ;;
          s)
            ssl=true
            ;;
          i)
            insecure=true
            ;;
          f)
            subfolder=${OPTARG}
            ;;
          *)
            exit 1
            echo -n "Usage: "
            rproxy_usage
            ;;
        esac
      done
      shift $((OPTIND-1))

      id="server:$name"

      if [ -z $name ] || [ -z $port ] || [ -z $fqdn ]; then
        echo "Missing arguments"
        echo -n "Usage: "
        rproxy_usage
        exit 2
      fi
      fqdn=$(echo $fqdn | sed 's/,/ /g')

      protocol="http"
      if [ "$ssl" = "true" ]; then
        protocol="https"
      fi

      echo "$name $fqdn $protocol $subfolder $port $insecure"
      exit

      # get private ip
      ip=$(scw inspect ${id} | jq ".[0].private_ip" | sed 's/"//g')

      if [ $insecure == true ]; then
        (cat <<EOF
server {
    listen 80;
    server_name ${fqdn};

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

        proxy_pass ${protocol}://${ip}:${port}/${subfolder};
    }
}
EOF
) > /tmp/scw-docker.$name.nginx.tmp
      else
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

        proxy_pass ${protocol}://${ip}:${port}/${subfolder};
    }
}
EOF
) > /tmp/scw-docker.$name.nginx.tmp
      fi
      #scw cp /tmp/scw-docker.$name.nginx.tmp edge:/etc/nginx/sites-available/${name}_${ip}
      scp /tmp/scw-docker.$name.nginx.tmp root@212.47.244.17:/etc/nginx/sites-available/${name}-${port}.conf
      scw exec server:edge "ln -sf /etc/nginx/sites-available/${name}-${port}.conf /etc/nginx/sites-enabled/"
      scw exec server:edge "/etc/init.d/nginx reload"
      ;;
    *)
      echo -n "Usage: "
      rproxy_usage
      exit 1
  esac
}

##############

function usage {
  echo -e "## $ps_help"
  ps_usage

  echo -e "\n## $ip_help"
  ip_usage

  echo -e "\n## $run_help"
  run_usage

  echo -e "\n## $deploy_help"
  deploy_usage

  echo -e "\n## $logs_help"
  logs_usage

  echo -e "\n## $images_help"
  images_usage

  echo -e "\n## $profiles_help"
  profiles_usage

  echo -e "\n## $install_help"
  install_usage

  echo -e "\n## $accept_keyword_help"
  accept_keyword_usage

  echo -e "\n## $update_help"
  update_usage

  echo -e "\n## $ssh_help"
  ssh_usage

  echo -e "\n## $rproxy_help"
  rproxy_usage
}

case $1 in
  ps)
    ps $@
    ;;
  ip)
    ip $@
    ;;
  run)
    run $@
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
    shift
    rproxy $@
    ;;
  *)
    #echo "Usage:"
    usage
    exit 1
esac
