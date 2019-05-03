#!/bin/bash

Usage() {
  echo 'Usage: sipit PACKAGE-NAME CONTENT-DIR DESCRIPTION-FILE'
}

# check input arguments

if [[ $# -ne 3 ]] ; then
  Usage
  exit 1
fi

PACKAGE_NAME="$1"
CONTENT_DIR="$2"
DESCRIPTION_FILE="$3"

SCRIPT_DIR="$(dirname "$(readlink -f "$BASH_SOURCE")")"

# read configuration

source "$SCRIPT_DIR/config"


# INPUT VALIDATION
# ***************************************************************

# test if content directory exists
if [ ! -d $CONTENT_DIR ]
then
  echo "The content directory '$CONTENT_DIR' does not exist."
  Usage
  exit 1
fi

# test if description file exists
if [ ! -f $DESCRIPTION_FILE ]
then
  echo "The description file '$DESCRIPTION_FILE' does not exist."
  Usage
  exit 1
fi

# test if package root directory exists
if [ ! -d $PACKAGE_ROOT_DIR ]
then
  echo "The package root directory does not exist. Check the configuration."
  exit 1
fi

PACKAGE_DIR="$PACKAGE_ROOT_DIR/$PACKAGE_NAME"

# test if package directory exists
if [ -d $PACKAGE_DIR ]
then
  echo "Package directory '$PACKAGE_DIR' already exists. Remove or use another name."
  exit 1
fi

# ADD SSH-AGENT IDENTITY
# ***************************************************************

if [ $USE_SSH_AGENT -eq 1 ]
then
  echo "Adding identity file to ssh-agent.."
  IDENTITY_FILE=$(ssh -G $PAS_HOST | grep identityfile | awk '{print $2}' | head -n 1)
  eval "ssh-add $IDENTITY_FILE"
fi


# SET UP PACKAGE DIRECTORIES
# ***************************************************************

echo "Creating new package directory.."
mkdir $PACKAGE_DIR

# workspace
WORKSPACE="$PACKAGE_DIR/workspace"
mkdir $WORKSPACE

# sip_dir
mkdir "$PACKAGE_DIR/sip"
SIPFILE_NAME="$PACKAGE_NAME-`date +"%Y%m%d-%H%M%S"`.tar"
SIPFILE_PATH="$PACKAGE_DIR/sip/$SIPFILE_NAME"

# report dir
REPORT_DIR="$PACKAGE_DIR/reports"
mkdir $REPORT_DIR



# SET UP CLEANUP
# ***************************************************************

Cleanup() {
  if [ $USE_SSH_AGENT -eq 1 ]
  then
    eval "ssh-add -d $IDENTITY_FILE"
  fi
}


# SET UP LOGGING
# ***************************************************************

mkdir $PACKAGE_DIR/log
LOGFILE="$PACKAGE_DIR/log/log_`date +"%Y%m%d-%H%M%S"`"
touch $LOGFILE

# logging functions

Log () {
  timestamp=`date +"%Y-%m-%d %H:%M:%S:"`
  echo "****************************************" >> $LOGFILE
  echo $timestamp $1 >> $LOGFILE
}

Run () {
  Log "$1"
  eval $1 >> $LOGFILE 2>&1
  if [ $? -ne 0 ]
  then
    Log "Command failed.. aborting."
    echo "Command failed: $1"
    echo "Check the log for more information."
    Cleanup
    exit
  fi
}

# start logging
Log "Start logging"


# SIPTOOLS
# ***************************************************************
echo "Using siptools to create package.."

# verify and start python virtualenv
Run "source $VIRTUALENV_PATH"

# import-object (directory)
Run "import-object --workspace $WORKSPACE $CONTENT_DIR"

# technical metadata for all supported file types
# NOT IMPLEMENTED

# premis-event
Run "premis-event creation '`date +"%Y-%m-%dT%H:%M:%S"`' --workspace $WORKSPACE --event_detail 'Creating a SIP from a structured data package' --event_outcome success --event_outcome_detail 'SIP created using pre-ingest tool' --agent_name 'Pre-Ingest tool' --agent_type software"

# import-description
Run "import-description $DESCRIPTION_FILE --workspace $WORKSPACE --remove_root"

# compile-structmap
Run "compile-structmap --workspace $WORKSPACE"

# compile-mets
Run "compile-mets --workspace $WORKSPACE ch '$ORGANIZATION' '$CONTRACT_ID' --copy_files --clean"

# sign-mets
Run "sign-mets --workspace $WORKSPACE $SIGN_KEY_PATH"

# compress
Run "compress --tar_filename $SIPFILE_PATH $WORKSPACE"

# SIP PACKAGE IS READY!
echo "SIP package created: $SIPFILE_PATH"



# SFTP FILE TRANSFER
# ***************************************************************

echo "Transfering the sip file to PAS host..."
Run "sftp $PAS_HOST:transfer <<< $'put $SIPFILE_PATH'"

echo "SIP package has been transfered."

if [ $AWAIT_REPORTS -ne 1 ]
then
  echo "Check for reports manually."
  Cleanup
  exit 0
fi

# retrieve reports

echo "Awaiting dissemination reports.."
echo "(This may take several minutes. Interruption with Ctrl+C will abort automatic retrieval of reports, but not the transfer itself.)"

er=1
n=0
echo -n "Waiting for $n minutes.."
while [ $er -ne 0 ]
do
  sleep 60s
  n=$(($n + 1))
  echo -ne \\r
  echo -n "Waiting for $n minutes.."
  eval "sftp pastesti:accepted/`date +"%Y-%m-%d"`/$SIPFILE_NAME/* $REPORT_DIR" &> /dev/null
  accepted=$?
  eval "sftp pastesti:rejected/`date +"%Y-%m-%d"`/$SIPFILE_NAME/* $REPORT_DIR" &> /dev/null
  rejected=$?
  er=$(($accepted * $rejected))
done

echo ""
[ $rejected -eq 0 ] && echo "The package was rejected." || echo "The package was accepted."
[ $rejected -eq 0 ] && Log "The package was rejected." || Log "The package was accepted."

echo "See dissemination reports in: '$REPORT_DIR'"
Cleanup
