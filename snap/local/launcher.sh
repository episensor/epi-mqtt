#!/bin/sh
# EpiSensor MQTT broker launcher
# Checks for custom config in $SNAP_COMMON (daemon) or $SNAP_USER_COMMON (user)

echo "Running epi-mqtt launcher script..."

case "$SNAP_USER_COMMON" in
  */root/snap/epi-mqtt/common*) COMMON=$SNAP_COMMON ;;
  *)                            COMMON=$SNAP_USER_COMMON ;;
esac

CONFIG_FILE="$SNAP/default_config.conf"
CONTENT_CONFIG="$SNAP_DATA/config/mosquitto.conf"
LEGACY_CONFIG="$COMMON/mosquitto.conf"

echo "Searching for custom Mosquitto configuration"

# Ensure config and certs directories exist for content interface
mkdir -p "$SNAP_DATA/config"
mkdir -p "$SNAP_DATA/certs"

# Copy example config if it doesn't exist
if [ ! -e "$COMMON/mosquitto_example.conf" ]; then
  echo "Copying example config to $COMMON/mosquitto_example.conf"
  cp "$SNAP/mosquitto.conf" "$COMMON/mosquitto_example.conf"
fi

# Preserve the legacy administrator override, then use the configuration
# shared through the mqtt-config content interface.
if [ -e "$LEGACY_CONFIG" ]; then
  echo "Found legacy config in $LEGACY_CONFIG"
  CONFIG_FILE="$LEGACY_CONFIG"
elif [ -e "$CONTENT_CONFIG" ]; then
  echo "Found content-interface config in $CONTENT_CONFIG"
  CONFIG_FILE="$CONTENT_CONFIG"
else
  echo "Using default config from $CONFIG_FILE"
fi

exec "$SNAP/usr/sbin/mosquitto" -c "$CONFIG_FILE" "$@"
