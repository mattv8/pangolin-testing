FROM powerdns/dnsdist-18:latest
USER root
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
USER pdns
