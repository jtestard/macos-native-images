# The browser client from voice/web, as a Linux image for the Kind cluster.
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod main.go index.html ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -o /out/web .

FROM scratch
COPY --from=build /out/web /web
EXPOSE 20090
ENTRYPOINT ["/web", "-addr", "0.0.0.0:20090", "-livekit-url", "ws://localhost:30880"]
