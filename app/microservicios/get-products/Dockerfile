ARG BASE=public.ecr.aws/docker/library/node:20-alpine
FROM ${BASE}
WORKDIR /app
COPY package.json index.js ./
COPY node_modules ./node_modules
EXPOSE 3001
CMD ["node", "index.js"]
