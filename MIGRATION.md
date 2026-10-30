# Live Site Migration Runbook

Steps to import a live Hoststar backup into the local Docker stack.

## 1. Download the backup tar

Download the full backup from the Hoststar backup manager and place it in the repo root (gitignored):

```
ch41740.YYYY-MM-DD_HH-MM-SS.tar
```

## 2. Start the stack with a clean state

```bash
docker compose down -v                   # wipe all volumes
docker compose build --pull              # rebuild, pulling fresh base images
docker compose up -d                     # start fresh
```

`--build` alone reuses whatever base images (`php:8.3-fpm-alpine`,
`node:20-alpine`, `caddy:*`, `mariadb:*`) are already cached locally —
it will NOT fetch newer patch releases of a floating tag. For a live
migration, always `docker compose build --pull` first so you're running
the latest PHP/MariaDB/Caddy security patches, not a stale cached layer.

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

## 7. Post-import cleanup

### Disable maintenance mode and uninstall shield

```bash
docker compose exec drupal php vendor/drush/drush/drush.php sset system.maintenance_mode 0
docker compose exec drupal php vendor/drush/drush/drush.php pmu shield -y
docker compose exec drupal php vendor/drush/drush/drush.php cr
```

### Enable the admin theme

```bash
docker compose exec drupal php vendor/drush/drush/drush.php theme:enable claro -y
```

### Search for remaining hardcoded domain links

Internal links pointing to old hostnames (`cevisteffisburg.ch`, `cevistb.uber.space`)
should use relative paths instead. Step 4's `migrate-d8-db.php` already rewrites
the main offenders (body/text fields, `field_link`, menu links), but content is
messy -- always re-scan after import. Check **config** first:

```bash
docker compose exec mariadb mariadb -udrupal -pchange-me drupal \
  -e "SELECT collection, name FROM config WHERE data LIKE '%cevisteffisburg.ch%' OR data LIKE '%cevistb.uber.space%';"
```

Then do a **full content/column sweep** (config alone misses body text, link fields,
and menu links -- all of which are separate tables):

```bash
docker compose exec mariadb mariadb -udrupal -pchange-me drupal -e "
  SELECT 'menu_link_content_data' t, COUNT(*) c FROM menu_link_content_data WHERE link__uri LIKE '%uber.space%' OR link__uri LIKE '%cevisteffisburg.ch%'
  UNION SELECT 'paragraph__field_link', COUNT(*) FROM paragraph__field_link WHERE field_link_uri LIKE '%uber.space%' OR field_link_uri LIKE '%cevisteffisburg.ch%'
  UNION SELECT 'paragraph__field_text', COUNT(*) FROM paragraph__field_text WHERE field_text_value LIKE '%uber.space%' OR field_text_value LIKE '%cevisteffisburg.ch%';
"
```

(Widen to any table/column you're unsure about with `information_schema.columns`
if something still looks off on the live site.)

**Important gotcha if you ever patch this data on an already-running site**
(not at fresh-import time, when there's no cache yet): menu links are resolved
through Drupal's menu link plugin deriver, which caches definitions permanently
in `cache_discovery`/`cache_menu`. That cache is only invalidated by the
`menu_link_content_list` tag, which fires when you save the entity through the
**Entity API** — a raw `UPDATE menu_link_content_data ...` will silently keep
serving the *old* URL indefinitely (surviving `drush cr` and even container
restarts), because the stale derivative definition just gets rebuilt from... itself.
Fix it properly with:

```bash
docker compose exec drupal vendor/bin/drush php:eval '
$storage = \Drupal::entityTypeManager()->getStorage("menu_link_content");
foreach ($storage->loadMultiple() as $entity) { $entity->save(); }
'
```

The config/sync YMLs already have the main site links replaced with relative
paths (e.g. `/form/contact-form`). After `drush cim` they should be gone. If any
remain, re-run `drush cim -y` or update them manually.

Email addresses (`@cevisteffisburg.ch`) in webform handlers, and the
`admin@cevisteffisburg.ch` param in the Google Calendar iframe embed, are
intentional — they are real addresses/identifiers, not links, and should remain.

### Remove temporary .bak files from the live server

During the emergency salt rotation a `.bak` copy was left next to each `settings.php`
on the Hoststar server. Remove them once the migration to the new stack is complete:

```bash
rm web/cevisteffisburg.ch/public_html/cevi-drupal/drupal/web/sites/default/settings.php.bak
rm web/cevisteffisburg.ch/public_html/cevi-drupal/settings/settings.php.bak
```

## 8. Verify

```bash
curl -sI http://localhost/
docker compose exec drupal php vendor/bin/drush status
docker compose exec drupal php vendor/bin/drush uli
```
