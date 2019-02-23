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
#USER=user
OUT_SUBDIR=scans # output directory, samba share, relative to $USER home dir
DOC_LANG="deu+eng" # tesseract OCR languages
CMD="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
# set up some paths
SCRIPT_PATH="$(readlink -f "$0")"

userExists() # returns a 'true' return code if the user exists already
{
    if [ x"$USER"x = x"$(whoami)"x ]; then
        /bin/true
    else
        sudo -u $USER /bin/true
    fi
}

getOutdir()
{
    # make local subdir in scan user $HOME absolute
    PREFIX=""
    [ x"$USER"x = x"$(whoami)"x ] || PREFIX="sudo -u $USER"
    outdir="$($PREFIX sh -c "cd;
        mkdir -p '$OUT_SUBDIR'; cd '$OUT_SUBDIR'; pwd" 2> /dev/null)"
    printf %s "$outdir"
}

if ! userExists && [ x"$CMD"x != xinstallx ]; then
    echo "Configured user '$USER' does not exist, please run 'install' first."
    exit 1
fi

# output directory for resulting PDF files
OUT_DIR="$(getOutdir)"
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

if [ -d "$OUT_DIR" ]; then # skipped in install mode
    # working directory for intermediate files such as scanned images
    # a persistent location, preferably not in /tmp to survive crash/reboot
    WORK_DIR="$OUT_DIR/work"
    # common queue for multiple instances
    QUEUEFN="$WORK_DIR/queue"
    LOG_DIR="$OUT_DIR/log"
fi
TIMESTAMPFN="$(mktemp)"
TRJOBSFN="$(mktemp)"
SCAN_PREFIX="scan"
# command to replace illegal file name chars (Windows) by underscore (renameByContent())
SANITIZE='tr "/\\\\?<>:*|&" _'

delIntermediate() {
    return 0; # debug is on
    return 1; # debug is off
}

logSubDir() {
    PREFIX="$1"
    TS="$2"
    echo "$LOG_DIR/$TS $PREFIX"
}

timestamp() {
    PREFIX="$1"
    TS="$(date '+%Y-%m-%d_%H-%M-%S')"
    # prevent identical time stamps by succeeding calls
    LAST_TS="$(cat "$TIMESTAMPFN")"
    if [ ! -z "$LAST_TS" ] && [ "$LAST_TS" == "$TS" ]; then
        while [ "$LAST_TS" == "$TS" ]; do
            NS="$(date +%N)"
            TS="${TS}-${NS:0:3}"
        done
    else
        echo "$TS" > "$TIMESTAMPFN"
    fi
    SUBDIR="$(logSubDir "$PREFIX" "$TS")"
    mkdir -p "$SUBDIR"
    LOG_FILE="$SUBDIR/${PREFIX}.log"
    # echo "$PREFIX $TS"
    echo "$PREFIX $TS > '$LOG_FILE' 2>&1"
}

imageWithCaption() {
    VSPACE="$1"
    echo "\thispagestyle{empty} \begin{center} \vspace*{${VSPACE}mm}
        \includegraphics[width=0.3\textwidth]{qrcode.png} \\\\
        {\huge $QRDESCR \\ ($QRCMD, ${RESOLUTION}dpi, farbe)} \end{center}"
}

createCommand() {
    echo "  ############# createCommand $1 #############"
    PREFIX="$1"
    QRCMD="$2"
    QRDESCR="$3"
    QR_DIR=$(mktemp -d)
    echo "Using working dir: '$QR_DIR'"
    cd "$QR_DIR" || return
    qrencode -s 5 -d 300 -l H -o qrcode.png "$QRCMD"
    # latex document
    cat > "qrcode.tex" << EOF
%-*- coding: utf-8; -*-
\documentclass[a4paper]{scrartcl}
\usepackage[utf8]{inputenc}
\usepackage[german]{babel}
\usepackage{graphicx}
\usepackage{geometry}
\geometry{a4paper, bindingoffset=0mm, left=20mm,right=20mm, top=20mm, bottom=20mm}
\begin{document}
$(imageWithCaption 10)
$(imageWithCaption 90)
\newpage
$(imageWithCaption 10)
$(imageWithCaption 90)
\end{document}
EOF
    pdflatex qrcode
    QRPDF="$QR_DIR/qrcode.pdf" # expected result pdf file
    if [ ! -f "$QRPDF" ]; then
        echo "No PDF was created: '$QRPDF'!"
        return 1
    fi;
    DEST_DIR="$OUT_DIR/$PREFIX"
    mkdir -p "$DEST_DIR"
    mv "$QRPDF" "$DEST_DIR/$QRCMD.pdf"
    echo "created qr command sheet: $QRCMD"
    delIntermediate || rm -Rf "$QR_DIR"
}

createCommandSheets() {
    echo "createCommandSheets $*"
    PREFIX="$1"
    createCommand "$PREFIX" multi \
        "Alle folgenden Blätter werden zu einem Dokument zusammengefasst.";
    createCommand "$PREFIX" single \
        "Jedes folgende Blatt wird ein einzelnes Dokument.";
}

classifyImg() {
    echo "classifyImg $*"
    INFN="$1"
    TMPFN=$(mktemp --tmpdir="$(pwd)" "test_XXXXXXXX.tif")
    chmod a+rx "$TMPFN"

    RATIO=0.14
    PIXCOUNT=$(convert "$INFN" -format "%[fx:w*h]" info:)
    PIXCOUNT=$(python -c "print(int($PIXCOUNT))")
    # calculate target pixel count, approx. 1M for 300dpi
    PIXCOUNT_A4=$(python -c "print(int(($RESOLUTION*210./25.4) * ($RESOLUTION*297./25.4) * $RATIO))")
    RESIZECMD=""
    echo "$INFN: pix count: $PIXCOUNT, target: $PIXCOUNT_A4"
    if [ ! -z "$PIXCOUNT" ] && [ ! -z "$PIXCOUNT_A4" ] && [ "$PIXCOUNT" -gt "$PIXCOUNT_A4" ]; then
        RESIZECMD="-resize $PIXCOUNT_A4@"
        echo "$INFN -> resizing by '$RESIZECMD'"
    else
        echo "$INFN -> ok."
    fi;

    convert "$INFN" -shave 10%x5% $RESIZECMD -blur 3x1.5 -threshold 20% \
        -fuzz 10% -trim +repage "$TMPFN"
    # old setting had probs with thin paper, text shining through
    # TME invoice Feb-2014
    # convert "$INFN" -shave 4%x4% $RESIZECMD -threshold 10% \
    #    -fuzz 20% -trim +repage $TMPFN 2> /dev/null
    PIXCOUNT_LEFT=$(convert "$TMPFN" -format "%[fx:w*h]" info:)
    PIXCOUNT_LEFT=$(python -c "print(int($PIXCOUNT_LEFT))")
    echo -n "$INFN: Test img pix count left: '$PIXCOUNT_LEFT' -> "
    if [ ! -z "$PIXCOUNT_LEFT" ] && [ "$PIXCOUNT_LEFT" -lt 100 ]; then
        # with less than 100 pix left, it's blank
#    if (convert $TMPFN info: | grep -q '1x1'); then
        echo "blank"
        mv "$INFN" "$INFN.blank"
    else
        echo "checking for command code"
        MODE="$(zbarimg -q --raw "$TMPFN")"
        if [ "$MODE" == "multi" ]; then
            mv "$INFN" "$INFN.multi"
        elif [ "$MODE" == "single" ]; then
            mv "$INFN" "$INFN.single"
        fi;
    fi;
    rm -f "$TMPFN"
}

getTmpDir() {
    PREFIX="$1"
    TEMPDIR="$(mktemp -d --tmpdir="$WORK_DIR" "${PREFIX}_XXXXXXXX")"
    chmod -fR a+rx "$TEMPDIR"
    echo "$TEMPDIR"
}

queueHead() {
    PID="$(head -n 1 "$QUEUEFN" | awk '{print $1}')"
    [ -z "$PID" ] && PID=0
    echo "$PID"
}

# extract text from pdf including bounding boxes for additional processing (TODO)
renameByContent() {
    OUTFILE="$1"
    TEXTFILE="$2"
    PYCONVERT=$(cat << EOF
import sys, datetime;
def convInt(x, width = 2):
    try:
        x = abs(int(x))
        if width == 4 and x < 100:
            cur = datetime.datetime.now().year % 100
            if x <= cur:
                x += 2000
            else:
                x += 1900
        x = str("{0:0" + str(width) + "d}").format(x)
    except:
        pass
    return x
y, m, d = sys.argv[1:]
print(convInt(y, 4) + "-" + convInt(m) + "-" + convInt(d))
EOF
)
    # pdftotext -bbox "$OUTFILE" "$TEXTFILE"
    pdftotext -layout "$OUTFILE" "$TEXTFILE"
    # get the first word in plain text, replace illegal chars
    #WORD="$(egrep '^\s+<word' "$TEXTFILE" | \
    #        awk -F'>' '{print $2}' | \
    #        awk -F'<' '{print $1}' | \
    #        head -n 1 | $SANITIZE )"
    WORD="$(head -n 1 "$TEXTFILE" | sed -e 's/^\s*//' -e 's/\s*$//' | $SANITIZE)"
    if [ ! -z "$WORD" ]; then
        # use the first 3 words and limit to 20 chars
        WORD="$(echo "$WORD" | grep -Eo '^(\<\w+\>\s*)?(\<\w+\>\s*)?(\<\w+\>\s*)?')"
        WORD="${WORD:0:20}"
        echo "extracted text: '$WORD'"
        # TODO:
        # - multiple date formats: dd.mm.yyyy (currently)
        #   but also: dd-mm-yyyy, yyyy-mm-dd, dd/mm/yyyy
        # - cut name length on word boundaries, trim whitespace after trimming!
        # - detect invoice number?
        #DATE="$(egrep -o '[0-9]?[0-9]\.[0-9]?[0-9]\.[0-9]?[0-9]?[0-9][0-9]' $TEXTFILE | head -n 1)"
        REGEX='[^0-9]([0-9]?[0-9])[-/\. ]([0-9]?[0-9])[-/\. ]([0-9]?[0-9]?[0-9][0-9])'
        [[ "$(cat "$TEXTFILE")" =~ $REGEX ]]
        [ -z "$BASH_REMATCH" ] || DATE="$(python -c "$PYCONVERT" \
            "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}")"
        # prepending date in iso format, if any
        [ -z "$DATE" ] || WORD="$DATE $WORD"
        # trim leading&trailing whitespace
        WORD="$(echo -e "${WORD}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$WORD" ] && return # nothing to rename to
        # save with new file name if it doesn't exist already
        OUTDIR="$(dirname "$OUTFILE")"
        NEWFN="$OUTDIR/$WORD.pdf"
        [ -e "$NEWFN" ] && NEWFN="${OUTFILE%*.pdf} $WORD.pdf"

        # move result PDF to final destination
        # include first word from doc in name, limit its length
        mv "$OUTFILE" "$NEWFN"
    fi;
}

queryJobCount() {
    jobs > "$TRJOBSFN"
}
getJobCount() {
    wc -l "$TRJOBSFN" | cut -d' ' -f1
}

st2pdf() {
    local outfile; outfile="$1"
    shift # do not loop over output file below
    local cpu_count;
    cpu_count=$(grep -c processor < /proc/cpuinfo)

    for fn in "$@"; do
        [ -f "$fn" ] || continue
        echo "Processing '$fn' ..."
        #sleep 1 &
        tesseract -l $DOC_LANG "$fn" "$fn" pdf &
        # job management
        queryJobCount
        while [ "$(getJobCount)" -ge "$cpu_count" ]; do
            sleep 1; queryJobCount
            echo "jc: '$(getJobCount)' '$cpu_count' "
        done
    done

    wait # wait for all jobs to finish
    rm "$TRJOBSFN"

    #-dPDFSETTINGS=/screen   (screen-view-only quality, 72 dpi images)
    #-dPDFSETTINGS=/ebook    (low quality, 150 dpi images)
    #-dPDFSETTINGS=/printer  (high quality, 300 dpi images)
    #-dPDFSETTINGS=/prepress (high quality, color preserving, 300 dpi imgs)
    #-dPDFSETTINGS=/default  (almost identical to /screen)

    eval gs -dPDFSETTINGS=/default \
        -sColorImageDownsampleType=Bicubic \
        -sGrayImageDownsampleType=Bicubic \
        -sMonoImageDownsampleType=Bicubic \
        -dColorImageDepth=2 \
        -dGrayImageDepth=2 \
        -dMonoImageDepth=2 \
        -sEncodeColorImages=true \
        -sEncodeGrayImages=true \
        -sEncodeMonoImages=true \
        -sColorImageFilter=DCTEncode \
        -sGrayImageFilter=DCTEncode \
        -sMonoImageFilter=CCITTFaxEncode \
        -dCompatibilityLevel=1.7 -dNOPAUSE -dBATCH -sDEVICE=pdfwrite \
        -o "$outfile" \
        $(for fn in "$@"; do printf "'%s.pdf' " "$fn"; done)
    for fn in "$@"; do rm -f "$fn.pdf"; done
}

# processes each document dir containing images and creates a ocr'd PDF file
processDoc() {
    DOC_DIR="$1"
    PREFIX="$2"
    TS="$3"
    STARTTIME=$(date +%s)
    echo "processDoc $*"
    # check if given document exists
    if [ ! -d "$DOC_DIR" ]; then
        echo "processDoc: Given document dir '$DOC_DIR' does not exist!"
        return;
    fi;
    cd "$DOC_DIR" || return
    SCANS="${SCAN_PREFIX}_*.tif"
    if [ -z "$(ls $SCANS 2> /dev/null)" ]; then
        echo "processDoc: No scans found in '$DOC_DIR', skipping!"
        return;
    fi;
    # add us to the queue and wait
    echo "$BASHPID $*" >> "$QUEUEFN"
    # stop this process if another is currently active
    [ "$(queueHead)" -ne "$BASHPID" ] && kill -STOP "$BASHPID"

    echo "
    ############## Converting to PDF ##############
    "
    mkdir -p out_st
    local textArgs="--normalize-illumination --skew-deviation=10.0"
#    textArgs="--rotate=0.0"
    scantailor-cli \
            --dpi=$RESOLUTION --output-dpi=$RESOLUTION \
            --layout=1 \
            --disable-content-detection --enable-auto-margins \
            --enable-page-detection \
            --white-margins \
            $textArgs \
            --color-mode=color_grayscale \
            --tiff-force-keep-color-space \
            $SCANS out_st

    # Use tiffcp to combine output tiffs to a single mult-page tiff
    tiffcp out_st/$SCANS combined.tif
    # Convert the tiff to PDF
    tiff2pdf -j -q 90 combined.tif > combined.pdf
    # fix pink color bug when using jpeg compression
    sed -i'' -e 's/\/DecodeParms << \/ColorTransform 0 >>//g' combined.pdf
    # move result (PDF containing images only) to output dir
    SUBDIR="$(logSubDir "$PREFIX" "$TS")"
    mv combined.pdf "$SUBDIR/img.pdf"

    echo "
    ################ OCR ################
    "
    OUTFILE="$OUT_DIR/$TS.pdf"
    st2pdf "$OUTFILE" $(ls out_st/$SCANS)

    renameByContent "$OUTFILE" "$SUBDIR/text.txt"

    echo "
    ################ Cleaning Up ################
    "
    cd ..
    delIntermediate || rm -Rf "$DOC_DIR"

    ELAPSED=$(($(date +%s)-STARTTIME))
    echo " Finished processDoc '$*' '$BASHPID' $(date) after ${ELAPSED}s"
    # remove this PID from queue, wake up the next
    echo "==bef=="
    cat "$QUEUEFN"
    grep -v "^$BASHPID" "$QUEUEFN" > "$QUEUEFN.tmp"
    mv "$QUEUEFN.tmp" "$QUEUEFN"
    echo "==aft=="
    cat "$QUEUEFN"
    [ "$(queueHead)" -eq 0 ] && return; # empty queue
    echo " Waking up $(head -n1 "$QUEUEFN")"
    kill -CONT "$(queueHead)"
}

removeDeskewArtifacts() {
    FN="$1"
    XMAX="$(convert -format "%[fx:w-1]" "$FN" info:)"
    YMAX="$(convert -format "%[fx:h-1]" "$FN" info:)"
    [ -z "$XMAX" ] || [ -z "$YMAX" ] && return
    SCANBCKG="rgb(213,220,220)"
    SHAVEPX=$((RESOLUTION/10)) # 10th of an inch == 2.5mm
#    cp "$FN" /tmp/ # for debugging
    mogrify -fill "$SCANBCKG" \
        -floodfill +$XMAX+0     black \
        -floodfill +$XMAX+$YMAX black \
        -floodfill +0+$YMAX     black \
        -floodfill +0+0         black \
        -fuzz 10% -trim +repage -shave ${SHAVEPX}x${SHAVEPX} \
        -brightness-contrast 7x7 \
        "$FN"
}

batchScan() {
    PREFIX="$1"
    TS="$2"

    # test required file/directory permissions
    [ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"
    if [ ! -w "$OUT_DIR" ]; then
        echo "Current user '$(whoami)' does not have write"\
             "permissions for output directory '$OUT_DIR'!"
        exit 1
    fi;
    if [ ! -e "$WORK_DIR" ]; then
        mkdir -p "$WORK_DIR";
        chmod a+rx "$WORK_DIR"
    fi;
    if [ ! -w "$WORK_DIR" ]; then
        echo "Current user '$(whoami)' does not have write"\
             "permissions for work directory '$WORK_DIR'!"
        exit 1
    fi;

    LOCKFILE="$WORK_DIR/$PREFIX"
    if ! lockfile-create --retry 1 "$LOCKFILE"; then
        echo "Error: scanning already in progress!"
        exit
    fi;
    echo " batchScan '$*' started on dev '$DEVICE_NAME'"
    SCAN_DIR="$(getTmpDir "$PREFIX")"
    cd "$SCAN_DIR" || return
    echo "
    ################## Scanning ###################
    "
    PATTERN="${PREFIX}_%03d.tif"
    # always scanning both side of a sheet, 2 images/sheet
    (scanimage \
            -d "$DEVICE_NAME" \
            --source 'ADF Duplex' \
            --mode Color \
            --resolution $RESOLUTION \
            --ald=yes --overscan On \
            --page-width $WIDTH -x $WIDTH \
            --page-height $HEIGHT -y $HEIGHT \
            --swdeskew=yes --swcrop=yes \
            --format=tiff --batch="$PATTERN" \
    ) & # scan in background

    # first idx in dir: $(($(ls -1 scan_*.tif | head -n 1 | egrep -o '[[:digit:]]+')));
    IDX=1
    LASTSCANTIME=$(date +%s)
    CURRENT_MODE=single
    # wait max $SCANTIMEOUT seconds for scanned images files to show up
    while [ "$(($(date +%s)-LASTSCANTIME))" -lt $SCANTIMEOUT ];
    do
        echo " .. $(($(date +%s)-LASTSCANTIME))/${SCANTIMEOUT}s since last scan"
        sleep 1; # check for results in 1sec intervals
        # wait for the first 2 pages becoming available, check expected file names
        FN1="$(printf "$PATTERN" $((IDX)))"
        FN2="$(printf "$PATTERN" $((IDX+1)))"
        if [ ! -f "$FN1" ] || [ ! -f "$FN2" ]; then continue; fi;

        removeDeskewArtifacts "$FN1"
        removeDeskewArtifacts "$FN2"

        # evaluate: qr, blank or sth else?
        classifyImg "$FN1" &
        FN1PID=$!
        classifyImg "$FN2" &
        FN2PID=$!
        echo " waiting for classifyImg PIDs: $FN1PID $FN2PID"
        wait $FN1PID $FN2PID

        # on mode switch create new temp dir, move there all files
        if [ -f "$FN1.single" ] || [ -f "$FN2.single" ]; then
            CURRENT_MODE=single
            rm -f "$FN1" "$FN2" # remove scans of mode sheet
        elif [ -f "$FN1.multi" ] || [ -f "$FN2.multi" ]; then
            CURRENT_MODE=multi
            rm -f "$FN1" "$FN2" # remove scans of mode sheet
            # in multi mode: create a new document on mode switch only
            [ -z "$DOC_DIR" ] || eval processDoc "$DOC_DIR" "$(timestamp doc)" &
            DOC_DIR="$(getTmpDir doc)"
        fi;
        rm -f ./*.single ./*.multi ./*.blank
        # in single mode: always create a new document for every two pages
        if [ "$CURRENT_MODE" == single ] && [ -z "$DOC_DIR" ]; then
            DOC_DIR="$(getTmpDir doc)"
        fi
        # move scanned images to appropriate document directory
        if [ -f "$FN1" ] || [ -f "$FN2" ]; then
            echo " -> $CURRENT_MODE mode, moving $(ls "$FN1" "$FN2" 2> /dev/null) to '$DOC_DIR'."
            mv -f "$FN1" "$FN2" "$DOC_DIR" 2> /dev/null
        fi
        [ "$CURRENT_MODE" == single ] && eval processDoc "$DOC_DIR" "$(timestamp doc)" &
        
        ls -1; # show directory contents in log file
        IDX=$((IDX+2))
        LASTSCANTIME=$(date +%s)
    done

    # cleanup, scanimage may still run in case of paper jam
    killall scanimage 2> /dev/null # FIXME: remember scanimage PID for that?
    # the following would kill this running script as well -> not appropriate
    # local scriptDir="$(dirname $0)"
    # kill $(ps ax | grep "$scriptDir/.*\\.sh" | grep -v ' grep' \
    #              | awk '{print $1}')

    # process the last multi document
    [ "$CURRENT_MODE" == multi ] && [ ! -z "$DOC_DIR" ] && eval processDoc "$DOC_DIR" "$(timestamp doc)" &

    sleep 2
    # directory empty, remove it
    cd ..
    delIntermediate || rm -Rf "$SCAN_DIR"

    if [ -f "$QUEUEFN" ]; then
        echo " Done with scanning, current queue:"
        cat "$QUEUEFN"
    fi

    echo " finished batchScan '$*' '$BASHPID' $(date)"
    lockfile-remove "$LOCKFILE"
}

installPackages() {
    echo "==> Updating the system first:"
    sudo apt update -y
    sudo apt dist-upgrade -y
    echo "==> Installing additional software packages:"
    sudo apt install -y scanbd samba lockfile-progs imagemagick zbar-tools poppler-utils libtiff-tools scantailor dirmngr
    # set up debian backports, regular dirmngr from stretch is buggy (DNS)
    sudo mkdir -p /root/.gnupg
    sudo sh -c "echo standard-resolver > /root/.gnupg/dirmngr.conf"
    killall -q dirmngr
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys E0B11894F66AEC98
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 7638D0442B90D010
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 8B48AD6246925553
    codename="$(lsb_release -cs)"
    sudo sh -c "echo 'deb https://deb.debian.org/debian ${codename}-backports main contrib non-free' > /etc/apt/sources.list.d/debian-backports.list"
    sudo apt-get update -y
    echo "==> Installing selected and recent OCR packages:"
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
#    local fn="$1"
#    if [ ! -z "$fn" ] && [ -f "$fn" ]; then
#        echo "config_samba: '$fn'" 1>&2
#        content="$(cat "$fn")"
#    fi

    content="$(cfg '\[global\]' '')"
    content="$(cfg workgroup WORKGROUP '\[global\]')"
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
   unix extensions = no
EOF
)"

    echo "# Generated SAMBA configuration on $(date +'%Y-%m-%d %H:%M:%S')"
    echo "# by $SCRIPT_PATH"
    echo "$content"
}

configSys() {
    echo "==> Configuring the system:"
    if ! userExists; then
        echo " => Creating user '$USER' ..."
        sudo adduser --system --ingroup scanner --disabled-login --shell=/bin/false $USER
        sudo -u $USER sh -c "cd; mkdir $OUT_SUBDIR"
    fi
    OUT_DIR="$(getOutdir)"
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
    sambacfg="/etc/samba/smb.conf"
    sudo mv "$sambacfg" "$sambacfg.bckp_$(date +%Y%m%d%H%M%S)"
    configSamba > "$tmpfn"
    sudo mv "$tmpfn" "$sambacfg"
    sudo chown root.root "$sambacfg"
    sudo smbpasswd -L -a $USER
    sudo service smbd restart
}

if [ "$CMD" = "install" ]; then
    echo "Installing the scan script:"
    echo "outdir: '$OUT_DIR', work dir: '$WORK_DIR', log: '$LOG_DIR'"
    installPackages && configSys && \
    echo "==> done."

elif [ $# -gt 0 ]; then
    # for any arguments provided, create available qr command sheets
    eval createCommandSheets "$(timestamp command-sheets)"

else
    eval batchScan "$(timestamp $SCAN_PREFIX)"
    # do not wait, this would include processing of all documents as well
    # wait # for all children
    chmod -fR a+rx "$OUT_DIR"/*
    # do not remove the queue, next batch scan will append jobs
    # delIntermediate || rm -f "$QUEUEFN"
fi;

# remove timestamp file, if any
[ -z "$TIMESTAMPFN" ] || rm -f "$TIMESTAMPFN"

# vim: set ts=4 sts=4 sw=4 tw=0:
