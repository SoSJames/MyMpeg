#!/usr/bin/env bash
# ffmpeg windows cross compile helper/download script, see github repo README
# Copyright (C) 2012 Roger Pack, the script is under the GPLv3, but output FFmpeg's executables aren't
# set -x

yes_no_sel () {
  unset user_input
  local question="$1"
  shift
  local default_answer="$1"
  while [[ "$user_input" != [YyNn] ]]; do
    echo -n "$question"
    read user_input
    if [[ -z "$user_input" ]]; then
      echo "using default $default_answer"
      user_input=$default_answer
    fi
    if [[ "$user_input" != [YyNn] ]]; then
      clear; echo 'Your selection was not vaild, please try again.'; echo
    fi
  done
  # downcase it
  user_input=$(echo $user_input | tr '[A-Z]' '[a-z]')
}

set_box_memory_size_bytes() {
  if [[ $OSTYPE == darwin* ]]; then
    box_memory_size_bytes=20000000000 # 20G fake it out for now :|
  else
    local ram_kilobytes=`grep MemTotal /proc/meminfo | awk '{print $2}'`
    local swap_kilobytes=`grep SwapTotal /proc/meminfo | awk '{print $2}'`
    box_memory_size_bytes=$[ram_kilobytes * 1024 + swap_kilobytes * 1024]
  fi
}

function sortable_version { echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'; }

ver_comp() { # params: required actual
  local sortable_required=$(sortable_version $1)
  local sortable_actual=$(sortable_version $2)
  [[ "$sortable_actual" -ge "$sortable_required" ]]
}

check_missing_packages () {
  # We will need this later if we don't want to just constantly be grepping the /etc/os-release file
  if [ -z "${VENDOR}" ] && grep -E '(centos|rhel)' /etc/os-release &> /dev/null; then
    # In RHEL this should always be set anyway. But not so sure about CentOS
    VENDOR="redhat"
  fi
  # zeranoe's build scripts use wget, though we don't here...
  local check_packages=('curl' 'pkg-config' 'make' 'git' 'svn' 'gcc' 'autoconf' 'automake' 'yasm' 'cvs' 'flex' 'bison' 'makeinfo' 'g++' 'ed' 'hg' 'pax' 'unzip' 'patch' 'wget' 'xz' 'nasm' 'gperf' 'autogen' 'bzip2')  
  # autoconf-archive is just for leptonica FWIW
  # I'm not actually sure if VENDOR being set to centos is a thing or not. On all the centos boxes I can test on it's not been set at all.
  # that being said, if it where set I would imagine it would be set to centos... And this contition will satisfy the "Is not initially set"
  # case because the above code will assign "redhat" all the time.
  if [ -z "${VENDOR}" ] || [ "${VENDOR}" != "redhat" ] && [ "${VENDOR}" != "centos" ]; then
    check_packages+=('cmake')
  fi
  # libtool check is wonky...
  if [[ $OSTYPE == darwin* ]]; then
    check_packages+=('glibtoolize') # homebrew special :|
  else
    check_packages+=('libtoolize') # the rest of the world
  fi
  # Use hash to check if the packages exist or not. Type is a bash builtin which I'm told behaves differently between different versions of bash.
  for package in "${check_packages[@]}"; do
    hash "$package" &> /dev/null || missing_packages=("$package" "${missing_packages[@]}")
  done
  if [ "${VENDOR}" = "redhat" ] || [ "${VENDOR}" = "centos" ]; then
    if [ -n "$(hash cmake 2>&1)" ] && [ -n "$(hash cmake3 2>&1)" ]; then missing_packages=('cmake' "${missing_packages[@]}"); fi
  fi
  if [[ -n "${missing_packages[@]}" ]]; then
    clear
    echo "Could not find the following execs (svn is actually package subversion, makeinfo is actually package texinfo, hg is actually package mercurial if you're missing them): ${missing_packages[*]}"
    echo 'Install the missing packages before running this script.'
    echo "for ubuntu: $ sudo apt-get install subversion curl texinfo g++ bison flex cvs yasm automake libtool autoconf gcc cmake git make pkg-config zlib1g-dev mercurial unzip pax nasm gperf autogen bzip2 autoconf-archive -y"
    echo "for gentoo (a non ubuntu distro): same as above, but no g++, no gcc, git is dev-vcs/git, zlib1g-dev is zlib, pkg-config is dev-util/pkgconfig, add ed..."
    echo "for OS X (homebrew): brew install wget cvs hg yasm autogen automake autoconf cmake hg libtool xz pkg-config nasm bzip2 autoconf-archive"
    echo "for debian: same as ubuntu, but also add libtool-bin and ed"
    echo "for RHEL/CentOS: First ensure you have epel repos available, then run $ sudo yum install subversion texinfo mercurial libtool autogen gperf nasm patch unzip pax ed gcc-c++ bison flex yasm automake autoconf gcc zlib-devel cvs bzip2 cmake3 -y"
    echo "for fedora: if your distribution comes with a modern version of cmake then use the same as RHEL/CentOS but replace cmake3 with cmake."
    exit 1
  fi

  export REQUIRED_CMAKE_VERSION="3.0.0"
  for cmake_binary in 'cmake' 'cmake3'; do
    # We need to check both binaries the same way because the check for installed packages will work if *only* cmake3 is installed or
    # if *only* cmake is installed.
    # On top of that we ideally would handle the case where someone may have patched their version of cmake themselves, locally, but if
    # the version of cmake required move up to, say, 3.1.0 and the cmake3 package still only pulls in 3.0.0 flat, then the user having manually
    # installed cmake at a higher version wouldn't be detected.
    if hash "${cmake_binary}"  &> /dev/null; then
      cmake_version="$( "${cmake_binary}" --version | sed -e "s#${cmake_binary}##g" | head -n 1 | tr -cd '[0-9.\n]' )"
      if ver_comp "${REQUIRED_CMAKE_VERSION}" "${cmake_version}"; then
        export cmake_command="${cmake_binary}"
        break
      else
        echo "your ${cmake_binary} version is too old ${cmake_version} wanted ${REQUIRED_CMAKE_VERSION}"
      fi 
    fi
  done

  # If cmake_command never got assigned then there where no versions found which where sufficient.
  if [ -z "${cmake_command}" ]; then
    echo "there where no appropriate versions of cmake found on your machine."
    exit 1
  else
    # If cmake_command is set then either one of the cmake's is adequate.
    echo "cmake binary for this build will be ${cmake_command}"
  fi

  if [[ ! -f /usr/include/zlib.h ]]; then
    echo "warning: you may need to install zlib development headers first if you want to build mp4-box [on ubuntu: $ apt-get install zlib1g-dev] [on redhat/fedora distros: $ yum install zlib-devel]" # XXX do like configure does and attempt to compile and include zlib.h instead?
    sleep 1
  fi

  # doing the cut thing with an assigned variable dies on the version of yasm I have installed (which I'm pretty sure is the RHEL default)
  # because of all the trailing lines of stuff
  export REQUIRED_YASM_VERSION="1.2.0"
  yasm_binary=yasm
  yasm_version="$( "${yasm_binary}" --version |sed -e "s#${yasm_binary}##g" | head -n 1 | tr -dc '[0-9.\n]' )"
  if ! ver_comp "${REQUIRED_YASM_VERSION}" "${yasm_version}"; then
    echo "your yasm version is too old $yasm_version wanted ${REQUIRED_YASM_VERSION}"
    exit 1
  fi
}


intro() {
  echo `date`
  cat <<EOL
     ##################### Welcome ######################
  Welcome to the ffmpeg cross-compile builder-helper script.
  Downloads and builds will be installed to directories within $cur_dir
  If this is not ok, then exit now, and cd to the directory where you'd
  like them installed, then run this script again from there.
  NB that once you build your compilers, you can no longer rename/move
  the sandbox directory, since it will have some hard coded paths in there.
  You can, of course, rebuild ffmpeg from within it, etc.
EOL
  if [[ $sandbox_ok != 'y' && ! -d sandbox ]]; then
    echo
    echo "Building in $PWD/sandbox, will use ~ 4GB space!"
    echo
  fi
  mkdir -p "$cur_dir"
  cd "$cur_dir"
  if [[ $disable_nonfree = "y" ]]; then
    non_free="n"
  else
    if  [[ $disable_nonfree = "n" ]]; then
      non_free="y"
    else
      yes_no_sel "Would you like to include non-free (non GPL compatible) libraries, like [libfdk_aac,libfaac,decklink -- note that the internal AAC encoder is ruled almost as high a quality as fdk-aac these days]
The resultant binary may not be distributable, but can be useful for in-house use. Include these non-free license libraries [y/N]?" "n"
      non_free="$user_input" # save it away
    fi
  fi
}

pick_compiler_flavors() {
  while [[ "$compiler_flavors" != [1-4] ]]; do
    if [[ -n "${unknown_opts[@]}" ]]; then
      echo -n 'Unknown option(s)'
      for unknown_opt in "${unknown_opts[@]}"; do
        echo -n " '$unknown_opt'"
      done
      echo ', ignored.'; echo
    fi
    cat <<'EOF'
What version of MinGW-w64 would you like to build or update?
  1. Both Win32 and Win64
  2. Win32 (32-bit only)
  3. Win64 (64-bit only)
  4. Exit
EOF
    echo -n 'Input your choice [1-4]: '
    read compiler_flavors
  done
  case "$compiler_flavors" in
  1 ) compiler_flavors=multi ;;
  2 ) compiler_flavors=win32 ;;
  3 ) compiler_flavors=win64 ;;
  4 ) echo "exiting"; exit 0 ;;
  * ) clear;  echo 'Your choice was not valid, please try again.'; echo ;;
  esac
}

# made into a method so I don't/don't have to download this script every time if only doing just 32 or just6 64 bit builds...
download_gcc_build_script() {
    local zeranoe_script_name=$1
    rm -f $zeranoe_script_name || exit 1
    curl -4 file://$patch_dir/$zeranoe_script_name -O --fail || exit 1
    chmod u+x $zeranoe_script_name
}

install_cross_compiler() {
  local win32_gcc="cross_compilers/mingw-w64-i686/bin/i686-w64-mingw32-gcc"
  local win64_gcc="cross_compilers/mingw-w64-x86_64/bin/x86_64-w64-mingw32-gcc"
  if [[ -f $win32_gcc && -f $win64_gcc ]]; then
   echo "MinGW-w64 compilers both already installed, not re-installing..."
   if [[ -z $compiler_flavors ]]; then
     echo "selecting multi build (both win32 and win64)...since both cross compilers are present assuming you want both..."
     compiler_flavors=multi
   fi
   return # early exit just assume they want both, don't even prompt :)
  fi

  if [[ -z $compiler_flavors ]]; then
    pick_compiler_flavors
  fi

  mkdir -p cross_compilers
  cd cross_compilers

    unset CFLAGS # don't want these "windows target" settings used the compiler itself since it creates executables to run on the local box (we have a parameter allowing them to set them for the script "all builds" basically)
    # pthreads version to avoid having to use cvs for it
    echo "Starting to download and build cross compile version of gcc [requires working internet access] with thread count $gcc_cpu_count..."
    echo ""

    # zee https://github.com/Zeranoe/mingw-w64-build/blob/master/mingw-w64-build for the 4.0.0 version
    local zeranoe_script_name=mingw-w64-build-r23.local
    download_gcc_build_script $zeranoe_script_name
    local zeranoe_script_options=""
    if [[ ($compiler_flavors == "win32" || $compiler_flavors == "multi") && ! -f ../$win32_gcc ]]; then
      zeranoe_script_options="$zeranoe_script_options i686"
    fi
    if [[ ($compiler_flavors == "win64" || $compiler_flavors == "multi") && ! -f ../$win64_gcc ]]; then
      zeranoe_script_options="$zeranoe_script_options x86_64"
    fi
    nice ./$zeranoe_script_name $zeranoe_script_options || exit 1
    if [[ ($compiler_flavors == "win32" || $compiler_flavors == "multi") && ! -f ../$win32_gcc ]]; then
      ln -s i686-w64-mingw32 mingw-w64-i686
    fi
    if [[ ($compiler_flavors == "win64" || $compiler_flavors == "multi") && ! -f ../$win64_gcc ]]; then
      ln -s x86_64-w64-mingw32 mingw-w64-x86_64
    fi
    reset_cflags
  cd ..
  echo "Done building (or already built) MinGW-w64 cross-compiler(s) successfully..."
  echo `date` # so they can see how long it took :)
}

# helper methods for downloading and building projects that can take generic input

do_svn_checkout() {
  repo_url="$1"
  to_dir="$2"
  desired_revision="$3"
  if [ ! -d $to_dir ]; then
    echo "svn checking out to $to_dir"
    if [[ -z "$desired_revision" ]]; then
      svn checkout $repo_url $to_dir.tmp  --non-interactive --trust-server-cert || exit 1
    else
      svn checkout -r $desired_revision $repo_url $to_dir.tmp || exit 1
    fi
    mv $to_dir.tmp $to_dir
  else
    cd $to_dir
    echo "not svn Updating $to_dir since usually svn repo's aren't updated frequently enough..."
    # XXX accomodate for desired revision here if I ever uncomment the next line...
    # svn up
    cd ..
  fi
}

do_git_checkout() {
  local repo_url="$1"
  local to_dir="$2"
  if [[ -z $to_dir ]]; then
    to_dir=$(basename $repo_url | sed s/\.git/_git/) # http://y/abc.git -> abc_git
  fi
  local desired_branch="$3"
  if [ ! -d $to_dir ]; then
    echo "Downloading (via git clone) $to_dir from $repo_url"
    rm -rf $to_dir.tmp # just in case it was interrupted previously...
    git clone $repo_url $to_dir.tmp || exit 1
    # prevent partial checkouts by renaming it only after success
    mv $to_dir.tmp $to_dir
    echo "done git cloning to $to_dir"
    cd $to_dir
  else
    cd $to_dir
    if [[ $git_get_latest = "y" ]]; then
      git fetch # need this no matter what
    else
      echo "not doing git get latest pull for latest code $to_dir"
    fi
  fi

  old_git_version=`git rev-parse HEAD`

  if [[ -z $desired_branch ]]; then
    echo "doing git checkout master"
    git checkout -f master || exit 1 # in case they were on some other branch before [ex: going between ffmpeg release tags]. # -f: checkout even if the working tree differs from HEAD.
    if [[ $git_get_latest = "y" ]]; then
      echo "Updating to latest $to_dir git version [origin/master]..."
      git merge origin/master || exit 1
    fi
  else
    echo "doing git checkout $desired_branch"
    git checkout -f "$desired_branch" || exit 1
    git merge "$desired_branch" || exit 1 # get incoming changes to a branch
  fi

  new_git_version=`git rev-parse HEAD`
  if [[ "$old_git_version" != "$new_git_version" ]]; then
    echo "got upstream changes, forcing re-configure."
    git clean -f # Throw away local changes; 'already_*' and bak-files for instance.
  else
    echo "fetched no code changes, not forcing reconfigure for that..."
  fi
  cd ..
}

get_small_touchfile_name() { # have to call with assignment like a=$(get_small...)
  local beginning="$1"
  local extra_stuff="$2"
  local touch_name="${beginning}_$(echo -- $extra_stuff $CFLAGS $LDFLAGS | /usr/bin/env md5sum)" # md5sum to make it smaller, cflags to force rebuild if changes
  touch_name=$(echo "$touch_name" | sed "s/ //g") # md5sum introduces spaces, remove them
  echo "$touch_name" # bash cruddy return system LOL
}

do_configure() {
  local configure_options="$1"
  local configure_name="$2"
  if [[ "$configure_name" = "" ]]; then
    configure_name="./configure"
  fi
  local cur_dir2=$(pwd)
  local english_name=$(basename $cur_dir2)
  local touch_name=$(get_small_touchfile_name already_configured "$configure_options $configure_name")
  if [ ! -f "$touch_name" ]; then
    # make uninstall # does weird things when run under ffmpeg src so disabled for now...

    echo "configuring $english_name ($PWD) as $ PKG_CONFIG_PATH=$PKG_CONFIG_PATH PATH=$mingw_bin_path:\$PATH $configure_name $configure_options" # say it now in case bootstrap fails etc.
    if [ -f bootstrap ]; then
      ./bootstrap # some need this to create ./configure :|
    fi
    if [[ ! -f $configure_name && -f bootstrap.sh ]]; then # fftw wants to only run this if no configure :|
      ./bootstrap.sh
    fi
    if [[ ! -f $configure_name ]]; then
      autoreconf -fiv # a handful of them require this to create ./configure :|
    fi
    rm -f already_* # reset
    "$configure_name" $configure_options || exit 1 # not nice on purpose, so that if some other script is running as nice, this one will get priority :)
    touch -- "$touch_name"
    echo "doing preventative make clean"
    nice make clean -j $cpu_count # sometimes useful when files change, etc.
  #else
  #  echo "already configured $(basename $cur_dir2)"
  fi
}

do_make() {
  local extra_make_options="$1 -j $cpu_count"
  local cur_dir2=$(pwd)
  local touch_name=$(get_small_touchfile_name already_ran_make "$extra_make_options" )

  if [ ! -f $touch_name ]; then
    echo
    echo "making $cur_dir2 as $ PATH=$mingw_bin_path:\$PATH make $extra_make_options"
    echo
    if [ ! -f configure ]; then
      nice make clean -j $cpu_count # just in case helpful if old junk left around and this is a 're make' and wasn't cleaned at reconfigure time
    fi
    nice make $extra_make_options || exit 1
    touch $touch_name || exit 1 # only touch if the build was OK
  else
    echo "already made $(basename "$cur_dir2") ..."
  fi
}

do_make_and_make_install() {
  local extra_make_options="$1"
  do_make "$extra_make_options"
  do_make_install "$extra_make_options"
}

do_make_install() {
  local extra_make_install_options="$1"
  local override_make_install_options="$2" # startingly, some need/use something different than just 'make install'
  if [[ -z $override_make_install_options ]]; then
    local make_install_options="install $extra_make_install_options"
  else
    local make_install_options="$override_make_install_options $extra_make_install_options"
  fi
  local touch_name=$(get_small_touchfile_name already_ran_make_install "$make_install_options")
  if [ ! -f $touch_name ]; then
    echo "make installing $(pwd) as $ PATH=$mingw_bin_path:\$PATH make $make_install_options"
    nice make $make_install_options || exit 1
    touch $touch_name || exit 1
  fi
}

do_cmake() {
  extra_args="$1"
  local touch_name=$(get_small_touchfile_name already_ran_cmake "$extra_args")

  if [ ! -f $touch_name ]; then
    rm -f already_* # reset so that make will run again if option just changed
    local cur_dir2=$(pwd)
    echo doing cmake in $cur_dir2 with PATH=$mingw_bin_path:\$PATH with extra_args=$extra_args like this:
    echo ${cmake_command} -G"Unix Makefiles" . -DENABLE_STATIC_RUNTIME=1 -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_RANLIB=${cross_prefix}ranlib -DCMAKE_C_COMPILER=${cross_prefix}gcc -DCMAKE_CXX_COMPILER=${cross_prefix}g++ -DCMAKE_RC_COMPILER=${cross_prefix}windres -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix $extra_args
    ${cmake_command} -G"Unix Makefiles" . -DENABLE_STATIC_RUNTIME=1 -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_RANLIB=${cross_prefix}ranlib -DCMAKE_C_COMPILER=${cross_prefix}gcc -DCMAKE_CXX_COMPILER=${cross_prefix}g++ -DCMAKE_RC_COMPILER=${cross_prefix}windres -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix $extra_args || exit 1
    touch $touch_name || exit 1
  fi
}

do_cmake_from_build_dir() { # XX combine with the above :)
  source_dir="$1"
  extra_args="$2"
  local touch_name=$(get_small_touchfile_name already_ran_cmake "$extra_args")

  if [ ! -f $touch_name ]; then
    rm -f already_* # reset so that make will run again if option just changed
    local cur_dir2=$(pwd)
    echo doing cmake in $cur_dir2 with PATH=$mingw_bin_path:\$PATH with extra_args=$extra_args like this:
    echo ${cmake_command} -G"Unix Makefiles" $source_dir -DENABLE_STATIC_RUNTIME=1 -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_RANLIB=${cross_prefix}ranlib -DCMAKE_C_COMPILER=${cross_prefix}gcc -DCMAKE_CXX_COMPILER=${cross_prefix}g++ -DCMAKE_RC_COMPILER=${cross_prefix}windres -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix $extra_args
    ${cmake_command} -G"Unix Makefiles" $source_dir -DENABLE_STATIC_RUNTIME=1 -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_RANLIB=${cross_prefix}ranlib -DCMAKE_C_COMPILER=${cross_prefix}gcc -DCMAKE_CXX_COMPILER=${cross_prefix}g++ -DCMAKE_RC_COMPILER=${cross_prefix}windres -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix $extra_args || exit 1
    touch $touch_name || exit 1
  fi
}

do_cmake_and_install() {
  do_cmake "$1"
  do_make_and_make_install
}

do_meson() {
    local configure_options="$1 --unity=off"
    local configure_name="$2"
    local configure_env="$3"
    local configure_noclean=""
    if [[ "$configure_name" = "" ]]; then
        configure_name="meson"
    fi
    local cur_dir2=$(pwd)
    local english_name=$(basename $cur_dir2)
    local touch_name=$(get_small_touchfile_name already_built_meson "$configure_options $configure_name $LDFLAGS $CFLAGS")
    if [ ! -f "$touch_name" ]; then
        if [ "$configure_noclean" != "noclean" ]; then
            make clean # just in case
        fi
        rm -f already_* # reset
        echo "Using meson: $english_name ($PWD) as $ PATH=$PATH ${configure_env} $configure_name $configure_options"
        #env
        "$configure_name" $configure_options || exit 1
        touch -- "$touch_name"
        make clean # just in case
    else
        echo "Already used meson $(basename $cur_dir2)"
    fi
}

generic_meson() {
    local extra_configure_options="$1"
    mkdir -pv build
    do_meson "--prefix=${mingw_w64_x86_64_prefix} --libdir=${mingw_w64_x86_64_prefix}/lib --buildtype=release --default-library=static --cross-file=${top_dir}/meson-cross.mingw.txt $extra_configure_options . build"
}

generic_meson_ninja_install() {
    generic_meson "$1"
    do_ninja_and_ninja_install
}

do_ninja_and_ninja_install() {
    local extra_ninja_options="$1"
    do_ninja "$extra_ninja_options"
    local touch_name=$(get_small_touchfile_name already_ran_make_install "$extra_ninja_options")
    if [ ! -f $touch_name ]; then
        echo "ninja installing $(pwd) as $PATH=$PATH ninja -C build install $extra_make_options"
        ninja -C build install || exit 1
        touch $touch_name || exit 1
    fi
}

do_ninja() {
  local extra_make_options=" -j $cpu_count"
  local cur_dir2=$(pwd)
  local touch_name=$(get_small_touchfile_name already_ran_make "${extra_make_options}")

  if [ ! -f $touch_name ]; then
    echo
    echo "ninja-ing $cur_dir2 as $ PATH=$PATH ninja -C build "${extra_make_options}"
    echo
    ninja -C build "${extra_make_options} || exit 1
    touch $touch_name || exit 1 # only touch if the build was OK
  else
    echo "already did ninja $(basename "$cur_dir2")"
  fi
}

build_meson_cross() {
  local cpu_family="x86_64"
  if [ $bits_target = 32 ]; then
    cpu_family="x86"
  fi
  rm -fv meson-cross.mingw.txt
  cat >> meson-cross.mingw.txt << EOF
[binaries]
c = '${cross_prefix}gcc'
cpp = '${cross_prefix}g++'
ld = '${cross_prefix}ld'
ar = '${cross_prefix}ar'
strip = '${cross_prefix}strip'
pkgconfig = '${cross_prefix}pkg-config'
nm = '${cross_prefix}nm'
windres = '${cross_prefix}windres'

[host_machine]
system = 'windows'
cpu_family = '$cpu_family'
cpu = '$cpu_family'
endian = 'little'
EOF
  mv -v meson-cross.mingw.txt ../..
}

get_local_meson_cross_with_propeties() {
  local local_dir="$1"
  local c_args=
  local cpp_args=
  local link_args=
  if [[ -z $local_dir ]]; then
    local_dir="."
  fi
  cp ${top_dir}/meson-cross.mingw.txt "$local_dir"
  if [[ -n "$CFLAGS" ]]; then
    c_args="'$(echo ${CFLAGS} | sed "s/ /\',\'/g")'"
  fi
  if [[ -n "$CXXFLAGS" ]]; then
    cpp_args="'$(echo ${CXXFLAGS} | sed "s/ /\',\'/g")'"
  fi
  if [[ -n "$LDFLAGS" ]]; then
    link_args="'$(echo ${LDFLAGS} | sed "s/ /\',\'/g")'"
  fi
  cat >> meson-cross.mingw.txt << EOF

[properties]
c_args = [$c_args]
c_link_args = [$link_args]
cpp_args = [$cpp_args]
cpp_link_args = [$link_args]
EOF
}

apply_patch() {
  local url=$1 # if you want it to use a local file instead of a url one [i.e. local file with local modifications] specify it like file://localhost/full/path/to/filename.patch
  local patch_type=$2
  if [[ -z $patch_type ]]; then
    patch_type="-p0"
  fi
  local patch_name=$(basename $url)
  local patch_done_name="$patch_name.done"
  if [[ ! -e $patch_done_name ]]; then
    if [[ -f $patch_name ]]; then
      rm $patch_name || exit 1 # remove old version in case it has been since updated on the server...
    fi
    curl -4 --retry 5 $url -O --fail || echo_and_exit "unable to download patch file $url"
    echo "applying patch $patch_name"
    patch $patch_type < "$patch_name" || exit 1
    touch $patch_done_name || exit 1
    rm -f already_ran* # if it's a new patch, reset everything too, in case it's really really really new
  #else
    #echo "patch $patch_name already applied"
  fi
}

echo_and_exit() {
  echo "failure, exiting: $1"
  exit 1
}

# takes a url, output_dir as params, output_dir optional
download_and_unpack_file() {
  url="$1"
  output_name=$(basename $url)
  output_dir="$2"
  if [[ -z $output_dir ]]; then
    output_dir=$(basename $url | sed s/\.tar\.*//) # remove .tar.xx
  fi
  if [ ! -f "$output_dir/unpacked.successfully" ]; then
    echo "downloading $url"
    if [[ -f $output_name ]]; then
      rm $output_name || exit 1
    fi

    #  From man curl
    #  -4, --ipv4
    #  If curl is capable of resolving an address to multiple IP versions (which it is if it is  IPv6-capable),
    #  this option tells curl to resolve names to IPv4 addresses only.
    #  avoid a "network unreachable" error in certain [broken Ubuntu] configurations a user ran into once
    #  -L means "allow redirection" or some odd :|

    curl -4 "$url" --retry 50 -O -L --fail || echo_and_exit "unable to download $url"
    tar -xf "$output_name" || unzip "$output_name" || exit 1
    touch "$output_dir/unpacked.successfully" || exit 1
    rm "$output_name" || exit 1
  fi
}

generic_configure() {
  local extra_configure_options="$1"
  do_configure "--host=$host_target --prefix=$mingw_w64_x86_64_prefix --disable-shared --enable-static $extra_configure_options"
}

# params: url, optional "english name it will unpack to"
generic_download_and_make_and_install() {
  local url="$1"
  local english_name="$2"
  if [[ -z $english_name ]]; then
    english_name=$(basename $url | sed s/\.tar\.*//) # remove .tar.xx, take last part of url
  fi
  local extra_configure_options="$3"
  download_and_unpack_file $url $english_name
  cd $english_name || exit "unable to cd, may need to specify dir it will unpack to as parameter"
  generic_configure "$extra_configure_options"
  do_make_and_make_install
  cd ..
}

do_git_checkout_and_make_install() {
  local url=$1
  local git_checkout_name=$(basename $url | sed s/\.git/_git/) # http://y/abc.git -> abc_git
  do_git_checkout $url $git_checkout_name
  cd $git_checkout_name
    generic_configure_make_install
  cd ..
}

generic_configure_make_install() {
  if [ $# -gt 0 ]; then
    echo "cant pass parameters to this today"
    echo "The following arguments where passed: ${@}"
    exit 1
  fi
  generic_configure # no parameters, force myself to break it up if needed
  do_make_and_make_install
}

gen_ld_script() {
  lib=$mingw_w64_x86_64_prefix/lib/$1
  lib_s="$2"
  if [[ ! -f $mingw_w64_x86_64_prefix/lib/lib$lib_s.a ]]; then
    echo "Generating linker script $lib: $2 $3"
    mv -f $lib $mingw_w64_x86_64_prefix/lib/lib$lib_s.a
    echo "GROUP ( -l$lib_s $3 )" > $lib
  fi
}

build_dlfcn() {
  do_git_checkout https://github.com/dlfcn-win32/dlfcn-win32.git
  cd dlfcn-win32_git
    if [[ ! -f Makefile.bak ]]; then # Change CFLAGS.
      sed -i.bak "s/-O3/-O2/" Makefile
    fi
    do_configure "--prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix" # rejects some normal cross compile options so custom here
    do_make_and_make_install
    gen_ld_script libdl.a dl_s -lpsapi # dlfcn-win32's 'README.md': "If you are linking to the static 'dl.lib' or 'libdl.a', then you would need to explicitly add 'psapi.lib' or '-lpsapi' to your linking command, depending on if MinGW is used."
  cd ..
}

build_bzip2() {
  download_and_unpack_file https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz
  cd bzip2-1.0.8
    apply_patch file://$patch_dir/bzip2-1.0.8_brokenstuff.diff
    if [[ ! -f ./libbz2.a ]] || [[ -f $mingw_w64_x86_64_prefix/lib/libbz2.a && ! $(/usr/bin/env md5sum ./libbz2.a) = $(/usr/bin/env md5sum $mingw_w64_x86_64_prefix/lib/libbz2.a) ]]; then # Not built or different build installed
      do_make "$make_prefix_options libbz2.a"
      install -m644 bzlib.h $mingw_w64_x86_64_prefix/include/bzlib.h
      install -m644 libbz2.a $mingw_w64_x86_64_prefix/lib/libbz2.a
    else
      echo "Already made bzip2-1.0.8"
    fi
  cd ..
}

build_liblzma() {
  download_and_unpack_file https://sourceforge.net/projects/lzmautils/files/xz-5.2.3.tar.xz
  cd xz-5.2.3
    generic_configure "--disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc --disable-nls"
    do_make_and_make_install
  cd ..
}

build_zlib() {
  rm -rf zlib-1.2.12
  download_and_unpack_file https://github.com/madler/zlib/archive/v1.2.13.tar.gz zlib-1.2.13
  cd zlib-1.2.13
    do_configure "--prefix=$mingw_w64_x86_64_prefix --static"
    do_make_and_make_install "$make_prefix_options ARFLAGS=rcs" # ARFLAGS Avoid failure in OS X
  cd ..
}

build_iconv() {
  rm -rf libiconv-1.15
  download_and_unpack_file https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.17.tar.gz
  cd libiconv-1.17
    generic_configure "--disable-nls"
    do_make "install-lib" # No need for 'do_make_install', because 'install-lib' already has install-instructions.
  cd ..
}

build_sdl2() {
  download_and_unpack_file http://libsdl.org/release/SDL2-2.0.5.tar.gz
  cd SDL2-2.0.5
    apply_patch file://$patch_dir/SDL2-2.0.5_lib-only.diff
    #apply_patch file://$patch_dir/sdl2.xinput.diff # mingw-w64 master needs it?
    if [[ ! -f configure.bak ]]; then
      sed -i.bak "s/ -mwindows//" configure # Allow ffmpeg to output anything to console.
    fi
    export CFLAGS=-DDECLSPEC=  # avoid SDL trac tickets 939 and 282 [broken shared builds], and not worried about optimizing yet...
    generic_configure "--bindir=$mingw_bin_path"
    do_make_and_make_install
    if [[ ! -f $mingw_bin_path/$host_target-sdl2-config ]]; then
      mv "$mingw_bin_path/sdl2-config" "$mingw_bin_path/$host_target-sdl2-config" # At the moment FFmpeg's 'configure' doesn't use 'sdl2-config', because it gives priority to 'sdl2.pc', but when it does, it expects 'i686-w64-mingw32-sdl2-config' in 'cross_compilers/mingw-w64-i686/bin'.
    fi
    reset_cflags
  cd ..
}

build_amd_amf_headers() {
  do_git_checkout https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git amf_headers_git # Use: https://github.com/DeadSix27/AMF or your own stripped fork if needed (original is like 120MB of data we don't need).
  cd amf_headers_git
    if [ ! -f "already_installed" ] ; then
      if [ ! -d "$mingw_w64_x86_64_prefix/include/AMF" ]; then
        mkdir -p "$mingw_w64_x86_64_prefix/include/AMF"
      fi
      cp -av "amf/public/include/." "$mingw_w64_x86_64_prefix/include/AMF" 
      touch "already_installed"
    fi
    rm -rf Thirdparty
  cd ..
}

build_nv_headers() {
  do_git_checkout https://github.com/FFmpeg/nv-codec-headers.git
  cd nv-codec-headers_git
    do_make_install "PREFIX=$mingw_w64_x86_64_prefix" # just copies in headers
  cd ..
}

build_intel_quicksync_mfx() { # i.e. qsv
  do_git_checkout https://github.com/lu-zero/mfx_dispatch.git # lu-zero??
  cd mfx_dispatch_git
#   apply_patch file://$patch_dir/revert_fix_linking_for_UWP_targets.patch
    if [[ ! -f "compile" ]]; then
      autoreconf -fiv || exit 1
      automake --add-missing || exit 1
    fi
    if [[ ! -f "configure" ]]; then
      autoreconf -fiv || exit 1
      automake --add-missing || exit 1
    fi
    generic_configure_make_install
  cd ..
}

build_libleptonica() {
  build_libjpeg_turbo
  do_git_checkout https://github.com/DanBloomberg/leptonica.git 
  cd leptonica_git
    generic_configure "--without-libopenjpeg" # never could quite figure out how to get it to work with jp2 stuffs...I think OPJ_STATIC or something, see issue for tesseract
    do_make_and_make_install
  cd ..
}

build_libtiff() {
  build_libjpeg_turbo # auto uses it?
  generic_download_and_make_and_install http://download.osgeo.org/libtiff/tiff-4.0.9.tar.gz
  sed -i.bak 's/-ltiff.*$/-ltiff -llzma -ljpeg -lz/' $PKG_CONFIG_PATH/libtiff-4.pc # static deps
} 

build_libtesseract() {
  build_libleptonica
  build_libtiff # no disable configure option for this in tesseract? odd...
  do_git_checkout https://github.com/tesseract-ocr/tesseract.git tesseract_git a2e72f258a3bd6811cae226a01802d # #315
  cd tesseract_git
    generic_configure_make_install
    sed -i.bak 's/-ltesseract.*$/-ltesseract -lstdc++ -lws2_32 -llept -ltiff -llzma -ljpeg -lz/' $PKG_CONFIG_PATH/tesseract.pc # why does it needs winsock? LOL plus all of libtiff's <sigh>
    sed -i.bak 's/-ltesseract.*$/-ltesseract -lstdc++ -lws2_32 -llept -ltiff -llzma -ljpeg -lz/' $PKG_CONFIG_PATH/tesseract.pc # 
  cd ..
}

build_libzimg() {
  do_git_checkout https://github.com/sekrit-twc/zimg.git zimg_git 8e87f5a4b88e16ccafb2e7ade8ef45
  cd zimg_git
    generic_configure_make_install
  cd ..
}

build_libopenjpeg() {
  do_git_checkout https://github.com/uclouvain/openjpeg.git # basically v2.3+ 
  cd openjpeg_git
    do_cmake_and_install "-DBUILD_SHARED_LIBS=0 -DBUILD_CODEC=0"
  cd ..
}

build_libpng() {
  do_git_checkout https://github.com/glennrp/libpng.git
  cd libpng_git
    generic_configure
    do_make_and_make_install
  cd ..
}

build_libwebp() {
  do_git_checkout https://chromium.googlesource.com/webm/libwebp.git
  cd libwebp_git
    export LIBPNG_CONFIG="$mingw_w64_x86_64_prefix/bin/libpng-config --static" # LibPNG somehow doesn't get autodetected.
    generic_configure "--disable-wic"
    do_make_and_make_install
    unset LIBPNG_CONFIG
  cd ..
}

build_harfbuzz() {
  local new_build=false
  do_git_checkout https://github.com/harfbuzz/harfbuzz.git harfbuzz_git
  if [ ! -f harfbuzz_git/already_done_harf ]; then # Not done or new master, so build
    new_build=true
  fi

  if $new_build; then # 0 is true
    rm -f harfbuzz_git/already* # Force rebuilding in case only freetype has changed
    # cmake no .pc file generated so use configure :|
    cd harfbuzz_git
      if [ ! -f configure ]; then
        ./autogen.sh # :|
      fi
      export LDFLAGS=-lpthread # :|
      generic_configure "--with-fontconfig=no --with-icu=no" # no fontconfig, don't want another circular what? icu is #372
      unset LDFLAGS
      do_make_and_make_install
    cd ..

    touch harfbuzz_git/already_done_harf
    echo "Done harfbuzz"
  else
    echo "Already done harfbuzz"
  fi
  sed -i.bak 's/-lfreetype.*/-lfreetype -lharfbuzz -lpthread/' "$PKG_CONFIG_PATH/freetype2.pc" # for some reason it lists harfbuzz as Requires.private only??
  sed -i.bak 's/-lharfbuzz.*/-lharfbuzz -lfreetype/' "$PKG_CONFIG_PATH/harfbuzz.pc" # does anything even use this?
  sed -i.bak 's/libfreetype.la -lbz2/libfreetype.la -lharfbuzz -lbz2/' "${mingw_w64_x86_64_prefix}/lib/libfreetype.la" # XXX what the..needed?
  sed -i.bak 's/libfreetype.la -lbz2/libfreetype.la -lharfbuzz -lbz2/' "${mingw_w64_x86_64_prefix}/lib/libharfbuzz.la"
}

build_freetype() {
  local freetype_version="2.10.4"
  local freetype_previous="2.10.0"
  rm -rf freetype-$freetype_previous
  download_and_unpack_file https://sourceforge.net/projects/freetype/files/freetype2/$freetype_version/freetype-$freetype_version.tar.xz
  cd freetype-$freetype_version
    # harfbuzz autodetect :|
    generic_configure "--with-bzip2"
    do_make_and_make_install
  cd ..
}

build_libxml2() {
  download_and_unpack_file http://xmlsoft.org/sources/libxml2-2.9.8.tar.gz libxml2-2.9.8
  cd libxml2-2.9.8
    if [[ ! -f libxml.h.bak ]]; then # Otherwise you'll get "libxml.h:...: warning: "LIBXML_STATIC" redefined". Not an error, but still.
      sed -i.bak "/NOLIBTOOL/s/.*/& \&\& !defined(LIBXML_STATIC)/" libxml.h
    fi
    generic_configure "--with-ftp=no --with-http=no --with-python=no"
    do_make_and_make_install
  cd ..
}

build_fontconfig() {
  download_and_unpack_file https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.12.4.tar.gz
  cd fontconfig-2.12.4
    #export CFLAGS= # compile fails with -march=sandybridge ... with mingw 4.0.6 at least ...
    generic_configure "--enable-iconv --enable-libxml2 --disable-docs --with-libiconv" # Use Libxml2 instead of Expat.
    do_make_and_make_install
    #reset_cflags
  cd ..
}

build_gmp() {
  download_and_unpack_file https://gmplib.org/download/gmp/gmp-6.1.2.tar.xz
  cd gmp-6.1.2
    #export CC_FOR_BUILD=/usr/bin/gcc # Are these needed?
    #export CPP_FOR_BUILD=usr/bin/cpp
    generic_configure "ABI=$bits_target"
    #unset CC_FOR_BUILD
    #unset CPP_FOR_BUILD
    do_make_and_make_install
  cd ..
}

build_libnettle() {
  download_and_unpack_file https://ftp.gnu.org/gnu/nettle/nettle-3.6.tar.gz
  cd nettle-3.6
    local config_options="--disable-openssl --disable-documentation" # in case we have both gnutls and openssl, just use gnutls [except that gnutls uses this so...huh?
    if [[ $compiler_flavors == "native" ]]; then
      config_options+=" --libdir=${mingw_w64_x86_64_prefix}/lib" # Otherwise native builds install to /lib32 or /lib64 which gnutls doesn't find
    fi
    generic_configure "$config_options" # in case we have both gnutls and openssl, just use gnutls [except that gnutls uses this so...huh? https://github.com/rdp/ffmpeg-windows-build-helpers/issues/25#issuecomment-28158515
    do_make_and_make_install # What's up with "Configured with: ... --with-gmp=/cygdrive/d/ffmpeg-windows-build-helpers-master/native_build/windows/ffmpeg_local_builds/sandbox/cross_compilers/pkgs/gmp/gmp-6.1.2-i686" in 'config.log'? Isn't the 'gmp-6.1.2' above being used?
  cd ..
}

build_librtmp_gnutls() {
  do_git_checkout "http://repo.or.cz/r/rtmpdump.git" rtmpdump_git
  cd rtmpdump_git/librtmp
	git co 883c33489403ed360a01d1a47ec76d476525b49e # trunk didn't build once...
	make install CRYPTO=GNUTLS OPT='-O2 -g' "CROSS_COMPILE=$cross_prefix" SHARED=no "prefix=$mingw_w64_x86_64_prefix" || exit 1
	sed -i 's/-lrtmp -lz/-lrtmp -lwinmm -lz/' "$PKG_CONFIG_PATH/librtmp.pc"
  cd ../..
}

build_librtmp() {
  #do_git_checkout git://git.ffmpeg.org/rtmpdump rtmpdump_git
  do_git_checkout https://github.com/JudgeZarbi/RTMPDump-OpenSSL-1.1 rtmpdump_git
  cd rtmpdump_git/librtmp
        # use the cross compiler binaries as gcc, windres, ar and ranlib
        ln -s "${cross_prefix}gcc"     "$mingw_bin_path/gcc"
        ln -s "${cross_prefix}g++"     "$mingw_bin_path/g++"
        ln -s "${cross_prefix}windres" "$mingw_bin_path/windres"
        ln -s "${cross_prefix}ar"      "$mingw_bin_path/ar"
        ln -s "${cross_prefix}ranlib"  "$mingw_bin_path/ranlib"
        ln -s "${cross_prefix}ld"  "$mingw_bin_path/ld"
		export prefix=$mingw_w64_x86_64_prefix
		export cross=${cross_prefix}
        which gcc
        gcc --version
		# undefined reference to `__imp_timeGetTime'
		# patch RTMP_GetTime() to return always 0
		apply_patch file://$patch_dir/librtmp_time_return_0.patch
		#bash
		echo do_make_install "CRYPTO=OPENSSL OPT=-O2 CROSS_COMPILE=$cross_prefix SHARED=no prefix=$mingw_w64_x86_64_prefix"
		#bash
		do_make_install "CRYPTO=OPENSSL OPT=-O2 CROSS_COMPILE=$cross_prefix SHARED=no prefix=$mingw_w64_x86_64_prefix"
        rm    "$mingw_bin_path/gcc"
        rm    "$mingw_bin_path/g++"
        rm    "$mingw_bin_path/windres"
        rm    "$mingw_bin_path/ar"
        rm    "$mingw_bin_path/ranlib"
		sed -i 's/-lrtmp -lz/-lrtmp -lwinmm -lws2_32 -lz/' "$PKG_CONFIG_PATH/librtmp.pc"
    cd ..
  cd ..
}

build_libssh2_wincng() {
  local ssh2_version="1.11.0"
  local ssh2_previous="1.10.0"
  rm -rf libssh2-$ssh2_previous
  download_and_unpack_file https://github.com/libssh2/libssh2/releases/download/libssh2-$ssh2_version/libssh2-$ssh2_version.tar.gz libssh2-$ssh2_version
  cd libssh2-$ssh2_version
	ln -s "${cross_prefix}gcc"     "$mingw_bin_path/gcc"
	ln -s "${cross_prefix}g++"     "$mingw_bin_path/g++"
	ln -s "${cross_prefix}windres" "$mingw_bin_path/windres"
	ln -s "${cross_prefix}ar"      "$mingw_bin_path/ar"
	ln -s "${cross_prefix}ranlib"  "$mingw_bin_path/ranlib"
    # echo remove line with ENGINE_load_builtin_engines in src/openssl.h - unresolved
    # apply_patch file://$patch_dir/ssh2_load_builtin_engines.diff
    # echo Implement sftp writeback https://github.com/djelinski/libssh2/commit/e3fd7f8cca77f03225829ab975cc3aae0026ae36
    # apply_patch file://$patch_dir/ssh2_sftp_writeback.diff -p1
    do_cmake_and_install "-DBUILD_SHARED_LIBS=0 -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DCRYPTO_BACKEND=WinCNG"
	rm    "$mingw_bin_path/gcc"
	rm    "$mingw_bin_path/g++"
	rm    "$mingw_bin_path/windres"
	rm    "$mingw_bin_path/ar"
	rm    "$mingw_bin_path/ranlib"
  cd ..
}

build_libssh2() {
  local ssh2_version="1.10.0"
  local ssh2_previous="1.9.0"
  rm -rf libssh2-$ssh2_previous
  download_and_unpack_file https://github.com/libssh2/libssh2/releases/download/libssh2-$ssh2_version/libssh2-$ssh2_version.tar.gz libssh2-$ssh2_version
  cd libssh2-$ssh2_version
	ln -s "${cross_prefix}gcc"     "$mingw_bin_path/gcc"
	ln -s "${cross_prefix}g++"     "$mingw_bin_path/g++"
	ln -s "${cross_prefix}windres" "$mingw_bin_path/windres"
	ln -s "${cross_prefix}ar"      "$mingw_bin_path/ar"
	ln -s "${cross_prefix}ranlib"  "$mingw_bin_path/ranlib"
    # echo remove line with ENGINE_load_builtin_engines in src/openssl.h - unresolved
    # apply_patch file://$patch_dir/ssh2_load_builtin_engines.diff
    # echo Implement sftp writeback https://github.com/djelinski/libssh2/commit/e3fd7f8cca77f03225829ab975cc3aae0026ae36
    # apply_patch file://$patch_dir/ssh2_sftp_writeback.diff -p1
    do_cmake_and_install "-DBUILD_SHARED_LIBS=0 -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DCRYPTO_BACKEND=OpenSSL"
	rm    "$mingw_bin_path/gcc"
	rm    "$mingw_bin_path/g++"
	rm    "$mingw_bin_path/windres"
	rm    "$mingw_bin_path/ar"
	rm    "$mingw_bin_path/ranlib"
  cd ..
}

build_libssh() {
  libssh_version_branch="0.7"
  libssh_version="0.7.5"
  # download_and_unpack_file http://sources.openelec.tv/mirror/libssh/libssh-$libssh_version.tar.xz libssh-$libssh_version
  download_and_unpack_file https://www.libssh.org/files/$libssh_version_branch/libssh-$libssh_version.tar.xz libssh-$libssh_version
  cd libssh-$libssh_version
    local touch_name=$(get_small_touchfile_name already_ran_cmake)

    if [ ! -f $touch_name ]; then
      local cur_dir2=$(pwd)
      sed -i 's/add_subdirectory(doc.*)//g' CMakeLists.txt
      mkdir build
      cd build
        # use the cross compiler binaries as gcc, windres, ar and ranlib
        ln -s "${cross_prefix}gcc"     "$mingw_bin_path/gcc"
        ln -s "${cross_prefix}g++"     "$mingw_bin_path/g++"
        ln -s "${cross_prefix}windres" "$mingw_bin_path/windres"
        ln -s "${cross_prefix}ar"      "$mingw_bin_path/ar"
        ln -s "${cross_prefix}ranlib"  "$mingw_bin_path/ranlib"
        which gcc
        gcc --version
        echo cmake .. -DWITH_STATIC_LIB=1 -DLIBSSH_THREADS=1 -DWITH_SERVER=0 -DWITH_PCAP=0 -DWITH_EXAMPLES=0 -DOPENSSL_ROOT_DIR=$mingw_w64_x86_64_prefix -DOPENSSL_INCLUDE_DIR=$mingw_w64_x86_64_prefix/../include -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix
        cmake      .. -DWITH_STATIC_LIB=1 -DLIBSSH_THREADS=1 -DWITH_SERVER=0 -DWITH_PCAP=0 -DWITH_EXAMPLES=0 -DOPENSSL_ROOT_DIR=$mingw_w64_x86_64_prefix -DOPENSSL_INCLUDE_DIR=$mingw_w64_x86_64_prefix/../include -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix

        # libssh 7.5.0
        # -- Looking for openssl/des.h
        # -- Looking for openssl/des.h - found
        # -- Looking for openssl/aes.h
        # -- Looking for openssl/aes.h - found
        # -- Looking for openssl/blowfish.h
        # -- Looking for openssl/blowfish.h - found
        # -- Looking for openssl/ecdh.h
        # -- Looking for openssl/ecdh.h - found
        # -- Looking for openssl/ec.h
        # -- Looking for openssl/ec.h - found
        # -- Looking for openssl/ecdsa.h
        # -- Looking for openssl/ecdsa.h - found

        # -- Threads_FOUND=TRUE
        # -- threads library: Threads_FOUND=TRUE
        # -- libssh_threads_SRCS=pthread.c
        # -- ********************************************
        # -- ********** libssh build options : **********
        # -- zlib support: ON
        # -- libgcrypt support: OFF
        # -- libnacl support: OFF
        # -- SSH-1 support: OFF
        # -- SFTP support: ON
        # -- Server support : 0
        # -- GSSAPI support : 0
        # -- Pcap debugging support : 0
        # -- With static library: 1
        # -- Unit testing: OFF
        # -- Client code Unit testing: OFF
        # -- Public API documentation generation
        # -- Benchmarks: OFF
        # -- ********************************************

        make clean
	make ssh_static
	make ssh_threads_static

	mkdir                                        $mingw_w64_x86_64_prefix/include/libssh
	chmod      755                               $mingw_w64_x86_64_prefix/include/libssh
        install -m 644 ../include/libssh/callbacks.h $mingw_w64_x86_64_prefix/include/libssh/callbacks.h
        install -m 644 ../include/libssh/libssh.h    $mingw_w64_x86_64_prefix/include/libssh/libssh.h
        install -m 644 ../include/libssh/ssh2.h      $mingw_w64_x86_64_prefix/include/libssh/ssh2.h
        install -m 644 ../include/libssh/legacy.h    $mingw_w64_x86_64_prefix/include/libssh/legacy.h
        install -m 644 ../include/libssh/sftp.h      $mingw_w64_x86_64_prefix/include/libssh/sftp.h
        install -m 644 src/libssh.a                  $mingw_w64_x86_64_prefix/lib/libssh.a
        install -m 644 libssh.pc                     $mingw_w64_x86_64_prefix/lib/pkgconfig/libssh.pc
        install -m 644 src/threads/libssh_threads.a  $mingw_w64_x86_64_prefix/lib/libssh_threads.a
        install -m 644 libssh_threads.pc             $mingw_w64_x86_64_prefix/lib/pkgconfig/libssh_threads.pc

        rm    "$mingw_bin_path/gcc"
        rm    "$mingw_bin_path/g++"
        rm    "$mingw_bin_path/windres"
        rm    "$mingw_bin_path/ar"
        rm    "$mingw_bin_path/ranlib"
      cd ..
      touch $touch_name
    fi

  cd ..
}

build_libgpg-error() {
  download_and_unpack_file https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.44.tar.bz2 libgpg-error-1.44
  cd libgpg-error-1.44
    generic_configure_make_install
  cd ..
}

build_libgcrypt() {
  download_and_unpack_file https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.10.0.tar.bz2 libgcrypt-1.10.0
  cd libgcrypt-1.10.0
    generic_configure_make_install
  cd ..
}

build_nghttp2() {
  do_git_checkout https://github.com/nghttp2/nghttp2.git nghttp2
  cd nghttp2
    local touch_name=$(get_small_touchfile_name already_ran_cmake)
    # if [ ! -f lib/libnghttp2.a ]; then
    #  if [[ ! -f configure ]]; then
    #   autoreconf -fiv
    #  fi
      ./configure
      cd lib
	rm CMakeCache.txt
	rm -rf CMakeFiles
	git stash
	patch -p1 < ~/patches/nghttp2_static_export.patch
	# 5 times __declspec(dllexport) in includes/nghttp2/nghttp2.h
	#
	# jan@box:~/sandbox/win32/nghttp2$ grep -R _nghttp2_session_want_write *
	# Binary file lib/libnghttp2.dll.a matches
	# Binary file lib/CMakeFiles/nghttp2.dir/nghttp2_session.c.obj matches
	# Binary file lib/CMakeFiles/nghttp2.dir/objects.a matches
	# Binary file lib/libnghttp2.dll matches
	# Binary file lib/libnghttp2.a matches
        do_cmake "-DENABLE_STATIC_LIB=1 -DNGHTTP2_STATICLIB=1 -DCMAKE_INSTALL_LIBDIR=$mingw_w64_x86_64_prefix/lib -Wno-dev"
        # use the cross compiler binaries as gcc, windres, ar and ranlib
        ln -s "${cross_prefix}gcc"     "$mingw_bin_path/gcc"
        ln -s "${cross_prefix}g++"     "$mingw_bin_path/g++"
        ln -s "${cross_prefix}windres" "$mingw_bin_path/windres"
        ln -s "${cross_prefix}ar"      "$mingw_bin_path/ar"
        ln -s "${cross_prefix}ranlib"  "$mingw_bin_path/ranlib"
        ln -s "${cross_prefix}ld"  "$mingw_bin_path/ld"
		export prefix=$mingw_w64_x86_64_prefix
		export cross=${cross_prefix}
        echo cmake . -DENABLE_STATIC_LIB=1 -DNGHTTP2_STATICLIB=1 -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix -DCMAKE_INSTALL_LIBDIR=$mingw_w64_x86_64_prefix/lib
        rm    "$mingw_bin_path/gcc"
        rm    "$mingw_bin_path/g++"
        rm    "$mingw_bin_path/windres"
        rm    "$mingw_bin_path/ar"
        rm    "$mingw_bin_path/ranlib"
        rm    "$mingw_bin_path/ld"
        grep AC_INIT ../configure.ac | cut -d'[' -f3 | sed -e 's/], //g' -e 's/1/export nghttp2ver=1/g'
	do_make
      cd ..
      #do_cmake_and_install
      install -d                                       $mingw_w64_x86_64_prefix/include/nghttp2
      install -m 644 lib/includes/nghttp2/nghttp2.h    $mingw_w64_x86_64_prefix/include/nghttp2/nghttp2.h
      install -m 644 lib/includes/nghttp2/nghttp2ver.h $mingw_w64_x86_64_prefix/include/nghttp2/nghttp2ver.h
      install -m 644 lib/libnghttp2.a $mingw_w64_x86_64_prefix/lib/libnghttp2.a
    # fi
  cd ..
}

build_curl() {
  local curl_version="8.2.1"
  local curl_previous="8.2.0"
  rm -rf curl-$curl_previous
  download_and_unpack_file https://curl.haxx.se/download/curl-$curl_version.tar.gz curl-$curl_version
  cd curl-$curl_version
    apply_patch file://$patch_dir/curl_sftp_buffer.patch
    # use the cross compiler binaries as gcc, windres, ar and ranlib
    ln -s "${cross_prefix}gcc"     "$mingw_bin_path/gcc"
    ln -s "${cross_prefix}g++"     "$mingw_bin_path/g++"
    ln -s "${cross_prefix}windres" "$mingw_bin_path/windres"
    ln -s "${cross_prefix}ar"      "$mingw_bin_path/ar"
    ln -s "${cross_prefix}ranlib"  "$mingw_bin_path/ranlib"
    export prefix=$mingw_w64_x86_64_prefix
    export cross=${cross_prefix}
#    CPPFLAGS="-DNGHTTP2_STATICLIB" ./configure      --prefix=$mingw_w64_x86_64_prefix --host=$host_target --enable-shared=no --with-libssh2 --with-nghttp2 --with-winidn --enable-sspi
#    echo CPPFLAGS="-DNGHTTP2_STATICLIB" ./configure --prefix=$mingw_w64_x86_64_prefix --host=$host_target --enable-shared=no --with-libssh2 --with-nghttp2 --with-winidn --enable-sspi
#    CPPFLAGS="-DNGHTTP2_STATICLIB" ./configure      --prefix=$mingw_w64_x86_64_prefix --host=$host_target --with-ssl=no --enable-shared=no --with-winidn --enable-sspi --with-schannel --with-libssh2 --with-nghttp2=no
#    echo CPPFLAGS="-DNGHTTP2_STATICLIB" ./configure --prefix=$mingw_w64_x86_64_prefix --host=$host_target --with-ssl=no --enable-shared=no --with-winidn --enable-sspi --with-schannel --with-libssh2 --with-nghttp2=no
    CPPFLAGS="-DNGHTTP2_STATICLIB" ./configure      --prefix=$mingw_w64_x86_64_prefix --host=$host_target --enable-shared=no --with-libssh2 --with-nghttp2 --with-winidn --enable-sspi --with-openssl=$mingw_w64_x86_64_prefix --with-schannel --with-librtmp=$mingw_w64_x86_64_prefix
    echo CPPFLAGS="-DNGHTTP2_STATICLIB" ./configure --prefix=$mingw_w64_x86_64_prefix --host=$host_target --enable-shared=no --with-libssh2 --with-nghttp2 --with-winidn --enable-sspi --with-openssl=$mingw_w64_x86_64_prefix --with-schannel --with-librtmp=$mingw_w64_x86_64_prefix
    # link the static libnghttp2
    echo cp $mingw_w64_x86_64_prefix/lib/libnghttp2.a $mingw_w64_x86_64_prefix/lib/libnghttp2.dll.a
	cp      $mingw_w64_x86_64_prefix/lib/libnghttp2.a $mingw_w64_x86_64_prefix/lib/libnghttp2.dll.a
	#bash
    make
    strip src/curl.exe
    rm    "$mingw_bin_path/gcc"
    rm    "$mingw_bin_path/g++"
    rm    "$mingw_bin_path/windres"
    rm    "$mingw_bin_path/ar"
    rm    "$mingw_bin_path/ranlib"
  cd ..
}
#  SSL:              enabled (Windows-native, OpenSSL)
#  SSH:              enabled (libSSH2)
#  zlib:             enabled
#  brotli:           no      (--with-brotli)
#  GSS-API:          no      (--with-gssapi)
#  TLS-SRP:          enabled
#  resolver:         POSIX threaded
#  IPv6:             enabled
#  Unix sockets:     no      (--enable-unix-sockets)
#  IDN:              enabled (Windows-native)
#  Build libcurl:    Shared=no, Static=yes
#  Built-in manual:  enabled
#  --libcurl option: enabled (--disable-libcurl-option)
#  Verbose errors:   enabled (--disable-verbose)
#  Code coverage:    disabled
#  SSPI:             enabled
#  ca cert bundle:   no
#  ca cert path:     no
#  ca fallback:      no
#  LDAP:             enabled (winldap)
#  LDAPS:            enabled
#  RTSP:             enabled
#  RTMP:             no      (--with-librtmp)
#  Metalink:         no      (--with-libmetalink)
#  PSL:              no      (libpsl not found)
#  Alt-svc:          no      (--enable-alt-svc)
#  HTTP2:            enabled (nghttp2)
#  Protocols:        DICT FILE FTP FTPS GOPHER HTTP HTTPS IMAP IMAPS LDAP LDAPS POP3 POP3S RTSP SCP SFTP SMB SMBS SMTP SMTPS TELNET TFTP
#  Features:         SSL IPv6 libz AsynchDNS IDN SSPI SPNEGO Kerberos NTLM TLS-SRP HTTP2 MultiSSL HTTPS-proxy

build_unistring() {
  generic_download_and_make_and_install https://ftp.gnu.org/gnu/libunistring/libunistring-0.9.10.tar.xz
}

build_gnutls() {
  download_and_unpack_file https://www.gnupg.org/ftp/gcrypt/gnutls/v3.6/gnutls-3.6.15.tar.xz
  cd gnutls-3.6.15
    # --disable-cxx don't need the c++ version, in an effort to cut down on size... XXXX test size difference...
    # --enable-local-libopts to allow building with local autogen installed,
    # --disable-guile is so that if it finds guile installed (cygwin did/does) it won't try and link/build to it and fail...
    # libtasn1 is some dependency, appears provided is an option [see also build_libnettle]
    # pks #11 hopefully we don't need kit
    generic_configure "--disable-doc --disable-tools --disable-cxx --disable-tests --disable-gtk-doc-html --disable-libdane --disable-nls --enable-local-libopts --disable-guile --with-included-libtasn1 --without-p11-kit"
    do_make_and_make_install
    if [[ $compiler_flavors != "native"  ]]; then
      # libsrt doesn't know how to use its pkg deps :| https://github.com/Haivision/srt/issues/565
      sed -i.bak 's/-lgnutls.*/-lgnutls -lcrypt32 -lnettle -lhogweed -lgmp -lidn2 -liconv -lunistring/' "$PKG_CONFIG_PATH/gnutls.pc"
      if [[ $OSTYPE == darwin* ]]; then
        sed -i.bak 's/-lgnutls.*/-lgnutls -framework Security -framework Foundation/' "$PKG_CONFIG_PATH/gnutls.pc"
      fi
    fi
  cd ..
}

build_openssl-1.0.2() {
  rm -rf openssl-1.0.2t
  download_and_unpack_file https://www.openssl.org/source/openssl-1.0.2u.tar.gz
  cd openssl-1.0.2u
    apply_patch file://$patch_dir/openssl-1.0.2l_lib-only.diff
    export CC="${cross_prefix}gcc"
    export AR="${cross_prefix}ar"
    export RANLIB="${cross_prefix}ranlib"
    local config_options="--prefix=$mingw_w64_x86_64_prefix zlib "
    if [ "$1" = "dllonly" ]; then
      config_options+="shared "
    else
      config_options+="no-shared no-dso no-hw no-gost no-capieng "
    fi
    if [ "$bits_target" = "32" ]; then
      config_options+="mingw" # Build shared libraries ('libeay32.dll' and 'ssleay32.dll') if "dllonly" is specified.
      local arch=x86
    else
      config_options+="mingw64" # Build shared libraries ('libeay64.dll' and 'ssleay64.dll') if "dllonly" is specified.
      local arch=x86_64
    fi
    do_configure "$config_options" ./Configure
    if [[ ! -f Makefile_1 ]]; then
      sed -i_1 "s/-O3/-O2/" Makefile # Change CFLAGS (OpenSSL's 'Configure' already creates a 'Makefile.bak').
    fi
    if [ "$1" = "dllonly" ]; then
      do_make "build_libs"

      mkdir -p $cur_dir/redist # Strip and pack shared libraries.
      archive="$cur_dir/redist/openssl-${arch}-v1.0.2l.7z"
      if [[ ! -f $archive ]]; then
        for sharedlib in *.dll; do
          ${cross_prefix}strip $sharedlib
        done
        sed "s/$/\r/" LICENSE > LICENSE.txt
        7z a -mx=9 $archive *.dll LICENSE.txt && rm -f LICENSE.txt
      fi
    else
      do_make_and_make_install
    fi
    unset CC
    unset AR
    unset RANLIB
  cd ..
}

build_openssl-1.1.0() {
  rm -rf openssl-1.1.0j
  download_and_unpack_file https://www.openssl.org/source/openssl-1.1.0k.tar.gz
  cd openssl-1.1.0k
    export CC="${cross_prefix}gcc"
    export AR="${cross_prefix}ar"
    export RANLIB="${cross_prefix}ranlib"
    local config_options="--prefix=$mingw_w64_x86_64_prefix zlib "
    if [ "$1" = "dllonly" ]; then
      config_options+="shared no-engine "
    else
      config_options+="no-shared no-dso no-engine "
    fi
    if [[ `uname` =~ "5.1" ]] || [[ `uname` =~ "6.0" ]]; then
      config_options+="no-async " # "Note: on older OSes, like CentOS 5, BSD 5, and Windows XP or Vista, you will need to configure with no-async when building OpenSSL 1.1.0 and above. The configuration system does not detect lack of the Posix feature on the platforms." (https://wiki.openssl.org/index.php/Compilation_and_Installation)
    fi
    if [ "$bits_target" = "32" ]; then
      config_options+="mingw" # Build shared libraries ('libcrypto-1_1.dll' and 'libssl-1_1.dll') if "dllonly" is specified.
      local arch=x86
    else
      config_options+="mingw64" # Build shared libraries ('libcrypto-1_1-x64.dll' and 'libssl-1_1-x64.dll') if "dllonly" is specified.
      local arch=x86_64
    fi
    do_configure "$config_options" ./Configure
    if [[ ! -f Makefile.bak ]]; then # Change CFLAGS.
      sed -i.bak "s/-O3/-O2/" Makefile
    fi
    do_make "build_libs"
    if [ "$1" = "dllonly" ]; then
      mkdir -p $cur_dir/redist # Strip and pack shared libraries.
      archive="$cur_dir/redist/openssl-${arch}-v1.1.0k.7z"
      if [[ ! -f $archive ]]; then
        for sharedlib in *.dll; do
          ${cross_prefix}strip $sharedlib
        done
        sed "s/$/\r/" LICENSE > LICENSE.txt
        7z a -mx=9 $archive *.dll LICENSE.txt && rm -f LICENSE.txt
      fi
    else
      do_make_install "" "install_dev"
    fi
    unset CC
    unset AR
    unset RANLIB
  cd ..
}

build_openssl-1.1.1() {
  rm -rf openssl-1.1.1u
  download_and_unpack_file https://www.openssl.org/source/openssl-1.1.1v.tar.gz
  cd openssl-1.1.1v
    export CC="${cross_prefix}gcc"
    export AR="${cross_prefix}ar"
    export RANLIB="${cross_prefix}ranlib"
    local config_options="--prefix=$mingw_w64_x86_64_prefix zlib "
    if [ "$1" = "dllonly" ]; then
      config_options+="shared no-engine "
    else
      config_options+="no-shared no-dso no-engine "
    fi
    if [[ `uname` =~ "5.1" ]] || [[ `uname` =~ "6.0" ]]; then
      config_options+="no-async " # "Note: on older OSes, like CentOS 5, BSD 5, and Windows XP or Vista, you will need to configure with no-async when building OpenSSL 1.1.0 and above. The configuration system does not detect lack of the Posix feature on the platforms." (https://wiki.openssl.org/index.php/Compilation_and_Installation)
    fi
    if [ "$bits_target" = "32" ]; then
      config_options+="mingw" # Build shared libraries ('libcrypto-1_1.dll' and 'libssl-1_1.dll') if "dllonly" is specified.
      local arch=x86
    else
      config_options+="mingw64" # Build shared libraries ('libcrypto-1_1-x64.dll' and 'libssl-1_1-x64.dll') if "dllonly" is specified.
      local arch=x86_64
    fi
    do_configure "$config_options" ./Configure
    if [[ ! -f Makefile.bak ]]; then # Change CFLAGS.
      sed -i.bak "s/-O3/-O2/" Makefile
    fi
    do_make "build_libs"
    if [ "$1" = "dllonly" ]; then
      mkdir -p $cur_dir/redist # Strip and pack shared libraries.
      archive="$cur_dir/redist/openssl-${arch}-v1.1.1h.7z"
      if [[ ! -f $archive ]]; then
        for sharedlib in *.dll; do
          ${cross_prefix}strip $sharedlib
        done
        sed "s/$/\r/" LICENSE > LICENSE.txt
        7z a -mx=9 $archive *.dll LICENSE.txt && rm -f LICENSE.txt
      fi
    else
      do_make_install "" "install_dev"
    fi
    unset CC
    unset AR
    unset RANLIB
  cd ..
}

build_libogg() {
  do_git_checkout https://github.com/xiph/ogg.git
  cd ogg_git
    generic_configure_make_install
  cd ..
}

build_libvorbis() {
  do_git_checkout https://github.com/xiph/vorbis.git
  cd vorbis_git
    generic_configure "--disable-docs --disable-examples --disable-oggtest"
    do_make_and_make_install
  cd ..
}

build_libopus() {
  do_git_checkout https://github.com/xiph/opus.git
  cd opus_git
    generic_configure "--disable-doc --disable-extra-programs --disable-stack-protector"
    do_make_and_make_install
  cd ..
}

build_libspeexdsp() {
  do_git_checkout https://github.com/xiph/speexdsp.git
  cd speexdsp_git
    generic_configure "--disable-examples"
    do_make_and_make_install
  cd ..
}

build_libspeex() {
  do_git_checkout https://github.com/xiph/speex.git
  cd speex_git
    export SPEEXDSP_CFLAGS="-I$mingw_w64_x86_64_prefix/include"
    export SPEEXDSP_LIBS="-L$mingw_w64_x86_64_prefix/lib -lspeexdsp" # 'configure' somehow can't find SpeexDSP with 'pkg-config'.
    generic_configure "--disable-binaries" # If you do want the libraries, then 'speexdec.exe' needs 'LDFLAGS=-lwinmm'.
    do_make_and_make_install
    unset SPEEXDSP_CFLAGS
    unset SPEEXDSP_LIBS
  cd ..
}

build_libtheora() {
  do_git_checkout https://github.com/xiph/theora.git
  cd theora_git
    generic_configure "--disable-doc --disable-oggtest --disable-vorbistest --disable-examples"
    # 'examples/encoder_example.c' would otherwise cause problems; "encoder_example.c:56:15: error: static declaration of 'rint' follows non-static declaration". No more issues with latest libpng either.
    do_make_and_make_install
  cd ..
}

build_libsndfile() {
  do_git_checkout https://github.com/erikd/libsndfile.git
  cd libsndfile_git
    generic_configure "--disable-sqlite --disable-external-libs --disable-full-suite"
    do_make_and_make_install
    if [ "$1" = "install-libgsm" ]; then
      if [[ ! -f $mingw_w64_x86_64_prefix/lib/libgsm.a ]]; then
        install -m644 src/GSM610/gsm.h $mingw_w64_x86_64_prefix/include/gsm.h || exit 1
        install -m644 src/GSM610/.libs/libgsm.a $mingw_w64_x86_64_prefix/lib/libgsm.a || exit 1
      else
        echo "already installed GSM 6.10 ..."
      fi
    fi
  cd ..
}

build_lame() {
  do_git_checkout https://github.com/rbrito/lame.git
  cd lame_git
    apply_patch file://$patch_dir/lame3.patch # work on mtune=generic type builds :| TODO figure out why, report back to https://sourceforge.net/p/lame/bugs/443/
    generic_configure "--enable-nasm --disable-decoder --disable-frontend"
    cpu_count=1 # can't handle it apparently... http://betterlogic.com/roger/2017/07/mp3lame-woe/
    do_make_and_make_install
    cpu_count=$original_cpu_count
  cd ..
}

build_twolame() {
  do_git_checkout https://github.com/njh/twolame.git
  cd twolame_git
    if [[ ! -f Makefile.am.bak ]]; then # Library only, front end refuses to build for some reason with git master
      sed -i.bak "/^SUBDIRS/s/ frontend.*//" Makefile.am || exit 1 
    fi
    cpu_count=1 # maybe can't handle it http://betterlogic.com/roger/2017/07/mp3lame-woe/ comments
    generic_configure_make_install
    cpu_count=$original_cpu_count
  cd ..
}

build_fdk-aac() {
  do_git_checkout https://github.com/mstorsjo/fdk-aac.git
  cd fdk-aac_git
    if [[ ! -f "configure" ]]; then
      autoreconf -fiv || exit 1
    fi
    generic_configure_make_install
  cd ..
}

build_libopencore() {
  generic_download_and_make_and_install https://sourceforge.net/projects/opencore-amr/files/opencore-amr/opencore-amr-0.1.5.tar.gz
  generic_download_and_make_and_install https://sourceforge.net/projects/opencore-amr/files/vo-amrwbenc/vo-amrwbenc-0.1.3.tar.gz
}

build_libilbc() {
  do_git_checkout https://github.com/TimothyGu/libilbc.git
  cd libilbc_git
    generic_configure_make_install
  cd ..
}

build_libmodplug() {
  do_git_checkout https://github.com/Konstanty/libmodplug.git
  cd libmodplug_git
    sed -i.bak 's/__declspec(dllexport)//' "$mingw_w64_x86_64_prefix/include/libmodplug/modplug.h" #strip DLL import/export directives
    sed -i.bak 's/__declspec(dllimport)//' "$mingw_w64_x86_64_prefix/include/libmodplug/modplug.h"
    if [[ ! -f "configure" ]]; then
      autoreconf -fiv || exit 1
      automake --add-missing || exit 1
    fi
    if [[ ! -f "compile" ]]; then
      automake --add-missing || exit 1
    fi
    generic_configure_make_install # or could use cmake I guess
  cd ..
}

build_libgme() {
  # do_git_checkout https://bitbucket.org/mpyne/game-music-emu.git
  download_and_unpack_file https://bitbucket.org/mpyne/game-music-emu/downloads/game-music-emu-0.6.2.tar.xz
  cd game-music-emu-0.6.2
    if [[ ! -f CMakeLists.txt.bak ]]; then
      sed -i.bak "s/ __declspec.*//" gme/blargg_source.h # Needed for building shared FFmpeg libraries.
    fi
    do_cmake_and_install "-DBUILD_SHARED_LIBS=0 -DENABLE_UBSAN=0"
  cd ..
}

build_libbluray() {
  unset JDK_HOME # #268 was causing failure
  do_git_checkout https://code.videolan.org/videolan/libbluray.git
  cd libbluray_git
    if [[ ! -d .git/modules ]]; then
      git submodule update --init --remote # For UDF support [default=enabled], which strangely enough is in another repository.
    else
      local local_git_version=`git --git-dir=.git/modules/contrib/libudfread rev-parse HEAD`
      local remote_git_version=`git ls-remote -h https://code.videolan.org/videolan/libudfread.git | sed "s/[[:space:]].*//"`
      if [[ "$local_git_version" != "$remote_git_version" ]]; then
        git clean -f # Throw away local changes; 'already_*' in this case.
        git submodule foreach -q 'git clean -f' # Throw away local changes; 'already_configured_*' and 'udfread.c.bak' in this case.
        rm -f contrib/libudfread/src/udfread-version.h
        git submodule update --remote -f # Checkout even if the working tree differs from HEAD.
      fi
    fi
    if [[ ! -f jni/win32/jni_md.h.bak ]]; then
      sed -i.bak "/JNIEXPORT/s/ __declspec.*//" jni/win32/jni_md.h # Needed for building shared FFmpeg libraries.
    fi
    cd contrib/libudfread
      if [[ ! -f src/udfread.c.bak ]]; then
        sed -i.bak "/WIN32$/,+4d" src/udfread.c # Fix WinXP incompatibility.
      fi
      if [[ ! -f src/udfread-version.h ]]; then
        generic_configure # Generate 'udfread-version.h', or building Libbluray fails otherwise.
      fi
    cd ../..
    generic_configure "--disable-examples --disable-bdjava-jar"
    do_make_and_make_install
  cd ..
}

build_libbs2b() {
  download_and_unpack_file https://downloads.sourceforge.net/project/bs2b/libbs2b/3.1.0/libbs2b-3.1.0.tar.gz
  cd libbs2b-3.1.0
    sed -i.bak "s/AC_FUNC_MALLOC//" configure.ac # #270
    generic_configure_make_install
  cd ..
}

build_libsoxr() {
  do_git_checkout https://git.code.sf.net/p/soxr/code soxr_git
  cd soxr_git
    do_cmake_and_install "-DHAVE_WORDS_BIGENDIAN_EXITCODE=0 -DWITH_OPENMP=0 -DBUILD_TESTS=0 -DBUILD_EXAMPLES=0"
  cd ..
}

build_libflite() {
  download_and_unpack_file http://www.festvox.org/flite/packed/flite-2.0/flite-2.0.0-release.tar.bz2
  cd flite-2.0.0-release
    if [[ ! -f configure.bak ]]; then
      sed -i.bak "s|i386-mingw32-|$cross_prefix|" configure
      #sed -i.bak "/define const/i\#include <windows.h>" tools/find_sts_main.c # Needed for x86_64? Untested.
      sed -i.bak "128,134d" main/Makefile # Library only. else fails with cannot copy bin/libflite or someodd
      sed -i.bak "s/cp -pd/cp -p/" main/Makefile # friendlier cp for OS X
    fi
    generic_configure
    do_make_and_make_install
  cd ..
}

build_libsnappy() {
  do_git_checkout https://github.com/google/snappy.git snappy_git 1.1.8 # got weird failure once
  cd snappy_git
    do_cmake_and_install "-DBUILD_SHARED_LIBS=OFF -DBUILD_BINARY=OFF -DCMAKE_BUILD_TYPE=Release -DSNAPPY_BUILD_TESTS=OFF" # extra params from deadsix27 and from new cMakeLists.txt content
    rm -f $mingw_w64_x86_64_prefix/lib/libsnappy.dll.a # unintall shared :|
  cd ..
}

build_vamp_plugin() {
  download_and_unpack_file https://github.com/c4dm/vamp-plugin-sdk/archive/vamp-plugin-sdk-v2.7.1.tar.gz vamp-plugin-sdk-vamp-plugin-sdk-v2.7.1
  cd vamp-plugin-sdk-vamp-plugin-sdk-v2.7.1
    apply_patch file://$patch_dir/vamp-plugin-sdk-2.7.1_static-lib.diff
    if [[ ! -f configure.bak ]]; then # Fix for "'M_PI' was not declared in this scope" (see https://stackoverflow.com/a/29264536).
      sed -i.bak "s/c++98/gnu++98/" configure
    fi
    do_configure "--host=$host_target --prefix=$mingw_w64_x86_64_prefix --disable-programs"
    do_make "install-static" # No need for 'do_make_install', because 'install-static' already has install-instructions.
  cd ..
}

build_fftw() {
  download_and_unpack_file http://fftw.org/fftw-3.3.6-pl2.tar.gz
  cd fftw-3.3.6-pl2
    generic_configure "--disable-doc"
    do_make_and_make_install
  cd ..
}

build_libsamplerate() {
  # I think this didn't work with ubuntu 14.04 [too old automake or some odd] :|
  #do_git_checkout https://github.com/erikd/libsamplerate.git
  #cd libsamplerate_git
  #  generic_configure
  #  do_make_and_make_install
  #cd ..
  generic_download_and_make_and_install http://www.mega-nerd.com/SRC/libsamplerate-0.1.8.tar.gz # can use this, but uses speex bundled by default [any difference?]
}

build_librubberband() {
  do_git_checkout https://github.com/breakfastquay/rubberband.git rubberband_git 18c06ab8c431854056407c467f4755f761e36a8e
  cd rubberband_git
    apply_patch file://$patch_dir/rubberband_git_static-lib.diff # create install-static target
    do_configure "--host=$host_target --prefix=$mingw_w64_x86_64_prefix --disable-ladspa"
    do_make "install-static AR=${cross_prefix}ar" # No need for 'do_make_install', because 'install-static' already has install-instructions.
    sed -i.bak 's/-lrubberband.*$/-lrubberband -lfftw3 -lsamplerate -lstdc++/' $PKG_CONFIG_PATH/rubberband.pc
  cd ..
}

build_frei0r() {
  do_git_checkout https://github.com/dyne/frei0r.git
  cd frei0r_git
    sed -i.bak 's/-arch i386//' CMakeLists.txt # OS X https://github.com/dyne/frei0r/issues/64
    do_cmake_and_install "-DWITHOUT_OPENCV=1" # XXX could look at this more...

    mkdir -p $cur_dir/redist # Strip and pack shared libraries.
    if [ $bits_target = 32 ]; then
      local arch=x86
    else
      local arch=x86_64
    fi
    archive="$cur_dir/redist/frei0r-plugins-${arch}-$(git describe --tags).7z"
    if [[ ! -f "$archive.done" ]]; then
      for sharedlib in $mingw_w64_x86_64_prefix/lib/frei0r-1/*.dll; do
        ${cross_prefix}strip $sharedlib
      done
      for doc in AUTHORS ChangeLog COPYING README.md; do
        sed "s/$/\r/" $doc > $mingw_w64_x86_64_prefix/lib/frei0r-1/$doc.txt
      done
      7z a -mx=9 $archive $mingw_w64_x86_64_prefix/lib/frei0r-1 && rm -f $mingw_w64_x86_64_prefix/lib/frei0r-1/*.txt
      touch "$archive.done" # for those with no 7z so it won't restrip every time
    fi
  cd ..
}

build_vidstab() {
  do_git_checkout https://github.com/georgmartius/vid.stab.git vid.stab_git
  cd vid.stab_git
    if [[ ! -f CMakeLists.txt.bak ]]; then # Change CFLAGS.
      sed -i.bak "s/O3/O2/;s/ -fPIC//" CMakeLists.txt
    fi
    do_cmake_and_install "-DBUILD_SHARED_LIBS=0 -DUSE_OMP=0" # '-DUSE_OMP' is on by default, but somehow libgomp ('cygwin_local_install/lib/gcc/i686-pc-cygwin/5.4.0/include/omp.h') can't be found, so '-DUSE_OMP=0' to prevent a compilation error.
  cd ..
}

build_libmysofa() {
  do_git_checkout https://github.com/hoene/libmysofa.git
  cd libmysofa_git
    do_cmake_and_install "-DBUILD_SHARED_LIBS=0 -DBUILD_TESTS=0"
  cd ..
}

build_libcaca() {
  do_git_checkout https://github.com/cacalabs/libcaca.git libcaca_git f1267fbd3cd3635a
  cd libcaca_git
    apply_patch file://$patch_dir/libcaca_git_stdio-cruft.diff -p1 # Fix WinXP incompatibility.
    cd caca
      sed -i.bak "s/__declspec(dllexport)//g" *.h # get rid of the declspec lines otherwise the build will fail for undefined symbols
      sed -i.bak "s/__declspec(dllimport)//g" *.h
    cd ..
    generic_configure "--libdir=$mingw_w64_x86_64_prefix/lib --disable-csharp --disable-java --disable-cxx --disable-python --disable-ruby --disable-doc"
    do_make_and_make_install
  cd ..
}

build_libdecklink() {
  if [[ ! -f $mingw_w64_x86_64_prefix/include/DeckLinkAPIVersion.h ]]; then
    # smaller files don't worry about partials for now, plus we only care about the last file anyway here...
    curl -4 file://$patch_dir/DeckLinkAPI.h --fail > $mingw_w64_x86_64_prefix/include/DeckLinkAPI.h || exit 1
    curl -4 file://$patch_dir/DeckLinkAPI_i.c --fail > $mingw_w64_x86_64_prefix/include/DeckLinkAPI_i.c.tmp || exit 1
    mv $mingw_w64_x86_64_prefix/include/DeckLinkAPI_i.c.tmp $mingw_w64_x86_64_prefix/include/DeckLinkAPI_i.c
    curl -4 file://$patch_dir/DeckLinkAPIVersion.h --fail > $mingw_w64_x86_64_prefix/include/DeckLinkAPIVersion.h || exit 1
  fi
}

build_zvbi() {
  download_and_unpack_file https://sourceforge.net/projects/zapping/files/zvbi/0.2.35/zvbi-0.2.35.tar.bz2
  cd zvbi-0.2.35
    apply_patch file://$patch_dir/zvbi-win32.patch
    apply_patch file://$patch_dir/zvbi-no-contrib.diff # weird issues with some stuff in contrib...
    generic_configure " --disable-dvb --disable-bktr --disable-proxy --disable-nls --without-doxygen --without-libiconv-prefix"
    # Without '--without-libiconv-prefix' 'configure' would otherwise search for and only accept a shared Libiconv library.
    do_make_and_make_install
  cd ..
}

build_fribidi() {
  do_git_checkout https://github.com/fribidi/fribidi.git fribidi_git f503e576c8345dd32d7438569346d6ca9aa50044
  cd fribidi_git
    cpu_count=1 # needed apparently with git master
    generic_configure "--disable-debug --disable-deprecated --disable-docs"
    do_make_and_make_install
    cpu_count=$original_cpu_count
  cd ..
}

build_libsrt() {
  # do_git_checkout https://github.com/Haivision/srt.git
  #cd srt_git
  #download_and_unpack_file https://codeload.github.com/Haivision/srt/tar.gz/v1.3.2 srt-1.3.2
  download_and_unpack_file https://github.com/Haivision/srt/archive/v1.4.1.tar.gz srt-1.4.1
  cd srt-1.4.1
    if [[ $compiler_flavors != "native" ]]; then
      apply_patch file://$patch_dir/srt.app.patch -p1
    fi
    # CMake Warning at CMakeLists.txt:893 (message):
    #   On MinGW, some C++11 apps are blocked due to lacking proper C++11 headers
    #   for <thread>.  FIX IF POSSIBLE.
    do_cmake "-DUSE_GNUTLS=ON -DENABLE_SHARED=OFF -DENABLE_CXX11=OFF"
    do_make_and_make_install
  cd ..
}

build_libass() {
  do_git_checkout_and_make_install https://github.com/libass/libass.git
}

build_libxavs() {
  do_svn_checkout https://svn.code.sf.net/p/xavs/code/trunk xavs_svn
  cd xavs_svn
    if [[ ! -f Makefile.bak ]]; then
      sed -i.bak "s/O4/O2/" configure # Change CFLAGS.
    fi
    do_configure "--host=$host_target --prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix" # see https://github.com/rdp/ffmpeg-windows-build-helpers/issues/3
    do_make_and_make_install "$make_prefix_options"
    rm -f NUL # cygwin causes windows explorer to not be able to delete this folder if it has this oddly named file in it...
  cd ..
}

build_libxvid() {
  download_and_unpack_file https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz xvidcore
  cd xvidcore/build/generic
    apply_patch file://$patch_dir/xvidcore-1.3.7_static-lib.patch
    do_configure "--host=$host_target --prefix=$mingw_w64_x86_64_prefix" # no static option...
    do_make_and_make_install
  cd ../../..
}

build_libvpx() {
  do_git_checkout https://chromium.googlesource.com/webm/libvpx.git
  cd libvpx_git
     apply_patch https://raw.githubusercontent.com/rdp/ffmpeg-windows-build-helpers/master/patches/vpx_160_semaphore.patch -p1 # perhaps someday can remove this after 1.6.0 or mingw fixes it LOL
    if [[ "$bits_target" = "32" ]]; then
      local config_options="--target=x86-win32-gcc"
    else
      local config_options="--target=x86_64-win64-gcc"
    fi
    export CROSS="$cross_prefix"
    do_configure "$config_options --prefix=$mingw_w64_x86_64_prefix --enable-static --disable-shared --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth"
    do_make_and_make_install
    unset CROSS
  cd ..
}

build_libaom() {
  do_git_checkout https://aomedia.googlesource.com/aom aom_git
  if [ "$bits_target" = "32" ]; then
    local config_options="-DCMAKE_TOOLCHAIN_FILE=../build/cmake/toolchains/x86-mingw-gcc.cmake -DAOM_TARGET_CPU=x86"
  else
    local config_options="-DCMAKE_TOOLCHAIN_FILE=../build/cmake/toolchains/x86_64-mingw-gcc.cmake -DAOM_TARGET_CPU=x86_64"
  fi
  mkdir -p aom_git/aom_build
  cd aom_git/aom_build
    do_cmake_from_build_dir .. $config_options
    do_make_and_make_install
  cd ../..
}

build_dav1d() {
  do_git_checkout https://code.videolan.org/videolan/dav1d.git libdav1d
  cd libdav1d
    if [[ $bits_target == 32 || $bits_target == 64 ]]; then # XXX why 64???
      apply_patch file://$patch_dir/david_no_asm.patch -p1 # XXX report
    fi
    cpu_count=1 # XXX report :|
    local meson_options="--prefix=${mingw_w64_x86_64_prefix} --libdir=${mingw_w64_x86_64_prefix}/lib --buildtype=release --default-library=static . build"
    if [[ $compiler_flavors != "native" ]]; then
      get_local_meson_cross_with_propeties # Need to add flags to meson properties; otherwise ran into some issues
      meson_options+=" --cross-file=${top_dir}/meson-cross.mingw.txt"
    fi
    do_meson "$meson_options"
    do_ninja_and_ninja_install
    cp build/src/libdav1d.a $mingw_w64_x86_64_prefix/lib || exit 1 # avoid 'run ranlib' weird failure, possibly older meson's https://github.com/mesonbuild/meson/issues/4138 :|
    cpu_count=$original_cpu_count
  cd ..
}

build_libx265() {
  local checkout_dir=x265_all_bitdepth
  local remote="https://bitbucket.org/multicoreware/x265_git"
  if [[ ! -z $x265_git_checkout_version ]]; then
    checkout_dir+="_$x265_git_checkout_version"
    do_git_checkout "$remote" $checkout_dir "$x265_git_checkout_version"
  fi
  if [[ $prefer_stable = "n" ]] && [[ -z $x265_git_checkout_version ]] ; then
    do_git_checkout "$remote" $checkout_dir "origin/master"
  fi
  if [[ $prefer_stable = "y" ]] && [[ -z $x265_git_checkout_version ]] ; then
    do_git_checkout "$remote" $checkout_dir "origin/stable"
  fi
  cd $checkout_dir

  local cmake_params="-DENABLE_SHARED=0" # build x265.exe

  if [ "$bits_target" = "32" ]; then
    cmake_params+=" -DWINXP_SUPPORT=1" # enable windows xp/vista compatibility in x86 build
  fi
  mkdir -p 8bit 10bit 12bit

  # Build 12bit (main12)
  cd 12bit
  local cmake_12bit_params="$cmake_params -DENABLE_CLI=0 -DHIGH_BIT_DEPTH=1 -DMAIN12=1 -DEXPORT_C_API=0"
  if [ "$bits_target" = "32" ]; then
    cmake_12bit_params="$cmake_12bit_params -DENABLE_ASSEMBLY=OFF" # apparently required or build fails
  fi
  do_cmake_from_build_dir ../source "$cmake_12bit_params"
  do_make
  cp libx265.a ../8bit/libx265_main12.a

  # Build 10bit (main10)
  cd ../10bit
  local cmake_10bit_params="$cmake_params -DENABLE_CLI=0 -DHIGH_BIT_DEPTH=1 -DENABLE_HDR10_PLUS=1 -DEXPORT_C_API=0"
  if [ "$bits_target" = "32" ]; then
    cmake_10bit_params="$cmake_10bit_params -DENABLE_ASSEMBLY=OFF" # apparently required or build fails
  fi
  do_cmake_from_build_dir ../source "$cmake_10bit_params"
  do_make
  cp libx265.a ../8bit/libx265_main10.a

  # Build 8 bit (main) with linked 10 and 12 bit then install
  cd ../8bit
  cmake_params="$cmake_params -DENABLE_CLI=1 -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=1 -DLINKED_12BIT=1"
  if [[ $compiler_flavors == "native" && $OSTYPE != darwin* ]]; then
    cmake_params+=" -DENABLE_SHARED=0 -DEXTRA_LIB='$(pwd)/libx265_main10.a;$(pwd)/libx265_main12.a;-ldl'" # Native multi-lib CLI builds are slightly broken right now; other option is to -DENABLE_CLI=0, but this seems to work (https://bitbucket.org/multicoreware/x265/issues/520)
  else
    cmake_params+=" -DEXTRA_LIB='$(pwd)/libx265_main10.a;$(pwd)/libx265_main12.a'"
  fi
  do_cmake_from_build_dir ../source "$cmake_params"
  do_make
  mv libx265.a libx265_main.a
  if [[ $compiler_flavors == "native" && $OSTYPE == darwin* ]]; then
    libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a 2>/dev/null
  else
    ${cross_prefix}ar -M <<EOF
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
EOF
  fi
  do_make_install
  cd ../..
}

build_libopenh264() {
  do_git_checkout "https://github.com/cisco/openh264.git"
  cd openh264_git
    sed -i.bak "s/_M_X64/_M_DISABLED_X64/" codec/encoder/core/inc/param_svc.h # for 64 bit, avoid missing _set_FMA3_enable, it needed to link against msvcrt120 to get this or something weird?
    if [ $bits_target = 32 ]; then
      local arch=i686 # or x86?
    else
      local arch=x86_64
    fi
    do_make "$make_prefix_options OS=mingw_nt ARCH=$arch ASM=yasm install-static" # No need for 'do_make_install', because 'install-static' already has install-instructions.
  cd ..
}

build_libx264() {
  local checkout_dir="x264"
  if [[ $build_x264_with_libav == "y" ]]; then
    build_ffmpeg static --disable-libx264 ffmpeg_git_pre_x264 # installs libav locally so we can use it within x264.exe FWIW...
    checkout_dir="${checkout_dir}_with_libav"
    # they don't know how to use a normal pkg-config when cross compiling, so specify some manually: (see their mailing list for a request...)
    export LAVF_LIBS="$LAVF_LIBS $(pkg-config --libs libavformat libavcodec libavutil libswscale)"
    export LAVF_CFLAGS="$LAVF_CFLAGS $(pkg-config --cflags libavformat libavcodec libavutil libswscale)"
    export SWSCALE_LIBS="$SWSCALE_LIBS $(pkg-config --libs libswscale)"
  fi

  local x264_profile_guided=n # or y -- haven't gotten this proven yet...TODO
  checkout_dir="${checkout_dir}_all_bitdepth"

  do_git_checkout "https://code.videolan.org/videolan/x264.git" $checkout_dir  "origin/stable" 
  cd $checkout_dir
    if [[ ! -f configure.bak ]]; then # Change CFLAGS.
      sed -i.bak "s/O3 -/O2 -/" configure
    fi

    local configure_flags="--host=$host_target --enable-static --cross-prefix=$cross_prefix --prefix=$mingw_w64_x86_64_prefix --enable-strip" # --enable-win32thread --enable-debug is another useful option here?
    if [[ $build_x264_with_libav == "n" ]]; then
      configure_flags+=" --disable-lavf" # lavf stands for libavformat, there is no --enable-lavf option, either auto or disable...
    fi
    configure_flags+=" --bit-depth=all"
    for i in $CFLAGS; do
      configure_flags+=" --extra-cflags=$i" # needs it this way seemingly :|
    done

    if [[ $x264_profile_guided = y ]]; then
      # I wasn't able to figure out how/if this gave any speedup...
      # TODO more march=native here?
      # TODO profile guided here option, with wine?
      do_configure "$configure_flags"
      curl -4 http://samples.mplayerhq.hu/yuv4mpeg2/example.y4m.bz2 -O --fail || exit 1
      rm -f example.y4m # in case it exists already...
      bunzip2 example.y4m.bz2 || exit 1
      # XXX does this kill git updates? maybe a more general fix, since vid.stab does also?
      sed -i.bak "s_\\, ./x264_, wine ./x264_" Makefile # in case they have wine auto-run disabled http://askubuntu.com/questions/344088/how-to-ensure-wine-does-not-auto-run-exe-files
      do_make_and_make_install "fprofiled VIDS=example.y4m" # guess it has its own make fprofiled, so we don't need to manually add -fprofile-generate here...
    else
      # normal path non profile guided
      do_configure "$configure_flags"
      do_make
      make install # force reinstall in case changed stable -> unstable
    fi

    unset LAVF_LIBS
    unset LAVF_CFLAGS
    unset SWSCALE_LIBS
  cd ..
}

build_lsmash() { # an MP4 library
  do_git_checkout https://github.com/l-smash/l-smash.git l-smash
  cd l-smash
    do_configure "--prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix"
    do_make_and_make_install
  cd ..
}

build_libdvdread() {
  build_libdvdcss
  download_and_unpack_file http://dvdnav.mplayerhq.hu/releases/libdvdread-4.9.9.tar.xz # last revision before 5.X series so still works with MPlayer
  cd libdvdread-4.9.9
    # XXXX better CFLAGS here...
    generic_configure "CFLAGS=-DHAVE_DVDCSS_DVDCSS_H LDFLAGS=-ldvdcss --enable-dlfcn" # vlc patch: "--enable-libdvdcss" # XXX ask how I'm *supposed* to do this to the dvdread peeps [svn?]
    #apply_patch file://$patch_dir/dvdread-win32.patch # has been reported to them...
    do_make_and_make_install
    sed -i.bak 's/-ldvdread.*/-ldvdread -ldvdcss/' "$PKG_CONFIG_PATH/dvdread.pc"
  cd ..
}

build_libdvdnav() {
  download_and_unpack_file http://dvdnav.mplayerhq.hu/releases/libdvdnav-4.2.1.tar.xz # 4.2.1. latest revision before 5.x series [?]
  cd libdvdnav-4.2.1
    if [[ ! -f ./configure ]]; then
      ./autogen.sh
    fi
    generic_configure_make_install
    sed -i.bak 's/-ldvdnav.*/-ldvdnav -ldvdread -ldvdcss -lpsapi/' "$PKG_CONFIG_PATH/dvdnav.pc" # psapi for dlfcn ... [hrm?]
  cd ..
}

build_libdvdcss() {
  generic_download_and_make_and_install https://download.videolan.org/pub/videolan/libdvdcss/1.2.13/libdvdcss-1.2.13.tar.bz2
}

build_libjpeg_turbo() {
  download_and_unpack_file https://sourceforge.net/projects/libjpeg-turbo/files/1.5.0/libjpeg-turbo-1.5.0.tar.gz
  cd libjpeg-turbo-1.5.0
    #do_cmake_and_install "-DNASM=yasm" # couldn't figure out a static only build with cmake...maybe you can these days dunno
    generic_configure "NASM=yasm"
    do_make_and_make_install
    sed -i.bak 's/typedef long INT32/typedef long XXINT32/' "$mingw_w64_x86_64_prefix/include/jmorecfg.h" # breaks VLC build without this...freaky...theoretically using cmake instead would be enough, but that installs .dll.a file... XXXX maybe no longer needed :|
  cd ..
}

build_libproxy() {
  # NB this lacks a .pc file still
  download_and_unpack_file https://libproxy.googlecode.com/files/libproxy-0.4.11.tar.gz
  cd libproxy-0.4.11
    sed -i.bak "s/= recv/= (void *) recv/" libmodman/test/main.cpp # some compile failure
    do_cmake_and_install
  cd ..
}

build_lua() {
  download_and_unpack_file https://www.lua.org/ftp/lua-5.3.3.tar.gz
  cd lua-5.3.3
    export AR="${cross_prefix}ar rcu" # needs rcu parameter so have to call it out different :|
    do_make "CC=${cross_prefix}gcc RANLIB=${cross_prefix}ranlib generic" # generic == "generic target" and seems to result in a static build, no .exe's blah blah the mingw option doesn't even build liblua.a
    unset AR
    do_make_install "INSTALL_TOP=$mingw_w64_x86_64_prefix" "generic install"
    cp etc/lua.pc $PKG_CONFIG_PATH
  cd ..
}

build_libcurl() {
  generic_download_and_make_and_install https://curl.haxx.se/download/curl-7.77.0.tar.gz
}

build_libhdhomerun() {
  exit 1 # still broken unfortunately, for cross compile :|
  download_and_unpack_file https://download.silicondust.com/hdhomerun/libhdhomerun_20150826.tgz libhdhomerun
  cd libhdhomerun
    do_make CROSS_COMPILE=$cross_prefix  OS=Windows_NT
  cd ..
}

build_dvbtee_app() {
  build_iconv # said it needed it
  build_libcurl # it "can use this" so why not
#  build_libhdhomerun # broken but possible dependency apparently :|
  do_git_checkout https://github.com/mkrufky/libdvbtee.git libdvbtee_git
  cd libdvbtee_git
    # checkout its submodule, apparently required
    if [ ! -e libdvbpsi/bootstrap ]; then
      rm -rf libdvbpsi # remove placeholder
      do_git_checkout https://github.com/mkrufky/libdvbpsi.git
      cd libdvbpsi_git
        generic_configure_make_install # library dependency submodule... TODO don't install it, just leave it local :)
      cd ..
    fi
    generic_configure
    do_make # not install since don't have a dependency on the library
  cd ..
}

build_qt() {
  build_libjpeg_turbo # libjpeg a dependency [?]
  unset CFLAGS # it makes something of its own first, which runs locally, so can't use a foreign arch, or maybe it can, but not important enough: http://stackoverflow.com/a/18775859/32453 XXXX could look at this
  #download_and_unpack_file http://pkgs.fedoraproject.org/repo/pkgs/qt/qt-everywhere-opensource-src-4.8.7.tar.gz/d990ee66bf7ab0c785589776f35ba6ad/qt-everywhere-opensource-src-4.8.7.tar.gz # untested
  #cd qt-everywhere-opensource-src-4.8.7
  # download_and_unpack_file http://download.qt-project.org/official_releases/qt/5.1/5.1.1/submodules/qtbase-opensource-src-5.1.1.tar.xz qtbase-opensource-src-5.1.1 # not officially supported seems...so didn't try it
  download_and_unpack_file http://pkgs.fedoraproject.org/repo/pkgs/qt/qt-everywhere-opensource-src-4.8.5.tar.gz/1864987bdbb2f58f8ae8b350dfdbe133/qt-everywhere-opensource-src-4.8.5.tar.gz
  cd qt-everywhere-opensource-src-4.8.5
    apply_patch file://$patch_dir/imageformats.patch
    apply_patch file://$patch_dir/qt-win64.patch
    # vlc's configure options...mostly
    do_configure "-static -release -fast -no-exceptions -no-stl -no-sql-sqlite -no-qt3support -no-gif -no-libmng -qt-libjpeg -no-libtiff -no-qdbus -no-openssl -no-webkit -sse -no-script -no-multimedia -no-phonon -opensource -no-scripttools -no-opengl -no-script -no-scripttools -no-declarative -no-declarative-debug -opensource -no-s60 -host-little-endian -confirm-license -xplatform win32-g++ -device-option CROSS_COMPILE=$cross_prefix -prefix $mingw_w64_x86_64_prefix -prefix-install -nomake examples"
    if [ ! -f 'already_qt_maked_k' ]; then
      make sub-src -j $cpu_count
      make install sub-src # let it fail, baby, it still installs a lot of good stuff before dying on mng...? huh wuh?
      cp ./plugins/imageformats/libqjpeg.a $mingw_w64_x86_64_prefix/lib || exit 1 # I think vlc's install is just broken to need this [?]
      cp ./plugins/accessible/libqtaccessiblewidgets.a  $mingw_w64_x86_64_prefix/lib || exit 1 # this feels wrong...
      # do_make_and_make_install "sub-src" # sub-src might make the build faster? # complains on mng? huh?
      touch 'already_qt_maked_k'
    fi
    # vlc needs an adjust .pc file? huh wuh?
    sed -i.bak 's/Libs: -L${libdir} -lQtGui/Libs: -L${libdir} -lcomctl32 -lqjpeg -lqtaccessiblewidgets -lQtGui/' "$PKG_CONFIG_PATH/QtGui.pc" # sniff
  cd ..
  reset_cflags
}

build_vlc() {
  # currently broken, since it got too old for libavcodec and I didn't want to build its own custom one yet to match, and now it's broken with gcc 5.2.0 seemingly
  # call out dependencies here since it's a lot, plus hierarchical FTW!
  # should be ffmpeg 1.1.1 or some odd?
  echo "not building vlc, broken dependencies or something weird"
  return
  # vlc's own dependencies:
  build_lua
  build_libdvdread
  build_libdvdnav
#  build_libx265
  build_libjpeg_turbo
  build_ffmpeg
  build_qt

  # currently vlc itself currently broken :|
  do_git_checkout https://github.com/videolan/vlc.git
  cd vlc_git
  #apply_patch file://$patch_dir/vlc_localtime_s.patch # git revision needs it...
  # outdated and patch doesn't apply cleanly anymore apparently...
  #if [[ "$non_free" = "y" ]]; then
  #  apply_patch https://raw.githubusercontent.com/gcsx/ffmpeg-windows-build-helpers/patch-5/patches/priorize_avcodec.patch
  #fi
  if [[ ! -f "configure" ]]; then
    ./bootstrap
  fi
  export DVDREAD_LIBS='-ldvdread -ldvdcss -lpsapi'
  do_configure "--disable-libgcrypt --disable-a52 --host=$host_target --disable-lua --disable-mad --enable-qt --disable-sdl --disable-mod" # don't have lua mingw yet, etc. [vlc has --disable-sdl [?]] x265 disabled until we care enough... Looks like the bluray problem was related to the BLURAY_LIBS definition. [not sure what's wrong with libmod]
  rm -f `find . -name *.exe` # try to force a rebuild...though there are tons of .a files we aren't rebuilding as well FWIW...:|
  rm -f already_ran_make* # try to force re-link just in case...
  do_make
  # do some gymnastics to avoid building the mozilla plugin for now [couldn't quite get it to work]
  #sed -i.bak 's_git://git.videolan.org/npapi-vlc.git_https://github.com/rdp/npapi-vlc.git_' Makefile # this wasn't enough...
  sed -i.bak "s/package-win-common: package-win-install build-npapi/package-win-common: package-win-install/" Makefile
  sed -i.bak "s/.*cp .*builddir.*npapi-vlc.*//g" Makefile
  make package-win-common # not do_make, fails still at end, plus this way we get new vlc.exe's
  echo "


     vlc success, created a file like ${PWD}/vlc-xxx-git/vlc.exe



"
  cd ..
  unset DVDREAD_LIBS
}

reset_cflags() {
  export CFLAGS=$original_cflags
}

build_mplayer() {
  # pre requisites
  build_libjpeg_turbo
  build_libdvdread
  build_libdvdnav

  download_and_unpack_file https://sourceforge.net/projects/mplayer-edl/files/mplayer-export-snapshot.2014-05-19.tar.bz2 mplayer-export-2014-05-19
  cd mplayer-export-2014-05-19
    do_git_checkout https://github.com/FFmpeg/FFmpeg ffmpeg d43c303038e9bd # known compatible commit
    export LDFLAGS='-lpthread -ldvdnav -ldvdread -ldvdcss' # not compat with newer dvdread possibly? huh wuh?
    export CFLAGS=-DHAVE_DVDCSS_DVDCSS_H
    do_configure "--enable-cross-compile --host-cc=cc --cc=${cross_prefix}gcc --windres=${cross_prefix}windres --ranlib=${cross_prefix}ranlib --ar=${cross_prefix}ar --as=${cross_prefix}as --nm=${cross_prefix}nm --enable-runtime-cpudetection --extra-cflags=$CFLAGS --with-dvdnav-config=$mingw_w64_x86_64_prefix/bin/dvdnav-config --disable-dvdread-internal --disable-libdvdcss-internal --disable-w32threads --enable-pthreads --extra-libs=-lpthread --enable-debug --enable-ass-internal --enable-dvdread --enable-dvdnav --disable-libvpx-lavc" # haven't reported the ldvdcss thing, think it's to do with possibly it not using dvdread.pc [?] XXX check with trunk
    # disable libvpx didn't work with its v1.5.0 some reason :|
    unset LDFLAGS
    reset_cflags
    sed -i.bak "s/HAVE_PTHREAD_CANCEL 0/HAVE_PTHREAD_CANCEL 1/g" config.h # mplayer doesn't set this up right?
    touch -t 201203101513 config.h # the above line change the modify time for config.h--forcing a full rebuild *every time* yikes!
    # try to force re-link just in case...
    rm -f *.exe
    rm -f already_ran_make* # try to force re-link just in case...
    do_make
    cp mplayer.exe mplayer_debug.exe
    ${cross_prefix}strip mplayer.exe
    echo "built ${PWD}/{mplayer,mencoder,mplayer_debug}.exe"
  cd ..
}

build_mp4box() { # like build_gpac
  # This script only builds the gpac_static lib plus MP4Box. Other tools inside
  # specify revision until this works: https://sourceforge.net/p/gpac/discussion/287546/thread/72cf332a/
  do_git_checkout https://github.com/gpac/gpac.git mp4box_gpac_git
  cd mp4box_gpac_git
    # are these tweaks needed? If so then complain to the mp4box people about it?
    sed -i.bak "s/has_dvb4linux=\"yes\"/has_dvb4linux=\"no\"/g" configure
    sed -i.bak "s/`uname -s`/MINGW32/g" configure
    # XXX do I want to disable more things here?
    # ./sandbox/cross_compilers/mingw-w64-i686/bin/i686-w64-mingw32-sdl-config
    generic_configure "--static-mp4box --enable-static-bin --disable-oss-audio --extra-ldflags=-municode --disable-x11 --sdl-cfg=${cross_prefix}sdl-config"
    # I seem unable to pass 3 libs into the same config line so do it with sed...
    sed -i.bak "s/EXTRALIBS=.*/EXTRALIBS=-lws2_32 -lwinmm -lz/g" config.mak
    cd src
      do_make "$make_prefix_options"
    cd ..
    rm -f ./bin/gcc/MP4Box* # try and force a relink/rebuild of the .exe
    cd applications/mp4box
      rm -f already_ran_make* # ??
      do_make "$make_prefix_options"
    cd ../..
    # copy it every time just in case it was rebuilt...
    cp ./bin/gcc/MP4Box ./bin/gcc/MP4Box.exe # it doesn't name it .exe? That feels broken somehow...
    echo "built $(readlink -f ./bin/gcc/MP4Box.exe)"
  cd ..
}

build_libMXF() {
  download_and_unpack_file https://sourceforge.net/projects/ingex/files/1.0.0/libMXF/libMXF-src-1.0.0.tgz "libMXF-src-1.0.0"
  cd libMXF-src-1.0.0
    apply_patch file://$patch_dir/libMXF.diff
    do_make "MINGW_CC_PREFIX=$cross_prefix"
    #
    # Manual equivalent of make install. Enable it if desired. We shouldn't need it in theory since we never use libMXF.a file and can just hand pluck out the *.exe files already...
    #
    #cp libMXF/lib/libMXF.a $mingw_w64_x86_64_prefix/lib/libMXF.a
    #cp libMXF++/libMXF++/libMXF++.a $mingw_w64_x86_64_prefix/lib/libMXF++.a
    #mv libMXF/examples/writeaviddv50/writeaviddv50 libMXF/examples/writeaviddv50/writeaviddv50.exe
    #mv libMXF/examples/writeavidmxf/writeavidmxf libMXF/examples/writeavidmxf/writeavidmxf.exe
    #cp libMXF/examples/writeaviddv50/writeaviddv50.exe $mingw_w64_x86_64_prefix/bin/writeaviddv50.exe
    #cp libMXF/examples/writeavidmxf/writeavidmxf.exe $mingw_w64_x86_64_prefix/bin/writeavidmxf.exe
  cd ..
}

build_pthreads() {
  # Zeranoe 4.0.0 does not build libpthread
  if [[ ! -f "$mingw_w64_x86_64_prefix/include/pthread.h" ]] || [[ ! -f "$mingw_w64_x86_64_prefix/lib/libpthread.a" ]]; then
    download_and_unpack_file ftp://sourceware.org/pub/pthreads-win32/pthreads-w32-2-9-1-release.tar.gz pthreads-w32-2-9-1-release
    cd pthreads-w32-2-9-1-release
      # use the cross compiler binaries as gcc, windres, ar and ranlib
      ln -s "${cross_prefix}gcc"     "$mingw_bin_path/gcc"
      ln -s "${cross_prefix}windres" "$mingw_bin_path/windres"
      ln -s "${cross_prefix}ar"      "$mingw_bin_path/ar"
      ln -s "${cross_prefix}ranlib"  "$mingw_bin_path/ranlib"
      which gcc
      gcc --version
      make -f GNUmakefile clean GC-static
      rm    "$mingw_bin_path/gcc"
      rm    "$mingw_bin_path/windres"
      rm    "$mingw_bin_path/ar"
      rm    "$mingw_bin_path/ranlib"
      cp 'libpthreadGC2.a' "$mingw_w64_x86_64_prefix/lib" || exit 1
      ln -s "$mingw_w64_x86_64_prefix/lib/libpthreadGC2.a" "$mingw_w64_x86_64_prefix/lib/libpthread.a"
      cp 'pthread.h' 'sched.h' 'semaphore.h' "$mingw_w64_x86_64_prefix/include/" || exit 1
      for file in 'pthread.h' 'sched.h' 'semaphore.h'; do
        sed -i.bak 's/ __declspec (dllexport)//g' "$mingw_w64_x86_64_prefix/include/$file" #strip DLL import/export directives
        sed -i.bak 's/ __declspec (dllimport)//g' "$mingw_w64_x86_64_prefix/include/$file"
      done
    cd ..
  fi
}

apply_ffmpeg_patch() {
 local url=$1
 local patch_name=$(basename $url)
 local patch_done_name="$patch_name.my_patch"
 if [[ ! -e $patch_done_name ]]; then
   wget $url || exit 1
   echo "applying patch $patch_name"
   patch -p1 < "$patch_name" && touch $patch_done_name && git diff > "/mnt/winshare/mympeg/ffmpeg_patches/$patch_name" \
     || git stash
   git commit -a -m applied
 else
   echo "patch $patch_name already applied"
 fi
}

build_ffmpeg() {
  local extra_postpend_configure_options=$2
  if [[ -z $3 ]]; then
    local output_dir="ffmpeg_git"
  else
    local output_dir=$3
  fi
  if [[ "$non_free" = "y" ]]; then
    output_dir+="_with_fdk_aac"
  fi
  if [[ $high_bitdepth == "y" ]]; then
    output_dir+="_x26x_high_bitdepth"
  fi
  if [[ $build_intel_qsv == "n" ]]; then
    output_dir+="_xp_compat"
  fi
  if [[ $enable_gpl == 'n' ]]; then
    output_dir+="_lgpl"
  fi
  if [[ ! -z $ffmpeg_git_checkout_version ]]; then
    output_dir+="_$ffmpeg_git_checkout_version"
  fi

  local postpend_configure_opts=""
  # can't mix and match --enable-static --enable-shared unfortunately, or the final executable seems to just use shared if the're both present
  if [[ $1 == "shared" ]]; then
    output_dir+="_shared"
    postpend_configure_opts="--enable-shared --disable-static --prefix=$(pwd)/${output_dir}"
  else
    postpend_configure_opts="--enable-static --disable-shared --prefix=$mingw_w64_x86_64_prefix"
  fi

  do_git_checkout https://github.com/FFmpeg/FFmpeg.git $output_dir $ffmpeg_git_checkout_version
  cd $output_dir
    apply_ffmpeg_patch https://raw.githubusercontent.com/Jan-E/mympeg/master/ffmpeg_patches/ass_fontsize.patch
    apply_ffmpeg_patch https://raw.githubusercontent.com/Jan-E/mympeg/master/ffmpeg_patches/subtitles_non_fatal.patch
    apply_ffmpeg_patch https://raw.githubusercontent.com/Jan-E/mympeg/master/ffmpeg_patches/asfenc.patch
    apply_ffmpeg_patch https://raw.githubusercontent.com/Jan-E/mympeg/master/ffmpeg_patches/movenc.patch
    apply_ffmpeg_patch https://raw.githubusercontent.com/Jan-E/mympeg/master/ffmpeg_patches/mpegvideo_enc.patch
    apply_ffmpeg_patch https://raw.githubusercontent.com/Jan-E/mympeg/master/ffmpeg_patches/swscale.patch
    apply_ffmpeg_patch https://raw.githubusercontent.com/Jan-E/mympeg/master/ffmpeg_patches/volnorm_new.patch

    apply_ffmpeg_patch https://raw.githubusercontent.com/Jan-E/mympeg/master/ffmpeg_patches/enable_libfaac.patch
    apply_patch file://$patch_dir/add-libfaac.diff

    apply_patch file://$patch_dir/frei0r_load-shared-libraries-dynamically.diff

    if [ "$bits_target" = "32" ]; then
      local arch=x86
    else
      local arch=x86_64
    fi

    init_options="--pkg-config=pkg-config --pkg-config-flags=--static --extra-version=ffmpeg-windows-build-helpers --enable-version3 --disable-debug --disable-w32threads"
    if [[ $compiler_flavors != "native" ]]; then
      init_options+=" --arch=$arch --target-os=mingw32 --cross-prefix=$cross_prefix"
    fi
    if [[ `uname` =~ "5.1" ]]; then
      init_options+=" --disable-schannel"
      # Fix WinXP incompatibility by disabling Microsoft's Secure Channel, because Windows XP doesn't support TLS 1.1 and 1.2, but with GnuTLS or OpenSSL it does.  XP compat!
    fi
    config_options="$init_options --enable-libcaca --enable-gray --enable-libtesseract --enable-fontconfig --enable-gmp --enable-gnutls --enable-libass --enable-libbluray --enable-libbs2b --enable-libflite --enable-libfreetype --enable-libfribidi --enable-libgme --enable-libgsm --enable-libilbc --enable-libmodplug --enable-libmp3lame --enable-libopencore-amrnb --enable-libopencore-amrwb --enable-libopus --enable-libsnappy --enable-libsoxr --enable-libspeex --enable-libtheora --enable-libtwolame --enable-libvo-amrwbenc --enable-libvorbis --enable-libvpx --enable-libwebp --enable-libzimg --enable-libzvbi --enable-libmysofa --enable-libaom --anable-dav1d --enable-libopenjpeg  --enable-libopenh264"
    if [[ $compiler_flavors != "native" ]]; then
      config_options+=" --enable-nvenc --enable-nvdec" # don't work OS X 
    fi

    config_options+=" --extra-cflags=-DLIBTWOLAME_STATIC --extra-cflags=-DMODPLUG_STATIC --extra-cflags=-DCACA_STATIC" # if we ever do a git pull then it nukes changes, which overrides manual changes to configure, so just use these for now :|
    if [[ $build_amd_amf = n ]]; then
      config_options+=" --disable-amf" # Since its autodetected we have to disable it if we do not want it. #unless we define no autodetection but.. we don't.
    else
      config_options+=" --enable-amf" # This is actually autodetected but for consistency.. we might as well set it.
    fi

    if [[ $build_intel_qsv = y ]]; then
      config_options+=" --enable-libmfx"
    fi
    if [[ $enable_gpl == 'y' ]]; then
      config_options+=" --enable-gpl --enable-avisynth --enable-frei0r --enable-filter=frei0r --enable-librubberband --enable-libvidstab --enable-libx264 --enable-libx265 --enable-libxvid"
      if [[ $compiler_flavors != "native" ]]; then
        config_options+=" --enable-libxavs" # don't compile OS X 
      fi
    fi
    local licensed_gpl=n # lgpl build with libx264 included for those with "commercial" license :)
    if [[ $licensed_gpl == 'y' ]]; then
      apply_patch file://$patch_dir/x264_non_gpl.diff -p1
      config_options+=" --enable-libx264"
    fi 
    # other possibilities:
    #   --enable-w32threads # [worse UDP than pthreads, so not using that]
    config_options+=" --enable-avresample" # guess this is some kind of libav specific thing (the FFmpeg fork) but L-Smash needs it so why not always build it :)

    for i in $CFLAGS; do
      config_options+=" --extra-cflags=$i" # --extra-cflags may not be needed here, but adds it to the final console output which I like for debugging purposes
    done

    config_options+=" $postpend_configure_opts"

    if [[ "$non_free" = "y" ]]; then
      config_options+=" --enable-nonfree --enable-decklink --enable-libfdk-aac --enable-libfaac"
      # other possible options: --enable-openssl [unneeded since we use gnutls]
    fi

    do_debug_build=n # if you need one for backtraces/examining segfaults using gdb.exe ... change this to y :) XXXX make it affect x264 too...and make it real param :)
    if [[ "$do_debug_build" = "y" ]]; then
      # not sure how many of these are actually needed/useful...possibly none LOL
      config_options+=" --disable-optimizations --extra-cflags=-Og --extra-cflags=-fno-omit-frame-pointer --enable-debug=3 --extra-cflags=-fno-inline $postpend_configure_opts"
      # this one kills gdb workability for static build? ai ai [?] XXXX
      config_options+=" --disable-libgme"
    fi
    config_options+=" $extra_postpend_configure_options"

    do_configure "$config_options"
    rm -f */*.a */*.dll *.exe # just in case some dependency library has changed, force it to re-link even if the ffmpeg source hasn't changed...
    rm -f already_ran_make*
    echo "doing ffmpeg make $(pwd)"

    do_make_and_make_install # install ffmpeg as well (for shared, to separate out the .dll's, for things that depend on it like VLC, to create static libs)

    # build ismindex.exe, too, just for fun
    if [[ $build_ismindex == "y" ]]; then
      make tools/ismindex.exe || exit 1
    fi

    # XXX really ffmpeg should have set this up right but doesn't, patch FFmpeg itself instead...
    if [[ $1 == "static" ]]; then
      if [[ $build_intel_qsv = y ]]; then
        sed -i.bak 's/-lavutil -lm.*/-lavutil -lm -lmfx -lstdc++ -lpthread/' "$PKG_CONFIG_PATH/libavutil.pc"
      else
        sed -i.bak 's/-lavutil -lm.*/-lavutil -lm -lpthread/' "$PKG_CONFIG_PATH/libavutil.pc"
      fi
      sed -i.bak 's/-lswresample -lm.*/-lswresample -lm -lsoxr/' "$PKG_CONFIG_PATH/libswresample.pc" # XXX patch ffmpeg
    fi

    sed -i.bak 's/-lswresample -lm.*/-lswresample -lm -lsoxr/' "$PKG_CONFIG_PATH/libswresample.pc" # XXX patch ffmpeg

    if [[ $non_free == "y" ]]; then
      if [[ $1 == "shared" ]]; then
        echo "Done! You will find $bits_target-bit $1 non-redistributable binaries in $(pwd)/bin"
      else
        echo "Done! You will find $bits_target-bit $1 non-redistributable binaries in $(pwd)"
      fi
    else
      mkdir -p $cur_dir/redist
      archive="$cur_dir/redist/ffmpeg-$(git describe --tags --match N)-win$bits_target-$1"
      if [[ $original_cflags =~ "pentium3" ]]; then
        archive+="_legacy"
      fi
      if [[ $1 == "shared" ]]; then
        echo "Done! You will find $bits_target-bit $1 binaries in $(pwd)/bin."
        if [[ ! -f $archive.7z ]]; then
          sed "s/$/\r/" COPYING.GPLv3 > bin/COPYING.GPLv3.txt
          cd bin
            7z a -mx=9 $archive.7z *.exe *.dll COPYING.GPLv3.txt && rm -f COPYING.GPLv3.txt
          cd ..
        fi
      else
        echo "Done! You will find $bits_target-bit $1 binaries in $(pwd)."
        if [[ ! -f $archive.7z ]]; then
          sed "s/$/\r/" COPYING.GPLv3 > COPYING.GPLv3.txt
          7z a -mx=9 $archive.7z ffmpeg.exe ffplay.exe ffprobe.exe COPYING.GPLv3.txt && rm -f COPYING.GPLv3.txt
        fi
      fi
      echo "You will find redistributable archives in $cur_dir/redist."
    fi
    echo `date`
  cd ..
}

build_lsw() {
   # Build L-Smash-Works, which are plugins based on lsmash
   #build_ffmpeg static # dependency, assume already built
   build_lsmash # dependency
   do_git_checkout https://github.com/VFR-maniac/L-SMASH-Works.git lsw
   cd lsw/VapourSynth
     do_configure "--prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix --target-os=mingw"
     do_make_and_make_install
     # AviUtl is 32bit-only
     if [ "$bits_target" = "32" ]; then
       cd ../AviUtl
       do_configure "--prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix"
       do_make
     fi
   cd ../..
}

find_all_build_exes() {
  local found=""
# NB that we're currently in the sandbox dir...
  for file in `find . -name ffmpeg.exe` `find . -name ffmpeg_g.exe` `find . -name ffplay.exe` `find . -name MP4Box.exe` `find . -name mplayer.exe` `find . -name mencoder.exe` `find . -name avconv.exe` `find . -name avprobe.exe` `find . -name x264.exe` `find . -name writeavidmxf.exe` `find . -name writeaviddv50.exe` `find . -name rtmpdump.exe` `find . -name x265.exe` `find . -name ismindex.exe` `find . -name dvbtee.exe` `find . -name boxdumper.exe` `find . -name muxer.exe ` `find . -name remuxer.exe` `find . -name timelineeditor.exe` `find . -name lwcolor.auc` `find . -name lwdumper.auf` `find . -name lwinput.aui` `find . -name lwmuxer.auf` `find . -name vslsmashsource.dll`; do
    found="$found $(readlink -f $file)"
  done

  # bash recursive glob fails here again?
  for file in `find . -name vlc.exe | grep -- -`; do
    found="$found $(readlink -f $file)"
  done
  echo $found # pseudo return value...
}

build_ffmpeg_dependencies() {
  echo "Building ffmpeg dependency libraries..." 
  build_pthreads
  build_dlfcn
  build_bzip2 # Bzlib (bzip2) in FFmpeg is autodetected.
  build_liblzma # Lzma in FFmpeg is autodetected. Uses dlfcn.
  build_meson_cross
  build_zlib # Zlib in FFmpeg is autodetected.
  build_iconv # Iconv in FFmpeg is autodetected. Uses dlfcn.
  build_sdl2 # Sdl2 in FFmpeg is autodetected. Needed to build FFPlay. Uses iconv and dlfcn.
  if [[ $build_amd_amf = y ]]; then
    build_amd_amf_headers
  fi
  if [[ $build_intel_qsv = y ]]; then
    build_intel_quicksync_mfx
  fi
  build_nv_headers
  build_libzimg # Uses dlfcn.
  build_libopenjpeg
  #build_libjpeg_turbo # mplayer can use this, VLC qt might need it? [replaces libjpeg]
  build_libpng # Needs zlib >= 1.0.4. Uses dlfcn.
  build_libwebp # Uses dlfcn.
  build_harfbuzz
  build_freetype # Uses zlib, bzip2, and libpng.
  build_libxml2 # Uses zlib, liblzma, iconv and dlfcn.
  build_fontconfig # Needs freetype and libxml >= 2.6. Uses iconv and dlfcn.
  build_gmp # For rtmp support configure FFmpeg with '--enable-gmp'. Uses dlfcn.
  build_libnettle # Needs gmp >= 3.0. Uses dlfcn.
  build_unistring 
  build_gnutls # Needs nettle >= 3.1, hogweed (nettle) >= 3.4, unistring Uses zlib and dlfcn.
  #if [[ "$non_free" = "y" ]]; then
  #  build_openssl-1.0.2 # Nonfree alternative to GnuTLS. 'build_openssl-1.0.2 "dllonly"' to build shared libraries only.
  #  build_openssl-1.1.0 # Nonfree alternative to GnuTLS. Can't be used with LibRTMP. 'build_openssl-1.1.0 "dllonly"' to build shared libraries only.
    build_openssl-1.1.1 # Nonfree alternative to GnuTLS. Can't be used with LibRTMP. 'build_openssl-1.1.1 "dllonly"' to build shared libraries only.
  #fi
  build_libogg # Uses dlfcn.
  build_libvorbis # Needs libogg >= 1.0. Uses dlfcn.
  build_libopus # Uses dlfcn.
  build_libspeexdsp # Needs libogg for examples. Uses dlfcn.
  build_libspeex # Uses libspeexdsp and dlfcn.
  build_libtheora # Needs libogg >= 1.1. Needs libvorbis >= 1.0.1, sdl and libpng for test, programs and examples [disabled]. Uses dlfcn.
  build_libsndfile "install-libgsm" # Needs libogg >= 1.1.3 and libvorbis >= 1.2.3 for external support [disabled]. Uses dlfcn. 'build_libsndfile "install-libgsm"' to install the included LibGSM 6.10.
  build_lame # Uses dlfcn.
  build_twolame # Uses libsndfile >= 1.0.0 and dlfcn.
  build_libopencore # Uses dlfcn.
  build_libilbc # Uses dlfcn.
  build_libmodplug # Uses dlfcn.
  build_libgme
  build_libbluray # Needs libxml >= 2.6, freetype, fontconfig. Uses dlfcn.
  build_libbs2b # Needs libsndfile. Uses dlfcn.
  build_libsoxr
  build_libflite
  build_libsnappy # Uses zlib (only for unittests [disabled]) and dlfcn.
  build_vamp_plugin # Needs libsndfile for 'vamp-simple-host.exe' [disabled].
  build_fftw # Uses dlfcn.
  build_libsamplerate # Needs libsndfile >= 1.0.6 and fftw >= 0.15.0 for tests. Uses dlfcn.
  build_librubberband # Needs libsamplerate, libsndfile, fftw and vamp_plugin. 'configure' will fail otherwise. Eventhough librubberband doesn't necessarily need them (libsndfile only for 'rubberband.exe' and vamp_plugin only for "Vamp audio analysis plugin"). How to use the bundled libraries '-DUSE_SPEEX' and '-DUSE_KISSFFT'?
#  build_frei0r # Needs dlfcn.
  build_vidstab
  build_libmysofa # Needed for FFmpeg's SOFAlizer filter (https://ffmpeg.org/ffmpeg-filters.html#sofalizer). Uses dlfcn.
  build_libcaca # Uses zlib and dlfcn.
  if [[ "$non_free" = "y" ]]; then
    build_fdk-aac # Uses dlfcn.
    build_libdecklink
  fi
  if [[ -f "$mingw_w64_x86_64_prefix/include/pthread.h" ]] && [[ -f "$mingw_w64_x86_64_prefix/lib/libpthread.a" ]]; then
    build_zvbi # Uses iconv, libpng and dlfcn.
  fi
  build_fribidi # Uses dlfcn.
#   build_libass # Requires harfbuzz now. Needs freetype >= 9.10.3 (see https://bugs.launchpad.net/ubuntu/+source/freetype1/+bug/78573 o_O) and fribidi >= 0.19.0. Uses fontconfig >= 2.10.92, iconv and dlfcn.
  build_libxavs
  build_libxvid # FFmpeg now has native support, but libxvid still provides a better image.
  build_libsrt # requires gnutls, mingw-std-threads
  build_libtesseract
  build_libvpx
  build_libx265
  build_libopenh264
  build_libaom
  build_dav1d
  build_librtmp
#  build_librtmp_gnutls
  build_libssh2
#  build_libssh2_wincng
  build_libssh
  build_libgpg-error
  build_libgcrypt
  build_nghttp2
  build_libx264 # at bottom as it might build a ffmpeg which needs the above deps...
  build_curl
}

build_apps() {
  if [[ $build_dvbtee = "y" ]]; then
    build_dvbtee_app
  fi
  # now the things that use the dependencies...
  if [[ $build_libmxf = "y" ]]; then
    build_libMXF
  fi
  if [[ $build_mp4box = "y" ]]; then
    build_mp4box
  fi
  if [[ $build_mplayer = "y" ]]; then
    build_mplayer
  fi
  if [[ $build_ffmpeg_static = "y" ]]; then
    build_ffmpeg static
  fi
  if [[ $build_ffmpeg_shared = "y" ]]; then
    build_ffmpeg shared
  fi
  if [[ $build_vlc = "y" ]]; then
    build_vlc
  fi
  if [[ $build_lsw = "y" ]]; then
    build_lsw
  fi
}

# set some parameters initial values
top_dir="$(pwd)"
cur_dir="$(pwd)/sandbox"
patch_dir="$(pwd)/patches"
cpu_count="$(grep -c processor /proc/cpuinfo 2>/dev/null)" # linux cpu count
if [ -z "$cpu_count" ]; then
  cpu_count=`sysctl -n hw.ncpu | tr -d '\n'` # OS X
  if [ -z "$cpu_count" ]; then
    echo "warning, unable to determine cpu count, defaulting to 1"
    cpu_count=1 # else default to just 1, instead of blank, which means infinite
  fi
fi
original_cpu_count=$cpu_count # save it away for some that revert it temporarily

set_box_memory_size_bytes
if [[ $box_memory_size_bytes -lt 600000000 ]]; then
  echo "your box only has $box_memory_size_bytes, 512MB (only) boxes crash when building cross compiler gcc, please add some swap" # 1G worked OK however...
  exit 1
fi

if [[ $box_memory_size_bytes -gt 2000000000 ]]; then
  gcc_cpu_count=$cpu_count # they can handle it seemingly...
else
  echo "low RAM detected so using only one cpu for gcc compilation"
  gcc_cpu_count=1 # compatible low RAM...
fi

# variables with their defaults
build_ffmpeg_static=y
build_ffmpeg_shared=n
build_dvbtee=n
build_libmxf=n
build_mp4box=n
build_mplayer=n
build_vlc=n
build_lsw=n # To build x264 with L-Smash-Works.
git_get_latest=y
prefer_stable=y # Only for x264 and x265.
if [[ `uname` =~ "5.1" ]]; then # Uncomment this if people report that AMF does not work on XP (I have no way to test this myself)
  build_amd_amf=n
else
  build_amd_amf=y
fi
if [[ `uname` =~ "5.1" ]]; then # Disable when WinXP is detected, or you'll get "The procedure entry point _wfopen_s could not be located in the dynamic link library msvcrt.dll".
  build_intel_qsv=n
else
  build_intel_qsv=y
fi
disable_nonfree=y # comment out to force user y/n selection
original_cflags='-mtune=generic -O3' # high compatible by default, see #219, some other good options are listed below, or you could use -march=native to target your local box:
# if you specify a march it needs to first so x264's configure will use it :| [ is that still the case ?]

#flags=$(cat /proc/cpuinfo | grep flags)
#if [[ $flags =~ "ssse3" ]]; then # See https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html, https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html and https://stackoverflow.com/questions/19689014/gcc-difference-between-o3-and-os.
#  original_cflags='-march=core2 -O2'
#elif [[ $flags =~ "sse3" ]]; then
#  original_cflags='-march=prescott -O2'
#elif [[ $flags =~ "sse2" ]]; then
#  original_cflags='-march=pentium4 -O2'
#elif [[ $flags =~ "sse" ]]; then
#  original_cflags='-march=pentium3 -O2 -mfpmath=sse -msse'
#else
#  original_cflags='-mtune=generic -O2'
#fi
ffmpeg_git_checkout_version=
build_ismindex=n
enable_gpl=y
build_x264_with_libav=n # To build x264 with Libavformat.

# parse command line parameters, if any
while true; do
  case $1 in
    -h | --help ) echo "available option=default_value:
      --build-ffmpeg-static=y  (ffmpeg.exe, ffplay.exe and ffprobe.exe)
      --build-ffmpeg-shared=n  (ffmpeg.exe (with libavformat-x.dll, etc., ffplay.exe, ffprobe.exe and dll-files)
      --ffmpeg-git-checkout-version=[master] if you want to build a particular version of FFmpeg, ex: n3.1.1 or a specific git hash
      --gcc-cpu-count=[number of cpu cores set it higher than 1 if you have multiple cores and > 1GB RAM, this speeds up initial cross compiler build. FFmpeg build uses number of cores no matter what]
      --disable-nonfree=y (set to n to include nonfree like libfdk-aac,libfaac,decklink)
      --build-intel-qsv=y (set to y to include the [non windows xp compat.] qsv library and ffmpeg module. NB this not not hevc_qsv...
      --sandbox-ok=n [skip sandbox prompt if y]
      -d [meaning \"defaults\" skip all prompts, just build ffmpeg static with some reasonable defaults like no git updates]
      --build-libmxf=n [builds libMXF, libMXF++, writeavidmxfi.exe and writeaviddv50.exe from the BBC-Ingex project]
      --build-mp4box=n [builds MP4Box.exe from the gpac project]
      --build-mplayer=n [builds mplayer.exe and mencoder.exe]
      --build-vlc=n [builds a [rather bloated] vlc.exe]
      --build-lsw=n [builds L-Smash Works VapourSynth and AviUtl plugins]
      --build-ismindex=n [builds ffmpeg utility ismindex.exe]
      -a 'build all' builds ffmpeg, mplayer, vlc, etc. with all fixings turned on
      --build-dvbtee=n [build dvbtee.exe a DVB profiler]
      --compiler-flavors=[multi,win32,win64] [default prompt, or skip if you already have one built, multi is both win32 and win64]
      --cflags=[default is $original_cflags, which works on any cpu, see README for options]
      --git-get-latest=y [do a git pull for latest code from repositories like FFmpeg--can force a rebuild if changes are detected]
      --build-x264-with-libav=n build x264.exe with bundled/included "libav" ffmpeg libraries within it
      --prefer-stable=y build a few libraries from releases instead of git master
      --high-bitdepth=n Enable high bit depth for x264 (10 bits) and x265 (10 and 12 bits, x64 build. Not officially supported on x86 (win32), but enabled by disabling its assembly).
      --debug Make this script  print out each line as it executes
      --enable-gpl=[y] set to n to do an lgpl build
       "; exit 0 ;;
    --sandbox-ok=* ) sandbox_ok="${1#*=}"; shift ;;
    --gcc-cpu-count=* ) gcc_cpu_count="${1#*=}"; shift ;;
    --ffmpeg-git-checkout-version=* ) ffmpeg_git_checkout_version="${1#*=}"; shift ;;
    --build-libmxf=* ) build_libmxf="${1#*=}"; shift ;;
    --build-mp4box=* ) build_mp4box="${1#*=}"; shift ;;
    --build-ismindex=* ) build_ismindex="${1#*=}"; shift ;;
    --git-get-latest=* ) git_get_latest="${1#*=}"; shift ;;
    --build-amd-amf=* ) build_amd_amf="${1#*=}"; shift ;;
    --build-intel-qsv=* ) build_intel_qsv="${1#*=}"; shift ;;
    --build-x264-with-libav=* ) build_x264_with_libav="${1#*=}"; shift ;;
    --build-mplayer=* ) build_mplayer="${1#*=}"; shift ;;
    --cflags=* )
       original_cflags="${1#*=}"; echo "setting cflags as $original_cflags"; shift ;;
    --build-vlc=* ) build_vlc="${1#*=}"; shift ;;
    --build-lsw=* ) build_lsw="${1#*=}"; shift ;;
    --build-dvbtee=* ) build_dvbtee="${1#*=}"; shift ;;
    --disable-nonfree=* ) disable_nonfree="${1#*=}"; shift ;;
    # this doesn't actually "build all", like doesn't build 10 high-bit LGPL ffmpeg, but it does exercise the "non default" type build options...
    -a         ) compiler_flavors="multi"; build_mplayer=y; build_libmxf=y; build_mp4box=y; build_vlc=y; build_lsw=y; 
                 high_bitdepth=y; build_ffmpeg_static=y; build_ffmpeg_shared=y; build_lws=y;
                 disable_nonfree=n; git_get_latest=y; sandbox_ok=y; build_amd_amf=y; build_intel_qsv=y; 
                 build_dvbtee=y; build_x264_with_libav=y; shift ;;
    -d         ) gcc_cpu_count=$cpu_count; disable_nonfree="y"; sandbox_ok="y"; compiler_flavors="win32"; git_get_latest="n"; shift ;;
    --compiler-flavors=* ) compiler_flavors="${1#*=}"; shift ;;
    --build-ffmpeg-static=* ) build_ffmpeg_static="${1#*=}"; shift ;;
    --build-ffmpeg-shared=* ) build_ffmpeg_shared="${1#*=}"; shift ;;
    --prefer-stable=* ) prefer_stable="${1#*=}"; shift ;;
    --enable-gpl=* ) enable_gpl="${1#*=}"; shift ;;
    --high-bitdepth=* ) high_bitdepth="${1#*=}"; shift ;;
    --debug ) set -x; shift ;;
    -- ) shift; break ;;
    -* ) echo "Error, unknown option: '$1'."; exit 1 ;;
    * ) break ;;
  esac
done

reset_cflags # also overrides any "native" CFLAGS, which we may need if there are some 'linux only' settings in there
check_missing_packages # do this first since it's annoying to go through prompts then be rejected
intro # remember to always run the intro, since it adjust pwd
install_cross_compiler

export PKG_CONFIG_LIBDIR= # disable pkg-config from finding [and using] normal linux system installed libs [yikes]

if [[ $OSTYPE == darwin* ]]; then
  # mac add some helper scripts
  mkdir -p mac_helper_scripts
  cd mac_helper_scripts
    if [[ ! -x readlink ]]; then
      # make some scripts behave like linux...
      curl -4 file://$patch_dir/md5sum.mac --fail > md5sum  || exit 1
      chmod u+x ./md5sum
      curl -4 file://$patch_dir/readlink.mac --fail > readlink  || exit 1
      chmod u+x ./readlink
    fi
    export PATH=`pwd`:$PATH
  cd ..
fi

original_path="$PATH"
if [[ $compiler_flavors == "multi" || $compiler_flavors == "win32" ]]; then
  echo
  echo "Starting 32-bit builds..."
  host_target='i686-w64-mingw32'
  host_build='i686-mingw32'
  mingw_w64_x86_64_prefix="$cur_dir/cross_compilers/mingw-w64-i686/$host_target"
  mingw_bin_path="$cur_dir/cross_compilers/mingw-w64-i686/bin"
  export PKG_CONFIG_PATH="$mingw_w64_x86_64_prefix/lib/pkgconfig"
  export PATH="$mingw_bin_path:$original_path"
  bits_target=32
  cross_prefix="$mingw_bin_path/i686-w64-mingw32-"
  make_prefix_options="CC=${cross_prefix}gcc AR=${cross_prefix}ar PREFIX=$mingw_w64_x86_64_prefix RANLIB=${cross_prefix}ranlib LD=${cross_prefix}ld STRIP=${cross_prefix}strip CXX=${cross_prefix}g++"
  mkdir -p win32
  cd win32
    build_ffmpeg_dependencies
#    build_apps
  cd ..
fi

if [[ $compiler_flavors == "multi" || $compiler_flavors == "win64" ]]; then
  echo
  echo "**************Starting 64-bit builds..." # make it have a bit easier to you can see when 32 bit is done
  host_target='x86_64-w64-mingw32'
  host_build='x86_64-mingw32'
  mingw_w64_x86_64_prefix="$cur_dir/cross_compilers/mingw-w64-x86_64/$host_target"
  mingw_bin_path="$cur_dir/cross_compilers/mingw-w64-x86_64/bin"
  export PKG_CONFIG_PATH="$mingw_w64_x86_64_prefix/lib/pkgconfig"
  export PATH="$mingw_bin_path:$original_path"
  bits_target=64
  cross_prefix="$mingw_bin_path/x86_64-w64-mingw32-"
  make_prefix_options="CC=${cross_prefix}gcc AR=${cross_prefix}ar PREFIX=$mingw_w64_x86_64_prefix RANLIB=${cross_prefix}ranlib LD=${cross_prefix}ld STRIP=${cross_prefix}strip CXX=${cross_prefix}g++"
  mkdir -p win64
  cd win64
    build_ffmpeg_dependencies
#    build_apps
  cd ..
fi

echo "searching for all local exe's (some may not have been built this round, NB)..."
for file in $(find_all_build_exes); do
  echo "built $file"
done
