# kiwix-zim-updater.sh

A script to check `download.kiwix.org` for updates to your local ZIM library.

Just pass this script your ZIM directory and away it goes. *(see Usage below)*

Tested on PopOS! 22.04, and should work out of the box on most debian systems, but I have not tested that.

# DEPRECATION WARNING
`kiwix-zim.sh` has been deprecated in favor of the more descriptive `kiwix-zim-updater.sh`. A hard link from `kiwix-zim.sh` to `kiwix-zim-updater.sh` will be maintained on this repo until at least `2025-01-01T00:00:00Z` for compatability with CRON users.

***CALLING `kiwix-zim.sh` WILL RESULT IN AN EXIT CODE OF 2 ON SUCCESSFUL EXECUTION. THIS BEHAVIOR IS EXPECTED. CALL `kiwix-zim-updater.sh` INSTEAD TO GET A 0 EXIT CODE***

## What It Does

I wanted an easy way to ensure my ZIM library was kept updated without actually needing to check every ZIM individually. I looked for a tool to do this, but didn't find anything... so I put on my amateur BASH hat and made one.

Some people run this script via a scheduled cron job where they store their ZIM library and host a Kiwix server. <!-- After it's complete, I follow it up with an automated call to update my `library.xml` for the Kiwix server (Note: this part is not provided via this script). This keeps my ZIM library and Kiwix server updated.-->

It works for me. Your mileage may vary...no warranty, see [the license](./LICENSE) for more info

This script will parse a list of all ZIM(s) found in the ZIM directory passed to it. It then checks each ZIM against what is on the `download.kiwix.org` website via the file name Year-Month part.

Any zims with newer versions online will then be replaced by default. There is an option to verify the downloaded checksums automatically, and options to set the maximum and minimum zim size to download. Although default behavior is to purge the old zim if the new zim passes inspection, purging can be disabled if you would like to keep an archive of old zims.

```text
Note: Due to the nature of ZIM sizes and internet connection speeds, 
      you should expect the download process to take a while.

      This script will output the download progress bar during the 
      download process just so you can see that the script hasn't 
      frozen or locked up.

      Download status is also logged in real-time for monitoring from
      outside this script.
```

### Special Note 1

For data safety reasons, I have coded this script to "dry-run" by default. This means that this script will not download or purge anything, however, it will "go through the motions" and output what it would have actually done, allowing you to review the "effects" before commiting to them.

Once you are good with the "dry-run" results and wish to commit to them, simply re-run the script like you did the first time, but this time, add the "dry-run" override flag (`-d`) to the end.

```text
Bonus: A dry-run/simulation run is not required. If you like to 
       live dangerously, feel free to just call the script with 
       the override flag right from the start. 

       It's your ZIM libary... not mine.
```

### Special Note 2

Creates `downloads.log` for the following reasons:

1. History of what was done. Just good to have.
2. Because downloads can take a really long time, if you were to run this script in the background, you'd have no real way of monitoring the status of any downloads it may be running... `download.log` can be monitored for real-time status of any downloads taking place. You could use a very simple `tail -f download.log` to watch those download stats in real-time from outside of the script.

## Limitations

- This script is only for ZIM(s) hosted by `download.kiwix.org` due to the file naming standard they use. If you have self-made ZIM(s) or ZIM(s) downloaded from somewhere else, they most likely do not use the same naming standards and will not be processed by this script.
- If you have ZIM(s) from `download.kiwix.org`, but you have changed their file names, this script will treat them like the previous limitation explains.
- This script does not attempt to update any `library.xml` that may or may not exist/be needed for your install/setup of Kiwix. If needed, you'll need to handle this part on your own.

## Requirements

This script does not need root, however it does need the same rights as your ZIM directory or it won't be able to download and/or purge ZIMs.

Not checked or installed via script:

- Git *(only needed for the self-update process to work.)*

## Install

This script is self-updating. The self-update routine uses git commands to make the update so this script should be "installed" with the below command.

```shell
git clone https://github.com/jojo2357/kiwix-zim-updater.git
```

UPDATE: If you decide not to install via a git clone, you can still use this script, however, it will just skip the update check and continue on.
NOTE: if you are not tracking the `main` branch, the update check will be skipped. So if you do not want to get updates, but like git, just track the commit of your choosing.

## Usage

```text
  Usage: ./kiwix-zim-updater.sh <options> /full/path/
  
      /full/path/                Full path to ZIM directory
  
  Universal Options:
      -h, --help                 Show this usage and exit.
      -u, --skip-update          Skips checking for script updates (very useful for development).
      -g, --get-index            Forces using remote index rather than cached index. Cache auto clears after one day
      -n <size>, --min-size      Minimum ZIM Size to be downloaded.
                                 Specify units include M Mi G Gi, etc. See `man numfmt`
      -x <size>, --max-size      Maximum ZIM Size to be downloaded.
                                 Specify units include M Mi G Gi, etc. See `man numfmt`
      -S, --no-sha               Disables saving the zim checksum for future reference. Does not delete present checksums.
                                 
  Action Method Options:
      -w, --web                  Downloads zims over http(s).
      -t, --torrent              Downloads `.torrent` files. REQUIRES ADDITIONAL SOFTWARE TO EXECUTE DOWNLOAD.
      
      -f, --verify-library       Verifies that the entire library has the correct checksums as found online.
                                 Expected behavior is to create sha256 files during a normal run so this option can be used at a later date without internet.
                                 Disable this using -S
  
  Web Download Options:
      -2, --wget2                Force use of `wget2`, this is only required if your distribution packages wget2 as `wget2` and not `wget`.
      -3, --aria2c <max conns>   Enable use of `aria2c`, aria2c is only used for parallel downloads, wget is still required for everything else like metadata, etc.
                                 Optionally specify max parallel download connections (defaults to 1, limited to 16).
      -c, --calculate-checksum   Verifies that the downloaded files were not corrupted, but can take a while for large downloads.
      -p, --skip-purge           Skips purging any replaced ZIMs.
      -l <location>, --location  Country Code to prefer mirrors from
      -d, --disable-dry-run      Dry-Run Override.
                                 *** Caution ***
```
