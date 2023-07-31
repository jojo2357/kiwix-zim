#!/bin/bash

VER="3.0"

# This array will contain all of the local zims, with the file extension
LocalZIMArray=()
# This array will contain all of the local zims, without the file extension
LocalZIMNameArray=()
# This array will map the local zim to the index in the remote arrays that contains the same base file name
LocalZIMRemoteIndexArray=()
# This array is a boolean array which remembers if a given local zim shoud be processed in the download loop
LocalRequiresDownloadArray=()

# This array stores the file names that kiwix has to offer, with .zim extensions
RemoteFiles=()
# Ditto, without the YYYY-MM (note a trailing _)
Basenames=()
# Contains the absolute path to this file, from /zims/
RemotePaths=()
# Contains the folder this file is in relative to /zims/
RemoteCategory=()

# Set Script Strings
SCRIPT="$(readlink -f "$0")"
SCRIPTFILE="$(basename "$SCRIPT")"
SCRIPTPATH="$(dirname "$SCRIPT")"
SCRIPTNAME="$0"
ARGS=("$@")
BRANCH="main"
SKIP_UPDATE=0
DEBUG=1 # This forces the script to default to "dry-run/simulation mode"
MIN_SIZE=0
MAX_SIZE=0
CALCULATE_CHECKSUM=0
VERIFY_LIBRARY=0
BaseURL="https://download.kiwix.org/zim/"
ZIMPath=""

printToLogAndTerminal() {
  echo -e "$1"
  echo -e "$1" >> download.log
}

# This will ask the api what files it has to offer and store them in arrays
master_scrape() {
  unset RemoteFiles
  unset Basenames
  unset RemotePaths
  unset RemoteCategory

  RawLibrary=$(wget --show-progress -q -O - "https://library.kiwix.org/catalog/v2/entries?count=-1" | grep -i 'application/x-zim')

  IFS=$'\n' read -r -d '' -a FileSizes < <(echo "$RawLibrary" | grep -ioP '(?<=length=")\d+(?=")')
  unset IFS

  hrefs=$(echo "$RawLibrary" | grep -ioP "(?<=href=\")[\w:\/\-.]+(?=\.meta4\")" | grep -ioP "$BaseURL\K.*")

  IFS=$'\n' read -r -d '' -a RemoteFiles < <(echo "$hrefs" | grep -ioP "[^/]/\K[\w:\/\-.]+")
  unset IFS
  IFS=$'\n' read -r -d '' -a Basenames < <(echo "$hrefs" | grep -ioP "[^/]/\K[\w:\/\-.]+(?=\d{4}-\d{2}\.zim)")
  unset IFS
  IFS=$'\n' read -r -d '' -a RemotePaths < <(echo "$hrefs" | grep -ioP "^[\w:\/\-.]+")
  unset IFS # distinct from above for processing speed reasons
  IFS=$'\n' read -r -d '' -a RemoteCategory < <(echo "$hrefs" | grep -ioP "^[^/]+")
  unset IFS

  if [[ ${#RemoteFiles[@]} -eq 0 ]]; then
    printToLogAndTerminal "\033[0;31m    ✗  Could not find any remote files, exiting"
    exit 0
  else
    printToLogAndTerminal "\033[1;32m    ✓ Found ${#RemoteFiles[@]} files online"
  fi

  # Housekeeping...
  unset RawLibrary
  unset hrefs
}

# self_update - Script Self-Update Function
self_update() {
  printToLogAndTerminal "\033[1;33m1. Checking for Script Updates...\033[0m"
  echo
  # Check if script path is a git clone.
  #   If true, then check for update.
  #   If false, skip self-update check/funciton.
  if [ $SKIP_UPDATE -eq 1 ]; then
    printToLogAndTerminal "\033[0;33m   Check Skipped\033[0m"
  elif [[ -d "$SCRIPTPATH/.git" ]]; then
    printToLogAndTerminal "\033[1;32m   ✓ Git Clone Detected: Checking Script Version...\033[0m"
    cd "$SCRIPTPATH" || exit 1
    [[ $(timeout 1s git rev-parse --abbrev-ref HEAD) != "$BRANCH" ]] && echo -e "\033[1;33m     You appear to be on a different branch so I will assume you are developing and do not want an update\033[0m" && echo && return
    timeout 1s git fetch --quiet
    timeout 1s git diff --quiet --exit-code "origin/$BRANCH" "$SCRIPTFILE"
    [ $? -eq 1 ] && {
      printToLogAndTerminal "\033[0;31m   ✗ Version: Mismatched\033[0m"
      echo
      printToLogAndTerminal "\033[1;33m1a. Fetching Update...\033[0m"
      echo
      if [ -n "$(git status --porcelain)" ]; then
        git stash push -m 'local changes stashed before self update' --quiet
      fi
      git pull --force --quiet
      git checkout $BRANCH --quiet
      git pull --force --quiet
      printToLogAndTerminal "\033[1;32m   ✓ Update Complete. Running New Version. Standby...\033[0m"
      sleep 3
      cd - >/dev/null || exit 1

      # Execute new instance of the new script
      exec "$SCRIPTNAME" "${ARGS[@]}"

      # Exit this old instance of the script
      exit 1
    }
    echo -e "\033[1;32m   ✓ Version: Current\033[0m"
  else
    echo -e "\033[0;31m   ✗ Git Clone Not Detected: Skipping Update Check\033[0m"
  fi
  echo
}

# usage_example - Show Usage and Exit
usage_example() {
  echo 'Usage: ./kiwix-zim.sh <options> /full/path/'
  echo
  echo '    /full/path/                Full path to ZIM directory'
  echo
  echo 'Options:'
  echo '    -c, --calculate-checksum   Verifies that the downloaded files were not corrupted, but can take a while for large downloads.'
  echo '    -f, --verify-library       Verifies that the entire library has the correct checksums as found online.'
  echo '                               For this reason, a file `library.sha256` will be left in your library for running sha256sum manually'
  echo '    -d, --disable-dry-run      Dry-Run Override.'
  echo '                               *** Caution ***'
  echo
  echo '    -h, --help                 Show this usage and exit.'
  echo '    -p, --skip-purge           Skips purging any replaced ZIMs.'
  echo '    -u, --skip-update          Skips checking for script updates (very useful for development).'
  echo '    -n <size>, --min-size      Minimum ZIM Size to be downloaded.'
  echo '                               Specify units include M Mi G Gi, etc. See `man numfmt`'
  echo '    -x <size>, --max-size      Maximum ZIM Size to be downloaded.'
  echo '                               Specify units include M Mi G Gi, etc. See `man numfmt`'
  echo '    -l <location>, --location  Country Code to prefer mirrors from'
  echo
  exit 0
}

# flags - Flag and ZIM Processing Functions
flags() {
  printToLogAndTerminal "\033[1;33m2. Preprocessing...\033[0m"
  echo
  printToLogAndTerminal "\033[1;34m  -Validating ZIM directory...\033[0m"

  # Let's identify which argument is the ZIM directory path and if it's an actual directory.
  if [[ -d ${1} ]]; then
    if [[ -w ${1} ]]; then
      ZIMPath=$1
    else
      ZIMPath=$1
      printToLogAndTerminal "\033[0;31m  ✗ Cannot write to '${1}', continuing in dry-run\033[0m"
      echo
      DEBUG=1
    fi
  else # Um... no ZIM directory path provided? Okay, let's show the usage and exit.
    if [[ -z ${1} ]]; then
      printToLogAndTerminal "\033[0;31m  ✗ Kiwix ZIM Directory not provided\033[0m"
    else
      printToLogAndTerminal "\033[0;31m  ✗ '$1' is not a directory\033[0m"
    fi
    echo
    usage_example
  fi

  # Check for and add if missing, trailing slash.
  [[ "${ZIMPath}" != */ ]] && ZIMPath="${ZIMPath}/"

  # Now we need to check for ZIM files.
  shopt -s nullglob # This is in case there are no matching files

  # Load all found ZIM(s) w/path into LocalZIMArray
  IFS=$'\n' read -r -d '' -a LocalZIMArray < <(ls -1 "$ZIMPath" | grep -iP "\.zim$")
  unset IFS

  # Check that ZIM(s) were actually found/loaded.
  if [ ${#LocalZIMArray[@]} -eq 0 ]; then # No ZIM(s) were found in the directory... I guess there's nothing else for us to do, so we'll Exit.
    echo -e "\033[0;31m  ✗ No ZIMs found. Exiting...\033[0m"
    exit 0
  else
    echo -e "\033[1;32m  ✓ Valid ZIM Directory \033[0m"
  fi
  echo

  echo -e "\033[1;34m  -Building online ZIM list...\033[0m"

  # Build online ZIM list.
  master_scrape

  echo

  # Populate ZIM arrays from found ZIM(s)
  echo -e "\033[1;34m  -Parsing ZIM(s)...\033[0m"

  for ((i = 0; i < ${#LocalZIMArray[@]}; i++)); do                                             # Loop through local ZIM(s).
    LocalZIMNameArray[$i]=$(basename "${LocalZIMArray[$i]}")                                   # Extract file name.
    filename=$(basename "${LocalZIMArray[$i]}" | grep -ioP "[\w:\/\-.]+(?=\d{4}-\d{2}\.zim$)") # Extract file name.
    #        IFS='_' read -ra fields <<< "${LocalZIMNameArray[$i]}"; unset IFS  # Break the filename into fields delimited by the underscore '_'

    # Search MasterZIMArray for the current local ZIM to discover the online Root (directory) for the URL
    for ((z = 0; z < ${#Basenames[@]}; z++)); do
      if [[ ${Basenames[$z]} == "$filename" ]]; then # Match Found (ignore the filename datepart).
        LocalZIMRemoteIndexArray[$i]="$z"
        break
      else # No Match Found.
        LocalZIMRemoteIndexArray[$i]="-1"
      fi
    done

    if [[ LocalZIMRemoteIndexArray[$i] -eq -1 ]]; then
      echo -e "\033[0;31m    ✗ ${LocalZIMNameArray[$i]}  No online match found.\033[0m"
    else
      echo -e "\033[1;32m    ✓ ${LocalZIMNameArray[$i]}  [${RemoteCategory[${LocalZIMRemoteIndexArray[$i]}]}]\033[0m"
    fi
  done

  echo
  echo -e "\033[0;32m    ${#LocalZIMNameArray[*]} ZIM(s) found.\033[0m"
  echo
}

# mirror_search - Find ZIM URL Priority #1 mirror from meta4 Function
mirror_search() {
  IsMirror=0
  DownloadURL=""
  RemotePath="${RemotePaths[${LocalZIMRemoteIndexArray[$z]}]}"
  ExpectedSize="${FileSizes[${LocalZIMRemoteIndexArray[$z]}]}"

  # If we need the checksum, we need a link  and the hash, which we can get both by using .meta4, otherwise we only need
  # Silently fetch (via wget) the associated meta4 xml and extract the mirror URL marked priority="1"
  MetaInfo=$(wget -q -O - "$BaseURL$RemotePath.meta4?country=$COUNTRY_CODE")
  ExpectedSize=$(echo "$MetaInfo" | grep '<size>' | grep -Po '\d+')
  ExpectedHash=$(echo "$MetaInfo" | grep '<hash type="sha-256">' | grep -Poi '(?<="sha-256">)[a-f\d]{64}(?=<)')
  RawMirror=$(echo "$MetaInfo" | grep 'priority="1"' | grep -Po 'https?://[^ ")]+(?=</url>)')

  # Check that we actually got a URL (this could probably be done better). If no mirror URL, default back to direct URL.
  if [[ $RawMirror == *"http"* ]]; then # Mirror URL found
    DownloadURL="$RawMirror"            # Set the mirror URL as our download URL
    IsMirror=1
  else                                # Mirror URL not found
    DownloadURL="$BaseURL$RemotePath" # Set the direct download URL as our download URL
  fi
}

#########################
# Begin Script Execute
#########################

while [[ $# -gt 0 ]]; do
  case $1 in
    -h | --help)
      usage_example
      ;;
    -d | --disable-dry-run)
      DEBUG=0
      shift # discard argument
      ;;
    -v | --version)
      echo "$VER"
      exit 0
      ;;
    -p | --skip-purge)
      SKIP_PURGE=1
      shift # discard argument
      ;;
    -n | --min-size)
      shift                               # discard -n argument
      MIN_SIZE=$(numfmt --from=auto "$1") # convert passed arg to bytes
      shift                               # discard value
      ;;
    -x | --max-size)
      shift                               # discard -x argument
      MAX_SIZE=$(numfmt --from=auto "$1") # convert passed arg to bytes
      shift                               # discard value
      ;;
    -l | --location)
      shift # discard -l argument
      if [[ "$1" =~ ^[A-Z]{2}$ ]]; then
        COUNTRY_CODE=$1 # convert passed arg to bytes
      else
        COUNTRY_CODE=""
        echo "Invlaid country code, falling back to default kiwix behavior"
      fi
      shift # discard value
      ;;
    -c | --calculate-checksum)
      CALCULATE_CHECKSUM=1
      shift
      ;;
    -f | --verfiy-library)
      VERIFY_LIBRARY=1
      CALCULATE_CHECKSUM=1
      shift
      ;;
    -u | --skip-update)
      SKIP_UPDATE=1
      shift
      ;;
    *)
      # We can either parse the arg here, or just tuck it away for safekeeping
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift                   # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters that we skipped earlier

clear # Clear screen

# Display Header
echo "=========================================="
echo " kiwix-zim"
echo "       download.kiwix.org ZIM Updater"
echo
echo "   v$VER by DocDrydenn and jojo2357"
echo "=========================================="
echo
echo "            DRY-RUN/SIMULATION"
[[ $DEBUG -eq 1 ]] && echo "               - ENABLED -"
[[ $DEBUG -eq 1 ]] && echo
[[ $DEBUG -eq 1 ]] && echo "           Use '-d' to disable."
[[ $DEBUG -eq 0 ]] && echo "               - DISABLED -"
[[ $DEBUG -eq 0 ]] && echo
[[ $DEBUG -eq 0 ]] && echo "             !!! Caution !!!"
echo
echo "=========================================="
echo

# First, Self-Update Check.
# Shouldnt this be first? it is not dependent on anything else and resets everything, so may as well reset it before getting all invested?
self_update

# Second, Flag Check.
flags "$@"

echo
echo -e "\033[1;33m3. Processing ZIM(s)...\033[0m"
echo

AnyDownloads=0

for ((i = 0; i < ${#LocalZIMNameArray[@]}; i++)); do
  RemoteIndex=${LocalZIMRemoteIndexArray[$i]}
  if [[ $RemoteIndex -eq -1 ]]; then
    if [[ $VERIFY_LIBRARY -eq 1 ]] && [[ -f "$FileName.sha256" ]]; then
      LocalRequiresDownloadArray+=(3)
      AnyDownloads=1
      echo -e "\033[1;34m  - $FileName:\033[0m"
      echo -e "\033[0;32m    Cached Checksum Found\033[0m"
    else
      LocalRequiresDownloadArray+=(0)
    fi
    continue
  fi

  FileName=${LocalZIMNameArray[$i]}
  echo -e "\033[1;34m  - $FileName:\033[0m"
  [[ -f "$ZIMPath.~lock.$FileName" ]] && echo -e "\033[0;33m    Incomplete download detected\n\033[1;32m    ✓ Online Version Found\033[0m\n" && LocalRequiresDownloadArray+=(1) && AnyDownloads=1 && continue

  MatchingSize=${FileSizes[$RemoteIndex]}
  MatchingFileName=${RemoteFiles[$RemoteIndex]}
  MatchingFullPath=${RemotePaths[$RemoteIndex]}
  MatchingCategory=${RemoteCategory[$RemoteIndex]}

  FileTooSmall=0
  [[ $MIN_SIZE -gt 0 ]] && [[ $MatchingSize -lt $MIN_SIZE ]] && FileTooSmall=1
  FileTooLarge=0
  [[ $MAX_SIZE -gt 0 ]] && [[ $MatchingSize -gt $MAX_SIZE ]] && FileTooLarge=1
  FileSizeAcceptable=0
  [ $FileTooSmall -eq 0 ] && [ $FileTooLarge -eq 0 ] && FileSizeAcceptable=1

  if [ $VERIFY_LIBRARY -eq 1 ] && [ $FileSizeAcceptable -eq 0 ]; then
    if [ $FileTooSmall -eq 1 ]; then
      LocalRequiresDownloadArray+=(0)
      [[ $DEBUG -eq 0 ]] && echo -e "\033[0;32m    ✓ Verification skipped due to file size (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))\033[0m"
      [[ $DEBUG -eq 1 ]] && echo -e "\033[0;32m    ✓ *** Simulated ***  Verification skipped due to file size (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))\033[0m"
    elif [ $FileTooLarge -eq 1 ]; then
      LocalRequiresDownloadArray+=(0)
      [[ $DEBUG -eq 0 ]] && echo -e "\033[0;32m    ✓ Verification skipped due to file size (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))\033[0m"
      [[ $DEBUG -eq 1 ]] && echo -e "\033[0;32m    ✓ *** Simulated ***  Verification skipped due to file size (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))\033[0m"
    fi
  elif [[ "$MatchingFileName" == "$FileName" ]]; then
    if [ $VERIFY_LIBRARY -eq 1 ]; then
      LocalRequiresDownloadArray+=(1)
      AnyDownloads=1
      echo -e "\033[1;32m    ✓ Online Version Found\033[0m"
    else
      LocalRequiresDownloadArray+=(0)
      echo "    ✗ No new update"
    fi
  else
    if [ $VERIFY_LIBRARY -eq 1 ]; then
      if [[ -f "$ZIMPath$FileName.sha256" ]]; then
        LocalRequiresDownloadArray+=(2)
        AnyDownloads=1
        echo -e "\033[0;32m    Cached Checksum Found\033[0m"
      else
        echo "    Checking for online checksum..."
        if wget -S --spider -q -O - "$BaseURL$MatchingCategory/$FileName.sha256" >/dev/null 2>&1; then
          LocalRequiresDownloadArray+=(1)
          AnyDownloads=1
          echo -e "\033[1;32m    ✓ Online Version Found\033[0m"
        else
          LocalRequiresDownloadArray+=(0)
          echo "    ✗ Online Version Not Found"
        fi
      fi
    else
      if [ $FileTooSmall -eq 1 ]; then
        LocalRequiresDownloadArray+=(0)
        [[ $DEBUG -eq 0 ]] && echo -e "\033[0;32m    ✓ Update skipped (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')\033[0m"
        [[ $DEBUG -eq 1 ]] && echo -e "\033[0;32m    ✓ *** Simulated ***  Update skipped (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')\033[0m"
      elif [ $FileTooLarge -eq 1 ]; then
        LocalRequiresDownloadArray+=(0)
        [[ $DEBUG -eq 0 ]] && echo -e "\033[0;32m    ✓ Update skipped (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')\033[0m"
        [[ $DEBUG -eq 1 ]] && echo -e "\033[0;32m    ✓ *** Simulated ***  Update skipped (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')\033[0m"
      else
        LocalRequiresDownloadArray+=(1)
        AnyDownloads=1
        echo -e "\033[1;32m    ✓ Update found! --> $(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')\033[0m"
      fi
    fi
  fi
  echo
done

# TODO Start handling all the ZIMs
echo -e "\033[1;33m4. Downloading New ZIM(s)...\033[0m"
echo

# Let's clear out any possible duplicates

# Let's Start the download process, but only if we have actual downloads to do.
if [ $AnyDownloads -eq 1 ]; then
  for ((z = 0; z < ${#LocalZIMNameArray[@]}; z++)); do # Iterate through the download queue.
    [[ ${LocalRequiresDownloadArray[$z]} -eq 0 ]] && continue

    OldZIM=${LocalZIMNameArray[$z]}
    OldZIMPath=$ZIMPath$OldZIM

    echo -e "\033[1;34m  Processing $OldZIM\033[0m"

    #todo figure out what to do to differentiate 2 and 3
    if [[ ${LocalRequiresDownloadArray[$z]} -eq 3 ]]; then
      ExpectedHash=$(grep -ioP "^[0-9a-f]{64}" <"$OldZIMPath.sha256")

      NewZIM="$OldZIM"
      NewZIMPath="$OldZIMPath"
    else
      mirror_search # Let's look for a mirror URL first.

      if [[ ${LocalRequiresDownloadArray[$z]} -eq 2 ]]; then
        ExpectedHash=$(grep -ioP "^[0-9a-f]{64}" <"$OldZIMPath.sha256")
      fi

      NewZIM=${RemoteFiles[${LocalZIMRemoteIndexArray[$z]}]}
      NewZIMPath=$ZIMPath$NewZIM
    fi

    FilePath=$ZIMPath$NewZIM              # Set destination path with file name
    LockFilePath="$ZIMPath.~lock.$NewZIM" # Set destination path with file name

    RequiresDownload=0

    if [ $VERIFY_LIBRARY -eq 0 ]; then
      if [[ -f $NewZIM ]] && ! [[ -f $LockFilePath ]]; then # New ZIM already found, and no interruptions, we don't need to download it.
        [[ $DEBUG -eq 0 ]] && echo -e "\033[0;32m    ✓ Status : ZIM already exists on disk. Skipping download.\033[0m"
        [[ $DEBUG -eq 1 ]] && echo -e "\033[0;32m    ✓ Status : *** Simulated ***  ZIM already exists on disk. Skipping download.\033[0m"
        echo
      else # New ZIM not found, so we'll go ahead and download it.
        RequiresDownload=1
        if [[ -f $LockFilePath ]]; then
          [[ $DEBUG -eq 0 ]] && echo -e "\033[0;32m    ✓ Status : ZIM download was interrupted. Continuing...\033[0m"
          [[ $DEBUG -eq 1 ]] && echo -e "\033[0;32m    ✓ Status : *** Simulated ***  ZIM download was interrupted. Continuing...\033[0m"
        else
          [[ $DEBUG -eq 0 ]] && echo -e "\033[0;32m    ✓ Status : ZIM doesn't exist on disk. Downloading...\033[0m"
          [[ $DEBUG -eq 1 ]] && echo -e "\033[0;32m    ✓ Status : *** Simulated ***  ZIM doesn't exist on disk. Downloading...\033[0m"
        fi
        echo
      fi
    else
      # lockfile implies an incomplete download
      if [[ -f $LockFilePath ]]; then
        echo "Incomplete download detected" >>download.log
        echo -e "\033[0;33m    Status: Incomplete download detected, resuming\033[0m"

        #                [[ $IsMirror -eq 0 ]] && echo -e "\033[1;34m  Download (direct) : $DownloadURL\033[0m"
        #                [[ $IsMirror -eq 1 ]] && echo -e "\033[1;34m  Download (mirror) : $DownloadURL\033[0m"
        RequiresDownload=1
      else
        # actually verify the file
        echo -e "\033[0;34m    Calculating checksum for : $OldZIM\033[0m"
        echo "    Calculating checksum for : $OldZIM" >>download.log
        [[ ${LocalRequiresDownloadArray[$z]} -ne 2 ]] && echo "$ExpectedHash $OldZIM" >"$OldZIMPath.sha256"
        if [[ ${LocalRequiresDownloadArray[$z]} -ne 2 ]] && [[ $(du -b "$OldZIMPath" | grep -ioP "^\d+") -ne "$ExpectedSize" ]]; then
          RequiresDownload=1
          if [[ $DEBUG -eq 0 ]]; then
            if [[ $SKIP_PURGE -eq 0 ]]; then
              echo -e "\033[1;31m    ✗ Status : File size verification failed, removing corrupt file\033[0m"
              echo "    ✗ Status : File size verification failed, removing corrupt file" >>download.log
              rm "$OldZIMPath"
            else
              echo -e "\033[1;31m    ✗ Status : File size verification failed but purge skipped\033[0m"
              echo "    ✗ Status : File size verification failed but purge skipped" >>download.log
            fi
          else
            [[ $SKIP_PURGE -eq 0 ]] && echo -e "\033[1;31m    ✗ Status : *** Simulated *** File size verification failed, removing corrupt file ($FilePath)\033[0m"
            [[ $SKIP_PURGE -eq 1 ]] && echo -e "\033[1;31m    ✗ Status : *** Simulated *** File size verification failed but purge skipped ($FilePath)\033[0m"
          fi

          echo
        elif [[ ${#ExpectedHash} -ne 64 ]]; then
          echo "    This hash doesn't look quite right...skipping"
        elif (cd "$ZIMPath" && ! sha256sum --status -c "$OldZIM.sha256"); then
          # we checked a very old file, but we will choose to not replace it because we cannot, so we will leave it. A regular update will purge it naturally
          [[ ${LocalRequiresDownloadArray[$z]} -eq 2 ]] && echo -e "\033[1;31m    Checksum failed, online file not found, continuing\033[0m" && echo && continue
          if [[ $DEBUG -eq 0 ]]; then
            if [[ $SKIP_PURGE -eq 0 ]]; then
              echo -e "\033[1;31m    ✗ Status : Checksum failed, removing corrupt file\033[0m"
              echo "    ✗ Status : Checksum failed, removing corrupt file" >>download.log
              rm "$OldZIMPath"
              rm "$OldZIMPath.sha256" 2>/dev/null
            else
              echo -e "\033[1;31m    ✗ Status : Checksum failed but purge was skipped\033[0m"
              echo "    ✗ Status : Checksum failed but purge was skipped" >>download.log
              echo
              continue
            fi
          else
            echo -e "\033[1;31m    ✗ Status : *** Simulated *** Checksum failed, removing corrupt file ($FilePath)\033[0m"
          fi

          RequiresDownload=1
          echo
        else
          echo -e "\033[1;32m    ✓ Status : Checksum passed\033[0m"
          echo "    ✓ Status : Checksum passed" >>download.log

          [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>download.log
          [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>download.log

          #                    rm "$OldZIMPath.sha256"

          echo
          continue
        fi
        [[ ${LocalRequiresDownloadArray[$z]} -eq 2 ]] && continue
        #                rm "$OldZIMPath.sha256"
      fi
    fi

    # Here is where we actually download the files and log to the download.log file.
    if [[ $RequiresDownload -eq 1 ]]; then
      [[ $IsMirror -eq 0 ]] && echo -e "\033[0;34m    Download (direct) : $DownloadURL\033[0m"
      [[ $IsMirror -eq 1 ]] && echo -e "\033[0;34m    Download (mirror) : $DownloadURL\033[0m"
      echo >>download.log
      echo "=======================================================================" >>download.log
      echo "File : $NewZIM" >>download.log
      [[ $IsMirror -eq 0 ]] && echo "URL (direct) : $DownloadURL" >>download.log
      [[ $IsMirror -eq 1 ]] && echo "URL (mirror) : $DownloadURL" >>download.log
      echo >>download.log
      [[ $DEBUG -eq 0 ]] && echo "Start : $(date -u)" >>download.log
      [[ $DEBUG -eq 1 ]] && echo "Start : $(date -u) *** Simulation ***" >>download.log
      echo >>download.log

      # Before we actually download, let's just check to see that it isn't already in the folder.
      if [[ -f "$LockFilePath" ]]; then
        [[ $DEBUG -eq 0 ]] && wget -q --show-progress -c -O "$FilePath" "$DownloadURL" 1>>download.log && echo # Download new ZIM
        [[ $DEBUG -eq 1 ]] && echo "    Continue Download : $FilePath" >>download.log
      elif [[ -f $FilePath ]]; then # New ZIM already found, we don't need to download it.
        [[ $DEBUG -eq 1 ]] && echo "    Download : New ZIM already exists on disk. Skipping download." >>download.log
      else # New ZIM not found, so we'll go ahead and download it.
        [[ $DEBUG -eq 0 ]] && touch "$LockFilePath"
        [[ $DEBUG -eq 0 ]] && wget -q --show-progress -c -O "$FilePath" "$DownloadURL" 1>>download.log && echo # Download new ZIM
        [[ $DEBUG -eq 1 ]] && echo "    Download : $FilePath" >>download.log
      fi
    fi

    echo "$ExpectedHash $NewZIM" 2>/dev/null 1>"$NewZIMPath.sha256"
    if [[ $CALCULATE_CHECKSUM -eq 1 ]]; then
      echo -e "\033[0;34m    Calculating checksum for : $NewZIMPath\033[0m"
      if [[ $(du -b "$NewZIMPath" 2>/dev/null | grep -ioP "^\d+") -ne "$ExpectedSize" ]]; then
        if [[ $DEBUG -eq 0 ]]; then
          echo -e "\033[1;31m    ✗ Status : File size verification failed, removing corrupt file\033[0m"
          echo "    ✗ Status : File size verification failed, removing corrupt file" >>download.log
          rm "$NewZIMPath"
        else
          echo -e "\033[1;32m    ✓ *** Simulated *** Checksum passed\033[0m"
        fi
      elif [[ ${#ExpectedHash} -ne 64 ]]; then
        echo -e "\033[1;33m    This hash doesn't look quite right...skipping\033[0m"
      elif [[ $DEBUG -eq 0 ]] && (cd "$ZIMPath" && ! sha256sum --status -c "$NewZIM.sha256"); then
        echo -e "\033[1;31m    ✗ Checksum failed, removing corrupt file\033[0m"
        rm "$NewZIMPath"
        touch "$NewZIMPath"
        DownloadFailed=1
      else
        if [[ $DEBUG -eq 0 ]]; then
          echo -e "\033[1;32m    ✓ Checksum passed\033[0m"
        else
          echo -e "\033[1;32m    ✓ *** Simulated *** Checksum passed\033[0m"
        fi
      fi
      #            rm "$NewZIMPath.sha256"
      #            rm "$LockFilePath"
      echo
    fi

    echo >> download.log
    [[ $DownloadFailed -eq 1 ]] && echo " !!! DOWNLOAD FAILED !!!" >>download.log

    # in all of these cases, we will not re-pruge and will leave the lockfile so we know to resume later
    if [[ $DownloadFailed -eq 1 ]] || [[ $SKIP_PURGE -eq 1 ]] || [[ $VERIFY_LIBRARY -eq 1 ]]; then
      [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>download.log
      [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>download.log
      continue
    fi

    [[ $RequiresDownload -eq 1 ]] && [[ $DEBUG -eq 0 ]] && rm "$LockFilePath"

    ########################################

    echo -e "\033[0;34m    Old : $OldZIM\033[0m"
    echo "    Old : $OldZIM" >>download.log
    echo -e "\033[1;34m    New : $NewZIM\033[0m"
    echo "    New : $NewZIM" >>download.log
    # Check for the new ZIM on disk.
    if [[ -f "$NewZIMPath" ]]; then # New ZIM found
      if [[ $DEBUG -eq 0 ]]; then
        if [[ "$OldZIMPath" == "$NewZIMPath" ]]; then
          echo -e "\033[1;32m    ✓ Status : New ZIM verified.\033[0m"
          echo "    ✓ Status : New ZIM verified." >>download.log
          #                    rm "$OldZIMPath.sha256" 2>/dev/null # Purge old ZIM
        else
          echo -e "\033[1;32m    ✓ Status : New ZIM verified. Old ZIM purged.\033[0m"
          echo "    ✓ Status : New ZIM verified. Old ZIM purged." >>download.log
          [[ -f "$OldZIMPath" ]] && rm "$OldZIMPath" && rm "$OldZIMPath.sha256" 2>/dev/null # Purge old ZIM
        fi
      else
        echo -e "\033[1;32m    ✓ Status : *** Simulated ***\033[0m"
        echo "    ✓ Status : *** Simulated ***" >>download.log
      fi
    else # New ZIM not found. Something went wrong, so we will skip this purge.
      if [[ $DEBUG -eq 0 ]]; then
        echo -e "\033[1;31m    ✗ Status : New ZIM failed verification. Old ZIM not purged.\033[0m"
        echo "    ✗ Status : New ZIM failed verification. Old ZIM not purged." >>download.log
      else
        if [[ $RequiresDownload -eq 1 ]]; then
          echo -e "\033[1;32m    ✓ Status : *** Simulated *** New zim exists, old zim purged\033[0m"
          echo "    ✓ Status : *** Simulated *** New zim exists, old zim purged" >>download.log
        else
          echo -e "\033[1;33m    ✗ Status : *** Simulated *** Zim was skipped, and will not be purged\033[0m"
          echo "    ✗ Status : *** Simulated *** Zim not purged" >>download.log
        fi
      fi
    fi
    echo
    echo >>download.log

    #########################################

    [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>download.log
    [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>download.log
  done
else
  echo -e "\033[0;32m    ✓ Download: Nothing to download.\033[0m"
  echo
fi

#unset LocalRequiresDownloadArray     # Housekeeping, I know, but we can't do this here - we need it to verify new ZIM(s) during the purge function.