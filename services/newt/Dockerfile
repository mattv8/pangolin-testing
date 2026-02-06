# Newt Test Dockerfile
# Builds Newt from local source with DNS Authority and Auth Proxy features

FROM golang:1.25-alpine AS builder

# Install git, ca-certificates, and build tools
RUN apk --no-cache add ca-certificates git tzdata gcc musl-dev

# Set the working directory inside the container
WORKDIR /app

# Copy go mod and sum files
COPY go.mod go.sum ./

# Download all dependencies
RUN go mod download

# Copy the source code into the container
COPY . .

# Build the application with race detector for testing
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /newt

FROM alpine:3.23 AS runner

# Install runtime dependencies plus debugging tools
RUN apk --no-cache add \
    ca-certificates \
    tzdata \
    iputils \
    bind-tools \
    curl \
    tcpdump \
    net-tools \
    iproute2

COPY --from=builder /newt /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh

# Expose ports
EXPOSE 53/udp
EXPOSE 53/tcp
EXPOSE 2112
EXPOSE 8080
EXPOSE 8443

# Fix potential line ending issues and make executable
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
CMD ["newt"]
