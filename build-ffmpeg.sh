#!/bin/bash
# Based on ideas from https://github.com/rdp/ffmpeg-windows-build-helpers but
# significantly cleaner and smaller to suit my needs.
log_error() {
  echo -e "\e[91m${1}\e[39m"
  exit -1
}

log_stage() {
  echo "$1"
}

g_log_info=1
log_info() {
  if (( g_log_info == 1 )); then
    echo $1
  fi
}

required_parameters() {
  for var in "$@"; do
    if [[ -z "${!var}" ]]; then
      log_error "In function \"${FUNCNAME[1]}\", \"$var\" is a required parameter."
    fi
  done
}

git_hard_reset() {
  git reset --hard 
  git clean -f 
}

update_svn_repo() {
  pushd "$src_path"
  declare -r repo_url="$1"
  declare -r dest_dir="$2"
  declare -r revision="$3"
  required_parameters repo_url dest_dir

  if [[ -z $revision ]]; then
    revision_string="-r$revision"
  fi

  if [ ! -d $dest_dir ]; then
    log_info "svn checkout from $repo_dir to $dest_dir"
    rm -Rf "$dest_dir.tmp"
    if ! svn checkout $revision_string $repo_url "$dest_dir"; then
      log_error "Failed to svn checkout $repo_url"
      exit 1
    fi
    mv "$dest_dir.tmp" "$dest_dir"
  fi
  popd
}

update_git_repo() {
  pushd "$src_path"
  declare -r repo_url="$1"
  declare -r dest_dir="$2"
  local checkout_name="$3"
  required_parameters repo_url dest_dir

  if [ ! -d $dest_dir ]; then
    log_info "git clone from $repo_url to $dest_dir"
    rm -rf $dest_dir.tmp
    if ! git clone "$repo_url" "$dest_dir.tmp"; then
      log_error "Failed to git clone $repo_url"
      exit 1
    fi
    mv "$dest_dir.tmp" "$dest_dir"
    log_info "done git cloning to $dest_dir"
    cd $dest_dir
  else
    cd $dest_dir
    if [[ $git_get_latest = "y" ]]; then
      git fetch # want this for later...
    else
      log_info "not doing git get latest pull for latest code $dest_dir" # too slow'ish...
    fi
  fi

  old_git_version=`git rev-parse HEAD`
  if [[ -z $checkout_name ]]; then
    checkout_name="origin/master"
  fi
  log_info "git checkout of $dest_dir:$checkout_name" 
  git checkout "$checkout_name" || (git_hard_reset && git checkout "$checkout_name") || (git reset --hard "$checkout_name") || exit 1 # can't just use merge -f because might "think" patch files already applied when their changes have been lost, etc...
  # vmaf on 16.04 needed that weird reset --hard? huh?
  if git show-ref --verify --quiet "refs/remotes/origin/$checkout_name"; then # $checkout_name is actually a branch, not a tag or commit
    git merge "origin/$checkout_name" || exit 1 # get incoming changes to a branch
  fi
  new_git_version=`git rev-parse HEAD`
  if [[ "$old_git_version" != "$new_git_version" ]]; then
    log_info "got upstream changes, forcing re-configure. Doing git clean -f"
    git_hard_reset
  else
    log_info "fetched no code changes, not forcing reconfigure for that..."
  fi
  popd
}

set_cpu_count() {
  local processor_count="$(grep -c processor /proc/cpuinfo 2>/dev/null)"
  if [ -z "$processor_count" ]; then
    processor_count=`sysctl -n hw.ncpu | tr -d '\n'` # OS X cpu count
    if [ -z "$processor_count" ]; then
      log_info "warning, unable to determine cpu count, defaulting to 1"
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
  export CC=${toolchain}-gcc
  export AR=${toolchain}-ar 
  export RANLIB=${toolchain}-ranlib 
  export LD=${toolchain}-ld 
  export STRIP=${toolchain}-strip 
  export CXX=${toolchain}-g++
  export CFLAGS="-I${prefix_path}/include"
  export CXXFLAGS="-I${prefix_path}/include"
  export LDFLAGS="-L${prefix_path}/lib -pthread"
  export PKG_CONFIG_PATH="${prefix_path}/lib/pkgconfig"
}

make_install() {
  if ! make -j$cpu_count; then
    log_error "Function \"${FUNCNAME[1]}\" failed to make."
  fi

  if ! make install; then
    log_error "Function \"${FUNCNAME[1]}\" failed to make install"
  fi
}

update_configure() {
  configure_hash=$(get_parameter_hash "configure" "$@")
  if [ ! -f "$configure_hash" ]; then   
    if ! ./configure "$@"; then
      log_error "Function \"${FUNCNAME[1]}\" failed to configure"
    fi
    touch -- "$configure_hash"
  fi
}

update_autoreconf() {
  if [ ! -f configure ]; then
    if ! autoreconf -fiv; then
      log_error "Function \"${FUNCNAME[1]}\" failed to autoreconf"
    fi
  fi
}

build_lame() {
  update_svn_repo https://svn.code.sf.net/p/lame/svn/trunk/lame lame RELEASE__3_100
  pushd lame
  update_configure --prefix="$prefix_path" --host=$host_target --enable-nasm --disable-shared
  make_install
  ffmpeg_config_opts+=(--enable-libmp3lame)
  popd 
}

build_fdk_aac() {
  update_git_repo https://github.com/mstorsjo/fdk-aac.git fdk-aac
  pushd fdk-aac
  update_autoreconf
  update_configure --prefix="$prefix_path" --host=$host_target --disable-shared
  make_install
  ffmpeg_config_opts+=(--enable-libfdk_aac)
  popd 
}

build_opus() {
  update_git_repo https://git.xiph.org/opus.git opus
  pushd opus
  update_autoreconf
  update_configure --prefix="$prefix_path" --host=$host_target --disable-doc --disable-extra-programs --disable-stack-protector --disable-shared
  make_install
  ffmpeg_config_opts+=(--enable-libopus)
  popd
}

build_x264() {
  update_git_repo "https://code.videolan.org/videolan/x264.git" "x264" "origin/stable"
  pushd x264
  update_configure --prefix="$prefix_path" --host=$host_target --enable-static --disable-cli
  make_install
  ffmpeg_config_opts+=(--enable-libx264)
  popd
}

build_vpx() {
  update_git_repo https://chromium.googlesource.com/webm/libvpx.git vpx
  pushd vpx
  local vpx_host_target=
  if [[ $host_target == "x86_64-w64-mingw32" ]]; then
    vpx_host_target="x86_64-win64-gcc"
  fi
  update_configure --prefix="$prefix_path" --target=$vpx_host_target --enable-static --disable-shared --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth 
  make_install
  ffmpeg_config_opts+=(--enable-libvpx)
  popd
}

build_dependencies() {
  pushd $src_path
  build_lame
  build_fdk_aac
  build_opus
  build_x264
  build_vpx
  popd
}

build_ffmpeg() {
  pushd "$src_path"
  update_git_repo "https://github.com/FFmpeg/FFmpeg.git" ffmpeg
  pushd ffmpeg
  ffmpeg_config_opts+=(--arch=x86_64)
  ffmpeg_config_opts+=(--target-os=mingw32)
  ffmpeg_config_opts+=(--cross-prefix=$toolchain-)
  ffmpeg_config_opts+=(--enable-cross-compile)
  ffmpeg_config_opts+=(--prefix=$prefix_path)
  ffmpeg_config_opts+=(--enable-static)
  ffmpeg_config_opts+=(--enable-nonfree)
  ffmpeg_config_opts+=(--enable-gpl)
  update_configure "${ffmpeg_config_opts[@]}"
  #make -j$cpu_count
  popd
  popd
}

main() {
  declare -r root_dir=$(pwd)
  declare -r host_target='x86_64-w64-mingw32'
  declare -r host_target_alt='x86_64-win64-gcc'
  mkdir -p $root_dir/_target/$host_target/prefix
  mkdir -p $root_dir/_target/$host_target/src
  declare -r prefix_path="$(realpath $root_dir/_target/$host_target/prefix)"
  declare -r src_path="$(realpath $root_dir/_target/$host_target/src)"
  declare -r toolchain="x86_64-w64-mingw32"
  declare -r toolchain_env="CC=${toolchain}-gcc \
                   AR=${toolchain}-ar \
                   RANLIB=${toolchain}-ranlib \
                   LD=${toolchain}-ld \
                   STRIP=${toolchain}-strip \
                   CXX=${toolchain}-g++ \
                   CFLAGS=\"-I${prefix_path}/include\" \
                   CXXFLAGS=\"-I${prefix_path}/include\" \
                   LDFLAGS=\"-L${prefix_path}/lib\" \
                   PKG_CONFIG_PATH=\"${prefix_path}/lib/pkgconfig\""
  set_cpu_count
  set_enviornment
  log_info "configuration: "
  log_info "prefix_path=$prefix_path"
  log_info "src_path=$src_path"
  log_info "host_target=$host_target"
  log_info "toolchain=$toolchain"
  log_info "toolchain_env=$toolchain_env"
  log_info "cpu_count=$cpu_count"
  #build_dependencies
  #build_ffmpeg
}

main "$@"