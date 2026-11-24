FROM node:20-alpine
WORKDIR /app
COPY package.json index.js ./
COPY node_modules ./node_modules
EXPOSE 3001
CMD ["node", "index.js"]
