#!/bin/sh

# Method to use to become root:
# - sudo: ubiquitous but requires running in a terminal to enter the password if
#         the sudoer is not set passwordless
# - pkexec: requires a graphical polkit agent
#RUN_AS_ROOT_CMD=sudo
RUN_AS_ROOT_CMD=pkexec

# Are we running as a normal user?
if [ $(whoami) != root ]; then

  # Make sure we run in Wayland
  if [ ! "${WAYLAND_DISPLAY}" ]; then
    echo "$0 must be run in a Wayland environment"
    exit
  fi
  
  # Make sure we run in Sway
  if [ ! "${SWAYSOCK}" ]; then
    echo "$0 must be run in a Sway session"
    exit
  fi
  
  # Get the nested session's user as first argument
  if [ ! "$1" ]; then
    echo "Usage: $0 username"
    exit
  fi
  NUSER=$1
  
  # Make sure the nested session's user exists
  if ! grep -q "^${NUSER}:" /etc/passwd; then
    echo "User ${NUSER} doesn't exist"
    exit
  fi
  
  # Make sure filterway is installed
  if ! which -s filterway; then
    echo "filterway not found in the PATH."
    echo "Please install if from https://github.com/andrewbaxter/filterway"
    exit
  fi

  # Find out if filterway supports --title
  if filterway -h | grep -q title; then
    FILTERWAY_CAN_SET_WINDOW_TITLE=1
  fi
  
  # Get a unique ID for this nested session
  UUID=$(uuidgen)
  
  # Figure out where our Wayland socket is and make sure it exists
  if echo ${WAYLAND_DISPLAY} | grep -q "^/"; then 
    RSOCKPATH=${WAYLAND_DISPLAY}
  else
    RSOCKPATH=${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}
  fi
  if ! [ -S ${RSOCKPATH} ]; then 
    echo -n "Socket file ${RSOCKPATH} for this Wayland display "
    echo "\"${WAYLAND_DISPLAY}\" doesn't exist!?"
    exit
  fi
  
  # Unique nested session's Wayland display name
  NWDISPLAY=wayland-nested-${UUID}
  
  # Unique filespec for the nested session's Wayland socket
  NSOCKPATH=/tmp/${NWDISPLAY}
  
  # Unique filespec for the nested Sway socket
  NSWAYSOCK=/tmp/sway-nested-ipc.${NUSER}.${UUID}.sock
  
  # Run filterway in the background to expose our private Wayland socket
  # located in XDG_RUNTIME_DIR, because XDG_RUNTIME_DIR is most likely a
  # tmpfs-mounted directory and changing its permissions to allow a different
  # user tp access the socket would compromise the directory
  rm -f ${NSOCKPATH}
  TITLE="Sway desktop - ${NUSER}"
  if [ "${FILTERWAY_CAN_SET_WINDOW_TITLE}" ]; then
    filterway --upstream ${RSOCKPATH} --downstream ${NSOCKPATH} \
		--title "${TITLE}" &
  else
    filterway --upstream ${RSOCKPATH} --downstream ${NSOCKPATH} &
  fi
  FILTERWAY_PID=$!
  
  # Wait until filterway has created the socket and associated lock files for
  # the nested session
  RETRY=3
  while [ ${RETRY} -gt 0 ] && \
	! ( [ -S ${NSOCKPATH} ] && [ -f ${NSOCKPATH}.lock ] ); do
    sleep 1
    RETRY=$((RETRY-1))
  done
  
  # If filterway somehow didn't start, try to kill it and clean up its files
  # for good measure
  if [ ${RETRY} = 0 ]; then
    kill ${FILTERWAY_PID}
    rm -f ${NSOCKPATH} ${NSOCKPATH}.lock
  fi
  
  # Fix up the permissions of the socket and associated lock files for the
  # nested session so it's only accessible to the owner
  chmod 600 ${NSOCKPATH} ${NSOCKPATH}.lock
  
  # Re-run ourselves as root to perform the rest of the operations to spawn the
  # nested session
  VARFILE=${XDG_RUNTIME_DIR}/$(echo $UUID | cut -d- -f1).nested_sway_vars

  echo "NUSER=${NUSER}" > ${VARFILE}
  echo "NWDISPLAY=${NWDISPLAY}" >> ${VARFILE}
  echo "NSOCKPATH=${NSOCKPATH}" >> ${VARFILE}
  echo "SWAYSOCK=${SWAYSOCK}" >> ${VARFILE}
  echo "NSWAYSOCK=${NSWAYSOCK}" >> ${VARFILE}
  echo "FILTERWAY_PID=${FILTERWAY_PID}" >> ${VARFILE}

  if ! ${RUN_AS_ROOT_CMD} $0 ${VARFILE}; then

    # If pkexec failed because the user cancelled the login or because the root
    # part of the script failed for whatever reason, kill filterway and remove
    # its socket and socket lock files ourselves
    kill ${FILTERWAY_PID}
    rm -f ${NUSER}: ${NSOCKPATH} ${NSOCKPATH}.lock

  fi

  # Remove the variables file
  rm ${VARFILE}

# We run as root
else

  # Source the variables file we need created in the non-root part
  if [ ! "$1" ]; then
    echo "$0 (running as root): missing variable file needed"
    exit 1
  fi
  . $1

  # Check that we were passed all the variables we need
  for VAR in NUSER NWDISPLAY NSOCKPATH SWAYSOCK NSWAYSOCK FILTERWAY_PID; do
    eval "VAL=\${$VAR}"
    if [ ! "${VAL}" ]; then
      echo "$0 (running as root): missing ${VAR} variable"
      exit 1
    fi
  done

  # Give the socket and associated lock files to the nested session's user
  chown ${NUSER}: ${NSOCKPATH} ${NSOCKPATH}.lock
  
  # Script to run as the nested session's user: clean up stale symlinks in
  # XDG_RUNTIME_DIR then run Sway
  CMD='[ "${XDG_RUNTIME_DIR}" ] &&
	(find ${XDG_RUNTIME_DIR} -maxdepth 1 \
				-name "wayland-nested-*" \
				-xtype l \
				-exec rm -f {} \; || true) &&
	rm -f ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY} &&
	ln -s ${NSOCKPATH} ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY} &&
	unset NSOCKPATH &&
	sway'

  # Run the command as the nested session's user
  systemd-run -E WAYLAND_DISPLAY=${NWDISPLAY} \
		-E NSOCKPATH=${NSOCKPATH} \
		-E SWAYSOCK=${NSWAYSOCK} \
		-PM ${NUSER}@ --user /bin/sh -c "${CMD}" &

  # Wait for the Sway container to appear within 3 seconds after starting Sway,
  # then wait for it to disappear for more than 5 seconds afterwards
  COUNTDOWN=3
  while [ ${COUNTDOWN} -gt 0 ]; do
    if SWAYSOCK=${SWAYSOCK} swaymsg -t get_tree | \
	grep -q "pid.: ${FILTERWAY_PID},"; then
      COUNTDOWN=5
    fi
    sleep 1
    COUNTDOWN=$((COUNTDOWN-1))
  done
  
  # Stop the nested Sway
  SWAYSOCK=${NSWAYSOCK} swaymsg exit

  # Kill filterway and remove its socket and socket lock files
  kill ${FILTERWAY_PID}
  rm -f ${NUSER}: ${NSOCKPATH} ${NSOCKPATH}.lock

fi
