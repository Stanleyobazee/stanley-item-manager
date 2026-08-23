FROM nginx:1.27-alpine

# Backend URL baked into index.html at build time. Leave empty (the default) to call
# the backend at the same origin — nginx.conf proxies /api/ to the backend Service
# internally, which is what k8s deployments (CI-built images) rely on. Only pass a
# real value for standalone `docker run` testing without Kubernetes, e.g.:
#   docker build --build-arg BACKEND_URL=http://localhost:3000 -t item-manager-frontend .
ARG BACKEND_URL=

COPY index.html /usr/share/nginx/html/index.html
RUN sed -i "s#__BACKEND_URL__#${BACKEND_URL}#g" /usr/share/nginx/html/index.html

COPY nginx.conf /etc/nginx/conf.d/default.conf

# nginx:1.27-alpine's own ENTRYPOINT already runs every executable script in
# /docker-entrypoint.d/ before starting nginx — dropping ours here instead of
# overriding ENTRYPOINT ourselves, so we extend the base image's startup instead of
# replacing it.
COPY resolve-dns.sh /docker-entrypoint.d/40-resolve-dns.sh
RUN chmod +x /docker-entrypoint.d/40-resolve-dns.sh

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
