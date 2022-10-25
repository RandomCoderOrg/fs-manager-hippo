#!/bin/bash

[[ ! -f proot-utils/proot-utils.sh ]] && echo "proot-utils.sh not found" && exit 1
[[ ! -f gum_wrapper.sh ]] && echo "gum_wrapper.sh not found" && exit 1

source proot-utils/proot-utils.sh
source gum_wrapper.sh

export distro_data

RTR="${PREFIX}/etc/udroid"
DLCACHE="${TODO_DIR}/dlcache"
RTCACHE="${RTR}/.cache"

fetch_distro_data() {
    URL="https://raw.githubusercontent.com/RandomCoderOrg/udroid-download/main/distro-data.json"
    _path="${RTCACHE}/distro-data.json.cache"

    gum_spin dot "Fetching distro data.." curl -L -s -o $_path $URL || {
        ELOG "[${0}] failed to fetch distro data"
    }

    if [[ -f $_path ]]; then
        LOG "set distro_data to $_path"
        distro_data=$_path
    else
        die "Distro data fetch failed!"
    fi
}

install() {
    local arg=$1
    local suite=${arg%%:*}
    local varient=${arg#*:}

    LOG "[USER] function args => suite=$suite varient=$varient"
    [[ -n $TEST_MODE ]] && distro_data=test.json

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
    if [[ $suite -eq $varient ]]; then
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
    arch=$(dpkg --print-architecture)
    link=$(cat $distro_data | jq -r ".$suite.$varient.${arch}url")
    LOG "link=$link"
    name=$(cat $distro_data | jq -r ".$suite.$varient.Name")
    LOG "name=$name"
    # final checks
    [[ "$link" == "null" ]] && {
        ELOG "link not found for $suite:$varient"
        echo "ERROR:"
        echo "link not found for $suite:$varient"
        echo "either the suite or varient is not supported or invalid options supplied"
        echo "Report this issue at https://github.com/RandomCoderOrg/ubuntu-on-android/issues"
        exit 1 
    }

    # echo "$link + $name"
    download "$name" "$link"

    # Start Extracting
    p_extract --file "$DLCACHE/$name" --path "$TODO_DIR"

}

login() {
    :
}

remove() {
    :
}

####################
downlaod() {
    local name=$1
    local link=$2

    axel -o ${DLCACHE}/$name $link
}
####################

if [ $# -eq 0 ]; then
    echo "usage: $0 [install|login|remove]"
    exit 1
fi

while [ $# -gt 0 ]; do
    case $1 in
        --install|-i) shift 1; install $1; break ;;
        --login|-l)     ;;
        --remove | --uninstall ) ;;
        *) echo "unkown option [$1]"; break ;;
    esac
done
