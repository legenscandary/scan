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

# user to run this script as; created during install
USER=scansrv
OUT_SUBDIR=scans # output directory, samba share, relative to $USER home dir
SMB_WORKGROUP=WORKGROUP
DOC_LANG="deu+eng" # tesseract OCR languages
CMD="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
# set up some paths
SCRIPT_PATH="$(readlink -f "$0")"

# tests if a user with the provided name exists
userExists()
{
    grep -q "^$1:" /etc/passwd
}

# returns the output dir based on the provided user, has to exist
getOutdir()
{
    local user="$1"
    local subdir="$2"
    if ! userExists "$user"; then
        echo "getOutdir: Provided user '$user' does not exist, giving up!" 1>&2
        exit 1
    fi
    # make local subdir in scan user $HOME absolute
    local prefix=""
    [ x"$user"x = x"$(whoami)"x ] || prefix="sudo -u '$user'"
    local outdir; outdir="$($prefix sh -c "cd;
        mkdir -p '$subdir'; cd '$subdir'; pwd" 2> /dev/null)"
    printf %s "$outdir"
}

# FIXME: move this to config
DEVICE_NAME='net:localhost:fujitsu:ScanSnap iX500:94825' # sane device to be used
[ -z "$SCANBD_DEVICE" ] || DEVICE_NAME="$SCANBD_DEVICE"
# max secs to wait for images from scanner, could be determined in test run
SCANTIMEOUT=20
# benchmark command:
# ts_start=$(date +%s); scanimage ... ; scan_time=$(expr $(date +%s)-$ts_start); echo "scan duration: $scan_time seconds"
# selected max width&height of ix500, using autocrop by driver
WIDTH="221.121"
HEIGHT="500.0"
RESOLUTION=300

loadConfig()
{
}

installPackages()
{
    echo " => Updating the system first:"
    echo
    sudo apt update -y
    sudo apt dist-upgrade -y
    echo
    echo " => Installing additional software packages for image processing and file server:"
    echo
    sudo apt install -y curl samba lockfile-progs imagemagick \
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
    pushd "$tempdir"
    curl -O http://ftp.debian.org/debian/pool/main/c/confuse/libconfuse-common_3.2.2+dfsg-1_all.deb
    curl -O http://ftp.debian.org/debian/pool/main/c/confuse/libconfuse2_3.2.2+dfsg-1_armhf.deb
    curl -O http://ftp.debian.org/debian/pool/main/s/scanbd/scanbd_1.5.1-4_armhf.deb
    echo 'f1423d3de46e57df6b7b300972571d3b4edf18e7befcdbebb422388eea91086b *libconfuse-common_3.2.2+dfsg-1_all.deb
b47a9c2339bcd0599b1328971661f58fca5a4b86014a17e31f458add64c71a38 *libconfuse2_3.2.2+dfsg-1_armhf.deb
1fa024fa18243196227c963245395e1c321d4d6f14f4a4235fffffeb76c73339 *scanbd_1.5.1-4_armhf.deb' | sha256sum --strict -c && sudo dpkg --force-confdef -i *.deb
    popd
    sudo sh -c "(echo '$entry'; echo) >> '$inetfn'"
    sudo service scanbd restart

    echo
    echo " => Installing selected OCR packages:"
    echo
    tess_lang_packs="$(IFS='+'; for l in $DOC_LANG; do echo tesseract-ocr-$l; done)"
    sudo apt install -y -t ${codename}-backports tesseract-ocr $tess_lang_packs
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
    local smbpassfn="/etc/samba/smbpasswd"
    content="$(cfg "passdb backend" "smbpasswd:$smbpassfn" "server role")"
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

configSys()
{
    echo
    echo " => Configuring the system:"
    if ! userExists "$USER"; then
        echo " => Creating user '$USER' ..."
        sudo adduser --system --ingroup scanner --disabled-login --shell=/bin/false $USER
        sudo -u $USER sh -c "cd; mkdir $OUT_SUBDIR"
    fi
    OUT_DIR="$(getOutdir "$user" "$OUT_SUBDIR")"
    echo " => Setting up scanbd ..."
    local scanbdPath; scanbdPath="/etc/scanbd"
    if [ ! -d "$scanbdPath" ]; then
        echo "scanbd config path '$scanbdPath' not found!"
        return 1
    fi
    sudo mkdir -p "$scanbdPath/scripts"
    tmpfn="$(mktemp)"
    cat > "$tmpfn" <<EOF
#!/bin/sh
logger -t "scanbd: \$0" "Begin of \$SCANBD_ACTION for device \$SCANBD_DEVICE"
sudo -u $USER $SCRIPT_PATH
logger -t "scanbd: \$0" "End   of \$SCANBD_ACTION for device \$SCANBD_DEVICE"
EOF
    chmod 755 "$tmpfn"
    sudo mv "$tmpfn" "$scanbdPath/scripts/test.script"
    sudo chown root.root "$scanbdPath/scripts/test.script"
    # change default user to root in scanbd.conf
    # when set to user, script is run as root anyway from test.script, bug?
    sudo sed -i -e 's/^\(\s*user\s*=\s*\)\([a-z]\+\)/\1root/' "$scanbdPath/scanbd.conf"
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
    install_end_ts=$(date +%s) # measure elapsed time before user input
    echo
    echo "Please specify a password for newly created user '$USER'"\
         "in workgroup '$SMB_WORKGROUP'."
    echo "Use it to connect to the new windows network share"
    echo
    echo "    \\\\$(hostname)\\$OUT_SUBDIR"
    echo
    echo "where all scanned documents will be stored."
    echo
    for num in seq 1 3; do sudo smbpasswd -L -a $USER && break; done
    echo
    echo " => To update the password later on, run:"
    echo
    echo "    sudo smbpasswd -L -a $USER"
    echo "    sudo service smbd restart"
    sudo service smbd restart
}

install()
{
    install_start_ts=$(date +%s)
    install_end_ts=$install_start_ts
    echo
    echo " ## Installing the legenscandary scan script! ##"
    echo
    loadConfig && installPackages && configSys && (\
    echo
    echo " ## Installation done, enjoy! ##" )
    secs=$((install_end_ts-install_start_ts))
    mins=$((secs/60))
    secs=$((secs-mins*60))
    echo " (took $mins min $secs sec to install)"; echo
}

install

# vim: set ts=4 sts=4 sw=4 tw=0:
