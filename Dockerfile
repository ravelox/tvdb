FROM node:slim

WORKDIR /app

COPY package.json .
RUN npm install

COPY . .
RUN chmod +x docker-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["node","server.js"]
