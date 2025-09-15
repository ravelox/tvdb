ARG NODE_VERSION=20.12.2-slim
FROM node:${NODE_VERSION}

WORKDIR /app

COPY package.json .
RUN npm install

COPY . .
RUN chmod +x docker-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["node","server.js"]
