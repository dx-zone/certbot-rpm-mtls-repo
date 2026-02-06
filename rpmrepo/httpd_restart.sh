#!/usr/bin/env bash
# Restart HTTPD gracefully
docker exec rpmrepo httpd -k graceful
