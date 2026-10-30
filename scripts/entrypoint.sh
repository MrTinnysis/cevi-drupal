#!/bin/sh
set -e

# Guard: fail fast if required env vars are missing.
for var in DRUPAL_DB_NAME DRUPAL_DB_USER DRUPAL_DB_PASS DRUPAL_HASH_SALT; do
  eval val=\$$var
  if [ -z "$val" ]; then
    echo "[entrypoint] ERROR: required environment variable $var is not set."
    echo "[entrypoint] Copy .env.example to .env and fill in all values."
    exit 1
  fi
done

echo "[entrypoint] Waiting for database..."
until php -r "\$h=getenv('DRUPAL_DB_HOST')?:'mariadb'; \$d=getenv('DRUPAL_DB_NAME'); \$u=getenv('DRUPAL_DB_USER'); \$p=getenv('DRUPAL_DB_PASS'); new PDO(\"mysql:host=\$h;dbname=\$d\",\$u,\$p);" 2>/dev/null; do
  sleep 2
done
echo "[entrypoint] Database is ready."

cd /var/www/html

# Run database updates and config import if Drupal is already installed
# NOTE: vendor/bin/drush is a shell shim, not a PHP script -- invoke it
# directly (no "php" prefix). Running `php vendor/bin/drush ...` just prints
# the shim's shell source as literal output and silently does nothing --
# which meant updb/cr never actually ran automatically here before this fix.
if vendor/bin/drush status --field=bootstrap 2>/dev/null | grep -q "Successful"; then
  echo "[entrypoint] Running database updates..."
  vendor/bin/drush updb -y --no-cache-clear || true
  echo "[entrypoint] Rebuilding cache..."
  vendor/bin/drush cr || true
  # Webform's third-party JS libraries (Select2, Choices.js, CodeMirror, etc.)
  # are not bundled with the module and would otherwise be loaded from a
  # public CDN (privacy/reliability concern). Download them once into the
  # drupal_web volume; idempotent -- skipped once web/libraries exists.
  if [ ! -d web/libraries ]; then
    echo "[entrypoint] Downloading Webform third-party libraries..."
    vendor/bin/drush webform:libraries:download -y || true
  fi
  # Config import is intentionally skipped here;
  # run manually: docker compose exec drupal vendor/bin/drush cim -y
  echo "[entrypoint] Site is ready."
else
  echo "[entrypoint] Drupal not yet installed — skipping drush deploy."
  echo "[entrypoint] To install: docker compose exec drupal vendor/bin/drush si --locale=de -y"
fi

exec "$@"
