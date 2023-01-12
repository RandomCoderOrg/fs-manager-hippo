#!/bin/bash

TERMUX_APP_PACKAGE="com.termux"
TERMUX_PREFIX="/data/data/${TERMUX_APP_PACKAGE}/files/usr"
TERMUX_ANDROID_HOME="/data/data/${TERMUX_APP_PACKAGE}/files/home"
TERMUX_HOME=${TERMUX_ANDROID_HOME}
RTR="${TERMUX_PREFIX}/etc/udroid"
DEFAULT_ROOT="${TERMUX_PREFIX}/var/lib/udroid"
DEFAULT_FS_INSTALL_DIR="${DEFAULT_ROOT}/installed-filesystems"
DLCACHE="${DEFAULT_ROOT}/dlcache"
RTCACHE="${RTR}/.cache"

[[ -d ${RTR} ]] && cd $RTR || exit 1
[[ ! -f proot-utils/proot-utils.sh ]] && echo "proot-utils.sh not found" && exit 1
[[ ! -f gum_wrapper.sh ]] && echo "gum_wrapper.sh not found" && exit 1

source proot-utils/proot-utils.sh
source gum_wrapper.sh
source help_udroid.sh

export distro_data

DIE() { echo -e "${@}"; exit 1 ;:;}
GWARN() { echo -e "\e[90m${*}\e[0m";:;}
WARN() { echo -e "[WARN]: ${*}\e[0m";:;}
INFO() { echo -e "\e[32m${*}\e[0m";:;}
TITLE() { echo -e "\e[100m${*}\e[0m";:;}

# Fetch distro data from the internet and save it to RTCACHE
# @param mode [online/offline] - online mode will fetch data from the internet, offline will use the cached data
# @return distro_data [string] - path to the downloaded data

fetch_distro_data() {

    # default to online mode
    offline_mode=false
    mode=$1
    isStrictMode=$2

    # if mode is offline, set offline_mode to true
    if (( mode == "offline" )); then
        offline_mode=true
    fi

    # set isStrictMode to false if not set
    if [[ -z $isStrictMode ]]; then
        isStrictMode=false
    fi

    # setup URL and path variables
    URL="https://raw.githubusercontent.com/RandomCoderOrg/udroid-download/main/distro-data.json"
    _path="${RTCACHE}/distro-data.json.cache"

    # if the cache file exists, check for updates
    if [[ -f $_path ]]; then
        # if not in offline mode, fetch the data from the internet
        if ! $offline_mode; then
            g_spin dot "Fetching distro data.." curl -L -s -o $_path $URL || {
                ELOG "[${0}] failed to fetch distro data"
                mv $_path.old $_path
                if $isStrictMode; then
                    DIE "Failed to fetch distro data from: \n $URL"
                fi
            }
        fi
        distro_data=$_path
    # otherwise, fetch the data from the internet
    else
        g_spin dot "Fetching distro data.." curl -L -s -o $_path $URL || {
            ELOG "[${0}] failed to fetch distro data"
            DIE "Failed to fetch distro data from $URL"
        }
        distro_data=$_path
    fi
}

## ask() - prompt the user with a message and wait for a Y/N answer
# 
# This function will prompt the user with a message and wait for a Y/N answer.
# It will return 0 if the answer is Y, y, yes or empty. It will return 1 if the
# answer is N, n, no. If the answer is anything else, it will return 1.
#
# Usage:
# ask "Do you want to continue?"
#
# Returns:
# 0 if the answer is Y, y, yes or empty. It will return 1 if the
# answer is N, n, no. If the answer is anything else, it will return 1.
ask() {
    local msg=$*

    echo -ne "$msg\t[Y/N]: "
    read -r choice

    case $choice in
        y|Y|yes) return 0;;
        n|N|No) return 1;;
        "") return 0;;
        *) return 1;;
    esac
}

# This function checks the integrity of a file.
#
# This function takes the filename and the expected SHA256 sum of the file as parameters.
# It calculates the SHA256 sum of the file and compares it to the expected SHA256 sum.
# If the calculated SHA256 sum is the same as the expected SHA256 sum, the file is considered to be intact.
# If the calculated SHA256 sum is not the same as the expected SHA256 sum, the file is considered to be corrupt.
# This function returns 0 if the file is intact, 1 if the file is corrupt.
verify_integrity() {
    local filename=$1
    local shasum=$2

    filesha=$(sha256sum $filename | cut -d " " -f 1)
    LOG "filesum=$filesha"
    LOG "shasum=$shasum"
    
    if [[ "$filesha" != "$shasum" ]]; then
        LOG "file integrity check failed"
        return 1
    else
        LOG "file integrity check passed"
        return 0
    fi
}

install() {
    ###
    # install()
    #
    # stages:
    #   1) take the arguments supplied ( i.e "arg"->$1 and "path"->$2 )
    #   2) parse the arg for suite and varient
    #       2-1) if suite or varient is null (i.e not supplied) the try to prompt by guessing it with avalible arguments
    #   3) parse the download link from json ( if null exit )
    #   4) Extract the filesystem to target path
    #   5) execute fixes file

    # local arg=$1
    TITLE "> INSTALL $arg"
    local no_check_integrity=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-check-integrity)
                no_check_integrity=true
                shift
            ;;
            *) 
                # [[ -n $_name ]] && {
                #     ELOG "login() error: name already set to $_name"
                #     echo "--name supplied $_name"
                # }
                
                if [[ -z $arg ]]; then
                    arg=$1
                else
                    ELOG "unkown option $1"
                fi
                shift
                break
            ;;
        esac
    done

    [[ -z $arg ]] && {
        ELOG "\$arg not supplied"
    }
    # parse the arg for suite and varient and get name,link
    parser $arg "online"
    
    # final checks
    [[ "$link" == "null" ]] && {
        ELOG "link not found for $suite:$varient"
        echo "ERROR:"
        echo "link not found for $suite:$varient"
        echo "either the suite or varient is not supported or invalid options supplied"
        echo "Report this issue at https://github.com/RandomCoderOrg/ubuntu-on-android/issues"
        exit 1 
    }
    if [[ -d $DEFAULT_FS_INSTALL_DIR/$name ]]; then
        ELOG "filesystem already installed"
        echo "filesystem already installed ."
        # [TODO]: write about reset and remove
        exit 1
    fi

    # file extension
    ext=$(echo $link | awk -F. '{print $NF}')
    
    # if path is set then download fs and extract it to path
    # cause it make better use of path
    if [[ -z $path ]]; then
        # echo "$link + $name"
        msg_download $name "$DLCACHE/$name.tar.$ext" $link
        download "$name.tar.$ext" "$link"

        # Start Extracting
        LOG "Extracting $name.tar.$ext"

        # create $name directory
        mkdir -p $DEFAULT_FS_INSTALL_DIR/$name

        # verify integrity
        if verify_integrity "$DLCACHE/$name.tar.$ext" "$shasum"; then
            LOG "file integrity check passed"
        else
            WARN "file integrity check failed"
            if $no_check_integrity; then
                INFO  "skipped integrity check .."
                GWARN "skipping integrity check"
                LOG   "skipping integrity check for \"$DLCACHE/$name.tar.$ext\""
            else
                if ask "Do you want to retry [ deleteing the file and re-download it? ]"; then
                    rm "$DLCACHE/$name.tar.$ext"
                    download "$name.tar.$ext" "$link"
                    
                    # recheck integrity after download
                    if verify_integrity "$DLCACHE/$name.tar.$ext" "$shasum"; then
                        LOG "file integrity check passed"
                    else
                        # exit condition
                        GWARN "file integrity check failed"
                        DIE "Exiting gracefully.."
                    fi
                else
                    # final exit condition
                    DIE "Integrity check failed. Exiting gracefully.."
                fi
            fi
        fi

        # call proot extract
        msg_extract "$DEFAULT_FS_INSTALL_DIR/$name"
        p_extract --file "$DLCACHE/$name.tar.$ext" --path "$DEFAULT_FS_INSTALL_DIR/$name"

        echo -e "Applying proot fixes"
        bash proot-utils/proot-fixes.sh "$DEFAULT_FS_INSTALL_DIR/$name"
    else
        msg_download $name "$path/$name.tar.$ext" "$link"
        download "$name.tar.$ext" "$link" "$path"

        if [[ -d $path ]]; then
            LOG "Extracting $name.tar.$ext"
            mkdir -p $path/$name
        else
            ELOG "ERROR: path $path not found"
            echo "ERROR: path $path not found"
        fi

        msg_extract "$path/$name"
        p_extract --file "$path/$name.tar.$ext" --path "$path/$name"

        # apply proot-fixes
        echo -e "Applying proot fixes"
        bash proot-utils/proot-fixes.sh "$path/$name"
    fi

    echo -e "[\xE2\x9C\x94] $name installed."

}

login() {
    # [ yoinked & modified ]
    # Most of the code is taken from proot-utils.sh 
    # PERMALINK : https://github.com/termux/proot-distro/blob/fcee91ca6c7632c09898c9d0a680c8ff72c3357f/proot-distro.sh#L933
    # 
    # @termux/proot-distro (C) GNU V3 License
    unset LD_PRELOAD

    local isolated_environment=false
    local use_termux_home=false
    local no_link2symlink=false
    local no_sysvipc=false
    local no_kill_on_exit=false
    local no_cwd_active_directory=false
    local no_fake_root_id=false
    local fix_low_ports=false
    local make_host_tmp_shared=true # its better to run with shared tmp
    local root_fs_path=""
    local login_user="root"
    local -a custom_fs_bindings
    local path=$DEFAULT_FS_INSTALL_DIR

    while [[ $# -gt 0 ]]; do
        case $1 in
            --)
             shift
             break
             ;;
            -p | --path) 

                # Custom paths are set either to point a new directory instead of default
                # this is not-recommended cause managing installed filesystems becomes harder when they are outside of DEFAULT directories
                #       operations like: remove, reset or analyzing filesystems
                # using custom path results in abonded installation -> script only cares when its path is supplied again
                #
                # possible solution is to cache the loaction every time a path is supplied and use that for operations
                local path=$2; shift 2
                LOG "(login) custom installation path set to $path"
                ;;
            --name)
                local _name=$2; shift 2
                LOG "(login) custom name set to $name"
                ;;
            --bind | -b )
                # For extra mount points
                [[ $# -ge 2 ]] && {
                    [[ -z $2 ]] && {
                        ELOG "ERROR: --bind requires a path"
                        DIE "ERROR: --bind requires a path"
                    }
                    custom_fs_bindings+=("$2")
                    shift 2
                    if [[ -z $UDROID_MOUNT_SANITY_CHECK ]]; then
                        [[ ! -d ${1%%:*} ]] && {
                            LOG  "WARNING: --bind path $1 not found"
                            GWARN "WARNING: --bind path $1 not found"
                        }
                    fi
                }
                ;;
            --user)
                [[ $# -ge 2 ]] && [[ -n $2 ]] && {
                    login_user=$2
                    shift 2
                }
            ;;
            # --termux-home)
            #     use_termux_home=true
            #     ;;
            --isolated)
                isolated_environment=true; shift
                ;;
            --fix-low-parts)
                fix_low_ports=true; shift
                ;;
            --no-shared-tmp)
                make_host_tmp_shared=false; shift
                ;;
            --no-link2symlink)
                no_link2symlink=true; shift
                ;;
            --no-sysvipc)
                no_sysvipc=true; shift
                ;;
            --no-fake-root-id)
                no_fake_root_id=true; shift
                ;;
            --no-cwd-active-directory | --ncwd)
                no_cwd_active_directory=true; shift
                ;;
            --no-kill-on-exit)
                no_kill_on_exit=true; shift
                ;;
            -*)
                echo "Unknown option: $1"
                exit 1
                ;;
            *) 
                [[ -n $_name ]] && {
                    ELOG "login() error: name already set to $_name"
                    echo "--name supplied $_name"
                }
                
                if [[ -z $arg ]]; then
                    arg=$1
                else
                    ELOG "unkown option $1"
                fi
                shift
                break
                ;;
        esac
    done

    if [[ -z $_name ]]; then
        TITLE "> LOGIN $arg"
        parser $arg "offline"
        distro=$name
    else
        TITLE "> LOGIN $_name"
        distro=$_name
    fi
    root_fs_path=$path/$distro

    [[ -z $distro ]] && echo "ERROR: distro not specified" && exit 1

    if [ -d $path/$distro ]; then
        # set PROOT_L2S_DIR
        if [ -d "${root_fs_path}/.l2s" ]; then
            export PROOT_L2S_DIR="${root_fs_path}/.l2s"
        fi

        # PARSE extra container command arguments and set SHELL
        if [ $# -ge 1 ]; then
            # Wrap in quotes each argument to prevent word splitting.
            local -a shell_command_args
            for i in "$@"; do
                shell_command_args+=("'$i'")
            done
            
            if stat "${root_fs_path}/bin/su" >/dev/null 2>&1; then
                set -- "/bin/su" "-l" "$login_user" "-c" "${shell_command_args[*]}"
            else
                GWARN "Warning: no /bin/su available in rootfs!"
                LOG "login() => Warning: no /bin/su available in rootfs!"

                if [ -x "${root_fs_path}/bin/bash" ]; then
                    set -- "/bin/bash" "-l" "-c" "${shell_command_args[*]}"
                else
                    set -- "/bin/sh" "-l" "-c" "${shell_command_args[*]}"
                fi
            fi
        else
            if stat "${root_fs_path}/bin/su" >/dev/null 2>&1; then
                set -- "/bin/su" "-l" "$login_user"
            else
                GWARN "Warning: no /bin/su available in rootfs! You may need to install package 'util-linux' or 'shadow' (shadow-utils) or equivalent, depending on distribution."
                if [ -x "${root_fs_path}/bin/bash" ]; then
                    set -- "/bin/bash" "-l"
                else
                    set -- "/bin/sh" "-l"
                fi
            fi
        fi

        # set basic environment variables
        set -- "/usr/bin/env" "-i" \
        "HOME=/root" \
        "LANG=C.UTF-8" \
        "TERM=${TERM-xterm-256color}" \
        "$@"

        # set --rootfs
        set -- "--rootfs=${root_fs_path}" "$@"

        # [CONDIRIONAL]: set --kill on exit
        if ! $no_kill_on_exit; then
            set -- "--kill-on-exit" "$@"
        fi

        # [CONDIRIONAL]: set --link2symlink
        if ! $no_link2symlink; then
            set -- "--link2symlink" "$@"
        fi

        # [CONDIRIONAL]: set --sysvipc
        if ! $no_sysvipc; then
            set -- "--sysvipc" "$@"
        fi

        # set fake kernel version string
        set -- "--kernel-release=5.4.2-proot-facked" "$@"
        
        # Fix lstat
        set -- "-L" "$@"

        # [CONDIRIONAL]: set cwd
        if ! $no_cwd_active_directory && ! $isolated_environment; then
            set -- "--cwd=$PWD" "$@"
        fi
        
        if $no_cwd_active_directory; then
            set -- "--cwd=/root" "$@"
        fi

        # root-id ( fake 0 id for proot )
        if ! $no_fake_root_id; then
            set -- "--root-id" "$@"
        fi

        # [CONDITIONAL]: parse special binds from fs
        if [ -f ${root_fs_path}/udroid_proot_mounts ]; then
            LOG "login() => Custom mount points found in ${root_fs_path}/udroid_proot_mounts"
            LOG "login() => parsing udroid_proot_mounts"
            while read -r line; do
                [[ -z $line ]] && continue
                [[ $line == \#* ]] && continue
                custom_fs_bindings+=("$line")
            done < ${root_fs_path}/udroid_proot_mounts
        fi

        # set up core-mounts [ /dev /proc /sys /tmp ]
        set -- "--bind=/dev" "$@"
        set -- "--bind=/dev/urandom:/dev/random" "$@"
        set -- "--bind=/proc" "$@"
        set -- "--bind=/proc/self/fd:/dev/fd" "$@"
        set -- "--bind=/proc/self/fd/0:/dev/stdin" "$@"
        set -- "--bind=/proc/self/fd/1:/dev/stdout" "$@"
        set -- "--bind=/proc/self/fd/2:/dev/stderr" "$@"
        set -- "--bind=/sys" "$@"
        
        if $make_host_tmp_shared; then
            set -- "--bind=$TERMUX_PREFIX/tmp:/tmp" "$@"
        else
            mkdir -p "${root_fs_path}/tmp"
            set -- "--bind=${root_fs_path}/tmp:/dev/shm" "$@"
        fi

        # set up custom binds
        for i in "${custom_fs_bindings[@]}"; do
            set -- "--bind=$i" "$@"
        done

        # [CONDITIONAL]: resolv fake mounts
        if ! cat /proc/loadavg >/dev/null 2>&1; then
            set -- "--bind=${root_fs_path}/proc/.loadavg:/proc/loadavg" "$@"
        fi

        # Fake /proc/stat if necessary.
        if ! cat /proc/stat >/dev/null 2>&1; then
            set -- "--bind=${root_fs_path}/proc/.stat:/proc/stat" "$@"
        fi

        # Fake /proc/uptime if necessary.
        if ! cat /proc/uptime >/dev/null 2>&1; then
            set -- "--bind=${root_fs_path}/proc/.uptime:/proc/uptime" "$@"
        fi

        # Fake /proc/version if necessary.
        if ! cat /proc/version >/dev/null 2>&1; then
            set -- "--bind=${root_fs_path}/proc/.version:/proc/version" "$@"
        fi

        # Fake /proc/vmstat if necessary.
        if ! cat /proc/vmstat >/dev/null 2>&1; then
            set -- "--bind=${root_fs_path}/proc/.vmstat:/proc/vmstat" "$@"
        fi

        
        # [CONDITIONAL]: set binds for local storage
        if ! $isolated_environment; then
            set -- "--bind=/data/dalvik-cache" "$@"
            set -- "--bind=/data/data/$TERMUX_APP_PACKAGE/cache" "$@"
            if [ -d "/data/data/$TERMUX_APP_PACKAGE/files/apps" ]; then
                set -- "--bind=/data/data/$TERMUX_APP_PACKAGE/files/apps" "$@"
            fi
            set -- "--bind=$TERMUX_HOME" "$@"
    
            # Setup bind mounting for shared storage.
            # We want to use the primary shared storage mount point there
            # with avoiding secondary and legacy mount points. As Android
            # OS versions are different, some directories may be unavailable
            # and we need to try them all.
            if ls -1U /storage/self/primary/ >/dev/null 2>&1; then
                set -- "--bind=/storage/self/primary:/sdcard" "$@"
            elif ls -1U /storage/emulated/0/ >/dev/null 2>&1; then
                set -- "--bind=/storage/emulated/0:/sdcard" "$@"
            elif ls -1U /sdcard/ >/dev/null 2>&1; then
                set -- "--bind=/sdcard:/sdcard" "$@"
            else
                # No access to shared storage.
                :
            fi
    
            # /storage also optional bind mounting.
            # If we can't access it, don't provide this directory
            # in proot environment.
            if ls -1U /storage >/dev/null 2>&1; then
                set -- "--bind=/storage" "$@"
            fi
            # [CONDITIONAL]: set binds for /apex /vendor /system

            if [ -d "/apex" ]; then
            set -- "--bind=/apex" "$@"
            fi
            if [ -e "/linkerconfig/ld.config.txt" ]; then
                set -- "--bind=/linkerconfig/ld.config.txt" "$@"
            fi
            set -- "--bind=$TERMUX_PREFIX" "$@"
            set -- "--bind=/system" "$@"
            set -- "--bind=/vendor" "$@"
            if [ -f "/plat_property_contexts" ]; then
                set -- "--bind=/plat_property_contexts" "$@"
            fi
            if [ -f "/property_contexts" ]; then
                set -- "--bind=/property_contexts" "$@"
            fi
        fi

        # [CONDITIONAL]: fix low ports
        if $fix_low_ports; then
            set -- "-p" "$@"
        fi

        exec proot "$@"
    else
        ELOG "ERROR: $distro not found or installed"
        echo "ERROR: $distro not found or installed"
        # echo "use 'install' to install it"
        exit 1
    fi

}

parser() {
    local arg=$1
    local mode=$2
    local suite=${arg%%:*}
    local varient=${arg#*:}

    LOG "[USER] function args => suite=$suite varient=$varient"
    
    # if TEST_MODE is set run scripts in current directory and use test.json for distro_conf
    if [[ -n $TEST_MODE ]]; then
        LOG "[TEST] test mode enabled"
        distro_data=test.json
        DLCACHE="./tmp/dlcache"
        mkdir -p $DLCACHE
        LOG "[TEST] DLCACHE=$DLCACHE"
        LOG "[TEST] distro_data=$distro_data"
    else
        mkdir $RTCACHE 2> /dev/null
        fetch_distro_data $mode
        distro_data=${RTCACHE}/distro-data.json.cache
    fi

    ############### START OF OPTION PARSER ##############

    # implemenation to parse two words seperated by a colon
    #   eg: jammy:xfce4
    #  Fallback conditions
    #  1. if no colon is found, then instead of error try to guess the user intentiom
    #      and give a promt to select missing value the construct the colon seperated arg
    #  2. if both colon seperated words are same then => ERROR

    # check if seperator is present & Guess logic
    [[ $(echo $arg | awk '/:/' | wc -l) == 0 ]] && {
        ELOG "seperator not found"
        LOG "trying to guess what does that mean"

        if [[ $(cat $distro_data | jq -r '.suites[]') =~ $arg ]]; then
            LOG "found suite [$arg]"
            suite=$arg
            varient=""
        else
            for _suites in $(cat $distro_data | jq -r '.suites[]'); do
                for _varients in $(cat $distro_data | jq -r ".${_suites}.varients[]"); do
                    if [[ $_varients =~ $arg ]]; then
                        suite=$""
                        varient=$arg
                    fi
                done
            done
        fi
    }
    
    # Check if somehow suite and varient are same ( which is not the case )
    if [[ "$suite" == "$varient" ]]; then
        [[ -n "$suite" ]] && [[ -n "$varient" ]] && {
            ELOG "Parsing error in [$arg] (both can't be same)"
            LOG "function args => suite=$suite varient=$varient"
            echo "parse error"
        }
    fi


    suites=$(cat $distro_data | jq -r '.suites[]')

    # if suite or varient is empty prompt user to select it!
    [[ -z $suite ]] && {
        suite=$(g_choose $(cat $distro_data | jq -r '.suites[]'))
    }
    [[ ! $suites =~ $suite ]] && echo "suite not found" && exit 1

    [[ -z $varient ]] && {
        varient=$(g_choose $(cat $distro_data | jq -r ".$suite.varients[]"))
    }
    [[ ! $varient =~ $varient ]] && echo "varient not found" && exit 1

    LOG "[Final] function args => suite=$suite varient=$varient"
    ############### END OF OPTION PARSER ##############

    # Finally to get link
    
    # arch transition
    case $(dpkg --print-architecture) in
        arm64 | aarch64) arch=aarch64 ;;
        armhf | armv7l | armv8l) arch=armhf ;;
        x86_64| amd64) arch=amd64;;
        *) die "unsupported architecture" ;;
    esac

    link=$(cat $distro_data | jq -r ".$suite.$varient.${arch}url")
    LOG "link=$link"
    name=$(cat $distro_data | jq -r ".$suite.$varient.Name")
    LOG "name=$name"
    shasum=$(cat $distro_data | jq -r ".$suite.$varient.${arch}sha")
    LOG "shasum=$shasum"
}

list() {
    ## List
    # list all the avalible suites varients and their status
    
    export size=false
    export show_installed_only=false
    local path=$DEFAULT_FS_INSTALL_DIR

    while [ $# -gt 0 ]; do
        case $1 in
            --size) size=true; shift 1;;
            --list-installed) show_installed_only=true; shift 1;;
            --path) path=$2; LOG "list(): looking in $path"; shift 2;;
            --help) help_list; exit 0;;
            *) shift ;;
        esac
    done

    fetch_distro_data "offline"

    suites=$(cat $distro_data | jq -r '.suites[]')

    # loop over suites
    for suite in $suites; do
        echo "$suite: "
        varients=$(cat $distro_data | jq -r ".$suite.varients[]")
        
        # loop over varients
        for varient in $varients; do
            # get name
            name=$(cat $distro_data | jq -r ".$suite.$varient.Name")
            supported_arch=$(cat $distro_data | jq -r ".$suite.$varient.arch")

            host_arch=$(dpkg --print-architecture)
            if [[ $host_arch =~ $supported_arch ]]; then
                    supported=true
                else
                    supported=false
            fi
            
            # check if installed
            if [[ -d $path/$name ]]; then
                _installed="[installed]"
            else
                _installed=""
            fi

            # check size
            if [[ $size == true ]]; then
                if [[ -d $path/$name ]]; then
                    _size="[ SIZE: $(du -sh $path/$name | awk '{print $1}') ]"
                else
                    _size=""
                fi
            else
                _size=""
            fi

            # set support status
            if [[ $supported == true ]]; then
                support_status="\e[1;32m [supported]\e[0m"
            else
                support_status="\e[31m [unsupported]\e[0m"
            fi

            # print out
            if ! $show_installed_only; then
                echo -e "\t- $varient $support_status $_installed $_size"
            else
                if [[ -d $path/$name ]]; then
                    echo -e "\t- $varient $support_status $_installed $_size"
                fi
            fi
        done
    done

}

remove() {
    local distro=""
    local arg=""
    local path=${DEFAULT_FS_INSTALL_DIR}
    local reset=false

    while [ $# -gt 0 ]; do
        case $1 in
            --name) distro=$2; LOG "remove(): --name supplied to $name"; shift 2;;
            --path) path=$2; LOG "remove(): looking in $path"; shift 2;;
            --reset) reset=true; shift 1;;
            --help) help_remove; exit 0;;
            *) 
                [[ -n $distro ]] && {
                    ELOG "remove() error: name already set to $distro"
                    echo "--name supplied $distro"
                }
                
                if [[ -z $arg ]]; then
                    arg=$1
                else
                    ELOG "unkown option $1"
                fi
                shift
                break 
            ;;
        esac
    done

    if ! $reset; then
        TITLE "> REMOVE $arg($distro)"
        spinner="pulse"
    else
        TITLE "> RESET $arg($distro)"
        spinner="jump"
    fi

    if [[ -z $distro ]]; then
        parser $arg "offline"
        distro=$name
    fi
    root_fs_path=$path/$distro

    [[ -z $distro ]] && echo "ERROR: distro not specified" && exit 1
    [[ ! -d $root_fs_path ]] && echo "ERROR: distro ($distro) not found or installed" && exit 1

    g_spin "$spinner" \
        "Removing $arg($distro)" \
        bash proot-utils/proot-uninstall-suite.sh "$root_fs_path"
    
    if [[ $reset == true ]]; then
        unset path
        install $arg
    fi

}

update_cache() {
    TITLE "> UPDATE distro data from remote"
    fetch_distro_data "online" true
}

# To upgrade tool with git
# by maintaining a local cache
_upgrade() {
    local branch=$1

    # place to store repository
    repo_cache="${HOME}/.fs-manager-udroid"
    repo_url="https://github.com/RandomCoderOrg/fs-manager-udroid"

    # check if repo exists and clone it if not found
    if [[ ! -d $repo_cache ]]; then
        LOG "upgrade(): cloning repo"
        git clone $repo_url $repo_cache || DIE "failed to upgrade"
    fi

    # check if branch is specified
    if [[ -z $branch ]]; then
        LOG "upgrade(): no branch specified, using master"
        branch="main"
    fi

    # if repo is not in $branch checkout to $branch
    if [[ $(git -C $repo_cache branch --show-current) != "$branch" ]]; then
        LOG "upgrade(): switching to branch $branch"
        git -C $repo_cache checkout $branch
    fi

    # pull latest changes, if conflict occurs, clean and pull again
    git -C $repo_cache pull || {
        LOG "upgrade(): conflict occured, cleaning and pulling again"
        git -C $repo_cache reset --hard
        git -C $repo_cache  pull
    }

    # change to repo directory and install it
    cd $repo_cache || {
        ELOG "upgrade(): failed to change to $repo_cache"
        exit 1
    }

    # install
    LOG "upgrade(): installing"
    bash install.sh

    # TODO: look out for commit hashes to see if upgrade is needed
    
}

_reset() {
    # TODO
    TITLE "[TODO] RESET"
}
####################
download() {
    local name=$1
    local link=$2

    [[ -n "$3" ]] && local path=$3
    [[ -z $path ]] && path="$DLCACHE"

    LOG "download() args => name=$name link=$link path=$path"

    if [[ -f $path/$name ]]; then
        LOG "download(): $name already exists in $path"
        GWARN "$name already exists, continuing with existing file"
    else
        wget -q --tries=10 --show-progress --progress=bar:force -O ${path}/$name  "$link"  2>&1 || {
            ELOG "failed to download $name"
            echo "failed to download $name"
            exit 1
        }
    fi
}

msg_download() {
    local name=$1
    local path=$2
    local link=$3

    grey_color="\e[90m"
    reset_color="\e[0m"

    echo -e "Downloading $name filesystem ${grey_color}($link)${reset_color}"
    echo -e ":[PATH]= ${grey_color}${path}${reset_color}"
}

msg_extract() {
    local path=$1

    echo
    echo -e "Extracting filesystem to ${grey_color}${path}${reset_color}"
    echo -e "This may take a while..."
    echo
}
####################
trap 'echo "exiting gracefully..."; exit 1' HUP INT TERM
####################

if [ $# -eq 0 ]; then
    echo "usage: $0 [install|login|remove]"
    exit 1
fi

while [ $# -gt 0 ]; do
    case $1 in
        install | --install|-i) shift 1; install $@ ; break ;;
        upgrade  | --upgrade|-u) shift 1; _upgrade "revamp-v2.5" ; break ;;
        --update-cache) shift 1; update_cache $@ ; break ;;
        login   | --login|-l) shift 1; login $@; break ;;
        remove  | --remove | --uninstall ) shift 1 ; remove $@; break;;
        reset   | --reset | --reinstall )  shift 1 ; _reset $@; break;;
        list    | --list) shift 1; list $@; break ;;
        *) echo "unkown option [$1]"; break ;;
    esac
done
