FROM golang:1.25-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/android-usage-receiver \
    ./cmd/android-usage-receiver

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/android-usage-receiver /android-usage-receiver

USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/android-usage-receiver"]
