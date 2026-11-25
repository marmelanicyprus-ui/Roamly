FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY index.mjs ./
ENV NODE_NO_WARNINGS=1 DATA_DIR=/data
EXPOSE 8080
CMD ["node", "index.mjs"]
