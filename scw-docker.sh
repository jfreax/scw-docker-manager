#!/bin/bash

######## ps ########

ps_help="List all running docker container of all running servers"
function ps_usage {
  echo -e "$0 ps [OPTIONS]"
  #echo -e "## List all running docker container of all running servers"
  echo -e "  Optional arguments"
  echo -e "    -a\t\tshow also inactive docker containers"
}
function ps {
  if [ -z "${2}" ] && [ $2 = '-a' ]; then
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

######## IP ########

ip_help="List private ip of a server instance"
function ip_usage {
  echo -e "$0 ip SERVER"
}
function ip {
  id="server:$2"
  scw inspect ${id} | jq ".[0].private_ip" | sed 's/"//g'
}

######## Start ########

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

######## Run ########

run_help="Deploys a docker profile"
function run_usage {
  echo -e "$0 run SERVER PROFILE [OPTIONS]"
  echo -e "  Optional arguments"
  echo -e "    -p\t\tscript to start before starting container"
}
function run {
  id=$1
  shift
  profile=$1

  if [ -z "${id}" ]; then
    echo "Missing arguments"
    echo -n "Usage:"
    run_usage
    exit 2
  fi

  if [ -z "${profile}" ]; then
    profile=${id}
  else
    shift
  fi

  echo $@
  while getopts "p:" o; do
    case "${o}" in
      p)
        prepare=${OPTARG}
        ;;
      *)
        echo -n "Usage: "
        run_usage
        exit 1
        ;;
    esac
  done
  shift $((OPTIND-1))

  # Run local prepare script
  if [ ! -z "${prepare}" ]; then
    ${prepare} ${id}
  fi

  echo ">>> Update repo infos"
  scw exec --gateway=edge ${id} \
    "cd ~/docker; git pull"
  scw exec --gateway=edge ${id} \
    "scp binpkguser@aafeac30-7cb2-4b13-9991-c63ce4bcbc10.priv.cloud.scaleway.com:/etc/portage/package.accept_keywords /etc/portage/package.accept_keywords"

  echo ">>> Starting container"
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

  echo ">>> Update metadata"
  tags=$(scw inspect server:${id} | jq -c ".[0].tags" | sed 's/"//g' | sed 's/,/ /g')
  tags=${tags:1:${#tags}-2}
  count=$(echo $tags | grep -c "profile:${profile}")
  if [ $count -eq 0 ]; then
    scw _patch server:${id} tags="${tags} profile:${profile}"
  fi
}

######## Deploy ########

deploy_help="Starts a new server and deploys a docker profile"
function deploy_usage { 
  echo -e "$0 deploy SERVER PROFILE [OPTIONS]"
  echo -e "  Optional arguments"
  echo -e "    -m\t\tuse mini image"
  echo -e "    -p\t\tscript to execute before starting container"
}
function deploy {
  name=$1
  shift
  if [[ $1 != -* ]]; then
    profile=$1
    shift
  fi

  if [ -z $name ]; then
    echo "Missing arguments"
    echo -n "Usage: "
    deploy_usage
    exit 2
  fi

  if [ -z $profile ]; then
    profile=$name
  fi

  mini=false
  while getopts "mp:" o; do
    case "${o}" in
      m)
        mini=true
        ;;
      p)
        prepare=${OPTARG}
        ;;
      *)
        echo -n "Usage: "
        deploy_usage
        exit 1
        ;;
    esac
  done
  shift $((OPTIND-1))

  image="user/minion"
  if [ $mini = true ]; then
    image="user/mini-minion"
  fi

  # check if server with this name already exists
  check=$(scw ps -f name=${name} -q)
  if [ "$check" == "" ]; then # does not exist
    echo ">>> Starting new server"
    id=`scw run -d \
      --name="$name" \
      --gateway="edge" \
      --bootscript="4.2-docker #253" \
      ${image}`

    if [ $? -ne 0 ]; then
      echo "Error creating new server"
      exit 4
    fi

    echo ">>> Configure server"
    echo -n "ID: "
    scw _patch ${id} tags="minion"

    if [ $? -ne 0 ]; then
      echo "Error creating new server"
      exit 5
    fi

    # change ipa config files
    scw exec --wait --gateway=edge ${id} \
      "/root/deploy.sh ${name}"

    # we have to reboot to actually load the hostname
    echo ">>> Issue reboot..."
    scw exec --gateway=edge ${id} "reboot"

    # register new host on ipa
    echo ">>> Register new IPA client"
    ip=$(scw inspect ${id} | jq ".[0].private_ip" | sed 's/"//g')
    scw exec --gateway=edge server:78e6b719-6cc4-4a08-9cc8-bb36f5bda824 "/root/add_host.sh ${name} ${ip}"

    echo ">>> Wait for client reboot"
    scw exec --wait --gateway=edge ${id} "echo \">>> Server up and running\"; uname -a" 2> /dev/null
    while [ $? -ne 0 ]; do # hack, because wait does not work on reboot
        scw exec --wait --gateway=edge ${id} "echo \">>> Server up and running\"; uname -a" 2> /dev/null
    done

    echo ">>> Starting sssd"
    scw exec --gateway=edge ${id} "/etc/init.d/sssd start"
    scw exec --gateway=edge ${id} "rc-update add sssd default"

  else # already exists
    echo -n "Server already exists. Redeploy? (y/n) "
    read yn
    if [ "$yn" != "y" ]; then
      exit 0
    fi 
  fi

  run ${name} ${profile} `if [ ! -z "${prepare}" ]; then echo "-p ${prepare}"; fi`
}

######## Logs ########

logs_help="Show logs of profile on a given server"
function logs_usage {
  echo -e "$0 logs SERVER"
}
function logs {
  id="server:$2"
  scw exec --gateway=edge ${id} \
    'if [ -f ~/.scw-docker.deploy ]; then cd ~/docker/$(cat ~/.scw-docker.deploy)/ && docker-compose logs; fi'
}

######## Images ########

images_help="List all available private images"
function images_usage {
  echo -e "$0 images"
}
function images {
  scw exec --gateway=edge hub "curl http://hub.jdsoft.de/v1/search" | jq '.results'
  exit $?
}

######## Profiles ########

profiles_help="List all available docker profiles"
function profiles_usage {
  echo -e "$0 profiles"
}
function profiles {
  scw exec --gateway=edge hub \
    "su - jens -c \"cd /home/jens/docker/; git pull > /dev/null 2> /dev/null \"; cd /home/jens/docker/; ls"
  exit 0
}

######## Install ########

install_help="Installs a new system package on a started server"
function install_usage {
  echo -e "$0 install SERVER PACKAGE"
}
function install {
  server="server:$1"
  package=$2

  if [ -z "${server}" ] || [ -z "${package}" ]; then
    echo "Missing arguments"
    install_usage
    exit 1
  fi


  # Check if binary package is available
  scw exec --gateway=edge hub \
    "~/install_pkg.sh $package"

  if [ $? -eq 0 ]; then
    ids="${server}"
    if [ "${server}" = "server:-a" ]; then
      ids=`scw ps -q`
    fi
    for id in $ids; do
      tags=$(scw inspect server:${id} | jq -c ".[0].tags" | sed 's/"//g' | sed 's/,/ /g')
      tags=${tags:1:${#tags}-2}
      count=$(echo $tags | grep -c "minion")
      if [ $count -gt 0 ]; then
        echo -e "\nStart installation on ${id}"
        scw exec --gateway=edge ${id} \
          "emerge -uDN $package"
      fi
    done
  else
    echo "Error: Cannot install package."
  fi
}

######## Accept keyword ########

accept_keyword_help="Accept portage ~arm keyword for a given package"
function accept_keyword_usage {
  echo -e "$0 accept_keyword PACKAGE [KEYWORD]"
}
function accept_keyword {
  package=$2
  keyword=$3

  if [ -z "${keyword}" ]; then
    keyword="~arm"
  fi

  ids=`scw ps -q`
  for id in $ids; do
    tags=$(scw inspect server:${id} | jq -c ".[0].tags" | sed 's/"//g' | sed 's/,/ /g')
    tags=${tags:1:${#tags}-2}
    count=$(echo $tags | grep -c "minion")
    if [ $count -gt 0 ]; then
      scw exec --gateway=edge ${id} \
        "echo ${package} ${keyword} >> /etc/portage/package.accept_keywords"
    fi
  done

  scw exec --gateway=edge server:hub \
    "echo ${package} ${keyword} >> /srv/gentoo-build/etc-portage/package.accept_keywords"
}

######## Use flag ########

use_flag_help="Manage use flag for portage packages"
function use_flag_usage {
  echo -e "$0 use_flag PACKAGE FLAG"
}
function use_flag {
  package=$2
  use_flag=$3

  ids=`scw ps -q`
  for id in $ids; do
    tags=$(scw inspect server:${id} | jq -c ".[0].tags" | sed 's/"//g' | sed 's/,/ /g')
    tags=${tags:1:${#tags}-2}
    count=$(echo $tags | grep -c "minion")
    if [ $count -gt 0 ]; then
      scw exec --gateway=edge ${id} \
        "echo ${package} ${use_flag} >> /etc/portage/package.use"
    fi
  done

  scw exec --gateway=edge server:hub \
    "echo ${package} ${use_flag} >> /srv/gentoo-build/etc-portage/package.use"
}

####### Update ########

update_help="Updates the hub server and distributes the update to all minion servers"
function update_usage {
  echo -e "$0 update"
}
function update {
  pid="$(scw exec --gateway=edge hub "docker exec gentoobuild_genoo-build_1 pgrep emerge || echo -n")"
  if [ ! -z "$pid" ]; then
    echo "Update already in progress..."
    scw exec --gateway=edge hub "docker exec gentoobuild_genoo-build_1 genlop -c"
  else
    echo ">>> Update repository info..."
    scw exec --gateway=edge hub \
      "docker exec gentoobuild_genoo-build_1 bash -c \"source ~/.bashrc; emerge-webrsync; eix-update\""

    echo ">>> Start emerging..."
    scw exec --gateway=edge hub \
      "echo -------- $(date) -------- >> /var/log/emerge-update.log"
    scw exec --gateway=edge hub \
      "docker exec -d gentoobuild_genoo-build_1 emerge -uDN --with-bdeps=y --keep-going world >> /var/log/emerge-update.log"

    ids=`scw ps -q`
    for id in $ids; do
      echo "Starting update on $(scw inspect server:$id | jq ".[0].name") (~/.scw-docker/emerge-update.$id.log)"
      nohup scw exec --gateway=edge $id "eix-sync; emerge -uDN --with-bdeps=y --keep-going world" >> ~/.scw-docker/emerge-update.$id.log &
    done
  fi
}

######## SSH ########

ssh_help="Login to a given server via ssh"
function ssh_usage {
  echo -e "$0 ssh SERVER"
}
function ssh {
  name="server:$2"
  scw exec --gateway=edge $name /bin/bash
}

######## Reverse proxy ########

rproxy_help="Manage remote proxy configuration"
function rproxy_usage { 
  echo -e "$0 rproxy [add|del|activate|deactivate] [OPTIONS]"
  echo -e "  Mandatory arguments"
  echo -e "    -s SERVER\tname or ID of server"
  echo -e "    -p PORT\tlistening port"
  echo -e "    -d FQDN\tfully qualified domain name"
  echo -e "  Optional arguments"
  echo -e "    -n NAME\tservice name"
  echo -e "    -f FOLDER\tsubfolder for remote connection"
  echo -e "    -t\t\tuse if remote connection uses ssl"
  echo -e "    -i\t\tuse plain http"
}
function rproxy {
  subcommand=$1
  shift

  while getopts "s:p:d:tf:in:" o; do
    case "${o}" in
      s)
        server=${OPTARG}
        ;;
      p)
        port=${OPTARG}
        ;;
      d)
        fqdn=${OPTARG}
        ;;
      t)
        ssl=true
        ;;
      i)
        insecure=true
        ;;
      f)
        subfolder=${OPTARG}
        ;;
      n)
        name=${OPTARG}
        ;;
      *)
        echo -n "Usage: "
        rproxy_usage
        exit 1
        ;;
    esac
  done
  shift $((OPTIND-1))

  if [ -z "${name}" ]; then
    name=$port
  fi

  case $subcommand in
    add)
      id="server:${server}"

      if [ -z $server ] || [ -z $port ] || [ -z $fqdn ]; then
        echo "Missing arguments"
        echo -n "Usage: "
        rproxy_usage
        exit 2
      fi
      fqdn=$(echo ${fqdn} | sed 's/,/ /g')

      protocol="http"
      if [ "${ssl}" = "true" ]; then
        protocol="https"
      fi

      # get private ip
      ip=$(scw inspect ${id} | jq ".[0].private_ip" | sed 's/"//g')

      if [ "${insecure}" = true ]; then
        (cat <<EOF
server {
    listen 80;
    server_name ${fqdn};

    access_log /var/log/nginx/${server}_${name}.log;
    error_log /var/log/nginx/${server}_${name}.error.log;

    location / {
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host   \$http_host;
        proxy_read_timeout      300;
        proxy_set_header        X-Forwarded-Proto https;
        proxy_set_header        Host \$http_host;
        add_header              Front-End-Https   on;

        proxy_pass ${protocol}://${server}.jdsoft.de:${port}/${subfolder};
    }
}
EOF
) > /tmp/scw-docker.${server}_${name}.nginx.tmp
      else
        (cat <<EOF
server {
   access_log /var/log/nginx/${server}_${name}.log;
   error_log /var/log/nginx/${server}_${name}.error.log;

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

    access_log /var/log/nginx/${server}_${name}.log;
    error_log /var/log/nginx/${server}_${name}.error.log;

    location / {
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host   \$http_host;
        proxy_read_timeout      300;
        proxy_set_header        X-Forwarded-Proto https;
        proxy_set_header        Host \$http_host;
        add_header              Front-End-Https   on;

        proxy_pass ${protocol}://${server}.jdsoft.de:${port}/${subfolder};
    }
}
EOF
) > /tmp/scw-docker.${server}_${name}.nginx.tmp
      fi
      scp /tmp/scw-docker.${server}_${name}.nginx.tmp root@212.47.244.17:/etc/nginx/sites-available/${server}_${name}.conf
      scw exec server:edge "ln -sf /etc/nginx/sites-available/${server}_${name}.conf /etc/nginx/sites-enabled/"
      ;;

    del)
      scw exec server:edge "rm /etc/nginx/sites-available/${server}_${name}.conf"
      scw exec server:edge "rm /etc/nginx/sites-enabled/${server}_${name}.conf"
      ;;
    *)
      echo -n "Usage: "
      rproxy_usage
      exit 1
  esac

  # Reload nginx config
  scw exec server:edge "/etc/init.d/nginx reload"
}

######## MAIN ########

function usage {
  echo -e "Usage: $0 <command> [arguments]\n"
  echo -e "The following commands are available:"
  echo -e "    ps\t\t\t $ps_help"
  echo -e "    ip\t\t\t $ip_help"
  echo -e "    run\t\t\t $run_help"
  echo -e "    deploy\t\t $deploy_help"
  echo -e "    logs\t\t $logs_help"
  echo -e "    images\t\t $images_help"
  echo -e "    profiles\t\t $profiles_help"
  echo -e "    install\t\t $install_help"
  echo -e "    accept_keyword\t $accept_keyword_help"
  echo -e "    use_flag\t $use_flag_help"
  echo -e "    update\t\t $update_help"
  echo -e "    ssh\t\t\t $ssh_help"
  echo -e "    rproxy\t\t $rproxy_help"
}

case $1 in
  ps)
    ps $@
    ;;
  ip)
    ip $@
    ;;
  run)
    shift
    run $@
    ;;
  deploy)
    shift
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
    shift
    install $@
    ;;
  accept_keyword)
    accept_keyword $@
    ;;
  use_flag)
    use_flag $@
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
