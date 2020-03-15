#!/bin/bash
# Based on ideas from https://github.com/rdp/ffmpeg-windows-build-helpers but
# significantly cleaner and smaller to suit my needs.

readonly colour_fg_norm="\e[39m"
readonly colour_red="\e[39m"
readonly colour_green="\e[32m"
readonly logfile=build-ffmpeg.log

echo "" > $logfile
log() {
  echo $@ >> $logfile
}

info() {
  echo "$@"
  log "$@"
}

infoc() {
  colour=$1
  shift
  echo -e "${colour}$@${colour_fg_norm}"
  log "$@"
}

die() {
  echo -e "${colour_red}$@${colour_fg_norm}"
  exit 1
}

call() {
  echo "$@"
  if is_debug; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

pushd_s() {
  if is_debug; then
    pushd "$1" || die "Failed to push $1"
  else
    pushd "$1" >/dev/null 2>&1
  fi
}

popd_s() {
  if is_debug; then
    popd || die "Failed to pop $1"
  else
    popd >/dev/null 2>&1
  fi
}

required_parameters() {
  for var in "$@"; do
    if [[ -z "${!var}" ]]; then
      die "In function \"${FUNCNAME[1]}\", \"$var\" is a required parameter."
    fi
  done
}

git_hard_reset() {
  call git reset --hard 
  call git clean -f 
}

update_svn_repo() {
  pushd_s "$src_path"
  declare -r repo_url="$1"
  declare -r dest_dir="$2"
  declare -r revision="$3"
  required_parameters repo_url dest_dir

  if [[ -z $revision ]]; then
    revision_string="-r$revision"
  fi

  info "svn checkout from $repo_url to $dest_dir"
  if [ ! -d $dest_dir ]; then
    call rm -Rf "$dest_dir.tmp"
    if ! call svn checkout $revision_string $repo_url "$dest_dir.tmp"; then
      die "Failed to svn checkout $repo_url"
      exit 1
    fi
    mv "$dest_dir.tmp" "$dest_dir"
  else
    if ! call svn checkout $revision_string $repo_url "$dest_dir"; then
      die "Failed to svn checkout $repo_url"
      exit 1
    fi
  fi
  popd_s
}

update_git_repo() {
  pushd_s "$src_path"
  declare -r repo_url="$1"
  declare -r dest_dir="$2"
  local checkout_name="$3"
  required_parameters repo_url dest_dir

  if [ ! -d $dest_dir ]; then
    info "git clone from $repo_url to $dest_dir"
    call rm -Rf "$dest_dir.tmp"
    if ! call git clone "$repo_url" "$dest_dir.tmp"; then
      die "Failed to git clone $repo_url"
      exit 1
    fi
    mv "$dest_dir.tmp" "$dest_dir"
    info "done git cloning to $dest_dir"
    cd $dest_dir
  else
    cd $dest_dir
    if [[ $git_get_latest = "y" ]]; then
      call git fetch # want this for later...
    else
      log "not doing git get latest pull for latest code $dest_dir" # too slow'ish...
    fi
  fi

  old_git_version=$(git rev-parse HEAD)
  if [[ -z $checkout_name ]]; then
    checkout_name="origin/master"
  fi
  info "git checkout of $dest_dir:$checkout_name" 
  call git fetch --all
  call git checkout "$checkout_name" || (git_hard_reset && git checkout "$checkout_name") || (git reset --hard "$checkout_name") || exit 1
  if call git show-ref --verify --quiet "refs/remotes/origin/$checkout_name"; then 
    call git merge "origin/$checkout_name" || exit 1 # get incoming changes to a branch
  fi
  new_git_version=`git rev-parse HEAD`
  if [[ "$old_git_version" != "$new_git_version" ]]; then
    log "got upstream changes, forcing re-configure. Doing git clean -f"
    git_hard_reset
  else
    log "fetched no code changes, not forcing reconfigure for that..."
  fi
  popd_s
}

set_cpu_count() {
  local processor_count="$(grep -c processor /proc/cpuinfo 2>/dev/null)"
  if [ -z "$processor_count" ]; then
    processor_count=`sysctl -n hw.ncpu | tr -d '\n'` # OS X cpu count
    if [ -z "$processor_count" ]; then
      log "warning, unable to determine cpu count, defaulting to 1"
      processor_count=1 # else default to just 1, instead of blank, which means infinite
    fi
  fi

  cpu_count=$processor_count
}

get_parameter_hash() {
  all_args="$(printenv) $@"
  hash=$(echo "$all_args" | md5sum | cut -f1 -d" ")
  echo "$1_$hash"
}

set_enviornment() {
  if is_cross; then
    export CC=${toolchain}-gcc
    export AR=${toolchain}-ar 
    export RANLIB=${toolchain}-ranlib 
    export LD=${toolchain}-ld 
    export STRIP=${toolchain}-strip 
    export CXX=${toolchain}-g++
  fi
  export CFLAGS="-I${prefix_path}/include"
  export CXXFLAGS="-I${prefix_path}/include"
  export LDFLAGS="-L${prefix_path}/lib -pthread"
  export PKG_CONFIG_PATH="${prefix_path}/lib/pkgconfig"
}

make_install() {
  info "${FUNCNAME[O]}"
  if ! call make -j$cpu_count; then
    die "Function \"${FUNCNAME[1]}\" failed to make."
  fi

  if ! call make install; then
    die "Function \"${FUNCNAME[1]}\" failed to make install"
  fi
}

update_configure() {
  configure_hash=$(get_parameter_hash "configure" "$@")
  if [ ! -f "$configure_hash" ]; then   
    if ! call ./configure "$@"; then
      die "Function \"${FUNCNAME[1]}\" failed to configure"
    fi
    touch -- "$configure_hash"
  fi
}

update_autoreconf() {
  if [ ! -f configure ]; then
    if ! call autoreconf -fiv; then
      die "Function \"${FUNCNAME[1]}\" failed to autoreconf"
    fi
  fi
}

is_debug() {
  if (("$debug" == 0)); then
    return 1
  else 
    return 0
  fi
}

is_cross() {
  if [[ "$builddir" == "native" ]]; then
    return 1
  else
    return 0
  fi
}

build_lame() {
  info "${FUNCNAME[O]}"
  update_svn_repo https://svn.code.sf.net/p/lame/svn/trunk/lame lame RELEASE__3_100
  pushd_s lame
  update_configure --prefix="$prefix_path" --host=$host --enable-nasm --disable-shared
  make_install
  ffmpeg_config_opts+=(--enable-libmp3lame)
  popd_s 
}

build_fdk_aac() {
  info "${FUNCNAME[O]}"
  update_git_repo https://github.com/mstorsjo/fdk-aac.git fdk-aac
  pushd_s fdk-aac
  update_autoreconf
  update_configure --prefix="$prefix_path" --host=$host --disable-shared
  make_install
  ffmpeg_config_opts+=(--enable-libfdk_aac)
  popd_s 
}

build_opus() {
  info "${FUNCNAME[O]}"
  update_git_repo https://git.xiph.org/opus.git opus
  pushd_s opus
  update_autoreconf
  update_configure --prefix="$prefix_path" --host=$host --disable-doc --disable-extra-programs --disable-stack-protector --disable-shared
  make_install
  ffmpeg_config_opts+=(--enable-libopus)
  popd_s
}

build_x264() {
  info "${FUNCNAME[O]}"
  update_git_repo "https://code.videolan.org/videolan/x264.git" "x264" "origin/stable"
  pushd_s x264
  update_configure --prefix="$prefix_path" --host=$host --enable-static --disable-cli
  make_install
  ffmpeg_config_opts+=(--enable-libx264)
  popd_s
}

build_vpx() {
  info "${FUNCNAME[O]}"
  update_git_repo https://chromium.googlesource.com/webm/libvpx.git vpx
  pushd_s vpx
  local vpx_host=
  if [[ $host == "x86_64-w64-mingw32" ]]; then
    vpx_host="x86_64-win64-gcc"
  fi
  update_configure \
    --prefix="$prefix_path" \
    --target=$vpx_host \
    --enable-static \
    --disable-shared \
    --disable-examples \
    --disable-tools \
    --disable-docs \
    --disable-unit-tests \
    --enable-vp9-highbitdepth 
  make_install
  ffmpeg_config_opts+=(--enable-libvpx)
  popd_s
}

build_dependencies() {
  pushd_s "$src_path"
  build_lame
  build_fdk_aac
  build_opus
  build_x264
  build_vpx
  popd_s
}

build_ffmpeg() {
  info "${FUNCNAME[O]}"
  pushd_s "$src_path"
  update_git_repo "https://github.com/FFmpeg/FFmpeg.git" ffmpeg
  pushd_s ffmpeg
  if is_cross; then
    ffmpeg_config_opts+=(--target-os=mingw32)
    ffmpeg_config_opts+=(--cross-prefix=$toolchain-)
    ffmpeg_config_opts+=(--enable-cross-compile)
    ffmpeg_config_opts+=(--pkg-config=pkg-config)
  fi
  ffmpeg_config_opts+=(--arch=x86_64)
  ffmpeg_config_opts+=(--prefix=$prefix_path)
  ffmpeg_config_opts+=(--enable-static)
  ffmpeg_config_opts+=(--enable-nonfree)
  ffmpeg_config_opts+=(--enable-gpl)
  update_configure "${ffmpeg_config_opts[@]}"
  make_install
  popd_s
  popd_s
  infoc "${colour_green}" "Success."
  info "You can find the ffmpeg executable in ${prefix_path}/bin"
}

parse_command_line() {
  for i in "$@"; do
    case $i in
        -d|--debug)
        cl_debug=1
        shift
        ;;
        -h=*|--host=*)
        cl_host="${i#*=}"
        shift 
        ;;
        --target-os=*)
        cl_target_os="${i#*=}"
        shift # past argument=value
        ;;
        --toolchain=*)
        cl_toolchain="${i#*=}"
        shift # past argument=value
        ;;
        --default)
        DEFAULT=YES
        shift # past argument with no value
        ;;
        *)
              # unknown option
        ;;
    esac
  done
}

main() {
  cl_debug=0
  cl_host=
  cl_target_os=
  cl_toolchain=
  parse_command_line $@

  readonly debug=$cl_debug

  if is_debug; then
    set -x
  fi

  if [[ "$cl_target_os" = "mingw32" ]]; then
    if [[ -z "$cl_toolchain" ]]; then
      readonly toolchain="x86_64-w64-mingw32"
    fi
    if [[ -z "$cl_host" ]]; then
      readonly host="x86_64-w64-mingw32"
    fi
  fi

  if [[ ! -z "$cl_toolchain" ]]; then
    readonly toolchain="cl_toolchain"
  fi
  if [[ ! -z "$cl_host" ]]; then
    readonly host="$cl_host"
  fi
  
  if [[ -z "$host" ]]; then
    readonly builddir="native"
  else
    readonly builddir="$host"
  fi

  readonly root_dir=$(pwd)
  mkdir -p $root_dir/_target/$builddir/prefix
  mkdir -p $root_dir/_target/$builddir/src
  readonly prefix_path="$(realpath $root_dir/_target/$builddir/prefix)"
  readonly src_path="$(realpath $root_dir/_target/$builddir/src)"
  # printf -v text "%s" \
  #   "CC=${toolchain}-gcc " \
  #   "AR=${toolchain}-ar " \
  #   "RANLIB=${toolchain}-ranlib " \
  #   "LD=${toolchain}-ld " \
  #   "STRIP=${toolchain}-strip " \
  #   "CXX=${toolchain}-g++ " \
  #   "CFLAGS=\"-I${prefix_path}/include\" " \
  #   "CXXFLAGS=\"-I${prefix_path}/include\" " \
  #   "LDFLAGS=\"-L${prefix_path}/lib\" " \
  #   "PKG_CONFIG_PATH=\"${prefix_path}/lib/pkgconfig\""
  # readonly toolchain_env="$text"
  set_cpu_count
  set_enviornment
  info "Configuration: "
  info "-----------------------------------------------------------------------"
  info "prefix_path=$prefix_path"
  info "src_path=$src_path"
  info "host=$host"
  info "toolchain=$toolchain"
  info "toolchain_env=$toolchain_env"
  info "cpu_count=$cpu_count"
  info "is_cross=$(is_cross)"
  build_dependencies
  build_ffmpeg
}

main "$@"