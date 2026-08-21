#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# If called from within the popup, run the real pinentry program and
# forward its input and output to the caller pinentry-tmux script.
# -----------------------------------------------------------------------------

# If a pinentry program has not already been specified via the 
# PINENTRY_TMUX_PROGRAM environment variable, look within the path for an
# executable named "pinentry".
if [ -z "${PINENTRY_TMUX_PROGRAM:-}" ]; then
	while read -r pinentry_program; do
		if [[ "$pinentry_program" = "$0" || ! -x "$pinentry_program" ]]; then
			continue
		fi

		PINENTRY_TMUX_PROGRAM="$pinentry_program"
		break
	done < <(which -a pinentry)
fi

# If PINENTRY_TMUX_POPUP is set to "1", we're (normally) running this within
# the tmux popup. Run the real pinentry here and forward its output back to
# the original pinentry-tmux process.
if [[ -n "${PINENTRY_TMUX_CALLER:-}" ]]; then
	popup_tty="$(tty)"

	# Redirect STDIN and STDOUT.
	exec 1>"${PINENTRY_TMUX_STDOUT}" 0<"${PINENTRY_TMUX_STDIN}"
	unset PINENTRY_TMUX_POPUP
	unset PINENTRY_TMUX_STDIN
	unset PINENTRY_TMUX_STDOUT
	unset TMUX_TMPDIR
	unset TMUX

	# Trap SIGINT to tell the original pinentry-tmux to cancel.
	trap 'rkill "$PINENTRY_TMUX_CALLER"; kill -USR1 "$PINENTRY_TMUX_CALLER"' INT

	# Call the real pinentry.
	# Force the TTY type to xterm for compatibility.
	"${PINENTRY_TMUX_PROGRAM}" \
		--ttyname="${popup_tty}" \
		--ttytype="xterm" \
		--lc-ctype="${LC_CTYPE:-c}"

	exit $?
fi

# -----------------------------------------------------------------------------
# pinentry-tmux
# -----------------------------------------------------------------------------
set -euo pipefail
pid_pinentry_tmux=$$

# Use the original pinentry directly unless this request originated inside tmux.
# gpg forwards PINENTRY_USER_DATA from the calling process into pinentry's
# environment (available at startup, unlike ttyname/ttytype which only arrive
# later over the Assuan protocol). Mark your tmux sessions by adding to tmux.conf:
#     set-environment -g PINENTRY_USER_DATA tmux
# The second test requires an attached client, which is what display-popup
# actually needs: a reachable server is not enough. A client-less server still
# expands #{client_name} to the empty string and exits 0, so testing
# reachability alone let a request that arrives while nothing is attached (a
# session restore relaunching ssh panes before the client attaches, for
# instance) take the popup branch and hang on a popup tmux refuses to create.
# Fall back to the direct pinentry rather than a doomed popup.
if [[ "${PINENTRY_USER_DATA:-}" != *tmux* ]] || [[ -z "$(tmux list-clients -F "#{client_name}" 2>/dev/null)" ]]; then
	"$PINENTRY_TMUX_PROGRAM" "$@"
	exit $?
fi

# From here on tmux is active and we go through the popup, which is a terminal
# UI. The default `pinentry` may resolve to a GUI program (useless in a popup),
# so prefer pinentry-curses when it is available. Exported so it is forwarded
# into the popup by the env capture below; if pinentry-curses is not installed,
# leave the discovered default in place. The non-tmux path above is unchanged.
if _pinentry_curses="$(command -v pinentry-curses)"; then
	export PINENTRY_TMUX_PROGRAM="$_pinentry_curses"
fi

# Make a pair of FIFOs to communicate with the popup.
fifodir=$(mktemp -u)
mkdir -m 700 "$fifodir"
PINENTRY_TMUX_STDOUT="$fifodir/r2t.sock"; mkfifo "$PINENTRY_TMUX_STDOUT"
PINENTRY_TMUX_STDIN="$fifodir/t2r.sock";  mkfifo "$PINENTRY_TMUX_STDIN"

# Function that kills all children of a process, except the process itself.
# Works with both BSD and GNU coreutils.
rkill() {
	{
		if ps --version &>/dev/null; then
			ps -o pid --ppid="$1"  # GNU ps
		else
			ps -o pid -g "$1"      # BSD ps
		fi
	} \
	| sed $'1d; s/[ \t]//g' \
	| grep -Fv "$1" \
	| xargs --no-run-if-empty kill -TERM \
	|| true
}

# Traps and cleanup.
cleanup() {
	if [ -e "$PINENTRY_TMUX_STDOUT" ]; then rm "$PINENTRY_TMUX_STDOUT"; fi 
	if [ -e "$PINENTRY_TMUX_STDIN"  ]; then rm "$PINENTRY_TMUX_STDIN";  fi
	if [ -d "$fifodir" ]; then rmdir "$fifodir"; fi

	if [ -n "${pid_popup:-}" ]   && kill -0 "$pid_popup" &>/dev/null; then tmux display-popup -C; fi
	# SIGTERM, not SIGINT: with job control off, bash makes an asynchronous
	# child ignore SIGINT, so the backgrounded reader would survive this script
	# and keep the inherited protocol pipe open. gpg-agent would then still be
	# waiting on a prompt that no longer exists, which is the hang this whole
	# teardown exists to prevent.
	if [ -n "${pid_in_sock:-}" ] && kill -0 "$pid_in_sock" &>/dev/null; then kill -TERM "$pid_in_sock"; fi

	echo "BYE"
}

abort() {
	echo "ERR 83886179 Operation cancelled <Pinentry-Tmux>";
	rkill "$pid_pinentry_tmux" 2>/dev/null
	exit 1
}

trap abort USR1
trap cleanup EXIT INT

# Read STDIN from the socket to pinentry-tmux STDOUT.
cat <"$PINENTRY_TMUX_STDIN" &
pid_in_sock=$!

# Create the popup.
({
	# Capture all the exported environment variables.
	# These will be forwarded to the popup.
	envs=()
	while read -r envvar; do
		envs+=(-e "$envvar")
	done < <(env)

	# Determine the ideal height for a popup.
	DESIRED_WIDTH=78
	DESIRED_HEIGHT=18
	read -r ACTUAL_WIDTH ACTUAL_HEIGHT \
		< <(tmux display-message -p '#{client_width} #{client_height}') || true

	# Shrink only to a size tmux actually reported. Both formats expand to the
	# empty string when no client is attached, and an empty operand counts as 0
	# in an arithmetic test, so an unguarded comparison would hand
	# display-popup an empty -w and make it fail.
	if [[ "$ACTUAL_WIDTH" =~ ^[0-9]+$ ]] && [[ "$ACTUAL_WIDTH" -lt "$DESIRED_WIDTH" ]]; then
		DESIRED_WIDTH="$ACTUAL_WIDTH"
	fi

	if [[ "$ACTUAL_HEIGHT" =~ ^[0-9]+$ ]] && [[ "$ACTUAL_HEIGHT" -lt "$DESIRED_HEIGHT" ]]; then
		DESIRED_HEIGHT="$ACTUAL_HEIGHT"
	fi
	
	# Create the popup. Anything other than a clean exit here means the prompt
	# is not on screen, or no longer is: tmux refuses to create the popup when
	# no client is attached or an overlay already owns the client, and a popup
	# dismissed with `display-popup -C` takes the real pinentry down with it
	# (status 129). gpg-agent runs one pinentry at a time, so a wrapper left
	# waiting on the FIFO rendezvous below holds that slot and silently starves
	# every later prompt until it is killed by hand. Tell the main process to
	# abort instead. Only stdout is discarded for the subshell, so tmux's reason
	# reaches stderr (the journal, under a systemd-managed gpg-agent).
	if ! tmux display-popup -E \
		-d "$(pwd)" \
		"${envs[@]}" \
		-e "PINENTRY_TMUX_CALLER=$pid_pinentry_tmux" \
		-e "PINENTRY_TMUX_STDIN=$PINENTRY_TMUX_STDOUT" \
		-e "PINENTRY_TMUX_STDOUT=$PINENTRY_TMUX_STDIN" \
		-T "[ pinentry-tmux ]" \
		-s 'fg=#0066aa bg=0' \
		-S 'fg=#0066ff' \
		-B \
		-w "$DESIRED_WIDTH" \
		-h "$DESIRED_HEIGHT" \
		"$0"; then
		kill -USR1 "$pid_pinentry_tmux" 2>/dev/null || true
	fi

}) 0>&- >/dev/null &
pid_popup=$!

# Write STDOUT from pinentry-tmux to the socket STDIN.
# A couple options will need to be intercepted for this to work properly.
exec 3>"$PINENTRY_TMUX_STDOUT"
while IFS='' read -r line; do
	case "$line" in
		"OPTION ttyname="*) printf "OK\n"; continue ;;
		"OPTION ttytype="*) printf "OK\n"; continue ;;
		"GETINFO flavor"*) printf "D pinentry-tmux\nOK\n"; continue ;;
		*) printf "%s\n" "$line" 1>&3 ;;
	esac
done

# Wait for the real pinentry to finish.
wait "$pid_in_sock"
wait "$pid_popup"

