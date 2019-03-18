#!/bin/bash
#
# run this script like this to test for correct file permissions:
# sudo -u saned /etc/scanbuttond/scan.sh
#
# TODO:
# - on reset/restart, remove queue
# - unlock scan button earlier
# - analysis: somehow eliminate empty space, match against (known) words?

# add a way to reset on scanner jamming:
# killall scanimage; kill $(ps ax | grep 'scanbuttond/.*\.sh' | grep -v ' grep' | awk '{print $1}'); rm -f "$(ls -1dt /home/scans/scans/work/scan_* | head -n1)"/*.tif; touch "$(ls -1dt /home/scans/scans/work/scan_* | head -n1)"/done

# set up some paths
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCANBD_DIR="/etc/scanbd"
SCANBD_SCRIPTS="$SCANBD_DIR/scripts"
REPO_PATH="$SCANBD_SCRIPTS/legenscandary"
CFGFN="scan.conf"
CFGPATH="$REPO_PATH/$CFGFN"
REPO_URL='https://github.com/legenscandary/scan.git'
CMD="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
SMBPASSFN="/etc/samba/smbpasswd"

# tests if a user with the provided name exists
userExists()
{
    id -u "$1" > /dev/null 2>&1
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

# sane device to be used
SCAN_DEVICE=
# tesseract OCR languages
DOC_LANG="deu+eng"
# default scan resolution, same resolution goes to OCR
RESOLUTION=300
# selected max width&height of the scanner, assuming using autocrop by driver
WIDTH="221.121"
HEIGHT="500.0"
# max secs to wait for images from scanner, can be determined in test run
# benchmark command: ts_start=$(date +%s); scanimage ... ; 
# scan_time=$(expr $(date +%s)-$ts_start); echo "scan duration: $scan_time seconds"
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
    fi
    source "$CFGPATH"
    sudo chown -R "$SCANUSER.scanner" "$REPO_PATH"
}

installPackages()
{
    echo " => Updating the system first:"
    echo
    sudo apt-get update -y
    sudo apt-get dist-upgrade -y
    echo
    echo " => Installing additional software packages for image processing and file server:"
    echo
    sudo apt-get install -y git curl samba lockfile-progs imagemagick \
        zbar-tools poppler-utils libtiff-tools scantailor sane-utils openbsd-inetd
    # get missing keys required for backports directly, dirmngr DNS is broken in this ver
    curl 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x7638D0442B90D010' \
        | sudo apt-key add -
    codename="$(lsb_release -cs)"
    sudo sh -c "echo 'deb https://deb.debian.org/debian ${codename}-backports main contrib non-free' > /etc/apt/sources.list.d/debian-backports.list"
    sudo apt-get update -y
    # install latest scanbd 1.5.1
    inetfn=/etc/inetd.conf
    entry="$(grep 'sane-port.*saned$' $inetfn)"
    sudo update-inetd --remove sane-port
    tempdir="$(mktemp -d)"
    cd "$tempdir"
    curl -O http://ftp.debian.org/debian/pool/main/c/confuse/libconfuse-common_3.2.2+dfsg-1_all.deb
    curl -O http://ftp.debian.org/debian/pool/main/c/confuse/libconfuse2_3.2.2+dfsg-1_armhf.deb
    curl -O http://ftp.debian.org/debian/pool/main/s/scanbd/scanbd_1.5.1-4_armhf.deb
    echo 'f1423d3de46e57df6b7b300972571d3b4edf18e7befcdbebb422388eea91086b *libconfuse-common_3.2.2+dfsg-1_all.deb
b47a9c2339bcd0599b1328971661f58fca5a4b86014a17e31f458add64c71a38 *libconfuse2_3.2.2+dfsg-1_armhf.deb
1fa024fa18243196227c963245395e1c321d4d6f14f4a4235fffffeb76c73339 *scanbd_1.5.1-4_armhf.deb' | sha256sum --strict -c && sudo dpkg --force-confdef -i *.deb
    sudo sh -c "(echo '$entry'; echo) >> '$inetfn'"
    sudo service scanbd restart

    echo
    echo " => Installing selected OCR packages:"
    echo
    [ -z "$DOC_LANG" ] && DOC_LANG="eng" # minimal language, updated from config file later
    tess_lang_packs="$(IFS='+'; for l in $DOC_LANG; do echo tesseract-ocr-$l; done)"
    sudo apt-get install -y -t ${codename}-backports tesseract-ocr $tess_lang_packs
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
                         awk -F':' '/^[^[:space:]:]+/ { ORS=" "; print $1 }')"
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
    for num in seq 1 3; do sudo smbpasswd -L -a "$SCANUSER" && break; done
    echo
    echo " => To update the password later on, run:"
    echo
    echo "    sudo smbpasswd -L -a $SCANUSER"
    echo "    sudo service smbd restart"
    echo
    sudo service smbd restart
}

# interactive function for determining the scanner device
get_scan_device()
{
    echo
    echo "Searching for the scanner to be used ..."
    read -p "Please make sure the scanner is connected, press <enter> to continue:"
    sudo service scanbd stop
    # TODO: check scanimage output for multiple devices
    local dev; dev="$(sudo -u "$SCANUSER" scanimage -f %d)"
    sudo service scanbd start
    if [ -z "$dev" ]; then
        echo " => No scanner found!"
    else
        echo " => using '$dev'"
        sed -i -e "s/\(SCANBD_DIR=\).*\$/\\1'$dev'/g" "$CFGPATH"
    fi
    echo "The scanner can be changed later by updating the entry 'SCAN_DEVICE' in '$CFGPATH'."
    echo "Find it by running:"
    echo
    echo "    sudo service scanbd stop"
    echo "    sudo -u $SCANUSER scanimage -L"
    echo "    sudo service scanbd start"
    echo
}

configSys()
{
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
    echo " => Setting up scanbd ..."
    if [ ! -d "$SCANBD_DIR" ]; then
        echo "scanbd config path '$SCANBD_DIR' not found!"
        return 1
    fi
    local scriptPath="$SCANBD_SCRIPTS/test.script"
    sudo mkdir -p "$SCANBD_SCRIPTS"
    tmpfn="$(mktemp)"
    cat > "$tmpfn" <<EOF
#!/bin/sh
logger -t "scanbd: \$0" "Begin of \$SCANBD_ACTION for device \$SCANBD_DEVICE"
sudo -u '$SCANUSER' $SCRIPT_DIR/scan.sh
logger -t "scanbd: \$0" "End   of \$SCANBD_ACTION for device \$SCANBD_DEVICE"
EOF
    chmod 755 "$tmpfn"
    sudo mv "$tmpfn" "$scriptPath"
    sudo chown root.root "$scriptPath"
    sudo chown -R "$SCANUSER" "$SCRIPT_DIR" # let the user own it who runs the script
    # change default user to root in scanbd.conf
    # when set to user, script is run as root anyway from test.script, bug?
    sudo sed -i -e 's/^\(\s*user\s*=\s*\)\([a-z]\+\)/\1root/' "$SCANBD_DIR/scanbd.conf"
    # restart scanbd automatically on exit/segfault
    sudo sed -i -e '/\[Service\]/ aRestart=always' \
                -e '/\[Service\]/ aRestartSec=5' "/lib/systemd/system/scanbd.service"
    sudo systemctl daemon-reload
    sudo service scanbd restart

    # configure samba with a share for the OUT_DIR
    echo " => Configuring the samba file server:"
    echo
    sambacfg="/etc/samba/smb.conf"
    sudo mv "$sambacfg" "$sambacfg.bckp_$(date +%Y%m%d%H%M%S)"
    configSamba > "$tmpfn"
    sudo mv "$tmpfn" "$sambacfg"
    sudo chown root.root "$sambacfg"
    # create samba user if it does not exist yet
    if [ ! -f "$SMBPASSFN" ] || ! sudo grep -q "^$SCANUSER:" "$SMBPASSFN"; then
        add_samba_user
    fi
    # interactively get scan device if not set in config file yet
    [ -z "$SCAN_DEVICE" ] && get_scan_device
    install_end_ts=$(date +%s) # measure elapsed time before user input
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
    cd "$REPO_PATH"
    local installScript="$REPO_PATH/install.sh"
    if [ -d ".git" ]; then # a git repo yet, update scripts?
        git pull
    elif [ ! -f "$installScript" ]; then # empty dir possibly
        git clone $REPO_URL .
    fi
    $installScript stage2 $install_start_ts
}

install()
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
}

# if not set, remember start time of installation
[ -z "$install_start_ts" ] && install_start_ts=$(date +%s)

if [ "$CMD" = stage2 ]; then
    install_start_ts="$2" # get start time from previous invokation
    install
else
    updateScripts
fi

# vim: set ts=4 sts=4 sw=4 tw=0:
