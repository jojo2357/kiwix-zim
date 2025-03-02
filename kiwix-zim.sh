#!/bin/bash

VER="3.4"

# This array will contain all of the local zims, with the file extension
LocalZIMArray=()
# This array will contain all of the local zims, without the file extension
LocalZIMNameArray=()
# This array will map the local zim to the index in the remote arrays that contains the same base file name
LocalZIMRemoteIndexArray=()
# This array is a boolean array which remembers if a given local zim shoud be processed in the download loop
LocalRequiresDownloadArray=()
# After updating, this array will be used to store hanging locks and to deal with them
HangingFileLocks=();

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
CALLEDSCRIPTNAME="$0"
CALLEDSCRIPTFILE="$(basename "$CALLEDSCRIPTNAME")"
CALLEDSCRIPTPATH="$(dirname "$CALLEDSCRIPTNAME")"
ARGS=("$@")
BRANCH="main"
SKIP_UPDATE=0
DEBUG=1 # This forces the script to default to "dry-run/simulation mode"
MIN_SIZE=0
MAX_SIZE=0
CALCULATE_CHECKSUM=0
CHECKSUM_FILES=1
VERIFY_LIBRARY=0
FORCE_FETCH_INDEX=0
DOWNLOAD_METHOD=1 # 1: web 2: torrent
BaseURL="https://download.kiwix.org/zim/"
ZIMPath=""
WGET_CMD="wget"
WGET_SHOW_PROGRESS="--show-progress --progress=bar:force"
WGET_VER=1
ARIA2C_MAX_CONN=1
ARIA2C_SUMMARY_INTERVAL=10

RED_REGULAR="\033[0;31m"
RED_BOLD="\033[1;31m"
YELLOW_REGULAR="\033[0;33m"
YELLOW_BOLD="\033[1;33m"
GREEN_REGULAR="\033[0;32m"
GREEN_BOLD="\033[1;32m"
BLUE_REGULAR="\033[0;34m"
BLUE_BOLD="\033[1;34m"
CLEAR="\033[0m"

# Ensure that external command exists
check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "Command not found: '$1'" >&2
    return 1
  fi
  return 0
}

# This will ask the api what files it has to offer and store them in arrays
master_scrape() {
  unset RemoteFiles
  unset Basenames
  unset RemotePaths
  unset RemoteCategory

  indexIsValid=1

  if [[ ! -f kiwix-index ]]; then
    indexIsValid=0
  else
    indexDate="$(head -1 "kiwix-index")"
    if [[ -z "${indexDate}" ]] || [[ "$(date -u -d "$indexDate" +%s)" -lt "$(date -u -d "1 day ago" +%s)" ]]; then
      indexIsValid=0
    fi
  fi

  if [[ FORCE_FETCH_INDEX -eq 1 ]] || [[ $indexIsValid -eq 0 ]]; then
    # both write the file timestamp to the index file and save all of the links to RawLibrary
    RawLibrary="$($WGET_CMD ${WGET_SHOW_PROGRESS//--progress=bar:force/} -q -O - "https://library.kiwix.org/catalog/v2/entries?count=-1" | tee --output-error=warn-nopipe >(grep -ioP "(?<=<updated>)\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?=Z</updated>)" | head -1 > kiwix-index) | grep -i 'application/x-zim' | grep -ioP "^\s+\K.*$")"

    echo "$RawLibrary" >> kiwix-index
  else
    RawLibrary=$(grep -i '<link rel' < kiwix-index)
  fi

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
    echo -e "${RED_REGULAR}    ✗  Could not find any remote files, exiting${CLEAR}"
    echo "✗  Could not find any remote files, exiting" >> download.log
    exit 0
  else
    echo -e "${GREEN_BOLD}    ✓ Found ${#RemoteFiles[@]} files online"
    echo "✓ Found ${#RemoteFiles[@]} files online" >> download.log
  fi

  # Housekeeping...
  unset RawLibrary
  unset hrefs
}

# run_downloader - Run the appropriate downloader
run_downloader() {
  if [[ -n "$ARIA2C_CMD" ]]; then
    [[ $DEBUG -eq 0 ]] && $ARIA2C_CMD --summary-interval=$ARIA2C_SUMMARY_INTERVAL -x $ARIA2C_MAX_CONN -c -d "${FilePath%/*}" -o "${FilePath##*/}" "$DownloadURL" 2>&1 |& tee -a download.log # Download new ZIM 
  else
    [[ $DEBUG -eq 0 ]] && $WGET_CMD -q $WGET_SHOW_PROGRESS -c -O "$FilePath" "$DownloadURL" 2>&1 |& tee -a download.log # Download new ZIM
  fi
}

# self_update - Script Self-Update Function
self_update() {
  echo -e "${YELLOW_BOLD}1. Checking for Script Updates...${CLEAR}"
  echo  "1. Checking for Script Updates..." >> download.log
  echo
  # Check if script path is a git clone.
  #   If true, then check for update.
  #   If false, skip self-update check/funciton.
  if [ $SKIP_UPDATE -eq 1 ]; then
    echo -e "${YELLOW_REGULAR}   Check Skipped${CLEAR}"
    echo "Check Skipped" >> download.log
  elif [[ -d "$SCRIPTPATH/.git" ]]; then
    echo -e "${GREEN_BOLD}   ✓ Git Clone Detected: Checking Script Version...${CLEAR}"
    echo "✓ Git Clone Detected: Checking Script Version..." >> download.log
    cd "$SCRIPTPATH" || exit 1
    [[ $(timeout 1s git rev-parse --abbrev-ref HEAD) != "$BRANCH" ]] && echo -e "${YELLOW_BOLD}     You appear to be on a different branch so I will assume you are developing and do not want an update${CLEAR}" && echo && return
    timeout 1s git fetch --quiet
    timeout 1s git diff --quiet --exit-code "origin/$BRANCH" "$SCRIPTFILE"
    [ $? -eq 1 ] && {
      echo -e "${RED_REGULAR}   ✗ Version: Mismatched${CLEAR}"
      echo "✗ Version: Mismatched" >> download.log
      echo
      echo -e "${YELLOW_BOLD}1a. Fetching Update...${CLEAR}"
      echo "1a. Fetching Update..." >> download.log
      echo
      if [ -n "$(git status --porcelain)" ]; then
        git stash push -m 'local changes stashed before self update' --quiet
      fi
      git pull --force --quiet
      git checkout $BRANCH --quiet
      git pull --force --quiet
      echo -e "${GREEN_BOLD}   ✓ Update Complete. Running New Version. Standby...${CLEAR}"
      echo "✓ Update Complete. Running New Version. Standby..." >> download.log
      sleep 3
      cd - >/dev/null || exit 1

      exec "$CALLEDSCRIPTNAME" "${ARGS[@]}"

      # Exit this old instance of the script
      exit 1
    }
    echo -e "${GREEN_BOLD}   ✓ Version: Current${CLEAR}"
  else
    echo -e "${RED_REGULAR}   ✗ Git Clone Not Detected: Skipping Update Check${CLEAR}"
  fi
  echo
}

# usage_example - Show Usage and Exit
usage_example() {
  echo "Usage: ./${CALLEDSCRIPTNAME##*/} <options> /full/path/"
  echo ''
  echo '    /full/path/                Full path to ZIM directory'
  echo ''
  echo 'Universal Options:'
  echo '    -h, --help                 Show this usage and exit.'
  echo '    -u, --skip-update          Skips checking for script updates (very useful for development).'
  echo '    -g, --get-index            Forces using remote index rather than cached index. Cache auto clears after one day'
  echo '    -n <size>, --min-size      Minimum ZIM Size to be downloaded.'
  echo '                               Specify units include M Mi G Gi, etc. See `man numfmt`'
  echo '    -x <size>, --max-size      Maximum ZIM Size to be downloaded.'
  echo '                               Specify units include M Mi G Gi, etc. See `man numfmt`'
  echo '    -S, --no-sha               Disables saving the zim checksum for future reference. Does not delete present checksums.'
  echo '                               '
  echo 'Action Method Options:'
  echo '    -w, --web                  Downloads zims over http(s).'
  echo '    -t, --torrent              Downloads `.torrent` files. REQUIRES ADDITIONAL SOFTWARE TO EXECUTE DOWNLOAD.'
  echo '    '
  echo '    -f, --verify-library       Verifies that the entire library has the correct checksums as found online.'
  echo '                               Expected behavior is to create sha256 files during a normal run so this option can be used at a later date without internet.'
  echo '                               Disable this using -S'
  echo ''
  echo 'Web Download Options:'
  echo '    -2, --wget2                Force use of `wget2`, this is only required if your distribution packages wget2 as `wget2` and not `wget`.'
  echo '    -3, --aria2c <max conns>   Enable use of `aria2c`, aria2c is only used for parallel downloads, wget is still required for everything else like metadata, etc.'
  echo '                               Optionally specify max parallel download connections (defaults to 1, limited to 16).'
  echo '    -c, --calculate-checksum   Verifies that the downloaded files were not corrupted, but can take a while for large downloads.'
  echo '    -p, --skip-purge           Skips purging any replaced ZIMs.'
  echo '    -l <location>, --location  Country Code to prefer mirrors from'
  echo '    -d, --disable-dry-run      Dry-Run Override.'
  echo '                               *** Caution ***'

  echo
  exit 0
}

# flags - Flag and ZIM Processing Functions
flags() {
  echo -e "${YELLOW_BOLD}2. Preprocessing...${CLEAR}"
  echo "2. Preprocessing..." >> download.log
  echo
  echo -e "${BLUE_BOLD}  -Validating ZIM directory...${CLEAR}"
  echo "Validating ZIM directory..." >> download.log

  # Let's identify which argument is the ZIM directory path and if it's an actual directory.
  if [[ -d ${1} ]]; then
    if [[ -w ${1} ]]; then
      ZIMPath=$1
    else
      ZIMPath=$1
      echo -e "${RED_REGULAR}  ✗ Cannot write to '${1}', continuing in dry-run${CLEAR}"
      echo "✗ Cannot write to '${1}', continuing in dry-run" >> download.log
      echo
      DEBUG=1
    fi
  else # Um... no ZIM directory path provided? Okay, let's show the usage and exit.
    if [[ -z ${1} ]]; then
      echo -e "${RED_REGULAR}  ✗ Kiwix ZIM Directory not provided${CLEAR}"
      echo "✗ Kiwix ZIM Directory not provided" >> download.log
    else
      echo -e "${RED_REGULAR}  ✗ '$1' is not a directory${CLEAR}"
      echo "✗ '$1' is not a directory" >> download.log
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

  for index in "${!LocalZIMArray[@]}" ; do
    duplicated=0
    myBasename=$(echo "${LocalZIMArray[$index]}" | grep -ioP "^.*(?=_\d{4}-\d{2}\.zim$)")
    for scanIndex in "${!LocalZIMArray[@]}"; do
      if [[ -f "${ZIMPath}.~lock.${LocalZIMArray[$index]}" ]]; then
        if [[ $index -le $scanIndex ]] || [[ -f "${ZIMPath}.~lock.${LocalZIMArray[$scanIndex]}" ]]; then continue; fi
      else
        if [[ $index -ge $scanIndex ]] || [[ -f "${ZIMPath}.~lock.${LocalZIMArray[$scanIndex]}" ]]; then continue; fi
      fi
      scanBasename=$(echo "${LocalZIMArray[$scanIndex]}" | grep -ioP "^.*(?=_\d{4}-\d{2}\.zim$)")

      if [[ "$myBasename" == "$scanBasename" ]]; then
        if [[ -f "${ZIMPath}.~lock.${LocalZIMArray[$index]}" ]]; then
          echo "Disregarding ${LocalZIMArray[$index]} because it was interrupted by ${LocalZIMArray[$scanIndex]}" >> download.log
        elif [[ -f "${ZIMPath}${LocalZIMArray[$index]}.torrent" ]]; then
          echo "Disregarding ${LocalZIMArray[$index]} because new torrent exists ${LocalZIMArray[$scanIndex]}" >> download.log
        else
          echo "Disregarding ${LocalZIMArray[$index]} because it is shadowed by ${LocalZIMArray[$scanIndex]}" >> download.log
        fi
        duplicated=1
        break
      fi
    done
    [[ $duplicated -eq 1 ]] && unset -v 'LocalZIMArray[$index]'
  done
  LocalZIMArray=("${LocalZIMArray[@]}")

  # Check that ZIM(s) were actually found/loaded.
  if [ ${#LocalZIMArray[@]} -eq 0 ]; then # No ZIM(s) were found in the directory... I guess there's nothing else for us to do, so we'll Exit.
    echo -e "${RED_REGULAR}  ✗ No ZIMs found. Exiting...${CLEAR}"
    exit 0
  else
    echo -e "${GREEN_BOLD}  ✓ Valid ZIM Directory ${CLEAR}"
  fi
  echo

  echo -e "${BLUE_BOLD}  -Building online ZIM list...${CLEAR}"

  # Build online ZIM list.
  master_scrape

  echo

  # Populate ZIM arrays from found ZIM(s)
  echo -e "${BLUE_BOLD}  -Parsing ZIM(s)...${CLEAR}"

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
      echo -e "${RED_REGULAR}    ✗ ${LocalZIMNameArray[$i]}  No online match found.${CLEAR}"
    else
      echo -e "${GREEN_BOLD}    ✓ ${LocalZIMNameArray[$i]}  [${RemoteCategory[${LocalZIMRemoteIndexArray[$i]}]}]${CLEAR}"
    fi
  done

  echo
  echo -e "${GREEN_REGULAR}    ${#LocalZIMNameArray[*]} ZIM(s) found.${CLEAR}"
}

# mirror_search - Find ZIM URL Priority #1 mirror from meta4 Function
mirror_search() {
  IsMirror=0
  DownloadURL=""
  RemotePath="${RemotePaths[${LocalZIMRemoteIndexArray[$z]}]}"
  ExpectedSize="${FileSizes[${LocalZIMRemoteIndexArray[$z]}]}"

  # wget2 option required to disable automatic .meta4 handling
  [[ $WGET_VER -eq 2 ]] && WGET_INFO_OPTIONS="--no-metalink"

  # If we need the checksum, we need a link  and the hash, which we can get both by using .meta4, otherwise we only need
  # Silently fetch (via wget) the associated meta4 xml and extract the mirror URL marked priority="1"
  MetaInfo=$($WGET_CMD -q -O - $WGET_INFO_OPTIONS "$BaseURL$RemotePath.meta4?country=$COUNTRY_CODE")
  ExpectedSize=$(echo "$MetaInfo" | grep '<size>' | grep -Po '\d+')
  ExpectedHash=$(echo "$MetaInfo" | grep '<hash type="sha-256">' | grep -Poi '(?<="sha-256">)[a-f\d]{64}(?=<)')

  # still run the last wget so that the logic is simple for verification.
  if [[ $DOWNLOAD_METHOD -eq 2 ]]; then
    DownloadURL="$BaseURL$RemotePath.torrent" # Set the direct download URL as our download URL
    return
  fi

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
        echo "Invalid country code, falling back to default kiwix behavior" >> download.log
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
    -g | --get-index)
      FORCE_FETCH_INDEX=1
      shift
      ;;
    -w | --web)
      DOWNLOAD_METHOD=1
      shift
      ;;
    -t | --torrent)
      DOWNLOAD_METHOD=2
      shift
      ;;
    -S | --no-sha)
      CHECKSUM_FILES=0
      shift
      ;;
    -2 | --wget2)
      WGET_CMD="wget2"
      shift
      ;;
    -3 | --aria2c)
      ARIA2C_CMD="aria2c"
      shift
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        # aria2c max parallel download connections
        # -x, --max-connection-per-server=<NUM>
        #       The maximum number of connections to one server for each download.  Default: 1
        [[ $1 -ge 1 ]] && [[ $1 -le 16 ]] && ARIA2C_MAX_CONN=$1
        shift
      fi
      ;;
    *)
      # We can either parse the arg here, or just tuck it away for safekeeping
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift                   # past argument
      ;;
  esac
done

# Test for downloader tools
if [[ "$WGET_CMD" == "wget" ]] && ! check_command "$WGET_CMD"; then
  # Default to wget, fallback to wget2
  echo "Using wget2 downloader" >> download.log
  WGET_CMD="wget2"
fi

# Support 1.99 alpha+
if $WGET_CMD -V | head -1 | grep -i "${WGET_CMD}\s\+\(2\|1\.99\)" &>/dev/null; then
  WGET_VER=2
  # Enable compatible options for wget2
  # explicitly omit --progress=bar:force to 
  # extend compatibility to alpha and beta
  WGET_SHOW_PROGRESS="--force-progress --progress=bar"
fi

if ! check_command "$WGET_CMD"; then
  echo "Fatal error, downloader not found!" >&2
  exit 1
fi

if [[ -n "$ARIA2C_CMD" ]]; then
  if ! check_command "$ARIA2C_CMD"; then
    echo "Fatal error, downloader not found!" >&2
    exit 1
  fi
fi

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters that we skipped earlier

clear # Clear screen

if [[ $CALCULATE_CHECKSUM -ne 0 ]] && [[ $DOWNLOAD_METHOD -ne 1 ]]; then
  echo -e "${RED_BOLD}Calculating Checksum not available with torrenting. Aborting.${CLEAR}"
fi

# Display Header
echo "=========================================="
echo " kiwix-zim-updater"
if [[ "$CALLEDSCRIPTFILE" == "kiwix-zim.sh" ]]; then
  echo " WARNING: kiwix-zim.sh has been deprecated "
  echo " in favor of kiwix-zim-updater             "
  echo "WARNING: kiwix-zim has been deprecated in favor of kiwix-zim-updater. kiwix-zim will be a hard link to the new script name until at least 2025-01-01" >> download.log
fi
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
echo -e "${YELLOW_BOLD}3. Processing ZIM(s)...${CLEAR}"
echo "3. Processing ZIM(s)..." >> download.log
echo

AnyDownloads=0

for ((i = 0; i < ${#LocalZIMNameArray[@]}; i++)); do
  RemoteIndex=${LocalZIMRemoteIndexArray[$i]}
  if [[ $RemoteIndex -eq -1 ]]; then
    if [[ $VERIFY_LIBRARY -eq 1 ]] && [[ -f "$FileName.sha256" ]]; then
      LocalRequiresDownloadArray+=(3)
      AnyDownloads=1
      echo -e "${BLUE_BOLD}  - $FileName:${CLEAR}"
      echo -e "${GREEN_REGULAR}    Cached Checksum Found${CLEAR}"
    else
      LocalRequiresDownloadArray+=(0)
    fi
    continue
  fi

  FileName=${LocalZIMNameArray[$i]}
  echo -e "${BLUE_BOLD}  - $FileName:${CLEAR}"
  [[ -f "$ZIMPath.~lock.$FileName" ]] && echo -e "${YELLOW_REGULAR}    Incomplete download detected\n${GREEN_BOLD}    ✓ Online Version Found${CLEAR}\n" && LocalRequiresDownloadArray+=(1) && AnyDownloads=1 && continue


  MatchingSize=${FileSizes[$RemoteIndex]}
  MatchingFileName=${RemoteFiles[$RemoteIndex]}
  MatchingFullPath=${RemotePaths[$RemoteIndex]}
  MatchingCategory=${RemoteCategory[$RemoteIndex]}

  [[ -f "$ZIMPath$MatchingFileName.torrent" ]] && [[ ! -f "$ZIMPath$MatchingFileName" ]] && echo -e "${YELLOW_REGULAR}    Torrent already downloaded\n${GREEN_BOLD}    ✓ Online Version Found${CLEAR}\n" && LocalRequiresDownloadArray+=(0) && continue

  MatchedDate="$(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')"
  MatchedYear="$(echo "$MatchedDate" | grep -oP '\d{4}(?=-\d{2})')"
  MatchedMonth="$(echo "$MatchedDate" | grep -oP '(?<=\d{4}-)\d{2}')"

  LocalDate="$(echo "$FileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')"
  LocalYear="$(echo "$LocalDate" | grep -oP '\d{4}(?=-\d{2})')"
  LocalMonth="$(echo "$LocalDate" | grep -oP '(?<=\d{4}-)\d{2}')"

  FileTooSmall=0
  [[ $MIN_SIZE -gt 0 ]] && [[ $MatchingSize -lt $MIN_SIZE ]] && FileTooSmall=1
  FileTooLarge=0
  [[ $MAX_SIZE -gt 0 ]] && [[ $MatchingSize -gt $MAX_SIZE ]] && FileTooLarge=1
  FileSizeAcceptable=0
  [ $FileTooSmall -eq 0 ] && [ $FileTooLarge -eq 0 ] && FileSizeAcceptable=1

  if [ $VERIFY_LIBRARY -eq 1 ] && [ $FileSizeAcceptable -eq 0 ]; then
    if [ $FileTooSmall -eq 1 ]; then
      LocalRequiresDownloadArray+=(0)
      [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Verification skipped due to file size (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
      [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Verification skipped due to file size (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
    elif [ $FileTooLarge -eq 1 ]; then
      LocalRequiresDownloadArray+=(0)
      [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Verification skipped due to file size (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
      [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Verification skipped due to file size (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
    fi
  elif [[ "$MatchingFileName" == "$FileName" ]]; then
    if [ $VERIFY_LIBRARY -eq 1 ]; then
      LocalRequiresDownloadArray+=(1)
      AnyDownloads=1
      echo -e "${GREEN_BOLD}    ✓ Online Version Found${CLEAR}"
    else
      LocalRequiresDownloadArray+=(0)
      echo "    ✗ No new update"
    fi
  else
    if [ $VERIFY_LIBRARY -eq 1 ]; then
      if [[ -f "$ZIMPath$FileName.sha256" ]]; then
        LocalRequiresDownloadArray+=(2)
        AnyDownloads=1
        echo -e "${GREEN_REGULAR}    Cached Checksum Found${CLEAR}"
      else
        echo "    Checking for online checksum..."
        if $WGET_CMD -S --spider -q -O - "$BaseURL$MatchingCategory/$FileName.sha256" >/dev/null 2>&1; then
          LocalRequiresDownloadArray+=(1)
          AnyDownloads=1
          echo -e "${GREEN_BOLD}    ✓ Online Version Found${CLEAR}"
        else
          LocalRequiresDownloadArray+=(0)
          echo "    ✗ Online Version Not Found"
        fi
      fi
    else
      if [ $FileTooSmall -eq 1 ]; then
        LocalRequiresDownloadArray+=(0)
        [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Update skipped (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')${CLEAR}"
        [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Update skipped (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')${CLEAR}"
      elif [ $FileTooLarge -eq 1 ]; then
        LocalRequiresDownloadArray+=(0)
        [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Update skipped (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')${CLEAR}"
        [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Update skipped (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP '\d{4}-\d{2}(?=\.zim$)')${CLEAR}"
      elif [ "$MatchedYear" -lt "$LocalYear" ]; then
        LocalRequiresDownloadArray+=(0)
        echo "    ✗ No new update"
      elif [ "$MatchedYear" -eq "$LocalYear" ] && [ "$MatchedMonth" -le "$LocalMonth" ]; then
        LocalRequiresDownloadArray+=(0)
        echo "    ✗ No new update"
      else
        LocalRequiresDownloadArray+=(1)
        AnyDownloads=1
        echo -e "${GREEN_BOLD}    ✓ Update found! --> $MatchedDate${CLEAR}"
      fi
    fi
  fi
  echo
done

echo -e "${YELLOW_BOLD}4. Downloading New ZIM(s)...${CLEAR}"
echo -e "4. Downloading New ZIM(s)..." >> download.log
echo

# Let's clear out any possible duplicates

# Let's Start the download process, but only if we have actual downloads to do.
if [ $AnyDownloads -eq 1 ]; then
  for ((z = 0; z < ${#LocalZIMNameArray[@]}; z++)); do # Iterate through the download queue.
    [[ ${LocalRequiresDownloadArray[$z]} -eq 0 ]] && continue

    OldZIM=${LocalZIMNameArray[$z]}
    OldZIMPath=$ZIMPath$OldZIM

    echo -e "${BLUE_BOLD}  Processing $OldZIM${CLEAR}"

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
    TorrentFilePath="$ZIMPath$NewZIM.torrent" # Set destination path with file name

    RequiresDownload=0

    if [ $VERIFY_LIBRARY -eq 0 ]; then
      if [[ $DOWNLOAD_METHOD -eq 2 ]]; then
        if [[ -f $NewZIM ]]; then
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM already exists on disk. Skipping download.${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM already exists on disk. Skipping download.${CLEAR}"
          echo
        elif [[ -f $TorrentFilePath ]]; then
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : Torrent already exists on disk. Skipping download.${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  Torrent already exists on disk. Skipping download.${CLEAR}"
          echo
        else
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : Torrent doesn't exist on disk. Downloading...${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  Torrent doesn't exist on disk. Downloading...${CLEAR}"
          RequiresDownload=1
        fi
      elif [[ -f $NewZIM ]] && ! [[ -f $LockFilePath ]]; then # New ZIM already found, and no interruptions, we don't need to download it.
        [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM already exists on disk. Skipping download.${CLEAR}"
        [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM already exists on disk. Skipping download.${CLEAR}"
        echo
      else # New ZIM not found, so we'll go ahead and download it.
        RequiresDownload=1
        if [[ -f $LockFilePath ]]; then
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM download was interrupted. Continuing...${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM download was interrupted. Continuing...${CLEAR}"
        else
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM doesn't exist on disk. Downloading...${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM doesn't exist on disk. Downloading...${CLEAR}"
        fi
        echo
      fi
    else
      # lockfile implies an incomplete download
      if [[ -f $LockFilePath ]]; then
        echo "Incomplete download detected, resuming" >>download.log
        echo -e "${YELLOW_REGULAR}    Status: Incomplete download detected, resuming${CLEAR}"

        #                [[ $IsMirror -eq 0 ]] && echo -e "${BLUE_BOLD}  Download (direct) : $DownloadURL${CLEAR}"
        #                [[ $IsMirror -eq 1 ]] && echo -e "${BLUE_BOLD}  Download (mirror) : $DownloadURL${CLEAR}"
        RequiresDownload=1
      elif [[ -f $TorrentFilePath ]]; then
        echo -e "${YELLOW_REGULAR}    Status: Torrent exists, skipping${CLEAR}"
        echo "Skipping checksum for torrent : $OldZIM. If the download has been completed, please delete the .torrent if you want me to verify the checksum." >>download.log
      else
        # actually verify the file
        echo -e "${BLUE_REGULAR}    Calculating checksum for : $OldZIM${CLEAR}"
        echo "Calculating checksum for : $OldZIM" >>download.log
        [[ ${LocalRequiresDownloadArray[$z]} -ne 2 ]] && echo "$ExpectedHash $OldZIM" >"$OldZIMPath.sha256"
        if [[ ${LocalRequiresDownloadArray[$z]} -ne 2 ]] && [[ $(du -b "$OldZIMPath" | grep -ioP "^\d+") -ne "$ExpectedSize" ]]; then
          RequiresDownload=1
          if [[ $DEBUG -eq 0 ]]; then
            if [[ $SKIP_PURGE -eq 0 ]]; then
              echo -e "${RED_BOLD}    ✗ Status : File size verification failed, removing corrupt file${CLEAR}"
              echo "✗ Status : File size verification failed, removing corrupt file" >>download.log
              rm "$OldZIMPath"
            else
              echo -e "${RED_BOLD}    ✗ Status : File size verification failed but purge skipped${CLEAR}"
              echo "✗ Status : File size verification failed but purge skipped" >>download.log
            fi
          else
            [[ $SKIP_PURGE -eq 0 ]] && echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** File size verification failed, removing corrupt file ($FilePath)${CLEAR}"
            [[ $SKIP_PURGE -eq 1 ]] && echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** File size verification failed but purge skipped ($FilePath)${CLEAR}"
          fi

          echo
        elif [[ ${#ExpectedHash} -ne 64 ]]; then
          echo "    This hash doesn't look quite right...skipping"
        elif (cd "$ZIMPath" && ! sha256sum --status -c "$OldZIM.sha256"); then
          # we checked a very old file, but we will choose to not replace it because we cannot, so we will leave it. A regular update will purge it naturally
          [[ ${LocalRequiresDownloadArray[$z]} -eq 2 ]] && echo -e "${RED_BOLD}    Checksum failed, online file not found, continuing${CLEAR}" && echo && continue
          if [[ $DEBUG -eq 0 ]]; then
            if [[ $SKIP_PURGE -eq 0 ]]; then
              echo -e "${RED_BOLD}    ✗ Status : Checksum failed, removing corrupt file${CLEAR}"
              echo "✗ Status : Checksum failed, removing corrupt file" >>download.log
              rm "$OldZIMPath"
              rm "$OldZIMPath.sha256" 2>/dev/null
            else
              echo -e "${RED_BOLD}    ✗ Status : Checksum failed but purge was skipped${CLEAR}"
              echo "✗ Status : Checksum failed but purge was skipped" >>download.log
              echo
              continue
            fi
          else
            echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** Checksum failed, removing corrupt file ($FilePath)${CLEAR}"
          fi

          RequiresDownload=1
          echo
        else
          echo -e "${GREEN_BOLD}    ✓ Status : Checksum passed${CLEAR}"
          echo "✓ Status : Checksum passed" >>download.log

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
    echo >>download.log
    [[ $DEBUG -eq 0 ]] && echo "Start : $(date -u)" >>download.log
    [[ $DEBUG -eq 1 ]] && echo "Start : $(date -u) *** Simulation ***" >>download.log
    # Here is where we actually download the files and log to the download.log file.
    if [[ $RequiresDownload -eq 1 ]]; then
      if [[ $DOWNLOAD_METHOD -eq 2 ]]; then
        FilePath="$FilePath.torrent"
        if [[ -f "$LockFilePath" ]]; then
          run_downloader
          [[ $DEBUG -eq 1 ]] && echo "Continue Download : $FilePath" >>download.log
        elif [[ -f $FilePath ]]; then # New ZIM already found, we don't need to download it.
          [[ $DEBUG -eq 1 ]] && echo "Download : New Torrent already exists on disk. Skipping download." >>download.log
        else # New ZIM not found, so we'll go ahead and download it.
          run_downloader
          [[ $DEBUG -eq 1 ]] && echo "Download : $FilePath" >>download.log
        fi

        continue
      else
        [[ $IsMirror -eq 0 ]] && echo -e "${BLUE_REGULAR}    Download (direct) : $DownloadURL${CLEAR}"
        [[ $IsMirror -eq 1 ]] && echo -e "${BLUE_REGULAR}    Download (mirror) : $DownloadURL${CLEAR}"
        echo >>download.log
        echo "=======================================================================" >>download.log
        echo "File : $NewZIM" >>download.log
        [[ $IsMirror -eq 0 ]] && echo "URL (direct) : $DownloadURL" >>download.log
        [[ $IsMirror -eq 1 ]] && echo "URL (mirror) : $DownloadURL" >>download.log
        echo >>download.log


        # Before we actually download, let's just check to see that it isn't already in the folder.
        if [[ -f "$LockFilePath" ]]; then
          run_downloader
          [[ $DEBUG -eq 1 ]] && echo "Continue Download : $FilePath" >>download.log
        elif [[ -f $FilePath ]]; then # New ZIM already found, we don't need to download it.
          [[ $DEBUG -eq 1 ]] && echo "Download : New ZIM already exists on disk. Skipping download." >>download.log
        else # New ZIM not found, so we'll go ahead and download it.
          [[ $DEBUG -eq 0 ]] && touch "$LockFilePath"
          run_downloader
          [[ $DEBUG -eq 1 ]] && echo "Download : $FilePath" >>download.log
        fi
      fi
    fi

    echo "$ExpectedHash $NewZIM" 2>/dev/null 1>"$NewZIMPath.sha256"
    if [[ $CALCULATE_CHECKSUM -eq 1 ]]; then
      echo -e "${BLUE_REGULAR}    Calculating checksum for : $NewZIMPath${CLEAR}"
      if [[ $(du -b "$NewZIMPath" 2>/dev/null | grep -ioP "^\d+") -ne "$ExpectedSize" ]]; then
        if [[ $DEBUG -eq 0 ]]; then
          echo -e "${RED_BOLD}    ✗ Status : File size verification failed, removing corrupt file${CLEAR}"
          echo "✗ Status : File size verification failed, removing corrupt file" >>download.log
          rm "$NewZIMPath"
        else
          echo -e "${GREEN_BOLD}    ✓ *** Simulated *** Checksum passed${CLEAR}"
        fi
      elif [[ ${#ExpectedHash} -ne 64 ]]; then
        echo -e "${YELLOW_BOLD}    This hash doesn't look quite right...skipping${CLEAR}"
      elif [[ $DEBUG -eq 0 ]] && (cd "$ZIMPath" && ! sha256sum --status -c "$NewZIM.sha256"); then
        echo -e "${RED_BOLD}    ✗ Checksum failed, removing corrupt file${CLEAR}"
        rm "$NewZIMPath"
        touch "$NewZIMPath"
        DownloadFailed=1
      else
        if [[ $DEBUG -eq 0 ]]; then
          echo -e "${GREEN_BOLD}    ✓ Checksum passed${CLEAR}"
        else
          echo -e "${GREEN_BOLD}    ✓ *** Simulated *** Checksum passed${CLEAR}"
        fi
      fi
      #            rm "$NewZIMPath.sha256"
      #            rm "$LockFilePath"
      echo
    fi

    echo >> download.log
    [[ $DownloadFailed -eq 1 ]] && echo " !!! DOWNLOAD FAILED !!!" >>download.log

    # in all of these cases, we will not re-purge and will leave the lockfile so we know to resume later
    if [[ $DownloadFailed -eq 1 ]] || [[ $SKIP_PURGE -eq 1 ]] || [[ $VERIFY_LIBRARY -eq 1 ]]; then
      [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>download.log
      [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>download.log
      [[ $SKIP_PURGE -eq 1 ]] && [[ $DownloadFailed -ne 1 ]] && rm "$LockFilePath"
      [[ $VERIFY_LIBRARY -eq 1 ]] && [[ $RequiresDownload -eq 1 ]] && rm "$LockFilePath"
      continue
    fi

    [[ $RequiresDownload -eq 1 ]] && [[ $DEBUG -eq 0 ]] && rm "$LockFilePath"

    ########################################

    echo -e "${BLUE_REGULAR}    Old : $OldZIM${CLEAR}"
    echo "Old : $OldZIM" >>download.log
    echo -e "${BLUE_BOLD}    New : $NewZIM${CLEAR}"
    echo "New : $NewZIM" >>download.log
    # Check for the new ZIM on disk.
    if [[ -f "$NewZIMPath" ]]; then # New ZIM found
      if [[ $DEBUG -eq 0 ]]; then
        if [[ "$OldZIMPath" == "$NewZIMPath" ]]; then
          echo -e "${GREEN_BOLD}    ✓ Status : New ZIM downloaded successfully.${CLEAR}"
          echo "✓ Status : New ZIM downloaded successfully." >>download.log
          #                    rm "$OldZIMPath.sha256" 2>/dev/null # Purge old ZIM
        else
          echo -e "${GREEN_BOLD}    ✓ Status : New ZIM downloaded successfully. Old ZIM purged.${CLEAR}"
          echo "✓ Status : New ZIM downloaded successfully. Old ZIM purged." >>download.log
          [[ -f "$OldZIMPath" ]] && rm "$OldZIMPath" && rm "$OldZIMPath.sha256" 2>/dev/null # Purge old ZIM
        fi
      else
        echo -e "${GREEN_BOLD}    ✓ Status : *** Simulated ***${CLEAR}"
        echo "✓ Status : *** Simulated ***" >>download.log
      fi
    else # New ZIM not found. Something went wrong, so we will skip this purge.
      if [[ $DEBUG -eq 0 ]]; then
        echo -e "${RED_BOLD}    ✗ Status : New ZIM failed verification. Old ZIM not purged.${CLEAR}"
        echo "✗ Status : New ZIM failed verification. Old ZIM not purged." >>download.log
      else
        if [[ $RequiresDownload -eq 1 ]]; then
          echo -e "${GREEN_BOLD}    ✓ Status : *** Simulated *** New zim exists, old zim purged${CLEAR}"
          echo "✓ Status : *** Simulated *** New zim exists, old zim purged" >>download.log
        else
          echo -e "${YELLOW_BOLD}    ✗ Status : *** Simulated *** Zim was skipped, and will not be purged${CLEAR}"
          echo "✗ Status : *** Simulated *** Zim not purged" >>download.log
        fi
      fi
    fi
    echo
    echo >>download.log

    #########################################

    [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>download.log
    [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>download.log
  done

  if [[ $DEBUG -eq 0 ]]; then
    IFS=$'\n' HangingFileLocks=("$ZIMPath".~lock.*.zim)
    unset IFS

    if [[ ${#HangingFileLocks[@]} -gt 0 ]]; then
      echo -e "${YELLOW_BOLD}5. Cleaning up...${CLEAR}"
      echo "5. Cleaning up..." >> download.log
      echo

      for ((i = 0; i < ${#HangingFileLocks[@]}; i++)); do
        baseFileName=$(echo "${HangingFileLocks[$i]}" | grep -ioP "(?<=\.~lock\.).*$")
        echo -e "  ${RED_BOLD}Found broken lock: ${HangingFileLocks[$i]}${CLEAR}"
        echo "Found broken lock: ${HangingFileLocks[$i]}" >> download.log
        if [[ -f "$ZIMPath$baseFileName" ]]; then
          echo -e "  ${BLUE_BOLD}Found abandoned download: $ZIMPath$baseFileName${CLEAR}"
          echo -e "Found abandoned download: $ZIMPath$baseFileName" >> download.log
          rm "$ZIMPath$baseFileName"
        fi
        if [[ -f "$ZIMPath$baseFileName.sha256" ]]; then
          echo -e "  ${BLUE_BOLD}Found abandoned checksum: $ZIMPath$baseFileName.sha256${CLEAR}"
          echo -e "Found abandoned checksum: $ZIMPath$baseFileName.sha256" >> download.log
          rm "$ZIMPath$baseFileName.sha256"
        fi
        rm  "${HangingFileLocks[$i]}"
        echo
      done
    fi
  fi
else
  echo -e "${GREEN_REGULAR}    ✓ Download: Nothing to download.${CLEAR}"
  echo "✓ Download: Nothing to download." >> download.log
  echo
fi

if [[ "$CALLEDSCRIPTFILE" == "kiwix-zim.sh" ]]; then
  echo "WARNING: kiwix-zim has been deprecated in favor of kiwix-zim-updater. kiwix-zim will be a hard link to the new script name until at least 2025-01-01.\n This exit code is nonzero, but the script has not errored out. This is simply so you may notice and switch to using kiwix-zim-updater " >> download.log
  exit 2
fi
