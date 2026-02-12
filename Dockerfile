FROM python:3.11-slim

# Install required system packages
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /action

# Copy entrypoint script
COPY entrypoint.sh /action/entrypoint.sh

# Make entrypoint executable and ensure Unix line endings
RUN chmod +x /action/entrypoint.sh && \
    sed -i 's/\r$//' /action/entrypoint.sh

# Set entrypoint
ENTRYPOINT ["/action/entrypoint.sh"]
