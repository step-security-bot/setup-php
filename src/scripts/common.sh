# Variables
export tick="✓"
export cross="✗"
export curl_opts=(-sL)
export old_versions="5.[3-5]"
export jit_versions="8.[0-9]"
export nightly_versions="8.[1-9]"
export xdebug3_versions="7.[2-4]|8.[0-9]"
export tool_path_dir="/usr/local/bin"
export composer_home="$HOME/.composer"
export composer_bin="$composer_home/vendor/bin"
export composer_json="$composer_home/composer.json"
export composer_lock="$composer_home/composer.lock"
export latest="releases/latest/download"
export github="https://github.com/shivammathur"
export jsdeliver="https://cdn.jsdelivr.net/gh/shivammathur"

# Function to log start of a operation.
step_log() {
  message=$1
  printf "\n\033[90;1m==> \033[0m\033[37;1m%s\033[0m\n" "$message"
}

# Function to log result of a operation.
add_log() {
  mark=$1
  subject=$2
  message=$3
  if [ "$mark" = "$tick" ]; then
    printf "\033[32;1m%s \033[0m\033[34;1m%s \033[0m\033[90;1m%s\033[0m\n" "$mark" "$subject" "$message"
  else
    printf "\033[31;1m%s \033[0m\033[34;1m%s \033[0m\033[90;1m%s\033[0m\n" "$mark" "$subject" "$message"
    [ "$fail_fast" = "true" ] && exit 1
  fi
}

# Function to log result of installing extension.
add_extension_log() {
  (
    check_extension "$(echo "$1" | cut -d '-' -f 1)" && add_log "$tick" "$1" "$2"
  ) || add_log "$cross" "$1" "Could not install $1 on PHP ${semver:?}"
}

# Function to read env inputs.
read_env() {
  [[ -z "${update}" ]] && update='false' && UPDATE='false' || update="${update}"
  [ "$update" = false ] && [[ -n ${UPDATE} ]] && update="${UPDATE}"
  [[ -z "${runner}" ]] && runner='github' && RUNNER='github' || runner="${runner}"
  [ "$runner" = false ] && [[ -n ${RUNNER} ]] && runner="${RUNNER}"
  [[ -z "${fail_fast}" ]] && fail_fast='false' || fail_fast="${fail_fast}"
}

# Function to download a file using cURL.
# mode: -s pipe to stdout, -v save file and return status code
# execute: -e save file as executable
get() {
  mode=$1
  execute=$2
  file_path=$3
  shift 3
  links=("$@")
  if [ "$mode" = "-s" ]; then
    sudo curl "${curl_opts[@]}" "${links[0]}"
  else
    for link in "${links[@]}"; do
      status_code=$(sudo curl -w "%{http_code}" -o "$file_path" "${curl_opts[@]}" "$link")
      [ "$status_code" = "200" ] && break
    done
    [ "$execute" = "-e" ] && sudo chmod a+x "$file_path"
    [ "$mode" = "-v" ] && echo "$status_code"
  fi
}

# Function to download and run scripts from GitHub releases with jsdeliver fallback.
run_script() {
  repo=$1
  shift
  args=("$@")
  get -q -e /tmp/install.sh "$github/$repo/$latest/install.sh" "$jsdeliver/$1@main/scripts/install.sh"
  bash /tmp/install.sh "${args[@]}"
}

# Function to install required packages on self-hosted runners.
self_hosted_setup() {
  if [ "$runner" = "self-hosted" ]; then
    if [[ "${version:?}" =~ $old_versions ]]; then
      add_log "$cross" "PHP" "PHP $version is not supported on self-hosted runner"
      exit 1
    else
      self_hosted_helper 
    fi
  fi
}

# Function to test if extension is loaded.
check_extension() {
  extension=$1
  if [ "$extension" != "mysql" ]; then
    php -m | grep -i -q -w "$extension"
  else
    php -m | grep -i -q "$extension"
  fi
}

# Function to check if extension is shared
shared_extension() {
  [ -e "${ext_dir:?}/$1.so" ]
}

# Function to enable cached extensions.
enable_cache_extension() {
  deps=()
  for ext in /tmp/extcache/"$1"/*; do
    deps+=("$(basename "$ext")")
  done
  if [ "x${deps[*]}" = "x" ]; then
    sudo rm -rf /tmp/extcache/"$1"
    enable_extension "$1" "$2"
  else
    deps+=("$1")
    if php "${deps[@]/#/-d ${2}=}" -m 2>/dev/null | grep -i -q "$1"; then
      for ext in "${deps[@]}"; do
        sudo rm -rf /tmp/extcache/"$ext"
        enable_extension "$ext" "$2"
      done
    fi
  fi
}

# Function to enable existing extensions.
enable_extension() {
  modules_dir="/var/lib/php/modules/$version"
  [ -d "$modules_dir" ] && sudo find "$modules_dir" -path "*disabled*$1" -delete
  enable_extension_dependencies "$1" "$2"
  if [ -d /tmp/extcache/"$1" ]; then
    enable_cache_extension "$1" "$2"
  elif ! check_extension "$1" && shared_extension "$1"; then
    echo "$2=${ext_dir:?}/$1.so" | sudo tee -a "${pecl_file:-${ini_file[@]}}" >/dev/null
  fi
}

# Function to get a map of extensions and their dependent shared extensions.
get_extension_map() {
  php -d'error_reporting=0' "${dist:?}"/../src/scripts/ext/extension_map.php
}

# Function to enable extension dependencies which are also extensions.
enable_extension_dependencies() {
  extension=$1
  prefix=$2
  if ! [ -e /tmp/map.orig ]; then
    get_extension_map | sudo tee /tmp/map.orig >/dev/null
  fi
  for dependency in $(grep "$extension:" /tmp/map.orig | cut -d ':' -f 2 | tr '\n' ' '); do
    enable_extension "$dependency" "$prefix"
  done
}

# Function to disable dependent extensions.
disable_extension_dependents() {
  local extension=$1
  for dependent in $(get_extension_map | grep -E ".*:.*\s$extension(\s|$)" | cut -d ':' -f 1 | tr '\n' ' '); do
    disable_extension_helper "$dependent" true
    add_log "${tick:?}" ":$extension" "Disabled $dependent as it depends on $extension"
  done
}

# Function to disable an extension.
disable_extension() {
  extension=$1
  if check_extension "$extension"; then
    if shared_extension "$extension"; then
      disable_extension_helper "$extension" true
      (! check_extension "$extension" && add_log "${tick:?}" ":$extension" "Disabled") ||
        add_log "${cross:?}" ":$extension" "Could not disable $extension on PHP ${semver:?}"
    else
      add_log "${cross:?}" ":$extension" "Could not disable $extension on PHP $semver as it not a shared extension"
    fi
  elif shared_extension "$extension"; then
    add_log "${tick:?}" ":$extension" "Disabled"
  else
    add_log "${tick:?}" ":$extension" "Could not find $extension on PHP $semver"
  fi
}

# Function to disable shared extensions.
disable_all_shared() {
  sudo sed -i.orig -E -e "/^(zend_)?extension\s*=/d" "${ini_file[@]}" "$pecl_file" 2>/dev/null || true
  sudo find "${ini_dir:-$scan_dir}"/.. -name "*.ini" -not -path "*php.ini" -not -path "*mods-available*" -delete  || true
  add_log "${tick:?}" "none" "Disabled all shared extensions"
}

# Function to configure PHP
configure_php() {
  (
    echo -e "date.timezone=UTC\nmemory_limit=-1"
    [[ "$version" =~ $jit_versions ]] && echo -e "opcache.enable=1\nopcache.jit_buffer_size=256M\nopcache.jit=1235"
    [[ "$version" =~ $xdebug3_versions ]] && echo -e "xdebug.mode=coverage"
  ) | sudo tee -a "${pecl_file:-${ini_file[@]}}" >/dev/null
}

# Function to configure PECL.
configure_pecl() {
  if ! [ -e /tmp/pecl_config ]; then
    for script in pear pecl; do
      sudo "$script" config-set php_ini "${pecl_file:-${ini_file[@]}}"
      sudo "$script" channel-update "$script".php.net
    done
    echo '' | sudo tee /tmp/pecl_config 
  fi
}

# Function to get the PECL version of an extension.
get_pecl_version() {
  extension=$1
  stability="$(echo "$2" | grep -m 1 -Eio "(stable|alpha|beta|rc|snapshot|preview)")"
  pecl_rest='https://pecl.php.net/rest/r/'
  response=$(get -s -n "" "$pecl_rest$extension"/allreleases.xml)
  pecl_version=$(echo "$response" | grep -m 1 -Eio "([0-9]+\.[0-9]+\.[0-9]+${stability}[0-9]+)")
  if [ ! "$pecl_version" ]; then
    pecl_version=$(echo "$response" | grep -m 1 -Eo "([0-9]+\.[0-9]+\.[0-9]+)")
  fi
  echo "$pecl_version"
}

# Function to install PECL extensions and accept default options
pecl_install() {
  local extension=$1
  add_pecl 
  yes '' 2>/dev/null | sudo pecl install -f "$extension" 
}

# Function to install a specific version of PECL extension.
add_pecl_extension() {
  extension=$1
  pecl_version=$2
  prefix=$3
  enable_extension "$extension" "$prefix"
  if [[ $pecl_version =~ .*(alpha|beta|rc|snapshot|preview).* ]]; then
    pecl_version=$(get_pecl_version "$extension" "$pecl_version")
  fi
  ext_version=$(php -r "echo phpversion('$extension');")
  if [ "$ext_version" = "$pecl_version" ]; then
    add_log "${tick:?}" "$extension" "Enabled"
  else
    disable_extension_helper "$extension" 
    pecl_install "$extension-$pecl_version"
    add_extension_log "$extension-$pecl_version" "Installed and enabled"
  fi
}

# Function to setup pre-release extensions using PECL.
add_unstable_extension() {
  extension=$1
  stability=$2
  prefix=$3
  pecl_version=$(get_pecl_version "$extension" "$stability")
  add_pecl_extension "$extension" "$pecl_version" "$prefix"
}

# Function to extract tool version.
get_tool_version() {
  tool=$1
  param=$2
  alp="[a-zA-Z0-9]"
  version_regex="[0-9]+((\.{1}$alp+)+)(\.{0})(-$alp+){0,1}"
  if [ "$tool" = "composer" ]; then
    if [ "$param" != "snapshot" ]; then
      composer_version="$(grep -Ea "const\sVERSION" "$tool_path_dir/composer" | grep -Eo "$version_regex")"
    else
      composer_version="$(grep -Ea "const\sBRANCH_ALIAS_VERSION" "$tool_path_dir/composer" | grep -Eo "$version_regex")+$(grep -Ea "const\sVERSION" "$tool_path_dir/composer" | grep -Eo "[a-zA-z0-9]+" | tail -n 1)"
    fi
    echo "$composer_version" | sudo tee /tmp/composer_version
  else
    $tool "$param" 2>/dev/null | sed -Ee "s/[Cc]omposer(.)?$version_regex//g" | grep -Eo "$version_regex" | head -n 1
  fi
}

# Function to configure composer
configure_composer() {
  tool_path=$1
  sudo ln -sf "$tool_path" "$tool_path.phar"
  php -r "try {\$p=new Phar('$tool_path.phar', 0);exit(0);} catch(Exception \$e) {exit(1);}"
  if [ $? -eq 1 ]; then
    add_log "$cross" "composer" "Could not download composer"
    exit 1
  fi
  if ! [ -d "$composer_home" ]; then
    sudo -u "$(id -un)" -g "$(id -gn)" mkdir -p -m=00755 "$composer_home"
  else
    sudo chown -R "$(id -un)":"$(id -gn)" "$composer_home"
  fi
  if ! [ -e "$composer_json" ]; then
    echo '{}' | tee "$composer_json" >/dev/null
    chmod 644 "$composer_json"
  fi
  composer -q config -g process-timeout 0
  echo "$composer_bin" >>"$GITHUB_PATH"
  if [ -n "$COMPOSER_TOKEN" ]; then
    composer -q config -g github-oauth.github.com "$COMPOSER_TOKEN"
  fi
}

# Function to setup a remote tool.
add_tool() {
  url=$1
  tool=$2
  ver_param=$3
  tool_path="$tool_path_dir/$tool"
  if ! [[ "$PATH" =~ $tool_path_dir ]]; then
    export PATH=$PATH:"$tool_path_dir"
    echo "export PATH=\$PATH:$tool_path_dir" | sudo tee -a "$GITHUB_ENV" >/dev/null
  fi
  if [ ! -e "$tool_path" ]; then
    rm -rf "$tool_path"
  fi
  IFS="," read -r -a url <<<"$url"
  status_code=$(get -v -e "$tool_path" "${url[@]}")
  if [ "$status_code" != "200" ] && [[ "${url[0]}" =~ .*github.com.*releases.*latest.* ]]; then
    url[0]="${url[0]//releases\/latest\/download/releases/download/$(get -s -n "" "$(echo "${url[0]}" | cut -d '/' -f '1-5')/releases" | grep -Eo -m 1 "([0-9]+\.[0-9]+\.[0-9]+)/$(echo "${url[0]}" | sed -e "s/.*\///")" | cut -d '/' -f 1)}"
    status_code=$(get -v -e "$tool_path" "${url[0]}")
  fi
  if [ "$status_code" = "200" ]; then
    add_tools_helper "$tool"
    tool_version=$(get_tool_version "$tool" "$ver_param")
    add_log "$tick" "$tool" "Added $tool $tool_version"
  else
    add_log "$cross" "$tool" "Could not setup $tool"
  fi
}

# Function to setup a tool using composer.
add_composertool() {
  tool=$1
  release=$2
  prefix=$3
  if [[ "$tool" =~ prestissimo|composer-prefetcher ]]; then
    composer_version=$(cat /tmp/composer_version)
    if [ "$(echo "$composer_version" | cut -d'.' -f 1)" != "1" ]; then
      echo "::warning:: Skipping $tool, as it does not support Composer $composer_version. Specify composer:v1 in tools to use $tool"
      add_log "$cross" "$tool" "Skipped"
      return
    fi
  fi
  (
    sudo rm -f "$composer_lock"  || true
    composer global require "$prefix$release" 2>&1 | tee /tmp/composer.log 
    log=$(grep "$prefix$tool" /tmp/composer.log) &&
      tool_version=$(get_tool_version 'echo' "$log") &&
      add_log "$tick" "$tool" "Added $tool $tool_version"
  ) || add_log "$cross" "$tool" "Could not setup $tool"
  add_tools_helper "$tool"
  if [ -e "$composer_bin/composer" ]; then
    sudo cp -p "$tool_path_dir/composer" "$composer_bin"
  fi
}

# Function to get PHP version in semver format.
php_semver() {
  php -v | grep -Eo -m 1 "[0-9]+\.[0-9]+\.[0-9]+((-?[a-zA-Z]+([0-9]+)?)?){2}" | head -n 1
}

# Function to get the tag for a php version.
php_src_tag() {
  commit=$(php_extra_version | grep -Eo "[0-9a-zA-Z]+")
  if [[ -n "${commit}" ]]; then
    echo "$commit"
  else
    echo "php-$semver"
  fi
}
