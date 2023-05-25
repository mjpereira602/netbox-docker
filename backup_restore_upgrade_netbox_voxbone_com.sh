#!/bin/bash
#
# Run entire script inside {} to ensure entire script is parsed into memory.
# As this script disappears as soon as it changes the containing repo's branch.
#
{
  #
  # Pull backup from netbox.voxbone.com
  #
  
  # With secrets
  #ssh netbox-001.vit.pod2.cloud.voxbone.com \
  #  "pg_dump --dbname=postgresql://netbox:${VOXBONE_NETBOX_PASS}@postgres-001.vit.pod2.cloud.voxbone.com:5432/netbox 2>pg_dump.errors \
  #  --no-owner --no-privileges" \
  #  | gzip > backups/voxbone_backup.sql.gz
  cp backups/voxbone_backup.sql.gz postgres_init.d/50_init.sql.gz
  
  # Without secrets
  #ssh netbox-001.vit.pod2.cloud.voxbone.com \
  #  "pg_dump --dbname=postgresql://netbox:${VOXBONE_POSTGRES_PASS}@postgres-001.vit.pod2.cloud.voxbone.com:5432/netbox 2>pg_dump.errors \
  #  --no-owner --no-privileges --exclude-table-data 'secrets*'" \
  #  | gzip > backups/voxbone_backup_no_secrets.sql.gz
  #cp backups/voxbone_backup_no_secrets.sql.gz postgres_init.d/50_init.sql.gz

  overrides="-f docker-compose.yml -f docker-compose.override.yml"
  if [ "$(uname -s)" == 'Darwin' ]
  then
    overrides="${overrides} -f docker-compose.override.macosx.yml"
  fi
    
  #
  # Spool up a netbox 3.1 instance and restore netbox.voxbone.com into it.
  #
  podman-compose  down -v
  podman volume prune -f
  git checkout bandwidth-3.1-1.6.0
  git pull --set-upstream origin bandwidth-3.1-1.6.0

  podman-compose ${overrides} build --no-cache netbox
  podman-compose ${overrides} up --no-start
  podman-compose ${overrides} start
  
  while ! curl -s -X GET http://localhost:8000 > /dev/null; do sleep 5; done
  
  #
  # Run two extra migration scripts to prep for netbox-3.2+
  #
  curl -X GET "http://localhost:8000/api/extras/scripts/" \
    -H "accept: application/json; indent=4" \
    -H "Authorization: Token 0123456789abcdef0123456789abcdef01234567"
    
  curl -X POST "http://localhost:8000/api/extras/scripts/netbox_v32_migration.MigrateSiteASNsScript/" \
    -H "accept: application/json; indent=4" \
    -H "Content-Type: application/json" \
    -H "Authorization: Token 0123456789abcdef0123456789abcdef01234567" \
    --data '{ "data": { "clear_site_field": true }, "commit": true }'
  
  curl -X POST "http://localhost:8000/api/tenancy/contact-roles/" \
    -H "accept: application/json; indent=4" \
    -H "Content-Type: application/json" \
    -H "Authorization: Token 0123456789abcdef0123456789abcdef01234567" \
    --data '{ "name": "Site", "slug": "site", "description": "Site Contacts" }'
  
  curl -X POST "http://localhost:8000/api/extras/scripts/netbox_v32_migration.MigrateSiteContactsScript/" \
    -H "accept: application/json; indent=4" \
    -H "Content-Type: application/json" \
    -H "Authorization: Token 0123456789abcdef0123456789abcdef01234567" \
    --data '{ "data": { "clear_site_fields": true, "contact_priority": "" }, "commit": true }'
  
  curl -X GET "http://localhost:8000/api/extras/scripts/" \
    -H "accept: application/json; indent=4" \
    -H "Authorization: Token 0123456789abcdef0123456789abcdef01234567"
  
  sleep 20
  
  #
  # backup database (overwriting our initial backup)
  #
  pg_dump -Z9 -f postgres_init.d/50_init.sql.gz --dbname=postgresql://netbox:J5brHrAXFLQSif0K@127.0.0.1:5432/netbox

  #
  # Migrate to 3.4 netbox to migrate secrets application
  #
  podman-compose ${overrides} down -v
  podman volume prune -f
  git checkout bandwidth-3.4-2.5.3
  git pull --set-upstream origin bandwidth-3.4-2.5.3
  
  podman-compose ${overrides} -f docker-compose.override.upgrade.yml build --no-cache netbox
  podman-compose ${overrides} -f docker-compose.override.upgrade.yml up --no-start
  podman-compose ${overrides} -f docker-compose.override.upgrade.yml start
  
  while ! curl -s -X GET http://localhost:8000 > /dev/null; do sleep 5; done

  # netbox-secretstore to netbox-secrets sqlsequence reset
  exit 
 
  ##
  ## backup database (overwriting our initial backup)
  ##
  pg_dump -Z9 -f postgres_init.d/50_init.sql.gz --dbname=postgresql://netbox:J5brHrAXFLQSif0K@127.0.0.1:5432/netbox
  
  #
  # Recreate netbox cluster with latest version
  #
  podman-compose ${overrides} down -v
  podman volume prune -f

  git checkout bandwidth
  git pull --set-upstream origin bandwidth

  podman-compose ${overrides} -f docker-compose.override.upgrade.yml build --no-cache netbox
  podman-compose ${overrides} -f docker-compose.override.upgrade.yml up --no-start
  podman-compose ${overrides} -f docker-compose.override.upgrade.yml start
  
  while [ "$(podman container inspect netbox-docker_netbox_1 --format '{{ .State.Health.Status }}')" = 'starting' ]; do sleep 5; done
  
  #
  # backup upgraded voxbone database
  #
  cd ..
  pg_dump -Z9 -f state/voxbone_upgraded_backup.sql.gz --dbname=postgresql://netbox:J5brHrAXFLQSif0K@127.0.0.1:5432/netbox
  
  exit
}
