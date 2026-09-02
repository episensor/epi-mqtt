#!/bin/sh
# EpiSensor MQTT broker launcher
# Uses one canonical durable config in $SNAP_COMMON. The old content-interface
# file is an import source only and never remains a competing authority.

echo "Running epi-mqtt launcher script..."

case "$SNAP_USER_COMMON" in
  */root/snap/epi-mqtt/common*) COMMON=$SNAP_COMMON ;;
  *)                            COMMON=$SNAP_USER_COMMON ;;
esac

CONFIG_FILE="$SNAP/default_config.conf"
CONTENT_CONFIG="$SNAP_DATA/config/mosquitto.conf"
CANONICAL_CONFIG="$COMMON/mosquitto.conf"
MIGRATION_MARKER="$COMMON/.config-authority-v1"

echo "Searching for custom Mosquitto configuration"

# Ensure config and certs directories exist for content interface
mkdir -p "$SNAP_DATA/config"
mkdir -p "$SNAP_DATA/certs"

# Copy example config if it doesn't exist
if [ ! -e "$COMMON/mosquitto_example.conf" ]; then
  echo "Copying example config to $COMMON/mosquitto_example.conf"
  cp "$SNAP/mosquitto.conf" "$COMMON/mosquitto_example.conf"
fi

# Establish one durable authority. Preserve an existing administrator/Core
# config byte-for-byte. Otherwise import the content-interface config once, or
# seed the packaged local-only default. Later content-file changes are ignored.
if [ ! -e "$CANONICAL_CONFIG" ]; then
  IMPORT_SOURCE="$SNAP/default_config.conf"
  IMPORT_KIND="packaged-default"
  if [ -f "$CONTENT_CONFIG" ] && [ ! -L "$CONTENT_CONFIG" ]; then
    IMPORT_SOURCE="$CONTENT_CONFIG"
    IMPORT_KIND="content-interface"
  fi
  TEMP_CONFIG=$(mktemp "$COMMON/.mosquitto.conf.XXXXXX")
  trap 'rm -f "$TEMP_CONFIG"' EXIT HUP INT TERM
  cp "$IMPORT_SOURCE" "$TEMP_CONFIG"
  chmod 600 "$TEMP_CONFIG"
  mv -f "$TEMP_CONFIG" "$CANONICAL_CONFIG"
  trap - EXIT HUP INT TERM
  printf 'schema_version=1\nauthority=%s\nimported_from=%s\n' \
    "$CANONICAL_CONFIG" "$IMPORT_KIND" > "$MIGRATION_MARKER"
fi

if [ -L "$CANONICAL_CONFIG" ] || [ ! -f "$CANONICAL_CONFIG" ]; then
  echo "Refusing invalid canonical Mosquitto config: $CANONICAL_CONFIG" >&2
  exit 1
fi

CONFIG_FILE="$CANONICAL_CONFIG"
echo "Using canonical config from $CONFIG_FILE"
exec "$SNAP/usr/sbin/mosquitto" -c "$CONFIG_FILE" "$@"
