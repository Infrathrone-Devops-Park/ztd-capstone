# syntax=docker/dockerfile:1

FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/catalog .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/catalog /catalog
USER nonroot:nonroot
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/catalog", "-healthcheck"]
ENTRYPOINT ["/catalog"]
