# Live Site Migration Runbook

Steps to import a live Hoststar backup into the local Docker stack.

## 1. Download the backup tar

Download the full backup from the Hoststar backup manager and place it in the repo root (gitignored):

```
ch41740.YYYY-MM-DD_HH-MM-SS.tar
```

## 2. Start the stack with a clean state

```bash
docker compose down -v          # wipe all volumes
docker compose up -d --build    # rebuild image and start fresh
```

## 3. Import the database

The DB dump is inside the backup tar, lz4-compressed:

```bash
tar xf ch41740.*.tar --to-stdout ./db/ch41740_cevistb/ch41740_cevistb.mysql.sql.lz4 \
  | lz4 -d - \
  | docker compose exec -T mariadb mariadb -udrupal -pchange-me drupal
```

## 4. Run the DB preparation script

Fixes D10→D11 module/theme changes, editor config, and stale cache entries
that block the entrypoint from bootstrapping:

```bash
docker compose exec drupal php scripts/migrate-d8-db.php
```

## 5. Run database updates and config import

```bash
docker compose exec drupal php vendor/bin/drush updb -y
docker compose exec drupal php vendor/bin/drush cr
docker compose exec drupal php vendor/bin/drush cim -y
```

## 6. Import the files

Stream the `sites/default/files/` directory from the backup directly into
the Docker volume (no temp disk needed — 1.2 GB):

```bash
# Extract the inner lz4 archive to /tmp
tar xf ch41740.*.tar -C /tmp ./web/cevisteffisburg.ch/domain_data.tar.lz4

# Stream into the container
# --strip-components=7: strips ./ + public_html/cevi-drupal/drupal/web/sites/default/ (6 segments)
# -C /var/www/html/web/sites/default/ so that files/ lands in the right place
lz4 -d /tmp/web/cevisteffisburg.ch/domain_data.tar.lz4 --stdout \
  | docker compose exec -T drupal \
    sh -c 'tar x --strip-components=7 -C /var/www/html/web/sites/default/ \
      "./public_html/cevi-drupal/drupal/web/sites/default/files"'

docker compose exec drupal chown -R www-data:www-data /var/www/html/web/sites/default/files/

rm -rf /tmp/web
```

## 7. Verify

```bash
curl -sI http://localhost/
docker compose exec drupal php vendor/bin/drush status
docker compose exec drupal php vendor/bin/drush uli
```
