###############################################################################
# 🚀 Dockerfile for Swagger UI with HTTPS support                             #
# This Dockerfile extends the official Swagger UI image to add HTTPS support  #
# using Nginx as a reverse proxy. It includes a custom entrypoint script that #
# waits for SSL certificates to be available and generates the Nginx          #
# configuration dynamically based on environment variables.                   #
###############################################################################

# Base image: The official Swagger UI image
FROM swaggerapi/swagger-ui:latest

# Metadata labels for the image
LABEL org.opencontainers.image.title="Swagger UI with HTTPS"
LABEL org.opencontainers.image.description="A Swagger UI instance configured to serve over HTTPS using Nginx as a reverse proxy."
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.maintainer="DevOps <devops@example.com>"

# Switch to root to configure the container
USER root

# 1. Prepare Directories
RUN mkdir -p /etc/nginx/ssl /etc/nginx/templates /docker-entrypoint.d

# 2. Remove the official template so it doesn't overwrite our custom configuration
RUN rm -f /etc/nginx/templates/default.conf.template

# 3. Copy custom configuration files (Crucial Step!)
# Copy the template to the path your script expects
COPY files/https.conf.template /etc/nginx/templates/default.conf.template

# Copy the script to the entrypoint directory
COPY files/00-envsubst-https-config.sh /docker-entrypoint.d/00-envsubst-https-config.sh

# 4. Set Permissions
RUN chmod +x /docker-entrypoint.d/00-envsubst-https-config.sh

# Optional: Ensure the nginx user can read the certs if not running as root
# (Though Swagger UI usually runs nginx as root/privileged)
