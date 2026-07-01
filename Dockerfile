FROM docker.io/library/node:24-slim@sha256:24dc26ef1e3c3690f27ebc4136c9c186c3133b25563ae4d7f0692e4d1fe5db0e AS dependencies
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable
RUN corepack prepare pnpm@11.1.1 --activate
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/readest-app/package.json ./apps/readest-app/
COPY patches/ ./patches/
COPY packages/ ./packages/
RUN --mount=type=cache,id=pnpm,sharing=locked,target=/pnpm/store pnpm install --frozen-lockfile
RUN test -f packages/foliate-js/vendor/pdfjs/annotation_layer_builder.css \
    && test -d packages/simplecc-wasm/dist/web \
    && test -f packages/js-mdict/src/index.ts \
    || { printf '\nERROR: Required git submodules are not initialized in the source directory.\nEnsure submodules are initialized before running docker build.\nRun: git submodule update --init packages/foliate-js packages/simplecc-wasm packages/js-mdict\n\n'; exit 1; }
RUN pnpm --filter @readest/readest-app setup-vendors

FROM docker.io/library/node:24-slim@sha256:24dc26ef1e3c3690f27ebc4136c9c186c3133b25563ae4d7f0692e4d1fe5db0e AS development-stage
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable
RUN corepack prepare pnpm@11.1.1 --activate
WORKDIR /app
COPY --from=dependencies /app /app
COPY . .
WORKDIR /app/apps/readest-app
EXPOSE 3000
ENTRYPOINT ["pnpm", "dev-web", "-H", "0.0.0.0"]

FROM docker.io/library/node:24-slim@sha256:24dc26ef1e3c3690f27ebc4136c9c186c3133b25563ae4d7f0692e4d1fe5db0e AS build
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable
RUN corepack prepare pnpm@11.1.1 --activate
WORKDIR /app
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_APP_PLATFORM=web
ARG NEXT_PUBLIC_API_BASE_URL
ARG NEXT_PUBLIC_OBJECT_STORAGE_TYPE
ARG NEXT_PUBLIC_STORAGE_FIXED_QUOTA
ARG NEXT_PUBLIC_TRANSLATION_FIXED_QUOTA
# Promote build-time ARGs to ENV so Next.js (next.config.mjs) and Serwist see
# them via process.env during `pnpm build-web`. Without this, NEXT_PUBLIC_APP_PLATFORM
# is undefined at build time, pwaDisabled defaults to true, service worker is
# never generated, and /sw.js returns 404 -> no offline support.
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_APP_PLATFORM=$NEXT_PUBLIC_APP_PLATFORM \
    NEXT_PUBLIC_API_BASE_URL=$NEXT_PUBLIC_API_BASE_URL \
    NEXT_PUBLIC_OBJECT_STORAGE_TYPE=$NEXT_PUBLIC_OBJECT_STORAGE_TYPE \
    NEXT_PUBLIC_STORAGE_FIXED_QUOTA=$NEXT_PUBLIC_STORAGE_FIXED_QUOTA \
    NEXT_PUBLIC_TRANSLATION_FIXED_QUOTA=$NEXT_PUBLIC_TRANSLATION_FIXED_QUOTA
COPY --from=dependencies /app/node_modules /app/node_modules
COPY --from=dependencies /app/apps/readest-app/node_modules /app/apps/readest-app/node_modules
COPY --from=dependencies /app/apps/readest-app/public/vendor /app/apps/readest-app/public/vendor
COPY --from=dependencies /app/packages/foliate-js/node_modules /app/packages/foliate-js/node_modules
COPY . .
WORKDIR /app/apps/readest-app
ENV NODE_OPTIONS="--max-old-space-size=6144"
RUN pnpm build-web && rm -rf .next/cache node_modules/.cache /app/.git && find . -name "*.map" -delete

FROM docker.io/library/node:24-slim@sha256:24dc26ef1e3c3690f27ebc4136c9c186c3133b25563ae4d7f0692e4d1fe5db0e AS production-stage
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable
RUN corepack prepare pnpm@11.1.1 --activate
WORKDIR /app
COPY --from=build /app /app
WORKDIR /app/apps/readest-app
ENTRYPOINT ["pnpm", "start-web", "-H", "0.0.0.0"]
EXPOSE 3000
