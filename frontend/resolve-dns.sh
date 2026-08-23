#!/bin/sh
set -e

# Picks up whatever DNS server Kubernetes actually injected for this pod, so nginx.conf's
# resolver works regardless of cluster (Minikube, EKS, ...) without hardcoding any one
# cluster's CoreDNS ClusterIP. Falls back to Docker's embedded resolver so standalone
# `docker run` (no /etc/resolv.conf nameserver line, or run outside Kubernetes entirely)
# still starts nginx successfully — see nginx.conf/Dockerfile comments on that path.
RESOLVER=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
RESOLVER=${RESOLVER:-127.0.0.11}
sed -i "s/__RESOLVER__/$RESOLVER/" /etc/nginx/conf.d/default.conf
