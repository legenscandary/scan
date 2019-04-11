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
CFGFN="scan.conf"
CFGPATH="$SCRIPT_DIR/$CFGFN"
SCAN_DEVICE="$1" # first argument can be a scan device or a command
CMD="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
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

# decide if a scanned page is blank (it won't be entirely @255)
# check for a command sheet with QR code on it and interpret it
classifyImg()
{
    echo "classifyImg $*"
    local infn="$1"
    [ -f "$infn" ] || return
    local tmpfn; tmpfn=$(mktemp --tmpdir="$(pwd)" "test_XXXXXXXX.tif")
    chmod a+rx "$tmpfn"

    local testRatio=0.14 # percentage of nominal pixel count of an A4 page to keep
    # get pixel count in given image
    local pixcount; pixcount="$(convert "$infn" -format "%[fx:w*h]" info:)"
    pixcount="$(python -c "print(int($pixcount))")"
    # calculate target pixel count, approx. 1.2M for 300dpi
    local pixcountMax=1200000 # always same number, calculus below for reference
    [ -z "$pixcountMax" ] && pixcountMax="$(python -c "print(int(
        ($RESOLUTION*210./25.4) * ($RESOLUTION*297./25.4) * $testRatio))")"
    local resizecmd=""
    if [ ! -z "$pixcount" ] && [ ! -z "$pixcountMax" ] \
        && [ "$pixcount" -gt "$pixcountMax" ]; then
        resizecmd="-resize $pixcountMax@"
    fi
    # https://www.imagemagick.org/Usage/crop/#trim_blur
    # https://superuser.com/a/1257643
    convert "$infn" $resizecmd -shave 8%x5% \
        -virtual-pixel White -blur 0x10 -fuzz 15% -trim \
        +repage "$tmpfn" 2> /dev/null
    pixcount="$(convert "$tmpfn" -format "%[fx:w*h]" info:)"
    pixcount="$(python -c "print(int($pixcount))")"
    printf "%s: Test img pix count: %d -> " "$infn" "$pixcount"
    local move="mv"
    if [ ! -z "$pixcount" ] && [ "$pixcount" -lt 100 ]; then
        # with less than 100 pix left, it's blank
        printf "blank\n"
        $move "$infn" "$infn.blank"
    else
        printf "command code? "
        mode="$(zbarimg -q --raw "$tmpfn")"
        if [ "$mode" == "multi" ]; then
            $move "$infn" "$infn.multi"
            printf "multi!\n"
        elif [ "$mode" == "single" ]; then
            $move "$infn" "$infn.single"
            printf "single!\n"
        else
            printf "nope\n"
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

    TRJOBSFN="$(mktemp)"
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
    rm -f "$TRJOBSFN"

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
    [ -z "$DOC_DIR" ] && return # ignore missing doc dir, happens on startup
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

removeDeskewArtifacts()
{
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

batchScan()
{
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
    echo " batchScan '$*' started on dev '$SCAN_DEVICE'"
    SCAN_DIR="$(getTmpDir "$PREFIX")"
    cd "$SCAN_DIR" || return
    echo "
    ################## Scanning ###################
    "
    PATTERN="${PREFIX}_%03d.tif"
    # always scanning both side of a sheet, 2 images/sheet
    (scanimage \
            -d "$SCAN_DEVICE" \
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
    local DOC_DIR=""
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

        # on mode switch create new doc dir, move there all files
        if [ -f "$FN1.multi" ] || [ -f "$FN2.multi" ]; then
            CURRENT_MODE=multi
            rm -f "$FN1" "$FN2" # remove scans of mode sheet
            # TODO: check for empty DOC_DIR and skip possibly
            # queue processing of the previous document
            eval processDoc "$DOC_DIR" "$(timestamp doc)" &
            # create a new document on mode switch
            DOC_DIR="$(getTmpDir doc)"
        elif [ -f "$FN1.single" ] || [ -f "$FN2.single" ]; then
            rm -f "$FN1" "$FN2" # remove scans of mode sheet
            # process previous multi sheet doc possibly
            if [ "$CURRENT_MODE" != single ]; then
                eval processDoc "$DOC_DIR" "$(timestamp doc)" &
                DOC_DIR="$(getTmpDir doc)"
            fi
            CURRENT_MODE=single
        fi
        # create new doc dir on first run, later it is set after start of processing
        [ -z "$DOC_DIR" ] && DOC_DIR="$(getTmpDir doc)"
        rm -f ./*.single ./*.multi ./*.blank
        # move scanned images to current document dir
        if [ -f "$FN1" ] || [ -f "$FN2" ]; then
            echo " -> $CURRENT_MODE mode, moving $(ls "$FN1" "$FN2" 2> /dev/null) to '$DOC_DIR'."
            mv -f "$FN1" "$FN2" "$DOC_DIR" 2> /dev/null
            # process directly after copying in single mode
            if [ "$CURRENT_MODE" == single ]; then
                eval processDoc "$DOC_DIR" "$(timestamp doc)" &
                DOC_DIR="$(getTmpDir doc)"
            fi
        fi
        
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

    # process the last multi document, after timeout of scanning loop
    [ "$CURRENT_MODE" == multi ] && eval processDoc "$DOC_DIR" "$(timestamp doc)" &

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

userExists() # returns a 'true' return code if the user exists already
{
    id -u "$1" > /dev/null 2>&1
}

runInstallFirst()
{
    echo "Please run '$(ls install*.sh)' first."
}

main()
{
    # load config file, if there is any
    if [ ! -f "$CFGPATH" ]; then
        echo "Config file '$CFGPATH' not found!"
        runInstallFirst
        exit 1
    fi
    source "$CFGPATH"

    # check for the correct user
    if ! userExists "$SCANUSER"; then
        echo "Configured user '$SCANUSER' does not exist!"
        runInstallFirst
        exit 1
    fi
    if [ "$(whoami)" != "$SCANUSER" ]; then
        echo "Wrong user, this script expects to be run by user '$SCANUSER'!"
        runInstallFirst
        exit 1
    fi
    # output directory for resulting PDF files, expected in current users $HOME
    OUT_DIR="$(cd && cd "$OUT_SUBDIR" && pwd)"
    if [ ! -d "$OUT_DIR" ]; then
        echo "Could not determine output directory!"
        exit 1
    fi
    # working directory for intermediate files such as scanned images
    # a persistent location, preferably not in /tmp to survive crash/reboot
    WORK_DIR="$OUT_DIR/work"
    # common queue for multiple instances
    QUEUEFN="$WORK_DIR/queue"
    LOG_DIR="$OUT_DIR/log"
    TIMESTAMPFN="$(mktemp)"

    if [ "$CMD" = "sheets" ]; then
        # for any arguments provided, create available qr command sheets
        eval createCommandSheets "$(timestamp command-sheets)"
    else
        eval batchScan "$(timestamp $SCAN_PREFIX)"
        # do not wait, this would include processing of all documents as well
        # wait # for all children
        chmod -fR a+rx "$OUT_DIR"/*
        # do not remove the queue, next batch scan will append jobs
        # delIntermediate || rm -f "$QUEUEFN"
    fi

    # remove timestamp file, if any
    rm -f "$TIMESTAMPFN"
}

main

# vim: set ts=4 sts=4 sw=4 tw=0:
