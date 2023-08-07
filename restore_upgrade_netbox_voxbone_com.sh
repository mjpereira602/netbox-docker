#!/bin/bash
#
# Run entire script inside {} to ensure entire script is parsed into memory.
# As this script disappears as soon as it changes the containing repo's branch.
#
{
  # Source variables
  source ./.env

  #
  # Copy backup from parent directory
  #
  cp ../backups/voxbone.sql.gz postgres_init.d/50_init.sql.gz

  overrides="-f docker-compose.yml -f docker-compose.override.yml"
  if [ "$(uname -s)" == 'Darwin' ]
  then
    overrides="${overrides} -f docker-compose.override.macosx.yml"
  fi
    
  #
  # spool up 3.5.2 netbox 
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
  # Create racktables_migration superuser account
  #
  podman-compose ${overrides} exec netbox \
  /opt/netbox/venv/bin/python \
  ./manage.py \
  createsuperuser \
  --username "${SUPERUSER_NAME}" \
  --email "${SUPERUSER_EMAIL}" \
  --noinput

  # Create token for above account
  cat<<EOF | podman-compose ${overrides} exec -T postgres psql --user netbox --dbname netbox
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

  ##
  ## backup database (overwriting our initial backup)
  ##
  #pg_dump -Z9 -f postgres_init.d/50_init.sql.gz --dbname=postgresql://netbox:J5brHrAXFLQSif0K@127.0.0.1:5432/netbox
  podman-compose ${overrides} exec -T postgres pg_dump --user netbox --dbname netbox \
  | gzip > postgres_init.d/50_init.sql.gz
  cp postgres_init.d/50_init.sql.gz ../backups/voxbone_upgraded_backup.sql.gz
  
  exit
}
