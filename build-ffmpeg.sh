#!/bin/bash
# Based on ideas from https://github.com/rdp/ffmpeg-windows-build-helpers but
# significantly cleaner and smaller to suit my needs.

declare -a g_ffmpeg_config_opts
g_prefix_path=
g_src_path=
g_toolchain=
g_toolchain_env=
g_cpu_count=0
# flags=(--foo --bar='baz')
# flags+=(--greeting="Hello ${name}")
# mybinary "${flags[@]}"

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
  pushd "$g_src_path"
  declare -r repo_url="$1"
  declare -r dest_dir="$2"
  declare -r revision="$3"
  required_parameters repo_url dest_dir

  if [[ -z $revision ]]; then
    revision_string="-r$revision"
  fi

  if [ ! -d $dest_dir ]; then
    log_info "svn checkout from $repo_dir to $dest_dir"
    rem -Rf "$dest_dir.tmp"
    if ! svn checkout $revision_string $repo_url "$dest_dir"; then
      log_error "Failed to svn checkout $repo_url"
      exit 1
    fi
    mv "$dest_dir.tmp" "$dest_dir"
  fi
  popd
}

update_git_repo() {
  pushd "$g_src_path"
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

get_cpu_count() {
  local cpu_count="$(grep -c processor /proc/cpuinfo 2>/dev/null)" # linux cpu count
  if [ -z "$cpu_count" ]; then
    cpu_count=`sysctl -n hw.ncpu | tr -d '\n'` # OS X cpu count
    if [ -z "$cpu_count" ]; then
      echo "warning, unable to determine cpu count, defaulting to 1"
      cpu_count=1 # else default to just 1, instead of blank, which means infinite
    fi
  fi

  g_cpu_count=$cpu_count
}

get_parameter_hash() {
  hash=$(echo "$@" | md5sum | cut -f1 -d" ")
  echo "$1_$hash"
}

set_enviornment() {
  export CC=${g_toolchain}-gcc
  export AR=${g_toolchain}-ar 
  export RANLIB=${g_toolchain}-ranlib 
  export LD=${g_toolchain}-ld 
  export STRIP=${g_toolchain}-strip 
  export CXX=${g_toolchain}-g++
  export CFLAGS="-I$g_prefix_path/include"
  export CXXFLAGS="-I$g_prefix_path/include"
  export LDFLAGS="-L$g_prefix_path/lib"
}

make_install() {
  if ! make -j$g_cpu_count; then
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
  update_configure --prefix="$g_prefix_path" --host=$host_target --enable-nasm --disable-shared
  make_install
  g_ffmpeg_config_opts+=(--enable-libmp3lame)
  popd 
}

build_fdk_aac() {
  update_git_repo https://github.com/mstorsjo/fdk-aac.git fdk-aac
  pushd fdk-aac
  update_autoreconf
  update_configure --prefix="$g_prefix_path" --host=$host_target --disable-shared
  make_install
  g_ffmpeg_config_opts+=(--enable-libfdk_aac)
  popd 
}

build_x264() {
  update_git_repo "https://code.videolan.org/videolan/x264.git" "x264" "origin/stable"
  pushd x264
  update_configure --prefix="$g_prefix_path" --host=$host_target --enable-static --disable-cli
  make_install
  g_ffmpeg_config_opts+=(--enable-libx264)
  popd
}

build_dependencies() {
  pushd $g_src_path
  build_lame
  build_fdk_aac
  build_x264
  popd
}

build_ffmpeg() {
  pushd "$g_src_path"
  update_git_repo "https://github.com/FFmpeg/FFmpeg.git" ffmpeg
  pushd ffmpeg
  g_ffmpeg_config_opts+=(--arch=x86_64)
  g_ffmpeg_config_opts+=(--target-os=mingw32)
  g_ffmpeg_config_opts+=(--cross-prefix=$g_toolchain-)
  g_ffmpeg_config_opts+=(--enable-cross-compile)
  g_ffmpeg_config_opts+=(--prefix=$g_prefix_path)
  g_ffmpeg_config_opts+=(--enable-static)
  g_ffmpeg_config_opts+=(--enable-nonfree)
  g_ffmpeg_config_opts+=(--enable-gpl)
  update_configure "${g_ffmpeg_config_opts[@]}"
  make -j$g_cpu_count
  popd
  popd
}

main() {
  local current_dir=$(pwd)
  local host_target='x86_64-w64-mingw32'
  mkdir -p $current_dir/_target/$host_target/prefix
  mkdir -p $current_dir/_target/$host_target/src
  g_prefix_path="$(realpath $current_dir/_target/$host_target/prefix)/"
  g_src_path="$(realpath $current_dir/_target/$host_target/src)/"
  g_toolchain="x86_64-w64-mingw32"
  g_toolchain_env="CC=${g_toolchain}-gcc \
                   AR=${g_toolchain}-ar \
                   RANLIB=${g_toolchain}-ranlib \
                   LD=${g_toolchain}-ld \
                   STRIP=${g_toolchain}-strip \
                   CXX=${g_toolchain}-g++ \
                   CFLAGS=\"-I$g_prefix_path/include\" \
                   CXXFLAGS=\"-I$g_prefix_path/include\" \
                   LDFLAGS=\"-L$g_prefix_path/lib\""
  get_cpu_count
  set_enviornment
  log_info "configuration: "
  log_info "prefix_path=$g_prefix_path"
  log_info "src_path=$g_src_path"
  log_info "host_target=$host_target"
  log_info "toolchain=$g_toolchain"
  log_info "toolchain_env=$g_toolchain_env"
  log_info "cpu_count=$g_cpu_count"
  build_dependencies
  build_ffmpeg
}

main "$@"