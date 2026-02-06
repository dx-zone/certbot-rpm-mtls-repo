#!/usr/bin/bash
printf "To bring up the entire stuff alive"
printf "docker compose up --detach" 

printf "To force the rebuild of a container (useful when changes occur and you want to re-apply them)"
printf "docker compose up -d --build --force-recreate client-test"
