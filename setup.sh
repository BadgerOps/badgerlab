#!/usr/bin/env bash
set -euo pipefail

### --------- EDITABLE DEFAULTS (override via env on the CLI) ---------
DOMAIN_DEFAULT="ca.badgerops.foo" # override: DOMAIN=badgerops.foo ./setup-stepca.sh
VOLUME_DEFAULT="step"             # override: VOLUME=step-prod
PORT_DEFAULT="9000"               # override: PORT=9443
ENABLE_ACME_DEFAULT="0"           # override: ENABLE_ACME=1
### -------------------------------------------------------------------

# Read overrides
DOMAIN="${DOMAIN:-$DOMAIN_DEFAULT}"
VOLUME="${VOLUME:-$VOLUME_DEFAULT}"
PORT="${PORT:-$PORT_DEFAULT}"
ENABLE_ACME="${ENABLE_ACME:-$ENABLE_ACME_DEFAULT}"

# Now that DOMAIN is final, build dependent defaults
CA_NAME_DEFAULT="Lab CA for ${DOMAIN}"
CA_NAME="${CA_NAME:-$CA_NAME_DEFAULT}"
PROVISIONER="${PROVISIONER:-admin@${DOMAIN}}"
PASSWORD="${STEP_CA_PASSWORD:-$(openssl rand -base64 32)}"
COMPOSE_FILE="docker-compose.yml"

command -v docker >/dev/null || {
  echo "Docker is required."
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  echo "Docker Compose v2 is required."
  exit 1
}

echo "==> Config:"
echo "    DOMAIN       = ${DOMAIN}"
echo "    CA_NAME      = ${CA_NAME}"
echo "    PROVISIONER  = ${PROVISIONER}"
echo "    VOLUME       = ${VOLUME}"
echo "    PORT         = ${PORT}"
echo "    ENABLE_ACME  = ${ENABLE_ACME}"

# Compose file (note: external volume)
cat >"${COMPOSE_FILE}" <<'YAML'
services:
  stepca:
    image: smallstep/step-ca:latest
    container_name: stepca
    environment:
      - STEPPATH=/home/step
    ports:
      - "${PORT}:9000"
    volumes:
      - "${VOLUME}:/home/step"
    command:
      - /usr/local/bin/step-ca
      - /home/step/config/ca.json
      - --password-file=/home/step/secrets/password
    restart: unless-stopped

volumes:
  step:
    external: true
    name: "${VOLUME}"
YAML

export PORT VOLUME

# Ensure the named (external) volume exists
docker volume inspect "${VOLUME}" >/dev/null 2>&1 || docker volume create "${VOLUME}" >/dev/null

# One-time init
echo "==> Initializing CA files (safe to re-run)"
docker compose run --rm \
  -e DOMAIN="${DOMAIN}" \
  -e CA_NAME="${CA_NAME}" \
  -e PROVISIONER="${PROVISIONER}" \
  -e PASSWORD="${PASSWORD}" \
  stepca sh -lc '
    set -e
    export STEPPATH=/home/step
    mkdir -p "$STEPPATH/secrets"
    if [ ! -s "$STEPPATH/secrets/password" ]; then
      echo -n "$PASSWORD" > "$STEPPATH/secrets/password"
      chmod 600 "$STEPPATH/secrets/password"
      echo "Created $STEPPATH/secrets/password"
    else
      echo "Password file already exists; leaving as-is."
    fi

    if [ ! -f "$STEPPATH/config/ca.json" ]; then
      echo "Running step ca init..."
      step ca init \
        --name "$CA_NAME" \
        --dns "$DOMAIN" \
        --address ":9000" \
        --provisioner "$PROVISIONER" \
        --ssh \
        --password-file "$STEPPATH/secrets/password"
      echo "Initialized CA config at $STEPPATH/config/ca.json"
    else
      echo "CA config already exists; skipping init."
    fi
  '

echo "==> Starting step-ca"
docker compose up -d

if [ "${ENABLE_ACME}" = "1" ]; then
  echo "==> Ensuring ACME provisioner exists"
  if docker exec stepca step ca provisioner add acme --type ACME >/dev/null 2>&1; then
    echo "Added ACME provisioner."
    docker restart stepca >/dev/null
  else
    echo "ACME provisioner likely already present; continuing."
  fi
  echo "ACME at: https://${DOMAIN}:${PORT}/acme/acme/directory"
fi

echo
echo "==> step-ca is up."
echo "    Health:         curl -k https://localhost:${PORT}/health"
echo "    CA URL:         https://${DOMAIN}:${PORT}"
echo "    Provisioner:    ${PROVISIONER}"
echo
echo "Bootstrap a client:"
echo "    FPR=\$(docker exec -it stepca step certificate fingerprint /home/step/certs/root_ca.crt | tr -d \"\r\")"
echo "    step ca bootstrap --ca-url https://${DOMAIN}:${PORT} --fingerprint \$FPR --install"
echo
echo "Issue a test cert:"
echo "    step ca certificate \"web1.${DOMAIN}\" web1.crt web1.key"
