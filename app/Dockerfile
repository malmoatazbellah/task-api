FROM node:24-alpine AS builder

WORKDIR /app

COPY package*.json ./

RUN npm ci --omit=dev && npm cache clean --force


FROM node:24-alpine

ENV NODE_ENV=production PORT=3000

WORKDIR /app

COPY --from=builder --chown=node:node /app/node_modules ./node_modules

COPY --chown=node:node package.json ./

COPY --chown=node:node src ./src

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s CMD ["wget", "-qO-", "http://localhost:3000/healthz"]

CMD ["node", "src/server.js"]
