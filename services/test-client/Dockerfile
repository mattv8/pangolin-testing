# Test Client Container
# Contains tools for testing DNS Authority and Auth Proxy

FROM alpine:3.23

# Install testing tools
RUN apk --no-cache add \
    bash \
    curl \
    wget \
    bind-tools \
    jq \
    tcpdump \
    net-tools \
    iproute2 \
    nmap \
    netcat-openbsd \
    lynx \
    python3 \
    py3-pip \
    openssl \
    ca-certificates

# Install httpie for better HTTP testing
RUN pip3 install --break-system-packages httpie requests

# Create results directory
RUN mkdir -p /results

# Set up custom resolv.conf (will be overridden by docker --dns)
COPY resolv.conf /etc/resolv.conf.custom

# Copy test utilities
COPY test-utils.sh /usr/local/bin/test-utils
RUN chmod +x /usr/local/bin/test-utils

WORKDIR /scripts

# Keep container running
CMD ["tail", "-f", "/dev/null"]
