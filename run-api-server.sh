#!/bin/bash
# This script is responsible for launching the API server that will handle certificate management and mTLS authentication for the RPM repository. It loads necessary environment variables from the .env file, ensures that required files for client authentication are created, and then starts the API server with the appropriate TLS configuration.

# Load environment variables from the .env file. This file should contain all the necessary configuration for the API server, including paths to TLS certificates, client authentication files, and other relevant settings. If the .env file is missing, the script will exit with an error message to prevent misconfiguration.
if [ ! -f .env ]; then
  echo "Error: .env file not found. Please create a .env file with the necessary configuration."
  exit 1
fi
source .env

# Ensure that the files for mTLS client authentication exist. The API server will use these files to verify the identity of clients that connect to it. If these files do not exist, the script will create them as empty files. This is important for the proper functioning of the API server, as it relies on these files to manage client access and ensure secure communication.
echo "${CLIENT_NAME}" > ${API_MTLS_CLIENTS_FILE}

# The API server will use the ${API_MTLS_CLIENTS_FILE} to determine which clients are allowed to connect to it. By writing the CLIENT_NAME to this file, we are effectively allowing that client to authenticate with the API server using mTLS. Make sure that the CLIENT_NAME variable is set correctly in the .env file, and that the corresponding client certificate is properly configured for mTLS authentication.
create_files() {
  touch ${API_MTLS_CLIENTS_FILE}
  touch ${API_MTLS_IPS_FILE}
}

# Launch the API
# NOTE: mTLS material in .env is pointing to the same mTLS material to access the RPM repository. This is intentional, as the API server needs to authenticate itself to the RPM repository using mTLS, and it also needs to authenticate clients that connect to it using mTLS. By using the same mTLS material for both purposes, we can simplify the configuration and ensure that the API server can securely communicate with both the RPM repository and its clients.
# Consider generating separate mTLS material for the API server to avoid potential security risks and to follow best practices for secure communication. This would involve creating a separate client certificate for the API server to use when authenticating with the RPM repository, and a separate set of client certificates for clients that connect to the API server. This way, you can have better control over access and improve the overall security of your system.
# TODO: Implement separate mTLS material for the API server and clients to enhance security and follow best practices for secure communication.
./cert-manager-api \
  -listen :8000 \
  -tls-cert ${API_TLS_CERT_FILE} \
  -tls-key ${API_TLS_KEY_FILE} \
  -mtls-client-ca ${API_MTLS_CA_FILE} \
  -mtls-allowed-cns ${API_MTLS_CLIENTS_FILE} \
  -ip-list ${API_MTLS_IPS_FILE} \
  -cert-csv ${API_CERT_CSV} \
  -cert-manager ${API_CERT_MANAGER}
