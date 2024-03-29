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
PYTHON="python3"

delIntermediate()
{
    return 0; # debug is on
    return 1; # debug is off
}

logSubDir()
{
    local prefix="$1"
    local ts="$2"
    echo "$LOG_DIR/$ts $prefix"
}

timestamp()
{
    local prefix="$1"
    local ts; ts="$(date '+%Y-%m-%d_%H-%M-%S')"
    # prevent identical time stamps by succeeding calls
    local tsPrev; tsPrev="$(cat "$TIMESTAMPFN")"
    if [ ! -z "$tsPrev" ] && [ "$tsPrev" = "$ts" ]; then
        while [ "$tsPrev" = "$ts" ]; do
            # add milliseconds if timestamp exists already
            local ns; ns="$(date +%N)"
            ts="${ts}-${ns:0:3}"
        done
    else
        echo "$ts" > "$TIMESTAMPFN"
    fi
    local subdir; subdir="$(logSubDir "$prefix" "$ts")"
    mkdir -p "$subdir"
    local logFile="$subdir/${prefix}.log"
    # echo "$prefix $ts"
    echo "$prefix $ts > '$logFile' 2>&1"
}

imageWithCaption()
{
    local vspace="$1"
    echo "\thispagestyle{empty} \begin{center} \vspace*{${vspace}mm}
        \includegraphics[width=0.3\textwidth]{qrcode.png} \\\\
        {\huge $qrdesc \\ ($qrcmd, ${RESOLUTION}dpi, farbe)} \end{center}"
}

createCommand() {
    echo "  ############# createCommand $1 #############"
    local prefix="$1"
    local qrcmd="$2"
    local qrdesc="$3"
    local qrdir=$(mktemp -d)
    echo "Using working dir: '$qrdir'"
    cd "$qrdir" || return
    qrencode -s 5 -d 300 -l H -o qrcode.png "$qrcmd"
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
    local qrpdf="$qrdir/qrcode.pdf" # expected result pdf file
    if [ ! -f "$qrpdf" ]; then
        echo "No PDF was created: '$qrpdf'!"
        return 1
    fi;
    dstdir="$OUT_DIR/$prefix"
    mkdir -p "$dstdir"
    mv "$qrpdf" "$dstdir/$qrcmd.pdf"
    echo "created qr command sheet: $qrcmd"
    delIntermediate || rm -Rf "$qrdir"
}

createCommandSheets()
{
    echo "createCommandSheets $*"
    local prefix="$1"
    createCommand "$prefix" multi \
        "Alle folgenden Blätter werden zu einem Dokument zusammengefasst.";
    createCommand "$prefix" single \
        "Jedes folgende Blatt wird ein einzelnes Dokument.";
}

# decide if a scanned page is blank (it won't be entirely @255)
# check for a command sheet with QR code on it and interpret it
classifyImg()
{
    echo "classifyImg $*"
    local infn="$1"
    [ -f "$infn" ] || return

    local testRatio=0.14 # percentage of nominal pixel count of an A4 page to keep
    # get pixel count in given image
    local pixcount; pixcount="$(convert "$infn" -format "%[fx:w*h]" info:)"
    pixcount="$($PYTHON -c "print(int($pixcount))")"
    # calculate target pixel count, approx. 1.2M for 300dpi
    local pixcountMax=1200000 # always same number, calculus below for reference
    [ -z "$pixcountMax" ] && pixcountMax="$($PYTHON -c "print(int(
        ($RESOLUTION*210./25.4) * ($RESOLUTION*297./25.4) * $testRatio))")"
    local resizecmd=""
    if [ ! -z "$pixcount" ] && [ ! -z "$pixcountMax" ] \
        && [ "$pixcount" -gt "$pixcountMax" ]; then
        resizecmd="-resize $pixcountMax@"
    fi
    local cropfn; cropfn=$(mktemp --tmpdir="$(pwd)" "crop_XXXXXXXX.tif")
    chmod a+rx "$cropfn"
    # https://www.imagemagick.org/Usage/crop/#trim_blur
    # https://superuser.com/a/1257643
    # resize only first, need this for QR interpretation later
    convert "$infn" $resizecmd -shave 8%x5% -colorspace gray "$cropfn"
    # get remaining pixel count and crop position (ROI)
    local pixcount geom
    read pixcount geom < <(convert "$cropfn" \
        -virtual-pixel White -blur 0x10 -fuzz 15% -trim \
        -format "%[fx:w*h] %[fx:w]x%[fx:h]+%[fx:page.x]+%[fx:page.y]" info: 2>/dev/null)
    pixcount="$($PYTHON -c "print(int($pixcount))")"
    printf "#pix %d, geom: %s -> " "$pixcount" "$geom"
    local move="mv"
    if [ ! -z "$pixcount" ] && [ "$pixcount" -lt 100 ]; then
        # with less than 100 pix left, it's blank
        printf "blank\n"
        $move "$infn" "$infn.blank"
    else
        mogrify -crop "$geom" "$cropfn"
        printf "command code? "
        mode="$(zbarimg -q --raw "$cropfn")"
        if [ "$mode" == "multi" ]; then
            printf "multi!\n"
            $move "$infn" "$infn.multi"
        elif [ "$mode" == "single" ]; then
            printf "single!\n"
            $move "$infn" "$infn.single"
        else
            printf "nope\n"
        fi;
    fi;
    rm -f "$cropfn" # disable this for debugging
}

getTmpDir()
{
    local prefix="$1"
    local tmpdir; tmpdir="$(mktemp -d --tmpdir="$WORK_DIR" "${prefix}_XXXXXXXX")"
    chmod -fR a+rx "$tmpdir"
    echo "$tmpdir"
}

queueHead()
{
    local pid; pid="$(head -n 1 "$QUEUEFN" | awk '{print $1}')"
    [ -z "$pid" ] && pid=0
    echo "$pid"
}

# extract text from pdf including bounding boxes for additional processing (TODO)
renameByContent()
{
    local outfn="$1"
    local textfn="$2"
    local pydateconv=$(cat << EOF
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
    # pdftotext -bbox "$outfn" "$textfn"
    pdftotext -layout "$outfn" "$textfn"
    # get the first word in plain text, replace illegal chars
    #word="$(egrep '^\s+<word' "$textfn" | \
    #        awk -F'>' '{print $2}' | \
    #        awk -F'<' '{print $1}' | \
    #        head -n 1 | $SANITIZE )"
    local word; word="$(head -n 1 "$textfn" | \
        sed -e 's/^\s*//' -e 's/\s*$//' | $SANITIZE)"
    if [ ! -z "$word" ]; then
        # use the first 3 words and limit to 20 chars
        word="$(echo "$word" | grep -Eo '^(\<\w+\>\s*)?(\<\w+\>\s*)?(\<\w+\>\s*)?')"
        word="${word:0:20}"
        echo "extracted text: '$word'"
        # TODO:
        # - multiple date formats: dd.mm.yyyy (currently)
        #   but also: dd-mm-yyyy, yyyy-mm-dd, dd/mm/yyyy
        # - cut name length on word boundaries, trim whitespace after trimming!
        # - detect invoice number?
        local docdate
        #docdate="$(egrep -o '[0-9]?[0-9]\.[0-9]?[0-9]\.[0-9]?[0-9]?[0-9][0-9]' $textfn | head -n 1)"
        local regex='[^0-9]([0-9]?[0-9])[-/\. ]([0-9]?[0-9])[-/\. ]([0-9]?[0-9]?[0-9][0-9])'
        [[ "$(cat "$textfn")" =~ $regex ]]
        [ -z "$BASH_REMATCH" ] || docdate="$($PYTHON -c "$pydateconv" \
            "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}")"
        # prepending date in iso format, if any
        [ -z "$docdate" ] || word="$docdate $word"
        # trim leading&trailing whitespace
        word="$(echo -e "${word}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$word" ] && return # nothing to rename to
        # save with new file name if it doesn't exist already
        local newfn; newfn="$(dirname "$outfn")/$word.pdf"
        [ -e "$newfn" ] && newfn="${outfn%*.pdf} $word.pdf"

        # move result PDF to final destination
        # include first word from doc in name, limit its length
        mv "$outfn" "$newfn"
    fi;
}

queryJobCount()
{
    jobs > "$TRJOBSFN"
}

getJobCount()
{
    wc -l "$TRJOBSFN" | cut -d' ' -f1
}

st2pdf()
{
    local outfile; outfile="$1"
    shift # do not loop over output file below
    local cpu_count; cpu_count=$(grep -c processor < /proc/cpuinfo)

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
processDoc()
{
    local docdir="$1"
    local prefix="$2"
    local ts="$3"
    [ -z "$docdir" ] && return # ignore missing doc dir, happens on startup
    echo "processDoc $*"
    renice 5 -u "$(whoami)" # lower process priority, this may take a while
    # check if given document exists
    if [ ! -d "$docdir" ]; then
        echo "processDoc: Given document dir '$docdir' does not exist!"
        return;
    fi;
    cd "$docdir" || return
    local scans="${SCAN_PREFIX}_*.tif"
    local fileCount; fileCount="$(ls -1 $scans 2> /dev/null | wc -l)"
    if [ -z "$fileCount" ] || [ "$fileCount" -lt 1 ]; then
        echo "processDoc: No scans found in '$docdir', skipping!"
        return;
    fi;
    # add us to the queue and wait
    echo "$BASHPID $*" >> "$QUEUEFN"
    # stop this process if another is currently active
    [ "$(queueHead)" -ne "$BASHPID" ] && kill -STOP "$BASHPID"

    # remember timestamp once we continue processing here
    local starttime; starttime="$(date +%s)"
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
            $scans out_st

    # Use tiffcp to combine output tiffs to a single mult-page tiff
    tiffcp out_st/$scans combined.tif
    # Convert the tiff to PDF
    tiff2pdf -j -q 90 combined.tif > combined.pdf
    # fix pink color bug when using jpeg compression
    sed -i'' -e 's/\/DecodeParms << \/ColorTransform 0 >>//g' combined.pdf
    # move result (PDF containing images only) to output dir
    local subdir; subdir="$(logSubDir "$prefix" "$ts")"
    mv combined.pdf "$subdir/img.pdf"

    echo "
    ################ OCR ################
    "
    local outfn="$OUT_DIR/$ts.pdf"
    st2pdf "$outfn" $(ls out_st/$scans)

    renameByContent "$outfn" "$subdir/text.txt"

    echo "
    ################ Cleaning Up ################
    "
    cd ..
    delIntermediate || rm -Rf "$docdir"

    local elapsed; elapsed=$(($(date +%s)-starttime))
    echo " Finished processDoc on $(date)."
    echo "  '$*' with PID '$BASHPID'"
    echo " Processed $fileCount pages in ${elapsed}s."
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
    local fn="$1"
    local xmax; xmax="$(convert -format "%[fx:w-1]" "$fn" info:)"
    local ymax; ymax="$(convert -format "%[fx:h-1]" "$fn" info:)"
    [ -z "$xmax" ] || [ -z "$ymax" ] && return
    local scanbckg="rgb(213,220,220)"
    local shavepx=$((RESOLUTION/10)) # 10th of an inch == 2.5mm
#    cp "$fn" /tmp/ # for debugging
    mogrify -fill "$scanbckg" \
        -floodfill +$xmax+0     black \
        -floodfill +$xmax+$ymax black \
        -floodfill +0+$ymax     black \
        -floodfill +0+0         black \
        -fuzz 10% -trim +repage -shave ${shavepx}x${shavepx} \
        -brightness-contrast 7x7 \
        "$fn"
}

batchScan()
{
    local prefix="$1"
    local ts="$2"

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

    local lockfn="$WORK_DIR/$prefix"
    if ! lockfile-create --retry 1 "$lockfn"; then
        echo "Error: scanning already in progress!"
        exit
    fi;
    echo " batchScan '$*' started on dev '$SCAN_DEVICE'"
    local scandir; scandir="$(getTmpDir "$prefix")"
    cd "$scandir" || return
    echo "
    ################## Scanning ###################
    "
    local pattern="${prefix}_%03d.tif"
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
            --format=tiff --batch="$pattern" \
    ) & # scan in background

    # first idx in dir: $(($(ls -1 scan_*.tif | head -n 1 | egrep -o '[[:digit:]]+')));
    local idx=1
    local lastScanTime; lastScanTime=$(date +%s)
    local currentMode=single
    local docdir=""
    local logdir; logdir="$(logSubDir "$prefix" "$ts")"
    # wait max $SCANTIMEOUT seconds for scanned images files to show up
    while [ "$(($(date +%s)-lastScanTime))" -lt $SCANTIMEOUT ];
    do
        echo " .. $(($(date +%s)-lastScanTime))/${SCANTIMEOUT}s since last scan"
        sleep 1; # check for results in 1sec intervals
        # wait for the first 2 pages becoming available, check expected file names
        local fn1; fn1="$(printf "$pattern" $((idx)))"
        local fn2; fn2="$(printf "$pattern" $((idx+1)))"
        if [ ! -f "$fn1" ] || [ ! -f "$fn2" ]; then continue; fi;

        removeDeskewArtifacts "$fn1"
        removeDeskewArtifacts "$fn2"

        # evaluate: qr, blank or sth else?
        local classifyLog1="$logdir/${fn1%*.tif}.log"
        echo "classifyImg "$fn1" > '$classifyLog1'"
        classifyImg "$fn1" > "$classifyLog1" 2>&1 &
        local fn1PID=$!
        local classifyLog2="$logdir/${fn2%*.tif}.log"
        echo "classifyImg "$fn2" > '$classifyLog2'"
        classifyImg "$fn2" > "$classifyLog2" 2>&1 &
        local fn2PID=$!
        echo " waiting for classifyImg PIDs: $fn1PID $fn2PID"
        wait $fn1PID $fn2PID

        # on mode switch create new doc dir, move there all files
        if [ -f "$fn1.multi" ] || [ -f "$fn2.multi" ]; then
            currentMode=multi
            rm -f "$fn1" "$fn2" # remove scans of mode sheet
            # TODO: check for empty docdir and skip possibly
            # queue processing of the previous document
            eval processDoc "$docdir" "$(timestamp doc)" &
            # create a new document on mode switch
            docdir="$(getTmpDir doc)"
        elif [ -f "$fn1.single" ] || [ -f "$fn2.single" ]; then
            rm -f "$fn1" "$fn2" # remove scans of mode sheet
            # process previous multi sheet doc possibly
            if [ "$currentMode" != single ]; then
                eval processDoc "$docdir" "$(timestamp doc)" &
                docdir="$(getTmpDir doc)"
            fi
            currentMode=single
        fi
        # create new doc dir on first run, later it is set after start of processing
        [ -z "$docdir" ] && docdir="$(getTmpDir doc)"
        rm -f ./*.single ./*.multi ./*.blank
        # move scanned images to current document dir
        if [ -f "$fn1" ] || [ -f "$fn2" ]; then
            local fns; fns="$(find . -mindepth 1 -maxdepth 1 \
                -regex ".*\\($fn1\\|$fn2\\)" -printf '%p ')"
            echo " -> $currentMode mode, moving $fns to '$docdir'."
            mv -f "$fn1" "$fn2" "$docdir" 2> /dev/null
            # process directly after copying in single mode
            if [ "$currentMode" == single ]; then
                eval processDoc "$docdir" "$(timestamp doc)" &
                docdir="$(getTmpDir doc)"
            fi
        fi
        
        ls -1; # show directory contents in log file
        idx=$((idx+2))
        lastScanTime=$(date +%s)
    done

    # cleanup, scanimage may still run in case of paper jam
    killall scanimage 2> /dev/null # FIXME: remember scanimage PID for that?
    # the following would kill this running script as well -> not appropriate
    # local scriptDir="$(dirname $0)"
    # kill $(ps ax | grep "$scriptDir/.*\\.sh" | grep -v ' grep' \
    #              | awk '{print $1}')

    # process the last multi document, after timeout of scanning loop
    [ "$currentMode" == multi ] && eval processDoc "$docdir" "$(timestamp doc)" &

    sleep 2
    # directory empty, remove it
    cd ..
    delIntermediate || rm -Rf "$scandir"

    if [ -f "$QUEUEFN" ]; then
        echo " Done with scanning, current queue:"
        cat "$QUEUEFN"
    fi

    echo " finished batchScan '$*' '$BASHPID' $(date)"
    lockfile-remove "$lockfn"
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
    elif [ "$CMD" = "process" ]; then
		# process given document dir (can be used if earlier process of this doc was killed)
		shift
		processDoc $@
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

main $@

# vim: set ts=4 sts=4 sw=4 tw=0:
