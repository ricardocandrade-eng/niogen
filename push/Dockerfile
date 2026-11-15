# NIOGEN | push/Dockerfile | 15/11/2026 — Claude Code. Imagem do niogen-push (Node 20 + web-push 3.6.7).
FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force
COPY servidor.js ./
USER node
CMD ["node", "servidor.js"]
