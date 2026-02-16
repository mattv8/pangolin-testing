# Pangolin Test Dockerfile
# Sets up Pangolin for local development/testing with PostgreSQL

FROM node:22-alpine

WORKDIR /app

# Install dependencies needed for healthcheck
RUN apk --no-cache add curl

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci

# Copy source code
COPY . .

# Set up for OSS build with PostgreSQL
RUN echo 'export const build = "oss" as "saas" | "enterprise" | "oss";' > server/build.ts
RUN cp tsconfig.oss.json tsconfig.json

# Set up for PostgreSQL database
RUN printf 'export * from "./pg";\nexport const driver: "pg" | "sqlite" = "pg";\n' > server/db/index.ts
RUN cp drizzle.pg.config.ts drizzle.config.ts
RUN cp server/setup/migrationsPg.ts server/setup/migrations.ts

# Generate database migrations
RUN npm run db:generate

# Expose ports (Next.js, API, WebSocket)
EXPOSE 3000 3001 3002

# Run database push then start dev server
CMD ["sh", "-c", "npm run db:push && npm run dev"]
