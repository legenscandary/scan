#!/bin/bash
#

# set up some paths
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCANBD_DIR="/etc/scanbd"
SCANBD_SCRIPTS="$SCANBD_DIR/scripts"
SANE_CFG_PATH="/etc/sane.d"
REPO_PATH="$SCANBD_SCRIPTS/legenscandary"
CFGFN="scan.conf"
CFGPATH="$REPO_PATH/$CFGFN"
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
# 1: resets any custom changes to samba config after install
# 0: do not touch the samba config after install
SMB_RESET=1
# GIT repository for getting updates
REPO_URL='https://github.com/legenscandary/scan.git'

EOF
        sudo mv "$tmpfn" "$CFGPATH"
        sudo chmod 644 "$CFGPATH"
    fi
    source "$CFGPATH"
    userExists "$SCANUSER" \
        && [ -d "$REPO_PATH" ] \
        && sudo chown -R "$SCANUSER:saned" "$REPO_PATH"
}

#isSANEconfigNetworkOnly()
#{
#    local dll_conf; dll_conf="$SANE_CFG_PATH/dll.conf"
#    [ -f "$dll_conf" ] && [ -z "$(grep -v '^\s*net\s*$' "$dll_conf" | tr -d [:space:])" ]
#}

installPackages()
{
    local listfn="/etc/apt/sources.list.d/scantailor.list"
    # set -x # for debugging
    echo
    echo " => Add ScanTailor sources for pre-processing scans:"
    echo
    sudo sh -c "echo 'deb http://ports.ubuntu.com/ bionic main restricted universe multiverse' > $listfn"
    tmpfn="$(mktemp)"
    sudo apt-get update 2>&1 | sed -En 's/.*NO_PUBKEY ([[:xdigit:]]+).*/\1/p' | sort -u > "${tmpfn}"
    # store the new key in /usr/share/keyrings/
    cat "${tmpfn}" | xargs sudo gpg --keyserver "hkps://keyserver.ubuntu.com:443" --recv-keys
    cat "${tmpfn}" | xargs -L 1 sh -c 'sudo gpg --yes --output "/etc/apt/keyrings/$1.gpg" --export "$1"' sh
    sudo sh -c "echo 'deb [signed-by=/etc/apt/keyrings/$(cat "${tmpfn}" | tr -d [:space:]).gpg] http://ports.ubuntu.com/ bionic main restricted universe multiverse' > $listfn"
    rm "${tmpfn}"

    echo
    echo " => Updating system packages:"
    echo
    sudo apt-get update -y
    sudo apt-get dist-upgrade -y
    sudo apt-get install -y scantailor

    echo
    echo " => Installing additional software packages for image processing and file server:"
    echo
    sudo apt-get install -y git curl samba smbclient apg lockfile-progs imagemagick \
        zbar-tools ghostscript poppler-utils libtiff-tools sane-utils scanbd qrencode
    echo
    echo " => Installing additional software packages generating command sheets with LaTeX:"
    echo
    sudo apt-get install -y texlive-extra-utils texlive-fonts-recommended texlive-latex-extra \
        texlive-lang-english texlive-lang-german texlive-lang-french
#    # disable conflicting inetd config
#    sudo update-inetd --disable sane-port # inetd not needed, all handled by systemd
#    sudo service inetd restart

    # stop scanbd for buggy config, starts later after config
    sudo systemctl stop scanbd

    echo
    echo " => Installing selected OCR packages:"
    echo
    [ -z "$DOC_LANG" ] && DOC_LANG="eng" # minimal language, updated from config file later
    tess_lang_packs="$(IFS='+'; for l in $DOC_LANG; do echo tesseract-ocr-$l; done)"
    sudo apt-get install -y tesseract-ocr $tess_lang_packs
    # remove the previously added testing source to avoid trouble with apt and pckg dependencies
    sudo rm -f "$listfn"
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
    local pass; pass="$(apg -m 11 -n 1)"
    sudo sh -c "(echo "$pass"; echo "$pass") | smbpasswd -s -L -a $SCANUSER"
    echo
    echo "Created SAMBA user '$SCANUSER' with password '$pass'"\
         "in workgroup '$SMB_WORKGROUP'."
    echo "Use it to connect to the new windows network share"
    echo
    echo "    \\\\$(hostname -f)\\$OUT_SUBDIR"
    echo
    echo "where all scanned documents will be stored."
    echo
    echo " => To change the password later on, run:"
    echo
    echo "    sudo smbpasswd -L -a $SCANUSER"
    echo "    sudo service smbd restart"
    echo
    sudo service smbd restart
}

# working config on raspbian 10 (buster):
# - sane with full default `dll.conf`
# - scanbd: copy over `/etc/sane.d/dll.conf` without `net` backend
#   - `/etc/scanbd/scanbd.conf`: user group has to be `saned`
#     (scanner not found otherwise)
#   - dropping privileges to user specified in /etc/scanbd/scanbd.conf works now
# - test with `whoami` and `scanimage -L` in /etc/scanbd/scripts/test.script
configSys()
{
    local tmpfn
    echo
    echo " => Configuring the system:"
    if ! userExists "$SCANUSER"; then
        echo " => Creating user '$SCANUSER' ..."
        sudo adduser --system --ingroup saned --disabled-login --shell=/bin/false \
            --home "/home/$SCANUSER" "$SCANUSER"
        sudo -u "$SCANUSER" sh -c "cd; mkdir $OUT_SUBDIR"
    fi
    # assuming user exists now, create OUT_DIR
    OUT_DIR="$(sudo -u "$SCANUSER" sh -c "cd;
        mkdir -p '$OUT_SUBDIR'; cd '$OUT_SUBDIR'; pwd" 2> /dev/null)"
    # configure sane, let it use the net backend only, in favor of scanbd/scanbm
#    if cd /etc/sane.d/; then
#        if [ -z "$(find dll.d -type d -empty)" ]; then
#            # move external sane config files somewhere else if there are any
#            sudo mkdir -p dll.disabled && sudo mv dll.d/* dll.disabled/
#        fi
#        # make sure only the net backend is enabled in sane config, disable original config
#        isSANEconfigNetworkOnly || sudo mv dll.conf "dll.disabled_$(getts).conf"
#        sudo sh -c 'echo net > dll.conf'
#        # configure sanes net backend, make sure required settings are present
#        local netcfgfn="net.conf" # configure net-backend
#        grep -q legenscandary "$netcfgfn" || sudo sh -c "echo '## configuration by legenscandary:' >> $netcfgfn"
#        grep -q '^connect_timeout' "$netcfgfn" || sudo sh -c "echo 'connect_timeout = 3' >> $netcfgfn"
#        grep -q '^localhost' "$netcfgfn" || sudo sh -c "echo 'localhost' >> $netcfgfn"
#    fi
    # configure scanbd
    echo " => Setting up scanbd ..."
    if [ ! -d "$SCANBD_DIR" ]; then
        echo "scanbd config path '$SCANBD_DIR' not found!"
        return 1
    fi
    # create dummy saned config for scanbd to prevent warning msg
    [ -f "$SCANBD_DIR/saned.conf" ] || sudo touch "$SCANBD_DIR/saned.conf"
    # replace buggy scanbd dll.conf (contains parport devices) with one from sane, w/o net backend
    sudo cp -v /etc/sane.d/dll.conf "$SCANBD_DIR"/ && \
    sudo sed -i -e 's/^\(net\)/#\1 # disabled for use with scanbd/' "$SCANBD_DIR/dll.conf"
    sudo sed -i -e 's/^\(escl\)/#\1 # disabled for use with scanbd/' "$SCANBD_DIR/dll.conf"
    # create script to be called on button press
    local scriptPath="$SCANBD_SCRIPTS/test.script"
    sudo mkdir -p "$SCANBD_SCRIPTS"
    tmpfn="$(mktemp)"
    cat > "$tmpfn" <<EOF
#!/bin/sh
logger -t "scanbd: \$0" "Begin of \$SCANBD_ACTION for device \$SCANBD_DEVICE"
$SCRIPT_DIR/scan.sh "\$SCANBD_DEVICE"
logger -t "scanbd: \$0" "End   of \$SCANBD_ACTION for device \$SCANBD_DEVICE"
EOF
    chmod 755 "$tmpfn"
    sudo mv "$tmpfn" "$scriptPath"
    sudo chown root:root "$scriptPath"
    sudo chown -R "$SCANUSER:saned" "$SCRIPT_DIR" # let the user own it who runs the script
    # change default user in scanbd.conf
    sudo sed -i -e 's/^\(\s*user\s*=\)\s*\w\+$/\1 '$SCANUSER'/' "$SCANBD_DIR/scanbd.conf"
    # set group in scanbd config
    sudo sed -i -e 's/^\(\s*group\s*=\)\s*\w\+$/\1 saned/' "$SCANBD_DIR/scanbd.conf"
    # restart scanbd automatically on exit/segfault
    local scanbd_svc; scanbd_svc="/lib/systemd/system/scanbd.service"
    grep -q 'Restart=always' "$scanbd_svc" || sudo sed -i -e '/\[Service\]/ aRestart=always' "$scanbd_svc"
    grep -q 'RestartSec=5'   "$scanbd_svc" || sudo sed -i -e '/\[Service\]/ aRestartSec=5'   "$scanbd_svc"
    sudo sed -i -e 's/\(^Also.\+scanbm.socket\)/#\1/g' "$scanbd_svc"
    sudo systemctl stop scanbm.socket
    sudo systemctl disable scanbm.socket
    sudo systemctl daemon-reload
    sudo service scanbd restart
#    # disable conflicting inetd config
#    sudo update-inetd --disable sane-port # inetd not needed, all handled by systemd
#    sudo service inetd restart
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
    sudo chown root:root "$cronPath"

    if [ "$SMB_RESET" -ne 0 ]; then
        # configure samba with a share for the OUT_DIR
        echo " => Configuring the samba file server:"
        echo
        sambacfg="/etc/samba/smb.conf"
        sudo mv "$sambacfg" "$sambacfg.bckp_$(getts)"
        configSamba > "$tmpfn"
        sudo mv "$tmpfn" "$sambacfg"
        sudo chown root:root "$sambacfg"
    fi
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
    loadConfig # this creates config file in repo dir if missing

    if [ -d ".git" ]; then # a git repo yet, update scripts?
        sudo chown -R "$USER" .
        # stash dirty work dir first
        [ -z "$(git config user.name)" ] && git config user.name "$USER"
        [ -z "$(git config user.email)" ] && git config user.email "$USER@$(hostname -f)"
        git stash save
        git pull       # update work dir
        git stash pop
        userExists "$SCANUSER" && sudo chown -R "$SCANUSER:saned" .
    elif [ ! -f "$installScript" ]; then # empty dir possibly
        if [ -z "$REPO_URL" ]; then
            echo "Repository URL empty! Nothing to do."
        else # clone, but it must be empty
            sudo chown "$USER" .
            local tmpdir; tmpdir="$(mktemp -d)"
            find . -maxdepth 1 -mindepth 1 -exec sudo mv {} "$tmpdir/" \;
            git clone "$REPO_URL" .
            mv "$tmpdir/"* .; rmdir "$tmpdir"
            sudo chown -R "$SCANUSER:saned" .
        fi
    fi
    if [ ! -f "$installScript" ]; then # fall back to default name, e.g. if called from pipe
        installScript="$REPO_PATH/install+update.sh"
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

# vim: set ts=4 sts=4 sw=4 tw=0 et:
