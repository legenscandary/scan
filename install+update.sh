#!/bin/bash
#

# set up some paths
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCANBD_DIR="/etc/scanbd"
SCANBD_SCRIPTS="$SCANBD_DIR/scripts"
REPO_PATH="$SCANBD_SCRIPTS/legenscandary"
CFGFN="scan.conf"
CFGPATH="$REPO_PATH/$CFGFN"
REPO_URL='https://github.com/legenscandary/scan.git'
SMBPASSFN="/etc/samba/smbpasswd"

# tests if a user with the provided name exists
userExists()
{
    id -u "$1" > /dev/null 2>&1
}

# generates a timestamp for use in file names
getts()
{
    date +%Y%m%d%H%M%S
}

loadConfig()
{
    # check for config file, if not existent, create one
    if [ ! -f "$CFGPATH" ]; then
        echo "Config file does not exist, creating one with default settings."
        sudo mkdir -p "$(dirname "$CFGPATH")"
        local tmpfn; tmpfn="$(mktemp)"
        cat > "$tmpfn" <<EOF
#
# Legenscandary configuration
#
# Changes get active by executing $SCRIPT_PATH

# tesseract OCR languages
DOC_LANG="deu+eng"
# default scan resolution, same resolution goes to OCR
RESOLUTION=300
# selected max width&height of the scanner, assuming using autocrop by driver
WIDTH="221.121"
HEIGHT="500.0"
# max secs to wait for images from scanner, can be determined in test run
# benchmark command: ts_start=\$(date +%s); scanimage ... ;
# scan_time=\$(expr \$(date +%s)-\$ts_start); echo "scan duration: \$scan_time seconds"
# if there arrive no images within that time and scanimage is still running,
# it is killed, assuming paper jam or similiar lock up
SCANTIMEOUT=20
# user to run as, set up during install
SCANUSER=legenscandary
# output directory, samba share, relative to \$SCANUSER home dir
OUT_SUBDIR=scans
# samba workgroup
SMB_WORKGROUP=WORKGROUP

EOF
        sudo mv "$tmpfn" "$CFGPATH"
        sudo chmod 644 "$CFGPATH"
    fi
    source "$CFGPATH"
    userExists "$SCANUSER" && sudo chown -R "$SCANUSER.scanner" "$REPO_PATH"
}

installPackages()
{
    echo
    echo " => Updating system packages:"
    echo
    sudo apt-get update -y
    sudo apt-get dist-upgrade -y
    echo
    echo " => Installing additional software packages for image processing and file server:"
    echo
    sudo apt-get install -y git curl samba lockfile-progs imagemagick \
        zbar-tools poppler-utils libtiff-tools scantailor sane-utils openbsd-inetd

    # install latest scanbd 1.5.1
    tempdir="$(mktemp -d)"
    if cd "$tempdir"; then
        export DEBIAN_FRONTEND=noninteractive
        curl -O http://ftp.debian.org/debian/pool/main/c/confuse/libconfuse-common_3.2.2+dfsg-1_all.deb
        curl -O http://ftp.debian.org/debian/pool/main/c/confuse/libconfuse2_3.2.2+dfsg-1_armhf.deb
        curl -O http://ftp.debian.org/debian/pool/main/s/scanbd/scanbd_1.5.1-4_armhf.deb
        echo 'f1423d3de46e57df6b7b300972571d3b4edf18e7befcdbebb422388eea91086b *libconfuse-common_3.2.2+dfsg-1_all.deb
b47a9c2339bcd0599b1328971661f58fca5a4b86014a17e31f458add64c71a38 *libconfuse2_3.2.2+dfsg-1_armhf.deb
1fa024fa18243196227c963245395e1c321d4d6f14f4a4235fffffeb76c73339 *scanbd_1.5.1-4_armhf.deb' | sha256sum --strict -c && sudo dpkg --force-confdef -i ./*.deb
    fi

    # get missing keys required for backports directly, dirmngr DNS is broken in this ver
    curl 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x7638D0442B90D010' \
        | sudo apt-key add -
    codename="$(lsb_release -cs)"
    sudo sh -c "echo 'deb https://deb.debian.org/debian ${codename}-backports main contrib non-free' > /etc/apt/sources.list.d/debian-backports.list"
    sudo apt-get update -y

    echo
    echo " => Installing selected OCR packages:"
    echo
    [ -z "$DOC_LANG" ] && DOC_LANG="eng" # minimal language, updated from config file later
    tess_lang_packs="$(IFS='+'; for l in $DOC_LANG; do echo tesseract-ocr-$l; done)"
    sudo apt-get install -y -t "${codename}-backports" tesseract-ocr $tess_lang_packs
}

cfg()
{
    if [ "$#" -lt 2 ]; then
        echo "cfg() received less arguments then expected ($#: '$*')." 1>&2
        return
    fi
    local key="$1" # config key
    local val="$2" # config value
    val="$(echo "$val" | awk '{gsub("/","\\/"); print}')"
    # insert the key after this one if it does not exist yet, optional
    local aft="$3"
    local ind="   "
    if echo "$content" | grep -E '^[^#;]' | grep -q "$key"; then
        echo "Found '$key' ..." 1>&2
        # 1. uncomment the key first
        # 2. set the requested value
        echo "$content" \
        | sed -e '/\b'"$key"'\b/ s/\(^\s*\)[#;]\+\(\s*\)\('"$key"'\)/\1\2\3/g' \
        | sed -e 's/\('"$key"'\s*=\s*\).\+$/\1'"$val"'/g'
        return
    elif [ ! -z "$aft" ]; then # insert new key = value
        echo "Inserting '$key = $val' ..." 1>&2
        # test if 'aft' key is present
        if echo "$content" | grep -E '^[^#;]' | grep -q "$aft"; then
            echo "$content" \
            | sed -e '/\s*'"$aft"'/s/^\(\s*\)\('"$aft"'.*\)$/&\n'"$ind$key = $val"'/g'
            return
        fi
    fi
    if [ -z "$val" ]; then
        echo "$content" \
        | sed -e "$ a $key"
    else
        echo "$content"
        echo "$ind$key = $val"
    fi
}

configSamba()
{
    local content
    content="$(cfg '\[global\]' '')"
    content="$(cfg workgroup "$SMB_WORKGROUP" '\[global\]')"
    content="$(cfg "server string" "Scan Server" "workgroup")"
    content="$(cfg "server role" "standalone server" "server string")"
    local devs; devs="$(/sbin/ifconfig | \
                         awk -F':' '/^[a-zA-Z0-9]/ { ORS=" "; print $1 }')"
    content="$(cfg "dns proxy" no "server role")"
    content="$(cfg "interfaces" "$devs" "dns proxy")"
    content="$(cfg "bind interfaces only" yes "interfaces")"
    content="$(cfg "domain master" yes "bind interfaces only")"
    content="$(cfg "passdb backend" "smbpasswd:$SMBPASSFN" "server role")"
    content="$(cfg "unix password sync" yes "passdb backend")"
    content="$(cfg "unix extensions" no "unix")"
    content="$(cfg security user usershare)"
    content="$(cfg "encrypt passwords" yes security)"

    # append share configuration
    content="$content
$(cat <<EOF
[$OUT_SUBDIR]
   path = $OUT_DIR
   browseable = yes
   writable = yes
   create mask = 0644
   directory mask = 0755
EOF
)"

    echo "# Generated SAMBA configuration on $(date +'%Y-%m-%d %H:%M:%S')"
    echo "# by $SCRIPT_PATH"
    echo "$content"
}

# interactive function for setting the samba share password
add_samba_user()
{
    echo
    echo "Please specify a password for newly created user '$SCANUSER'"\
         "in workgroup '$SMB_WORKGROUP'."
    echo "Use it to connect to the new windows network share"
    echo
    echo "    \\\\$(hostname)\\$OUT_SUBDIR"
    echo
    echo "where all scanned documents will be stored."
    echo
    for _ in seq 1 3; do sudo smbpasswd -L -a "$SCANUSER" && break; done
    echo
    echo " => To update the password later on, run:"
    echo
    echo "    sudo smbpasswd -L -a $SCANUSER"
    echo "    sudo service smbd restart"
    echo
    sudo service smbd restart
}

configSys()
{
    local tmpfn
    echo
    echo " => Configuring the system:"
    if ! userExists "$SCANUSER"; then
        echo " => Creating user '$SCANUSER' ..."
        sudo adduser --system --ingroup scanner --disabled-login --shell=/bin/false "$SCANUSER"
        sudo -u "$SCANUSER" sh -c "cd; mkdir $OUT_SUBDIR"
    fi
    # assuming user exists now, create OUT_DIR
    OUT_DIR="$(sudo -u "$SCANUSER" sh -c "cd;
        mkdir -p '$OUT_SUBDIR'; cd '$OUT_SUBDIR'; pwd" 2> /dev/null)"
    # configure sane, let it use the net backend only, in favor of scanbd/scanbm
    if cd /etc/sane.d/; then
        if [ -z "$(find dll.d -type d -empty)" ]; then
            # move external sane config files somewhere else if there are any
            sudo mkdir -p dll.disabled && sudo mv dll.d/* dll.disabled/
        fi
        # make sure only the net backend is enabled in sane config, disable original config
        [ -z "$(grep -v net dll.conf | tr -d [:space:])" ] || sudo mv dll.conf "dll.disabled_$(getts).conf"
        sudo sh -c 'echo net > dll.conf'
        # configure sanes net backend, make sure required settings are present
        local netcfgfn="net.conf" # configure net-backend
        grep -q legenscandary "$netcfgfn" || sudo sh -c "echo '## configuration by legenscandary:' >> $netcfgfn"
        grep -q '^connect_timeout' "$netcfgfn" || sudo sh -c "echo 'connect_timeout = 3' >> $netcfgfn"
        grep -q '^localhost' "$netcfgfn" || sudo sh -c "echo 'localhost' >> $netcfgfn"
    fi
    # configure scanbd
    echo " => Setting up scanbd ..."
    if [ ! -d "$SCANBD_DIR" ]; then
        echo "scanbd config path '$SCANBD_DIR' not found!"
        return 1
    fi
       # create dummy saned config for scanbd to prevent warning msg
    [ -f "$SCANBD_DIR/saned.conf" ] || sudo touch "$SCANBD_DIR/saned.conf"
    # create script to be called on button press
    local scriptPath="$SCANBD_SCRIPTS/test.script"
    sudo mkdir -p "$SCANBD_SCRIPTS"
    tmpfn="$(mktemp)"
    cat > "$tmpfn" <<EOF
#!/bin/sh
logger -t "scanbd: \$0" "Begin of \$SCANBD_ACTION for device \$SCANBD_DEVICE"
sudo -u '$SCANUSER' $SCRIPT_DIR/scan.sh "\$SCANBD_DEVICE"
logger -t "scanbd: \$0" "End   of \$SCANBD_ACTION for device \$SCANBD_DEVICE"
EOF
    chmod 755 "$tmpfn"
    sudo mv "$tmpfn" "$scriptPath"
    sudo chown root.root "$scriptPath"
    sudo chown -R "$SCANUSER.scanner" "$SCRIPT_DIR" # let the user own it who runs the script
    # change default user to root in scanbd.conf
    # when set to user, script is run as root anyway from test.script, bug?
    sudo sed -i -e 's/^\(\s*user\s*=\s*\)\([a-z]\+\)/\1root/' "$SCANBD_DIR/scanbd.conf"
    # restart scanbd automatically on exit/segfault
    sudo sed -i -e '/\[Service\]/ aRestart=always' \
                -e '/\[Service\]/ aRestartSec=5' \
                -e 's/\(^Also.\+scanbm.socket\)/#\1/g' \
                   "/lib/systemd/system/scanbd.service"
    sudo systemctl stop scanbm.socket
    sudo systemctl disable scanbm.socket
    sudo systemctl daemon-reload
    sudo service scanbd restart
    # disable conflicting inetd config
    sudo update-inetd --disable sane-port # inetd not needed, all handled by systemd
    sudo service inetd restart
    sudo systemctl restart scanbm.socket

    # add a daily cron job for the update script
    tmpfn="$(mktemp)"
    cat > "$tmpfn" <<EOF
#!/bin/sh
# update the legenscandary scripts, possibly
$SCRIPT_PATH
EOF
    chmod 755 "$tmpfn"
    local cronPath="/etc/cron.daily/legenscandary"
    sudo mv "$tmpfn" "$cronPath"
    sudo chown root.root "$cronPath"

    # configure samba with a share for the OUT_DIR
    echo " => Configuring the samba file server:"
    echo
    sambacfg="/etc/samba/smb.conf"
    sudo mv "$sambacfg" "$sambacfg.bckp_$(getts)"
    configSamba > "$tmpfn"
    sudo mv "$tmpfn" "$sambacfg"
    sudo chown root.root "$sambacfg"
    # measure elapsed time before user input
    install_end_ts=$(date +%s)
    # create samba user if it does not exist yet
    if [ ! -f "$SMBPASSFN" ] || ! sudo grep -q "^$SCANUSER:" "$SMBPASSFN"; then
        add_samba_user
    fi
}

# scenario 1: called from anywhere: install us to scripts dir, git clone
# scenario 2: called from scripts dir within git repo, git pull
# scenario 3: called from scripts dir, no git repo
updateScripts()
{
    echo
    echo " ## Installing the legenscandary scan script! ##"
    echo
    if [ ! -d "$SCANBD_DIR" ] \
    || [ "$(dirname "$SCRIPT_DIR")" != "$SCANBD_SCRIPTS" ]; then
        # assuming first time call on this system
        installPackages # install scanbd first
        # running this again later in stage2 but without interactive functions
    fi
    if [ ! -d "$SCANBD_DIR" ]; then # scanbd should be installed by now
        echo "scanbd config path '$SCANBD_DIR' not found,"\
             "it seems, scanbd could not be installed!"
        exit 1
    fi
    if [ ! -d "$REPO_PATH" ]; then # create the repo if doesn't exist yet,
        # $SCANUSER is not known yet
        sudo mkdir -p "$REPO_PATH" && sudo chown "$USER" "$REPO_PATH"
    fi
    cd "$REPO_PATH" || return
    local installScript; installScript="$REPO_PATH/$(basename "$SCRIPT_PATH")"

    if [ -d ".git" ]; then # a git repo yet, update scripts?
        # stash dirty work dir first
        [ -z "$(git config user.name)" ] && git config user.name "$USER"
        [ -z "$(git config user.email)" ] && git config user.email "$USER@$(hostname)"
        git stash save
        # update work dir
        git pull
    elif [ ! -f "$installScript" ]; then # empty dir possibly
        git clone $REPO_URL .
    fi
    $installScript stage2 "$install_start_ts"
}

installme()
{
    if ! cd "$REPO_PATH"; then
        echo "Could not change to directory '$REPO_PATH'!"
        echo "Please run $SCRIPT_PATH again."
        exit 1
    fi
    loadConfig # this creates config file in repo dir if missing
    installPackages && configSys && (\
    echo
    echo " ## Installation done, enjoy! ##" )
    # show elapsed time
    if [ ! -z "$install_start_ts" ] && [ ! -z "$install_end_ts" ]; then
        secs=$((install_end_ts-install_start_ts))
        mins=$((secs/60))
        secs=$((secs-mins*60))
        echo " (took $mins min $secs sec to install)"; echo
    fi
    # clean up log files, keep the most recent 5
    local scriptName; scriptName="$(basename "$SCRIPT_PATH")"
    (cd "$SCRIPT_DIR" && rm -f $(ls -1t "${scriptName%*.sh}"*.log | tail -n+5))
}

main()
{
    set +x # log script in debug mode
    # if not set, remember start time of installation
    [ -z "$install_start_ts" ] && install_start_ts=$(date +%s)

    CMD="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    if [ "$CMD" = stage2 ]; then
        install_start_ts="$2" # get start time from previous invokation
        installme
    else
        updateScripts
    fi
}

LOGFILE="${SCRIPT_PATH%.*}_$(getts).log"
main "$@" 2>&1 | tee "$LOGFILE"

# vim: set ts=4 sts=4 sw=4 tw=0:
