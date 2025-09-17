ARG NODE_VERSION=20.12.2-slim
FROM node:${NODE_VERSION}

ARG APP_VERSION=0.0.0
ARG BUILD_NUMBER=0
LABEL org.opencontainers.image.version="${APP_VERSION}"
LABEL org.opencontainers.image.revision="${BUILD_NUMBER}"
ENV APP_VERSION=${APP_VERSION}
ENV BUILD_NUMBER=${BUILD_NUMBER}

WORKDIR /app

COPY package.json .
RUN npm install

COPY . .
RUN chmod +x docker-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["node","server.js"]
