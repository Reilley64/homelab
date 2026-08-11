FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/observability-agent ./cmd/observability-agent

FROM alpine:3.23
RUN apk add --no-cache ca-certificates
COPY --from=build /out/observability-agent /usr/local/bin/observability-agent
ENTRYPOINT ["/usr/local/bin/observability-agent"]
