# The voice agent from voice/agent, with the Node runtime it needs.
FROM scratch AS build
COPY --from=node-toolchain / /node/
COPY --from=agent-source / /app/agent/
WORKDIR /app
RUN mkdir -p home tmp \
    && app_dir="$(pwd -P)" \
    && node="$(dirname "$app_dir")/node/bin/node" \
    && HOME="$app_dir/home" TMPDIR="$app_dir/tmp" \
       PATH="$(dirname "$node"):/usr/bin:/bin" \
       "$node" "$(dirname "$app_dir")/node/lib/node_modules/npm/bin/npm-cli.js" \
         ci --omit=dev --no-audit --no-fund --prefix "$app_dir/agent"
# The runtime extracts only regular files and directories, so resolve symlinks.
RUN rm -rf agent/node_modules/.bin \
    && cp -RL agent/node_modules agent/node_modules.flat \
    && rm -rf agent/node_modules home tmp \
    && mv agent/node_modules.flat agent/node_modules

FROM scratch
WORKDIR /app
COPY --from=launcher /launch ./bin/launch
COPY --from=node-toolchain /bin/node ./bin/node
COPY --from=build /app/agent/ ./agent/
COPY launch.json ./launch.json
EXPOSE 20083
ENTRYPOINT ["./bin/launch"]
