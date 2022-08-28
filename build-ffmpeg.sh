#!/bin/bash
# Based on ideas from https://github.com/rdp/ffmpeg-windows-build-helpers but
# significantly cleaner and smaller to suit my needs.

readonly colour_fg_norm="\033[39m"
readonly colour_red="\033[39m"
readonly colour_green="\033[32m"
readonly logfile=$(realpath build-ffmpeg.log)

echo "" > $logfile
log() {
  echo $@ >> $logfile
}

info() {
  echo "$@"
  log "$@"
}

die() {
  echo -e "${colour_red}$@${colour_fg_norm}"
  exit 1
}

call() {
  info "$@"
  if is_debug; then
    $@ | tee -a "$logfile"
  else
    $@ >> "$logfile" 2>&1
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
  pushd "$src_path"
  local -r repo_url="$1"
  local -r dest_dir="$2"
  local -r revision="$3"
  required_parameters repo_url dest_dir revision

  if [[ ! -z $revision ]]; then
    revision_string="-r $revision"
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
  popd
}

update_git_repo() {
  pushd "$src_path"
  local -r repo_url="$1"
  local -r dest_dir="$2"
  local -r checkout_name="$3"
  required_parameters repo_url dest_dir checkout_name

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
  popd
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

ninja_install() {
  info "${FUNCNAME[O]}"
  if ! call ninja; then
    die "Function \"${FUNCNAME[1]}\" failed to make."
  fi

  if ! call ninja install; then
    die "Function \"${FUNCNAME[1]}\" failed to make install"
  fi
}

update_command() {
  local -r hash_name=$1
  shift
  file=$(get_parameter_hash "$hash_name" "$@")
  if [ ! -f "$file" ]; then   
    if ! call $@; then
      die "Function \"${FUNCNAME[1]}\" failed to configure (PWD=$PWD)"
    fi
    touch -- "$file"
  fi
}

update_configure() {
  update_command "configure" ./configure $@
}

update_cmake() {
  local -r build_dir=$1
  local -r cur_dir=$(pwd)
  shift
  mkdir -p "$build_dir"
  pushd "$build_dir"
  update_command "cmake" cmake "$cur_dir" $@ $cmake_system_arg -DCMAKE_INSTALL_PREFIX="$prefix_path"
  popd
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

build_zlib() {
  info "${FUNCNAME[O]}"
  update_git_repo https://github.com/madler/zlib.git zlib v1.2.11
  pushd zlib
  update_cmake "../zlib_build" -G Ninja
  pushd "../zlib_build"
  ninja_install
  popd
  popd
}

build_lame() {
  info "${FUNCNAME[O]}"
  update_svn_repo https://svn.code.sf.net/p/lame/svn/trunk/lame lame 6507
  pushd lame
  # DNCURSES_STATIC Due to https://github.com/msys2/MINGW-packages/issues/10312
  CFLAGS="-DNCURSES_STATIC ${CFLAGS}" 
    update_configure --prefix="${prefix_path}" \
                     $host_arg                 \
                     --enable-nasm             \
                     --enable-static           \
                     --disable-shared          \
                     --disable-decoder
  make_install
  ffmpeg_config_opts+=(--enable-libmp3lame)
  popd 
}

build_fdk_aac() {
  info "${FUNCNAME[O]}"
  update_git_repo https://github.com/mstorsjo/fdk-aac.git fdk-aac v2.0.2
  pushd fdk-aac
  update_autoreconf
  update_configure --prefix="$prefix_path" $host_arg --disable-shared
  make_install
  ffmpeg_config_opts+=(--enable-libfdk_aac)
  popd 
}

build_opus() {
  info "${FUNCNAME[O]}"
  update_git_repo https://github.com/xiph/opus.git opus
  pushd opus
  update_autoreconf
  update_configure --prefix="$prefix_path"    \
                   $host_arg                  \
                   --disable-doc              \
                   --disable-extra-programs   \
                   --disable-stack-protector  \
                   --disable-shared
  make_install
  ffmpeg_config_opts+=(--enable-libopus)
  popd
}

build_x264() {
  info "${FUNCNAME[O]}"
  update_git_repo "https://code.videolan.org/videolan/x264.git" "x264" "origin/stable"
  pushd x264
  update_configure --prefix="$prefix_path" $host_arg --enable-static --disable-cli --disable-opencl
  make_install
  ffmpeg_config_opts+=(--enable-libx264)
  popd
}

build_vpx() {
  info "${FUNCNAME[O]}"
  update_git_repo https://chromium.googlesource.com/webm/libvpx.git vpx v1.12.0
  pushd vpx
  # vxp doesn't compile with mingw on native windows.
  # If using msys, then install the vpx library and comment
  # out everything but ffmpeg_config_opts+=(--enable-libvpx)
  local target_arg=
  if [[ $host == "x86_64-w64-mingw32" ]]; then
    target_arg="--target=x86_64-win64-gcc"
  fi
  CFLAGS="-std=gnu99 ${CFLAGS}" \
    update_configure \
      --prefix="$prefix_path" \
      ${target_arg} \
      --enable-static \
      --disable-shared \
      --disable-examples \
      --disable-tools \
      --disable-docs \
      --disable-unit-tests \
      --enable-vp9-highbitdepth \
  make_install
  ffmpeg_config_opts+=(--enable-libvpx)
  popd
}

build_aomav1() {
  info "${FUNCNAME[O]}" 
  update_git_repo https://aomedia.googlesource.com/aom aom
  pushd aom
  update_cmake "../aom_build" -DENABLE_DOCS=0 -DENABLE_TESTS=0 -DCONFIG_RUNTIME_CPU_DETECT=0 -DAOM_TARGET_CPU=generic -DCMAKE_BUILD_STATIC_LIBS=ON
  pushd "../aom_build"
  make_install
  ffmpeg_config_opts+=(--enable-libaom)
  popd
}

build_dependencies() {
  pushd "$src_path"
  build_zlib
  build_lame
  build_fdk_aac
  #build_opus
  build_x264
  build_vpx
  #build_aomav1
  popd
}

build_ffmpeg() {
  info "${FUNCNAME[O]}"
  pushd "$src_path"
  update_git_repo "https://git.ffmpeg.org/ffmpeg.git" ffmpeg n5.1
  pushd ffmpeg
  if is_cross; then
    ffmpeg_config_opts+=(--target-os=mingw32)
    ffmpeg_config_opts+=(--cross-prefix="$toolchain-")
    ffmpeg_config_opts+=(--enable-cross-compile)
    ffmpeg_config_opts+=(--pkg-config=pkg-config)
  fi
  ffmpeg_config_opts+=(--arch=x86_64)
  ffmpeg_config_opts+=(--prefix=$prefix_path)
  ffmpeg_config_opts+=(--enable-static)
  ffmpeg_config_opts+=(--enable-nonfree)
  ffmpeg_config_opts+=(--enable-gpl)
  ffmpeg_config_opts+=(--extra-libs="-lm")
  ffmpeg_config_opts+=(--extra-ldflags="-static")
  update_configure "${ffmpeg_config_opts[@]}"
  make_install
  popd
  popd
  info "Success."
  info "You can find the ffmpeg executable in ${prefix_path}/bin"
}

parse_command_line() {
  for i in "$@"; do
    case $i in
        -d|--debug)
        FLAG_debug=1
        shift
        ;;
        -h=*|--host=*)
        FLAG_host="${i#*=}"
        shift 
        ;;
        --target-os=*)
        FLAG_target_os="${i#*=}"
        shift # past argument=value
        ;;
        --toolchain=*)
        FLAG_toolchain="${i#*=}"
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
  FLAG_debug=0
  FLAG_host=
  FLAG_target_os=
  FLAG_toolchain=
  parse_command_line $@

  readonly debug=$FLAG_debug

  set -e
  if is_debug; then
    set -x
  fi

  if [[ "$FLAG_target_os" = "mingw32" ]]; then
    if [[ -z "$FLAG_toolchain" ]]; then
      readonly toolchain="x86_64-w64-mingw32"
    fi
    if [[ -z "$FLAG_host" ]]; then
      readonly host="x86_64-w64-mingw32"
      readonly host_arg="--host=$host"
    fi
  fi

  if [[ ! -z "$FLAG_toolchain" ]]; then
    readonly toolchain="FLAG_toolchain"
  fi

  if [[ ! -z "$FLAG_host" ]]; then
    readonly host="$FLAG_host"
    readonly host_arg="--host=$host"
  fi
  
  if [[ -z "$host" ]]; then
    readonly builddir="native"
  else
    readonly builddir="$host"
  fi

  if is_cross; then
    declare -r cmake_system_arg="-DCMAKE_SYSTEM_NAME=Windows"
  fi

  readonly root_dir=$(pwd)
  mkdir -p $root_dir/_target/$builddir/prefix
  mkdir -p $root_dir/_target/$builddir/src
  readonly prefix_path="$(realpath $root_dir/_target/$builddir/prefix)"
  readonly src_path="$(realpath $root_dir/_target/$builddir/src)"
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