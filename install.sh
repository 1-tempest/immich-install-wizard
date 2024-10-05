#!/usr/bin/env bash
set -o nounset
set -o pipefail

local_mount_paths=()

create_immich_directory() {
  local -r Tgt='./immich-app'
  echo "Creating Immich directory..."
  if [[ -e $Tgt ]]; then
    echo "Found existing directory $Tgt, will overwrite YAML files"
  else
    mkdir "$Tgt" || return
  fi
  cd "$Tgt" || return 1
}

download_docker_compose_file() {
  echo "  Downloading docker-compose.yml..."
  "${Curl[@]}" "$RepoUrl"/docker-compose.yml -o ./docker-compose.yml
}

download_dot_env_file() {
  echo "  Downloading .env file..."
  "${Curl[@]}" "$RepoUrl"/example.env -o ./.env
}

generate_random_password() {
  echo "  Generate random password for .env file..."
  rand_pass=$(echo "$RANDOM$(date)$RANDOM" | sha256sum | base64 | head -c10)
  if [ -z "$rand_pass" ]; then
    sed -i -e "s/DB_PASSWORD=postgres/DB_PASSWORD=postgres${RANDOM}${RANDOM}/" ./.env
  else
    sed -i -e "s/DB_PASSWORD=postgres/DB_PASSWORD=${rand_pass}/" ./.env
  fi
}

prompt_for_upload_location() {
  echo ""
  echo "Your original media is located in the upload location. You can change the upload location to a different directory or network path."
  read -r -p "Enter the upload location (or press Enter to use the default './library'): " upload_location
  if [[ -n $upload_location ]]; then
    detect_path_add_volume "$upload_location" update_upload_location
  fi
}

update_upload_location() {
  local mount_path=$1
  local app_upload_path="/usr/src/app/upload"

  # Check if it's an NFS mount (contains "nfs,nolock")
  if [[ $mount_path != *"nfs,nolock"* ]]; then
    # Replace the local path in .env file
    sed -i -e "s|UPLOAD_LOCATION=./library|UPLOAD_LOCATION=${mount_path}|" ./.env
  else
    # Modify the NFS path to use the app-specific path
    mount_path=$(echo "$mount_path" | sed -E "s|^([^:]*:[^:]*:)[^:]*|\1$app_upload_path|")
    # echo "New mount path: $mount_path"

    # Delete the line containing /usr/src/app/upload and insert the new mount path immediately after
    sed -i -E "/\/usr\/src\/app\/upload/{d; a\\
      - ${mount_path}
    }" docker-compose.yml
  fi
}


start_docker_compose() {
  echo "Starting Immich's docker containers"

  if ! docker compose >/dev/null 2>&1; then
    echo "failed to find 'docker compose'"
    return 1
  fi

  if ! docker compose up --remove-orphans -d; then
    echo "Could not start. Check for errors above."
    return 1
  fi
  show_friendly_message
}

show_friendly_message() {
  local ip_address
  ip_address=$(hostname -I | awk '{print $1}')
  cat <<EOF
Successfully deployed Immich!
You can access the website at http://$ip_address:2283 and the server URL for the mobile app is http://$ip_address:2283/api
---------------------------------------------------
If you want to configure custom information of the server, including the database, Redis information, or the backup (or upload) location, etc.

  1. First bring down the containers with the command 'docker compose down' in the immich-app directory,

  2. Then change the information that fits your needs in the '.env' file,

  3. Finally, bring the containers back up with the command 'docker compose up --remove-orphans -d' in the immich-app directory
EOF
}

prompt_for_external_library() {
  local_mount_paths=()
  echo ""
  echo "External Libraries - https://immich.app/docs/guides/external-library/"
  read -r -p "Would you like to use one or more external libraries? (y/n): " dir_path
  if [[ $dir_path == "y" ]]; then
    while true; do
      read -r -p " Enter the directory path. Network and local paths are supported (s to skip): " dir_path
      if [[ $dir_path == "s" ]]; then
        break
      fi
      # Detecting NFS paths correctly
      detect_path_add_volume "$dir_path" docker_compose_add_external_volume
    done
  fi
}

detect_path_add_volume() {
  local dir_path=$1
  local volume_handler=$2
  if [[ $dir_path =~ ^// || $dir_path =~ ^\\\\ ]]; then
    # echo "  Detected network mount: $dir_path"
    get_nfs_permissions "$dir_path" "$volume_handler"
  else
    # echo "  Detected local directory"
    get_local_permissions "$dir_path" "$volume_handler"
  fi
}

get_local_permissions() {
  local dir_path=$1
  local volume_handler=$2
  local local_mount_type=""
  local rw_required=""

  if [[ $volume_handler == "update_upload_location" ]]; then
    rw_required="true"
  fi

  if [[ -r $dir_path && -w $dir_path ]]; then
    #echo "Local directory has read/write permissions"
    local_mount_type="rw"
  elif [[ -r $dir_path && !$rw_required ]]; then
    #echo "Local directory has read-only permissions"
    local_mount_type="ro"
  else
    echo "    Local directory does not have read permissions"
    echo "    Error: Invalid directory. Please enter a valid directory."
    exit 1
    return 1
  fi

local mount_type
  # determine the mount type
  if [[ rw_required && !(-z $local_mount_type || $local_mount_type == "rw") ]];
  then
    echo "    Directory has read-only permissions, need read-write"
    exit 1
    return 14
  fi
  if [[ -z $local_mount_type || $local_mount_type == "rw" ]]; then
    mount_type=$(prompt_readonly)
  else
    echo "    Directory has read-only permissions, mounting as read-only"
    mount_type="ro"
  fi
  local local_mount_path="/mnt/${dir_path}"
  local_mount_paths+=("$local_mount_path")
  local mount_path="${dir_path}:$local_mount_path:${mount_type}"

  $volume_handler "$mount_path"
}

get_nfs_permissions() {
  local dir_path=$1
  local volume_handler=$2
  local nfs_addr
  local nfs_share
  local rw_required=""

  if [[ $volume_handler == "update_upload_location" ]]; then
    rw_required="true"
  fi

  # Convert backslashes to forward slashes for consistency
  dir_path=${dir_path//\\/\/}

  # Extract NFS server address and share path
  nfs_addr=$(echo "$dir_path" | awk -F'/' '{print $3}')
  nfs_share=$(echo "$dir_path" | sed -e "s|//$nfs_addr||")

  local mount_options
  if [[ $rw_required == "true" ]]; then
    mount_options="rw"
  else
    mount_options=$(prompt_readonly)  # Define mount_type based on the mount_options
  fi
  
  # Define the mount type based on the mount options
  local mount_type="hard"
  [[ $mount_options == "ro" ]] && mount_type="soft"
  
  local local_mount_path="/mnt/${nfs_addr}${nfs_share}"
  local_mount_paths+=("$local_mount_path")
  local mount_path="${nfs_addr}:${nfs_share}:$local_mount_path:nfs,nolock,${mount_type},${mount_options}"

  $volume_handler "$mount_path"
}

prompt_readonly() {
  read -p "    Should the directory be mounted as read-only? (y/n): " readonly
  if [[ $readonly == "y" ]]; then
    echo "ro"
  else
    echo "rw"
  fi
}

docker_compose_add_external_volume() {
  local volume=$1
  # echo "  Updating docker-compose.yml with the new volume..."
  sed -i "/\/etc\/localtime:\/etc\/localtime:ro/a\      # Added by wizard\n      - ${volume}" docker-compose.yml
}

show_mount_paths() {
  echo "Mount path(s) available for use in Immich:"
  for path in "${local_mount_paths[@]}"; do
    echo "  $path"
  done
}

prompt_start_docker_compose() {
  read -p "Would you like to start the docker containers now? (y/n): " start_containers
  if [[ $start_containers == "y" ]]; then
    start_docker_compose
  fi
}

# --- BACKUPS ---

prompt_for_backups() {
  echo ""
  read -p "Would you like to enable database backups? (y/n): " backups
  if [[ $backups == "y" ]]; then
  sed -i '/^services:/a\
  backup:\n\
    container_name: immich_db_dumper\n\
    image: prodrigestivill/postgres-backup-local:14\n\
    restart: always\n\
    env_file:\n\
      - .env\n\
    environment:\n\
      POSTGRES_HOST: database\n\
      POSTGRES_CLUSTER: '\''TRUE'\''\n\
      POSTGRES_USER: ${DB_USERNAME}\n\
      POSTGRES_PASSWORD: ${DB_PASSWORD}\n\
      POSTGRES_DB: ${DB_DATABASE_NAME}\n\
      SCHEDULE: "@daily"\n\
      POSTGRES_EXTRA_OPTS: '\''--clean --if-exists'\''\n\
      BACKUP_DIR: /db_dumps\n\
    volumes:\n\
      - ./db_dumps:/db_dumps\n\
    depends_on:\n\
      - database' docker-compose.yml

      read -r -p "Enter the backup location (or press Enter to use the default './db_dumps'): " backup_location
    if [[ -n $backup_location ]]; then
      detect_path_add_volume "$upload_location" update_backup_location
      mkdir ./db_dumps
      else
      detect_path_add_volume "$backup_location" docker_compose_change_backup_location
    fi
  fi
}


docker_compose_change_backup_location() {
  local volume=$1
  # echo "  Updating docker-compose.yml with the new volume..."
    sed -i "s|./db_dumps|$volume|g" docker-compose.yml
}

# --- END OF BACKUPS --- 

# MAIN
main() {
  echo "Starting Immich installation..."
  local -r RepoUrl='https://github.com/immich-app/immich/releases/latest/download'
  local -a Curl
  if command -v curl >/dev/null; then
    Curl=(curl -fsSL)
  else
    echo 'no curl binary found; please install curl and try again'
    return 14
  fi

  create_immich_directory
  download_docker_compose_file
  download_dot_env_file
  generate_random_password
  prompt_for_upload_location
  prompt_for_external_library
  show_mount_paths
  prompt_for_backups
  prompt_start_docker_compose
}

main "$@"