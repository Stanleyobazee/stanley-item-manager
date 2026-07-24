FROM nginx:1.27-alpine

# Backend URL baked into index.html at build time, e.g.:
#   docker build --build-arg BACKEND_URL=http://<EC2_PUBLIC_IP>:30800 -t item-manager-frontend .
# Leave empty to call the backend at the same origin (e.g. behind a reverse proxy).
ARG BACKEND_URL=http://localhost:3000

COPY index.html /usr/share/nginx/html/index.html
RUN sed -i "s#__BACKEND_URL__#${BACKEND_URL}#g" /usr/share/nginx/html/index.html

COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
