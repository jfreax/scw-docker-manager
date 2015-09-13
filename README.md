##### List all running docker container of all running servers
```
scw-docker ps [OPTIONS]
  Optional arguments
    -a          show also inactive docker containers
```

##### List private ip of a server instance
```
scw-docker ip SERVER
```

##### Deploys a docker profile
```
scw-docker run SERVER PROFILE
```

##### Starts a new server and deploys a docker profile
```
scw-docker deploy SERVER PROFILE [OPTIONS]
  Optional arguments
    -m          Use mini image
```

##### Show logs of profile on a given server
```
scw-docker logs SERVER
```

##### List all available private images
```
scw-docker images
```

##### List all available docker profiles
```
scw-docker profiles
```

##### Installs a new system package on a started server
```
scw-docker install SERVER PACKAGE
```

##### Accept portage ~arm keyword for a given package
```
scw-docker accept_keyword PACKAGE
```

##### Updates the repository server and distributes the update to all minion servers
```
scw-docker update
```

##### Login to a given server via ssh
```
scw-docker ssh SERVER
```

##### Manage remote proxy configuration
```
scw-docker rproxy [add|del|activate|deactivate] [OPTIONS]
  Mandatory arguments
    -n NAME     name or ID of server
    -p PORT     listening port
    -d FQDN     fully qualified domain name
  Optional arguments
    -f FOLDER   subfolder for remote connection
    -s          use if remote connection uses ssl
    -i          use plain http
```
