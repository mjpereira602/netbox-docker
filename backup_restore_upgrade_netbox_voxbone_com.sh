#!/bin/bash
#
# Run entire script inside {} to ensure entire script is parsed into memory.
# As this script disappears as soon as it changes the containing repo's branch.
#
{
  # Source variables
  source .env

  #
  # Pull backup from netbox.voxbone.com
  #
  
  # With secrets
  ssh netbox-001.vit.pod2.cloud.voxbone.com \
    "pg_dump --dbname=postgresql://netbox:${VOXBONE_POSTGRES_PASS}@postgres-001.vit.pod2.cloud.voxbone.com:5432/netbox 2>pg_dump.errors \
    --no-owner --no-privileges" \
    | gzip > backups/voxbone_backup.sql.gz
  cp backups/voxbone_backup.sql.gz postgres_init.d/50_init.sql.gz
  
  # Without secrets
  #ssh netbox-001.vit.pod2.cloud.voxbone.com \
  #  "pg_dump --dbname=postgresql://netbox:${VOXBONE_POSTGRES_PASS}@postgres-001.vit.pod2.cloud.voxbone.com:5432/netbox 2>pg_dump.errors \
  #  --no-owner --no-privileges --exclude-table-data 'secrets*'" \
  #  | gzip > backups/voxbone_backup_no_secrets.sql.gz
  #cp backups/voxbone_backup_no_secrets.sql.gz postgres_init.d/50_init.sql.gz

  overrides="-f docker-compose.yml -f docker-compose.override.yml -f docker-compose.override.migrate.yml"
  if [ "$(uname -s)" == 'Darwin' ]
  then
    overrides="${overrides} -f docker-compose.override.macosx.yml"
  fi
    
  #
  # spool up 3.4 netbox to migrate secrets application
  #
  podman-compose ${overrides} down -v
  podman volume prune -f
  git checkout bandwidth-3.4-2.5.3
  git pull --set-upstream origin bandwidth-3.4-2.5.3
  
  podman-compose ${overrides} build 
  podman-compose ${overrides} up --detach

  until podman-compose ${overrides} exec -T netbox curl -f http://localhost:8080/api/ > /dev/null 2>&1
  do
    echo "checking..."
    sleep 5
  done

  #
  # Create racktables_migration superuser account
  #
  podman-compose exec netbox \
  /opt/netbox/venv/bin/python \
  ./manage.py \
  createsuperuser \
  --username "${SUPERUSER_NAME}" \
  --email "${SUPERUSER_EMAIL}" \
  --noinput

  # Create token for above account
  cat<<EOF | podman-compose exec -T postgres psql --user netbox --dbname netbox
INSERT INTO users_token (created, key, write_enabled, description, user_id)
SELECT
  NOW(),
  '${SUPERUSER_API_TOKEN}',
  True,
  'racktables migration api key; delete me',
  id
FROM auth_user
WHERE username = 'racktables_migration'
ON CONFLICT(key) DO NOTHING;
EOF

  # Finish netbox-secretstore to netbox-secrets migration
  echo "BEGIN;" > secretstore_cleanup.sql

  podman-compose exec -T netbox /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py \
  sqlsequencereset netbox_secrets | \
  sed "s,\x1B\[[0-9;]*[a-zA-Z],,g" | \
  sed '1,/BEGIN;/d' | \
  sed "/COMMIT;/d" >> secretstore_cleanup.sql

  cat >> secretstore_cleanup.sql <<SQL
DROP TABLE IF EXISTS netbox_secretstore_secret;
DROP TABLE IF EXISTS netbox_secretstore_secretrole;
DROP TABLE IF EXISTS netbox_secretstore_sessionkey;
DROP TABLE IF EXISTS netbox_secretstore_userkey;
COMMIT;
SQL

  cat secretstore_cleanup.sql | podman-compose exec -T postgres psql --user netbox --dbname netbox
  rm secretstore_cleanup.sql

  # Recover ASNs and Contacts.
  podman-compose exec -T netbox \
  curl -X POST "http://localhost:8080/api/extras/scripts/netbox_v32_migration.MigrateSiteASNsScript/" \
    -H "accept: application/json; indent=4" \
    -H "Content-Type: application/json" \
    -H "Authorization: Token ${SUPERUSER_API_TOKEN}" \
    --data '{ "data": { "clear_site_field": true }, "commit": true }'

  podman-compose exec -T netbox \
  curl -X POST "http://localhost:8080/api/tenancy/contact-roles/" \
    -H "accept: application/json; indent=4" \
    -H "Content-Type: application/json" \
    -H "Authorization: Token ${SUPERUSER_API_TOKEN}" \
    --data '{ "name": "Site", "slug": "site", "description": "Site Contacts" }'

  podman-compose exec -T netbox \
  curl -X POST "http://localhost:8080/api/extras/scripts/netbox_v32_migration.MigrateSiteContactsScript/" \
    -H "accept: application/json; indent=4" \
    -H "Content-Type: application/json" \
    -H "Authorization: Token ${SUPERUSER_API_TOKEN}" \
    --data '{ "data": { "clear_site_fields": true, "contact_priority": "" }, "commit": true }'

  ##
  ## backup database (overwriting our initial backup)
  ##
  #pg_dump -Z9 -f postgres_init.d/50_init.sql.gz --dbname=postgresql://netbox:J5brHrAXFLQSif0K@127.0.0.1:5432/netbox
  podman-compose exec -T postgres pg_dump --user netbox --dbname netbox \
  | gzip > postgres_init.d/50_init.sql.gz
  
  #
  # Recreate netbox cluster with latest version
  #
  podman-compose ${overrides} down -v
  podman volume prune -f

  git checkout bandwidth
  git pull --set-upstream origin bandwidth

  podman-compose ${overrides} build 
  podman-compose ${overrides} up --detach
  
  until podman-compose ${overrides} exec -T netbox curl -f http://localhost:8080/api/ > /dev/null 2>&1
  do
    echo "checking..."
    sleep 5
  done

  #
  # backup upgraded voxbone database
  #
  podman-compose exec -T postgres pg_dump --user netbox --dbname netbox \
  | gzip > postgres_init.d/50_init.sql.gz
  cp postgres_init.d/50_init.sql.gz backups/voxbone_upgraded_backup.sql.gz

  podman-compose ${overrides} down -v
  podman volume prune -f

  exit
}
