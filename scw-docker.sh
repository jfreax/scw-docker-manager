#!/bin/bash

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

function deploy {
  name=$2
  image=$3

  if [ -z $name ]; then
    echo "Missing arguments"
  fi

  if [ -z $image ]; then
    image=$name
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

  echo "Starting container"
  scw exec --gateway=edge ${id} \
    "cd ~/docker/${image}/; \
     if [ -f ./prepare.sh ]; then \
       ./prepare.sh; \
     fi; \
    docker-compose up -d"
  exit $?
}

function images {
  scw exec --gateway=edge repository "curl http://hub.jdsoft.de/v1/search" | jq '.results'
  exit $?
}

function profiles {
  scw exec --gateway=edge repository \
    "su - jens -c \"cd /home/jens/docker/; git pull > /dev/null 2> /dev/null \"; cd /home/jens/docker/; ls"
  exit 0
}

function install {
  name=$2
  package=$3
  if [ -z $name ] || [ -z $package]; then
    echo "Missing arguments"
  fi

  # Check if binary package is available
  scw exec --gateway=edge repository \
    "equery list '$package'; if [ $? ]; then emerge $package; fi"

  scw exec --gateway=edge $name \
    "emerge $package"
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
      echo "Starting update on $(scw inspect $id | jq ".[0].name")"
      scw exec --gateway=edge $id "eix-sync; emerge -uDN --with-bdeps=y --keep-going world" & > /dev/null 2> /dev/null
    done
  fi
}

function ssh {
  name=$2
  scw exec --gateway=edge $name /bin/bash
}

case $1 in
  ps)
    ps $@
    ;;
  deploy)
    deploy $@
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
  update)
    update $@
    ;;
  ssh)
    ssh $@
    ;;
  *)
    echo "Unknown command"
    exit 1
esac

