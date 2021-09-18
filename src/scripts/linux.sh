# Function to setup environment for self-hosted runners.
self_hosted_helper() {
  if ! command -v sudo >/dev/null; then
    apt-get update
    apt-get install -y sudo || add_log "${cross:?}" "sudo" "Could not install sudo"
  fi
  if ! command -v apt-fast >/dev/null; then
    sudo ln -sf /usr/bin/apt-get /usr/bin/apt-fast
    trap "sudo rm -f /usr/bin/apt-fast 2>/dev/null" exit
  fi
  install_packages apt-transport-https ca-certificates curl file make jq unzip autoconf automake gcc g++ gnupg
}

# Function to install a package
install_packages() {
  packages=("$@")
  [[ "${packages[*]}" =~ php ]] && add_ppa ondrej/php 
  $apt_install "${packages[@]}"  || (update_lists && $apt_install "${packages[@]}" )
}

# Function to disable an extension.
disable_extension_helper() {
  local extension=$1
  local disable_dependents=${2:-false}
  if [ "$disable_dependents" = "true" ]; then
    disable_extension_dependents "$extension"
  fi
  sudo sed -Ei "/=(.*\/)?\"?$extension(.so)?$/d" "${ini_file[@]}" "$pecl_file"
  sudo find "$ini_dir"/.. -name "*$extension.ini" -not -path "*mods-available*" -delete  || true
}

# Function to add PDO extension.
add_pdo_extension() {
  pdo_ext="pdo_$1"
  if check_extension "$pdo_ext"; then
    add_log "${tick:?}" "$pdo_ext" "Enabled"
  else
    ext=$1
    ext_name=$1
    if shared_extension pdo; then
      disable_extension_helper pdo
      echo "extension=pdo.so" | sudo tee "${ini_file[@]/php.ini/conf.d/10-pdo.ini}" 
    fi
    if [ "$ext" = "mysql" ]; then
      enable_extension "mysqlnd" "extension"
      ext_name='mysqli'
    elif [ "$ext" = "dblib" ]; then
      ext_name="sybase"
    elif [ "$ext" = "firebird" ]; then
      install_packages libfbclient2 
      enable_extension "pdo_firebird" "extension"
      ext_name="interbase"
    elif [ "$ext" = "sqlite" ]; then
      ext="sqlite3"
      ext_name="sqlite3"
    fi
    add_extension "$ext_name" "extension" 
    add_extension "$pdo_ext" "extension" 
    add_extension_log "$pdo_ext" "Enabled"
  fi
}

# Function to add extensions.
add_extension() {
  extension=$1
  prefix=$2
  enable_extension "$extension" "$prefix"
  if check_extension "$extension"; then
    add_log "${tick:?}" "$extension" "Enabled"
  else
    if [[ "$version" =~ ${nightly_versions:?} ]]; then
      pecl_install "$extension"
    else
      install_packages "php$version-$extension" || pecl_install "$extension"
    fi
    add_extension_log "$extension" "Installed and enabled"
  fi
  sudo chmod 777 "${ini_file[@]}"
}

# Function to setup phpize and php-config.
add_devtools() {
  tool=$1
  if ! command -v "$tool$version" >/dev/null; then
    install_packages "php$version-dev" "php$version-xml"
  fi
  switch_version "phpize" "php-config"
  add_log "${tick:?}" "$tool" "Added $tool $semver"
}

# Function to setup the nightly build from shivammathur/php-builder
setup_nightly() {
  run_script "php-builder" "${runner:?}" "$version"
}

# Function to setup PHP 5.3, PHP 5.4 and PHP 5.5.
setup_old_versions() {
  run_script "php5-ubuntu" "$version"
}

# Function to add PECL.
add_pecl() {
  add_devtools phpize 
  if ! command -v pecl >/dev/null; then
    install_packages php-pear
  fi
  configure_pecl 
  pear_version=$(get_tool_version "pecl" "version")
  add_log "${tick:?}" "PECL" "Added PECL $pear_version"
}

# Function to switch versions of PHP binaries.
switch_version() {
  tools=("$@") && ! (( ${#tools[@]} )) && tools+=(pear pecl php phar phar.phar php-cgi php-config phpize phpdbg)
  to_wait=()
  for tool in "${tools[@]}"; do
    if [ -e "/usr/bin/$tool$version" ]; then
      sudo update-alternatives --set "$tool" /usr/bin/"$tool$version" &
      to_wait+=($!)
    fi
  done
  wait "${to_wait[@]}"
}

# Function to install packaged PHP
add_packaged_php() {
  if [ "$runner" = "self-hosted" ] || [ "${use_package_cache:-true}" = "false" ]; then
    update_lists
    IFS=' ' read -r -a packages <<<"$(echo "cli curl mbstring xml intl" | sed "s/[^ ]*/php$version-&/g")"
    install_packages "${packages[@]}"
  else
    run_script "php-ubuntu" "$version"
  fi
}

# Function to update PHP.
update_php() {
  initial_version=$(php_semver)
  add_packaged_php
  updated_version=$(php_semver)
  if [ "$updated_version" != "$initial_version" ]; then
    status="Updated to"
  else
    status="Switched to"
  fi
}

# Function to install PHP.
add_php() {
  if [[ "$version" =~ ${nightly_versions:?} ]]; then
    setup_nightly
  elif [[ "$version" =~ ${old_versions:?} ]]; then
    setup_old_versions
  else
    add_packaged_php
  fi
  status="Installed"
}

# Function to ini file for pear and link it to each SAPI.
link_pecl_file() {
  echo '' | sudo tee "$pecl_file" 
  for file in "${ini_file[@]}"; do
    sapi_scan_dir="$(realpath -m "$(dirname "$file")")/conf.d"
    [ "$sapi_scan_dir" != "$scan_dir" ] && ! [ -h "$sapi_scan_dir" ] && sudo ln -sf "$pecl_file" "$sapi_scan_dir/99-pecl.ini"
  done
}

# Function to get extra version.
php_extra_version() {
  if [ -e /etc/php/"$version"/COMMIT ]; then
    echo " ($(cat "/etc/php/$version/COMMIT"))"
  fi
}

# Function to Setup PHP
setup_php() {
  step_log "Setup PHP"
  sudo mkdir -m 777 -p /var/run /run/php
  if [ "$(php-config --version 2>/dev/null | cut -c 1-3)" != "$version" ]; then
    if [ ! -e "/usr/bin/php$version" ]; then
      add_php 
    else
      if [ "${update:?}" = "true" ]; then
        update_php 
      else
        status="Switched to"
      fi
    fi
    if ! [[ "$version" =~ ${old_versions:?}|${nightly_versions:?} ]]; then
      switch_version 
    fi
  else
    if [ "$update" = "true" ]; then
      update_php 
    else
      status="Found"
    fi
  fi
  if ! command -v php"$version" >/dev/null; then
    add_log "$cross" "PHP" "Could not setup PHP $version"
    exit 1
  fi
  semver=$(php_semver)
  extra_version=$(php_extra_version)
  ext_dir=$(php -i | grep "extension_dir => /" | sed -e "s|.*=> s*||")
  scan_dir=$(php --ini | grep additional | sed -e "s|.*: s*||")
  ini_dir=$(php --ini | grep "(php.ini)" | sed -e "s|.*: s*||")
  pecl_file="$scan_dir"/99-pecl.ini
  export ext_dir
  mapfile -t ini_file < <(sudo find "$ini_dir/.." -name "php.ini" -exec readlink -m {} +)
  link_pecl_file
  configure_php
  sudo rm -rf /usr/local/bin/phpunit 
  sudo chmod 777 "${ini_file[@]}" "$pecl_file" "${tool_path_dir:?}"
  sudo cp "$dist"/../src/configs/*.json "$RUNNER_TOOL_CACHE/"
  echo "::set-output name=php-version::$semver"
  add_log "${tick:?}" "PHP" "$status PHP $semver$extra_version"
}

# Variables
version=$1
dist=$2
debconf_fix="DEBIAN_FRONTEND=noninteractive"
apt_install="sudo $debconf_fix apt-fast install -y --no-install-recommends"
scripts="${dist}"/../src/scripts

. /etc/os-release
# shellcheck source=.
. "${scripts:?}"/ext/source.sh
. "${scripts:?}"/tools/ppa.sh
. "${scripts:?}"/tools/add_tools.sh
. "${scripts:?}"/common.sh
read_env
self_hosted_setup
setup_php
