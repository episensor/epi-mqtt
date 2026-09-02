#!/bin/sh
# Apply a generated Mosquitto configuration transactionally. This command owns
# the config file; callers supply only an auth mode and bounded listener ports.
set -eu
umask 077

MODE=""
USERNAME=""
LOCAL_PORT="1883"
GATEWAY_PORT="8883"
COMMON="${SNAP_COMMON:?SNAP_COMMON is required}"
DATA="${SNAP_DATA:?SNAP_DATA is required}"
SNAP_ID="${SNAP_NAME:-epi-mqtt}"
CANONICAL_CONFIG="$COMMON/mosquitto.conf"
CONFIG_DIR="$COMMON/config"
ACL_FILE="$CONFIG_DIR/aclfile"
STATE_FILE="$COMMON/broker-config.state"
CERT_DIR="$COMMON/certs"
SHARED_CERT_DIR="$DATA/certs"
LOCK_DIR="$COMMON/.configure-broker.lock"
SNAPCTL_BIN="${EPI_MQTT_SNAPCTL_BIN:-snapctl}"
VERIFY_ATTEMPTS="${EPI_MQTT_VERIFY_ATTEMPTS:-20}"
VERIFY_INTERVAL="${EPI_MQTT_VERIFY_INTERVAL:-0.25}"
NEXT=""
PREVIOUS=""
NEXT_ACL=""
PREVIOUS_ACL=""
STATE_NEXT=""

usage() {
  echo "usage: epi-mqtt.configure --mode local|core-mtls|core-password [--local-port PORT] [--gateway-port PORT] [--username USER]" >&2
  exit 64
}

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

json_error() {
  code="$1"
  message="$2"
  printf '{"schema_version":1,"applied":false,"code":"%s","message":"%s"}\n' "$code" "$message"
}

release_lock() {
  rm -f "$LOCK_DIR/owner" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

cleanup() {
  for temporary in "$NEXT" "$PREVIOUS" "$NEXT_ACL" "$PREVIOUS_ACL" "$STATE_NEXT"; do
    [ -n "$temporary" ] && rm -f "$temporary" 2>/dev/null || true
  done
  release_lock
}

acquire_lock() {
  mkdir "$LOCK_DIR" 2>/dev/null && return 0
  [ ! -L "$LOCK_DIR" ] || return 1

  owner=""
  if [ -f "$LOCK_DIR/owner" ] && [ ! -L "$LOCK_DIR/owner" ]; then
    IFS= read -r owner < "$LOCK_DIR/owner" || owner=""
  fi
  case "$owner" in
    ''|*[!0-9]*) ;;
    *) kill -0 "$owner" 2>/dev/null && return 1 ;;
  esac

  # A terminated configure process cannot release its directory. Remove only
  # the known owner file and the now-empty lock directory; never recurse.
  rm -f "$LOCK_DIR/owner" 2>/dev/null || return 1
  rmdir "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR" 2>/dev/null
}

restore_previous() {
  if [ "$HAD_PREVIOUS" = true ]; then
    restore=$(mktemp "$COMMON/.mosquitto.restore.XXXXXX") || return 1
    cp "$PREVIOUS" "$restore" && chmod 600 "$restore" && mv -f "$restore" "$CANONICAL_CONFIG"
  else
    rm -f "$CANONICAL_CONFIG"
  fi
  if [ "$HAD_PREVIOUS_ACL" = true ]; then
    acl_restore=$(mktemp "$CONFIG_DIR/.aclfile.restore.XXXXXX") || return 1
    cp "$PREVIOUS_ACL" "$acl_restore" && chmod 600 "$acl_restore" && mv -f "$acl_restore" "$ACL_FILE"
  else
    rm -f "$ACL_FILE"
  fi
}

service_is_active() {
  "$SNAPCTL_BIN" services "$SNAP_ID.mosquitto" 2>/dev/null \
    | awk 'NR > 1 && $1 ~ /\.mosquitto$/ && $3 == "active" { found = 1 } END { exit found ? 0 : 1 }'
}

restart_and_verify() {
  "$SNAPCTL_BIN" restart "$SNAP_ID.mosquitto" >/dev/null 2>&1 || return 1
  attempt=0
  consecutive=0
  while [ "$attempt" -lt "$VERIFY_ATTEMPTS" ]; do
    if service_is_active; then
      consecutive=$((consecutive + 1))
      [ "$consecutive" -ge 3 ] && return 0
    else
      consecutive=0
    fi
    attempt=$((attempt + 1))
    sleep "$VERIFY_INTERVAL"
  done
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || usage; MODE="$2"; shift 2 ;;
    --mode=*) MODE=${1#*=}; shift ;;
    --local-port) [ "$#" -ge 2 ] || usage; LOCAL_PORT="$2"; shift 2 ;;
    --local-port=*) LOCAL_PORT=${1#*=}; shift ;;
    --gateway-port) [ "$#" -ge 2 ] || usage; GATEWAY_PORT="$2"; shift 2 ;;
    --gateway-port=*) GATEWAY_PORT=${1#*=}; shift ;;
    --username) [ "$#" -ge 2 ] || usage; USERNAME="$2"; shift 2 ;;
    --username=*) USERNAME=${1#*=}; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

case "$MODE" in
  local|core-mtls|core-password) ;;
  *) usage ;;
esac
valid_port "$LOCAL_PORT" || { json_error invalid_local_port "Local listener port is invalid"; exit 65; }
valid_port "$GATEWAY_PORT" || { json_error invalid_gateway_port "Gateway listener port is invalid"; exit 65; }
[ "$MODE" = local ] || [ "$LOCAL_PORT" -ne "$GATEWAY_PORT" ] \
  || { json_error duplicate_listener_port "Local and Gateway listener ports must differ"; exit 65; }
if [ "$MODE" = core-password ]; then
  case "$USERNAME" in
    ''|*[!A-Za-z0-9._@:-]*) json_error invalid_username "MQTT username contains unsupported characters"; exit 65 ;;
  esac
  [ "${#USERNAME}" -le 128 ] \
    || { json_error invalid_username "MQTT username is too long"; exit 65; }
fi

mkdir -p "$CONFIG_DIR" "$CERT_DIR" "$SHARED_CERT_DIR"
[ ! -L "$COMMON" ] && [ ! -L "$CANONICAL_CONFIG" ] \
  || { json_error unsafe_config_path "Canonical configuration path is a symlink"; exit 66; }

if [ "$MODE" = core-mtls ]; then
  for required in \
    "$CERT_DIR/server-fullchain.pem" \
    "$CERT_DIR/server-privkey.pem" \
    "$SHARED_CERT_DIR/gateway-client-ca.crt"; do
    [ -f "$required" ] && [ ! -L "$required" ] \
      || { json_error missing_dependency "Required mTLS file is missing or unsafe"; exit 66; }
  done
elif [ "$MODE" = core-password ]; then
  for required in \
    "$CERT_DIR/server-fullchain.pem" \
    "$CERT_DIR/server-privkey.pem" \
    "$CONFIG_DIR/passwordfile"; do
    [ -f "$required" ] && [ ! -L "$required" ] \
      || { json_error missing_dependency "Required password-auth file is missing or unsafe"; exit 66; }
  done
fi

if ! acquire_lock; then
  json_error configuration_busy "Another broker configuration change is in progress"
  exit 75
fi
printf '%s\n' "$$" > "$LOCK_DIR/owner"
trap 'cleanup' EXIT HUP INT TERM

NEXT=$(mktemp "$COMMON/.mosquitto.next.XXXXXX")
PREVIOUS=$(mktemp "$COMMON/.mosquitto.previous.XXXXXX")
NEXT_ACL=$(mktemp "$CONFIG_DIR/.aclfile.next.XXXXXX")
PREVIOUS_ACL=$(mktemp "$CONFIG_DIR/.aclfile.previous.XXXXXX")
HAD_PREVIOUS=false
HAD_PREVIOUS_ACL=false
if [ -f "$CANONICAL_CONFIG" ]; then
  cp "$CANONICAL_CONFIG" "$PREVIOUS"
  HAD_PREVIOUS=true
fi
if [ -f "$ACL_FILE" ]; then
  cp "$ACL_FILE" "$PREVIOUS_ACL"
  HAD_PREVIOUS_ACL=true
fi

cat > "$NEXT" <<EOF
# Managed by epi-mqtt.configure. Manual edits may be replaced.
persistence false
user root
EOF

if [ "$MODE" = local ]; then
  cat >> "$NEXT" <<EOF
allow_anonymous true
listener $LOCAL_PORT 127.0.0.1
EOF
elif [ "$MODE" = core-mtls ]; then
  cat > "$NEXT_ACL" <<'EOF'
pattern readwrite %u/#
topic read server/broadcast
EOF
  cat >> "$NEXT" <<EOF
per_listener_settings true
listener $LOCAL_PORT 127.0.0.1
allow_anonymous true

listener $GATEWAY_PORT 0.0.0.0
allow_anonymous false
cafile /var/snap/$SNAP_ID/current/certs/gateway-client-ca.crt
certfile /var/snap/$SNAP_ID/common/certs/server-fullchain.pem
keyfile /var/snap/$SNAP_ID/common/certs/server-privkey.pem
require_certificate true
use_identity_as_username true
acl_file /var/snap/$SNAP_ID/common/config/aclfile
EOF
elif [ "$MODE" = core-password ]; then
  cat > "$NEXT_ACL" <<EOF
user $USERNAME
topic readwrite #
EOF
  cat >> "$NEXT" <<EOF
per_listener_settings true
listener $LOCAL_PORT 127.0.0.1
allow_anonymous true

listener $GATEWAY_PORT 0.0.0.0
allow_anonymous false
certfile /var/snap/$SNAP_ID/common/certs/server-fullchain.pem
keyfile /var/snap/$SNAP_ID/common/certs/server-privkey.pem
password_file /var/snap/$SNAP_ID/common/config/passwordfile
acl_file /var/snap/$SNAP_ID/common/config/aclfile
EOF
fi

chmod 600 "$NEXT"
if [ "$MODE" != local ]; then
  chmod 600 "$NEXT_ACL"
  mv -f "$NEXT_ACL" "$ACL_FILE"
  NEXT_ACL=""
else
  rm -f "$NEXT_ACL"
  NEXT_ACL=""
fi
mv -f "$NEXT" "$CANONICAL_CONFIG"
NEXT=""

if ! restart_and_verify; then
  restore_previous || true
  restart_and_verify || true
  rm -f "$PREVIOUS" "$PREVIOUS_ACL"
  PREVIOUS=""
  PREVIOUS_ACL=""
  json_error service_verification_failed "Broker did not remain active; previous configuration was restored"
  exit 1
fi

REVISION=$(cksum "$CANONICAL_CONFIG" | awk '{print $1 "-" $2}')
STATE_NEXT=$(mktemp "$COMMON/.broker-config.state.XXXXXX")
printf 'schema_version=1\nmode=%s\nlocal_port=%s\ngateway_port=%s\nusername=%s\nrevision=%s\n' \
  "$MODE" "$LOCAL_PORT" "$GATEWAY_PORT" "$USERNAME" "$REVISION" > "$STATE_NEXT"
chmod 600 "$STATE_NEXT"
mv -f "$STATE_NEXT" "$STATE_FILE"
STATE_NEXT=""
rm -f "$PREVIOUS" "$PREVIOUS_ACL"
PREVIOUS=""
PREVIOUS_ACL=""
printf '{"schema_version":1,"applied":true,"persisted":true,"restarted":true,"verified":true,"mode":"%s","local_port":%s,"gateway_port":%s,"revision":"%s"}\n' \
  "$MODE" "$LOCAL_PORT" "$GATEWAY_PORT" "$REVISION"
