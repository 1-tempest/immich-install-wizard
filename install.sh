#!/usr/bin/env bash
set -o nounset
set -o pipefail

local_mount_paths=()
network_volumes=""
added_by_wizard="# Added by wizard"

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
  while true; do
    upload_location=$(prompt "Enter the original media storage location." "" "./library")

    if [[ -n $upload_location && $upload_location != "./library" ]]; then
      # Call the detect_path_add_volume function
      if detect_path_add_volume "$upload_location" "update_upload_location"; then
        hardcode_local_assets
        break  # Exit the loop if the function returns true
      fi
    elif [[ -z $upload_location ]]; then
      echo "  Upload location cannot be empty. Please try again." >&2
    else
      break  # Exit the loop if the user enters the default value
    fi
  done
  return 0
}

update_upload_location() {
  local mount_path=$1
  local app_upload_path="/usr/src/app/upload"

  # Replace the local path in .env file
  sed -i -e "s|UPLOAD_LOCATION=./library|UPLOAD_LOCATION=${mount_path}|" ./.env
  return 0
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

add_network_volumes(){  
  escaped_network_volumes=$(echo "$network_volumes" | sed ':a;N;$!ba;s/[\/&]/\\&/g; s/\n/\\n/g')
  sed -i "/^volumes:/a \\
  $escaped_network_volumes" docker-compose.yml
  return 0
}


prompt() {
  # Example 1: Prompt for starting docker with y/n options and default value of 'n'
  # start_containers=$(prompt_user "Yes or No?" "y n" "n")

  # Example 2: Prompt for any string input with a default value
  # username=$(prompt_user "Enter your username" "" "default_user")
  local prompt_message="$1"
  local accepted_responses="$2"
  local default_value="$3"
  local user_input
  local formatted_responses=""

  # If accepted responses are provided, format them by replacing spaces with slashes
  if [[ -n $accepted_responses ]]; then
    formatted_responses=$(echo "$accepted_responses" | sed 's/ /\\/g')
  fi

  while true; do
    # Construct the prompt message dynamically
    if [[ -n $default_value && -n $formatted_responses ]]; then
      read -r -p "$prompt_message Press Enter to use default: [$default_value] or ($formatted_responses): " user_input
    elif [[ -n $default_value ]]; then
      read -r -p "$prompt_message Press Enter to use default: [$default_value]: " user_input
    elif [[ -n $formatted_responses ]]; then
      read -r -p "$prompt_message ($formatted_responses): " user_input
    else
      read -r -p "$prompt_message: " user_input
    fi

    # Use the default value if the user just presses enter
    if [[ -z $user_input ]]; then
      user_input="$default_value"
      echo "  Using default value [$default_value]" >&2
    fi

    # If accepted responses are provided, ensure user_input is valid
    if [[ -n $accepted_responses ]]; then
      if [[ " $accepted_responses " =~ " $user_input " ]]; then
        break  # valid input, exit the loop
      else
        echo "  Invalid input. Please enter one of: ($formatted_responses)" >&2
      fi
    else
      break  # no accepted responses provided, exit the loop
    fi
  done

  # Return the user's response
  echo "$user_input"
}

prompt_for_external_library() {
  local_mount_paths=()
  echo ""
  echo "External Libraries - https://immich.app/docs/guides/external-library/"
  local add_external_libraries=$(prompt "Would you like to use one or more external libraries?" "y n" "n")
  if [[ $add_external_libraries == "y" ]]; then
    while true; do
      local dir_path=$(prompt "Enter the directory path. Network and local paths are supported (s to stop):")
      if [[ $dir_path == "s" ]]; then
        break
      fi
      # Detecting network paths correctly
      detect_path_add_volume "$dir_path" docker_compose_add_external_volume
    done
  fi
}

detect_path_add_volume() {
  local dir_path=$1
  local volume_handler=$2
  if [[ $dir_path =~ ^// || $dir_path =~ ^\\\\ ]]; then
    # echo "  Detected network mount: $dir_path"
    get_network_permissions "$dir_path" "$volume_handler"
    local exit_code=$?  # Capture the exit code

    if [[ $exit_code -ne 0 ]]; then
      echo "Error: Failed to get network permissions." >&2
      return 1
    fi

    # Continue with the rest of the function
    return 0  # Indicate success
  else
    # echo "  Detected local directory"
    get_local_permissions "$dir_path" "$volume_handler"
    local exit_code=$?  # Capture the exit code

    if [[ $exit_code -ne 0 ]]; then
      echo "Error: Failed to get Local permissions." >&2
      return 1
    fi

    # Continue with the rest of the function
    return 0  # Indicate success
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
    echo "    Local directory does not have read permissions" >&2
    echo "    Error: Invalid directory. Please enter a valid directory." >&2
    return 1
  fi

  local mount_type
  # determine the mount type
  if [[ rw_required && !(-z $local_mount_type || $local_mount_type == "rw") ]];
  then
    echo "    Directory has read-only permissions, need read-write" >&2
    return 1
  fi
  if [[ -z $local_mount_type || $local_mount_type == "rw" ]]; then
    mount_type=$(prompt_readonly)
  else
    echo "    Directory has read-only permissions, mounting as read-only" >&2
    mount_type="ro"
  fi
  local local_mount_path="/mnt/${dir_path}"
  local_mount_paths+=("$local_mount_path")
  local mount_path="${dir_path}:$local_mount_path:${mount_type}"

  return $($volume_handler "$mount_path")
}

hardcode_local_assets() {
  # mkdir -p library/thumbs library/encoded-video
  
  sed -i "/- \${UPLOAD_LOCATION}:/a \\
      - ./library/thumbs:/usr/src/app/upload/thumbs\${added_by_wizard} \\
      - ./library/encoded-video:/usr/src/app/upload/encoded-video\${added_by_wizard}" docker-compose.yml

}

get_network_permissions() {
  local dir_path=$1
  local volume_handler=$2
  local network_addr
  local network_share
  local rw_required=""
  local local_mount_type=""

  if [[ $volume_handler == "update_upload_location" ]]; then
    rw_required="true"
  fi

  # Convert backslashes to forward slashes for consistency
  dir_path=${dir_path//\\/\/}

  # Extract network server address and share path
  #network_addr=$(echo "$dir_path" | awk -F'/' '{print $3}')
  network_addr=$(echo "$dir_path" | sed 's|^\([^/]*/\)\{2\}||; s|/.*||')
  network_share=$(echo "$dir_path" | sed -e "s|//$network_addr||")

  local mount_options
  if [[ $rw_required == "true" ]]; then
    mount_options="rw"
  else
    mount_options=$(prompt_readonly)  # Define mount_type based on the mount_options
  fi
  
  # Define the mount type based on the mount options
  local mount_type="hard"
  [[ $mount_options == "ro" ]] && mount_type="soft"
  
  local local_mount_path="mnt/network/${network_addr}${network_share}"
  # Replace slashes with dashes for the local mount path
  local_mount_path=$(echo "$local_mount_path" | sed 's|/|-|g')

  local_mount_paths+=("$local_mount_path")
  echo "*** Please note all credentials will be stored in plain-text in the docker-compose.yml file ***" >&2
  local username=$(prompt " Enter your username for the Network share" "" "")
  local password=$(prompt " Enter your password for the Network share" "" "")

  network_volumes+="
  $local_mount_path:
    driver: local
    driver_opts:
      type: \"cifs\"
      o: \"addr=$network_addr,username=$username,password=$password,$mount_options\"
      device: \"//${network_addr}${network_share}\""
  
  return $($volume_handler "$local_mount_path")
}

prompt_readonly() {
  local readonly=$(prompt "Should the directory be mounted as read-only?" "y n" "n")
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
  return 0
}

show_mount_paths() {
  echo "Mount path(s) available for use in Immich:"
  for path in "${local_mount_paths[@]}"; do
    echo "  $path"
  done
}

prompt_start_docker_compose() {
  local start_containers=$(prompt "Would you like to start the docker containers now?" "y n" "y")
  if [[ $start_containers == "y" ]]; then
    start_docker_compose
  fi
}

# --- BACKUPS ---

prompt_for_backups() {
  echo ""
  local backups=$(prompt "Would you like to enable database backups?" "y n" "y")
  if [[ $backups == "y" ]]; then
    sed -i '/^services:/a\
  backup:\
    container_name: immich_db_dumper\
    image: prodrigestivill/postgres-backup-local:14\
    restart: always\
    env_file:\
      - .env\
    environment:\
      POSTGRES_HOST: database\
      POSTGRES_CLUSTER: '\''TRUE'\''\
      POSTGRES_USER: ${DB_USERNAME}\
      POSTGRES_PASSWORD: ${DB_PASSWORD}\
      POSTGRES_DB: ${DB_DATABASE_NAME}\
      SCHEDULE: "@daily"\
      POSTGRES_EXTRA_OPTS: '\''--clean --if-exists'\''\
      BACKUP_DIR: /db_dumps\
    volumes:\
      - ./db_dumps:/db_dumps\
    depends_on:\
      - database\
      ' docker-compose.yml

    local backup_location
    while true; do
      backup_location=$(prompt "Enter backup location or use default" "" "./db_dumps")

      if [[ -n $backup_location && $backup_location != "./db_dumps" ]]; then
        # Validate the entered backup location
        if detect_path_add_volume "$backup_location" docker_compose_change_backup_location; then
          # Location is valid, exit the loop
          break
        else
          echo "  Invalid Location. Please enter a valid location." >&2
        fi
      else
        mkdir -p ./db_dumps  # Create the directory if it doesn't exist
        break  # Exit the loop
      fi
    done

    
  fi
}


docker_compose_change_backup_location() {
  local volume=$1
  # echo "  Updating docker-compose.yml with the new volume..."
    sed -i "s|./db_dumps|$volume|g" docker-compose.yml
    return 0
}

# --- END OF BACKUPS --- 

# --- DETECT HW ---
hw_is_wsl() {
  # Check if running in WSL by looking for WSL-specific files
  if grep -q "Microsoft" /proc/version || [ -f /proc/sys/kernel/osrelease ] && grep -q "WSL" /proc/sys/kernel/osrelease; then
    return 0  # True (running in WSL)
  else
    return 1  # False (not running in WSL)
  fi
}

hwa_is_cuda() {
  # Check for NVIDIA GPU, drivers, and CUDA toolkit
  if command -v lspci > /dev/null 2>&1; then
    if lspci | grep -i nvidia > /dev/null 2>&1; then
      # NVIDIA GPU detected
      
      # Use command -v to check for nvidia-smi and nvcc safely
      if command -v nvidia-smi > /dev/null 2>&1 && command -v nvcc > /dev/null 2>&1; then
        # NVIDIA drivers and CUDA toolkit are installed
        return 0  # True (CUDA available)
      fi
    fi
  fi
  
  return 1  # False (CUDA not available)
}

hwa_is_armnn() {
  # Check for ARM architecture
  if [[ $(uname -m) == "arm"* || $(uname -m) == "aarch64" ]]; then
    echo "ARM architecture detected."

    # Check for specific instruction sets (e.g., NEON)
    if grep -q "neon" /proc/cpuinfo; then
      echo "NEON support detected."
      return 0  # True (Arm NN compatible)
    fi
  fi
  return 1  # False (not Arm NN compatible)
}

hwa_is_openvino() {
  # Check for Intel CPU
  if grep -q "GenuineIntel" /proc/cpuinfo; then
    # Intel CPU detected
    
    # Check for AVX2 support
    if grep -q "avx2" /proc/cpuinfo; then
      # AVX2 is supported
      return 0  # True (compatible)
    fi

    # Check for AVX512 support
    if grep -q "avx512" /proc/cpuinfo; then
      # AVX512 is supported
      return 0  # True (compatible)
    fi
  fi
  return 1  # False (not compatible)
}

hwt_is_nvec() {
  # Check for NVIDIA GPU and NVENC support
  if command -v lspci > /dev/null 2>&1; then
    if lspci | grep -i nvidia > /dev/null 2>&1; then
      # NVIDIA GPU detected
      
      # Check if nvidia-smi is available
      if command -v nvidia-smi > /dev/null 2>&1; then
        # Get the GPU information
        local gpu_info=$(nvidia-smi --query-gpu=name --format=csv,noheader)
        
        # Check if NVENC is supported (can be adjusted based on GPU model)
        if nvidia-smi -q -d SUPPORTED_CLOCKS | grep -i "NVENC" > /dev/null 2>&1; then
          # NVENC is available for use
          return 0  # True (NVENC available)
        fi
      fi
    fi
  fi
  return 1  # False (NVENC not available)
}

hwt_is_quicksync() {
  # Check if lscpu is available
  if command -v lscpu > /dev/null 2>&1; then
    # Check for Intel CPU
    if lscpu | grep -i "Intel" > /dev/null 2>&1; then
      # Intel CPU detected

      # Check if the CPU supports Quick Sync
      if lscpu | grep -q "avx" && lscpu | grep -q "sse"; then
        # Check if the necessary video drivers are loaded
        if command -v vainfo > /dev/null 2>&1; then
          local quick_sync_support=$(vainfo | grep -i "h264")

          if [[ -n $quick_sync_support ]]; then
            return 0  # True (Quick Sync available)
          fi
        fi
      fi
    fi
  fi
  return 1  # False (Quick Sync not available)
}

hwt_is_rkmpp() {
  # Check for Rockchip hardware
  if command -v lspci > /dev/null 2>&1; then
    if lspci | grep -i "rockchip" > /dev/null 2>&1; then
      # Rockchip hardware detected

      # Check if the necessary drivers are loaded
      if command -v rkmpp > /dev/null 2>&1; then
        local rkmpp_support=$(rkmpp -version)

        if [[ -n $rkmpp_support ]]; then
          return 0  # True (RKMMP available)
        fi
      fi
    fi
  fi
  return 1  # False (RKMMP not available)
}

hwt_is_vaapi() {
  # Check for VAAPI support
  if command -v vainfo > /dev/null 2>&1; then
    # VAAPI command found, check for hardware support
    local vaapi_support=$(vainfo)

    if [[ $vaapi_support == *"driver:"* ]]; then
      return 0  # True (VAAPI available)
    fi
  fi
  return 1  # False (VAAPI not available)
}

download_file() {
  local file="$1"
  echo "  Downloading $file..."
  # Execute curl and store the result
  if "${Curl[@]}" "$RepoUrl/$file" -o "./$file"; then
    return 0  # Success (true)
  else
    return 1  # Failure (false)
  fi
}

merge_extends() {
  local compose_file="$1"
  local extends_file="$2"
  local service_name="$3"
  local image_flag="$4"
  local hw_flag="$image_flag"
  local extends_content=$(< "$extends_file")

  # Check if WSL is detected
  if hw_is_wsl; then
    # If WSL is detected and extends_content contains the flag, append "-wsl"
    if [[ "$extends_content" == *"$image_flag+=\"-wsl\""* ]]; then
      hw_flag="$image_flag-wsl"
    fi
  fi

  extends_content=$(sed -n "/^  $hw_flag:/,/^[[:space:]]\{2\}[^[:space:]]/ { /^[[:space:]]\{2\}[^[:space:]]/!p }" "$extends_file")
  local original_compose_content=$(sed -n "/^  $service_name:/,/^[[:space:]]\{2\}[a-zA-Z0-9_-]\+:/p" "$compose_file" | sed '$d')
  local compose_content=$original_compose_content


  # append the image flag to the image field in the compose file
  compose_content=$(echo "$compose_content" | sed "s|\(image:.*:\${IMMICH_VERSION:-release}\)|\1-$image_flag|")

  # --- Extract only the actual device mappings from extends_content ---

  # Initialize variables to store device groups and their settings
  declare -a device_groups
  declare -a device_group_settings
  local current_group=""
  local current_settings=""

  # Read each line of extends_content
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]{4}([a-zA-Z_]+): ]]; then
      # If we encounter a new group, store the previous group and its settings
      if [[ -n "$current_group" ]]; then
        device_groups+=("$current_group")
        device_group_settings+=("$current_settings")
      fi
      # Set the new current group
      current_group="${BASH_REMATCH[1]}:" # Get the group name from regex
      current_settings="" # Reset current settings for the new group
    else
      current_settings+="$line"$'\n' # Append to current settings
    fi
  done <<< "$extends_content"

  # Capture the last group settings if any
  if [[ -n "$current_group" ]]; then
    device_groups+=("$current_group")
    device_group_settings+=("$current_settings")
  fi
  # --- End of Extract only the actual device mappings from extends_content ---

  # --- Merge Files ---
  for i in "${!device_groups[@]}"; do
    local current_device_group=${device_groups[$i]}
    local current_group_settings=$(echo "${device_group_settings[$i]}" | sed "/^$/! s/\$/ $added_by_wizard/")


    # Check if 'current_device_group' section exists in the compose_content
    if echo "$compose_content" | grep -q $current_device_group; then  
      # Escape the current_device_group for use in sed, including slashes and hyphens
      local escaped_current_group_settings=$(echo "$current_group_settings" | sed 's/[\/&-]/\\&/g')

      # Prepare the escaped content for proper insertion into sed
      # Replace newline characters with `\n` and add 6 spaces before each new line for indentation
      escaped_current_group_settings=$(echo "$escaped_current_group_settings" | sed ':a;N;$!ba;s/\n/\\n/g')

      # Append new devices to the existing devices section, using the variable
      compose_content=$(echo "$compose_content" | sed "/    $current_device_group/a\\
$escaped_current_group_settings")
    else
      # Add new devices section after the immich-machine-learning service, using the variable
      compose_content="${compose_content}
    $current_device_group
$current_group_settings"
    fi

  done
  # --- End of Merge Files ---

  # --- Update the compose file with the merged content ---
  # Escape special characters in the content, including newlines
  escaped_compose_content=$(echo "$compose_content" | sed ':a;N;$!ba;s/[\/&]/\\&/g; s/\n/\\n/g')

# Perform the replacement directly, matching the original content based on the service_name
sed -i "/^  $service_name:/,/^[[:space:]]\{2\}[a-zA-Z0-9_-]\+:/ {
  /^  $service_name:/ {
    s|.*|$escaped_compose_content| 
  }
  /^[[:space:]]*$/!{ # Do not delete empty lines, keep them intact
    /^[[:space:]]\{2\}[a-zA-Z0-9_-]\+:/!d
  }
}" "$compose_file"
  

  # Check the result of the replacement
  if [[ $? -eq 0 ]]; then
    echo "File '$compose_file' updated successfully!"
  else
    echo "Failed to update '$compose_file'."
  fi

  # --- End of Update the compose file with the merged content ---
}



set_hwa() {
  local image_flag=""

  if hwa_is_cuda; then
    image_flag="cuda"
  elif hwa_is_armnn; then
    image_flag="armnn"
  elif hwa_is_openvino; then
    image_flag="openvino"
  fi

  if [[ -n "$image_flag" ]]; then
    local enable_hwa=$(prompt "Would you like to enable hardware acceleration?" "y n" "y")
    if [[ "$enable_hwa" == "y" ]]; then
      local hwa_file="hwaccel.ml.yml"
      if download_file "$hwa_file"; then
        merge_extends "docker-compose.yml" "$hwa_file" "immich-machine-learning" "$image_flag"
        rm -f "$hwa_file"
      else
        echo "  Failed to download $hwa_file. Skipping hardware acceleration."
      fi
    fi
  fi

}

set_hwt() {
  local image_flag=""

  if hwt_is_nvec; then
    image_flag="nvec"
  elif hwt_is_quicksync; then
    image_flag="quicksync"
  elif hwt_is_rkmpp; then
    image_flag="rkmpp"
  elif hwt_is_vaapi; then
    image_flag="vaapi"
  fi

  if [[ -n "$image_flag" ]]; then
    local enable_hwt=$(prompt "Would you like to enable hardware transcoding?" "y n" "y")
    if [[ "$enable_hwt" == "y" ]]; then
      local hwt_file="hwaccel.transcoding.yml"
      if download_file "$hwt_file"; then
        merge_extends "docker-compose" "$hwt_file" "immich-machine-learning" "$image_flag"
      else
        echo "  Failed to download $hwt_file. Skipping hardware transcoding."
      fi
    fi
  fi

}

# --- END OF DETECT HW ---

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
  set_hwa
  set_hwt
  prompt_for_upload_location
  prompt_for_external_library
  show_mount_paths
  prompt_for_backups
  add_network_volumes
  prompt_start_docker_compose
}

main "$@"