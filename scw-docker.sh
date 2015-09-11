#!/bin/bash

function ps {
  if [ -z $2 ]; then
  	show_all=false
  else
  	show_all=true
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
  	"echo ${id} > /etc/hostname"
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
  *)
    echo "Unknown command"
    exit 1
esac

