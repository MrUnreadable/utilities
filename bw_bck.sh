#!/bin/sh
# MrUnreadable - 14-09-2023 - bw_bck.sh - Perform bitwarden export


# Functions 

# Usage functions.
usage(){
	cat << HELP_EOF
	backup bitwarden instance.

	-h | --help 	Print this and exit.
	-b | --bin DIR	Where to find the 'bw' command.
	-s | --store DIR 	Where to save the export. ( Only the directory name ).
	-k | --keep NR 	How many items keep begore star's overwriting old backup.
	-f | --format USER.ORG 	Backup file's naming convention. If none is provided,
	                        userid ( from 'bw status' output ) will be used.
	-p | --pid DIR 	Write pid on disks at DIR/bw_bck.pid. Default is /run/bw_bck.pid.
	-v | --verbose	Add verbose output to the backup process. Message are print on stderr.
HELP_EOF
}


# On exit remove the pid file ( just to avoid sending signal to
# some other process ) and, eventualy, the temporary file with the bw export.
cleanup() {
	kill $pid 2>/dev/null
	rm -f -- "$pidFile" "$tmpFile"
}


# Debug utility function. Print the given message in
# a fashion like, eg: "2023-09-15:17:16:15 - Start backup process"
# Message are print on stderr.
dbg_on_stderr() {
	printf '%s - %s\n' "$(date +%Y-%m-%d:%H:%M:%S)" "$1" >&2
}


# Testing for mandatory tools like, eg, jq.
getoptTest="$(getopt -T)"
rc=$?
{ 
	{
		[ $rc -eq 4 ] && [ "$getoptTest" = "" ] 
	} || 
	{
		[ $rc -eq 0 ] && [ "$getoptTest" = ' --' ]
	}
} || {
	dbg_on_stderr 'Bad getopt version.'
	exit 1
}
	
command -v jq >/dev/null 2>&1 || {
	dbg_on_stderr 'jq required.'
	exit 1
}

command -v mktemp >/dev/null 2>&1 || {
	dbg_on_stderr 'mktemp required.'
	exit 1
}


# set this programs name
this="${0##*/}"
this="${this%.sh}"


# Working with parameters
argv="$(getopt -l 'help,bin:,store:,keep:,format:,pid:,verbose' \
	-o 'h,b:,s:,k:,f:,p:,v' -- "$@")"
set -- $argv


while [ $# -gt 0 ]
do
	case "$1" in
		-h|--help) usage ; exit ;;
		-b|--bin) shift; PATH="$PATH:$1";;
		-s|--store) shift  # Mandatory
			store="${1#\'}"
			store="${store%\'}"
			store="${store%/}"
			[ -d "$store" ] || {
				dbg_on_stderr "$1 should be a directory."
				exit 1
			}
		;;
		-k|--keep) shift # Default is 30
			keep="${1#\'}"
			keep="${keep%\'}"
			! awk -v t="$keep" 'BEGIN{exit t~/^[0-9]+$/}' || {
				dbg_on_stderr "$1 not a valid integer gibven."
				exit 1
			}
		;;
		-f|--format) shift
			user="${1%.*}"
			org="${1#*.}"
			fmt="${user#\'}.${org%\'}"
			[ "'$fmt'" = "$1" ] || {
				dbg_on_stderr "$1: not a good format. Valid format are like:USER.ORG"
				exit 1
			}
		;;
		-p|--pid) shift
			pidFile="${1%\'}" 
			pidFile="${pidFile%/}/$this.pid"
			pidFile="${pidFile#\'}"
		;;
		-v|--verbose) v=1;;
	esac ; shift
done


[ -z "$v" ] || dbg_on_stderr "$this start"


# Store is a mandatory option
[ -n "$store" ] || {
	dbg_on_stderr '-s ( --store ) is a mandatory option.'
	exit 1
}

# If not specified keep the last 30 items
: "${keep:=30}"

[ -n "$fmt" ] || {
	bwStatus=$(bw status)
	[ $? -ne 127 ] || {
		dbg_on_stderr "Can't find bw utility. Specify a valid one via -b (--bin)."
		exit 1
	}

	userId="$(printf -- '%s' "$bwStatus" | jq -r .userId)"
	serverUrl="$(printf -- '%s' "$bwStatus" |
		jq -r '.serverUrl|sub("https://";"")')"
	fmt="$userId.$serverUrl"
}

: "${pidFile:=/run/$this.pid}"
{ [ -d "${pidFile%/$this.pid}" ] && [ -w "${pidFile%/$this.pid}" ] ; } || {
	dbg_on_stderr "Can't write pid at: $pidFile"
	exit 1
}


[ -z "$v" ] || dbg_on_stderr \
	"parameters -> store: $store, keep: $keep, fmt: $fmt, pid: $pidFile"


# Using bw session key to export the items and
# let the user choose the preferred authentication method.
# To avoid to keep somewhere ( cron log, history, etc ... )
# the session key in clear this can be given only from
# stdin.
printf 'Session Key:\n'
# https://stackoverflow.com/questions/3980668/how-to-get-a-password-from-a-shell-script-without-echoing
stty -echo
trap 'stty echo' EXIT
read -r BW_SESSION
stty echo
trap - EXIT
printf '\nsession key taken successfully\n'
export BW_SESSION


# To avoid that 'pidFile' could survive to
# premature process killing ignore those signal.
trap '' EXIT INT QUIT TERM
printf '%d' $$ > "$pidFile"


while :
do
	# Register the real handler.
	# USR1 signal is the one that let the main process to
	# start and perform the backup.
	# The other ( EXIT, INT, QUIT, TERM ) have an associated
	# cleanup function here to remove temporary file when 
	# the process is terminated.
	trap 'kill "$pid" 2>/dev/null' USR1
	trap 'cleanup ; exit' EXIT INT QUIT TERM


	sleep 86400 &
	pid=$!
	wait
	pid=


	[ -z "$v" ] || dbg_on_stderr 'main loop start. syncing the vault now.'


	# sync the vault
	bw sync -f


	# The USR1 signal is reached. The main loop is started.
	# Don't let it be interrupted and ignore some signal here.
	trap '' USR1
	trap '' EXIT INT QUIT TERM


	# Get the next backup item index
	next=$(LC_ALL=C find "$store" -type f -name "$fmt*" -exec sh -c '
		idx=1
		for x
		do : $((idx+=1))
		done
		printf "%d" "$idx"
	' __xXx__ {} + 2>/dev/null)


	[ -z "$v" ] || dbg_on_stderr "next backup item will be $next"


	# Check the status of the vault with the given session key
	[ "$(bw status | jq -r .status)" = unlocked ] || {
		dbg_on_stderr 'Not a good session key.'
		trap - EXIT INT QUIT TERM
		cleanup
		exit 1
	}


	# FIXME:
	# if the session key is expired at this time
	# the following 'bw' command will wait indefinitely.
	tmpFile="$(mktemp)"
	bw export --output "$tmpFile" --format encrypted_json


	[ -z "$v" ] || dbg_on_stderr 'export finished.'


	# Rotate the backup
	last="$next"
	while [ "$((last-=1))" -gt 0 ]
	do [ -z "$v" ] || dbg_on_stderr "processing item: $last"
		[ -f "$store/$fmt.$last" ] || continue
		[ "$((last+1))" -le "$keep" ] || {
			dbg_on_stderr "$keep value exceeded. Removing: $store/$fmt.$last"
			rm -f -- "$store/$fmt.$last"
			continue
		}
		[ -z "$v" ] || dbg_on_stderr \
			"moving $store/$fmt.$last to $store/$fmt.$((last+1))"
		mv -- "$store/$fmt.$last" "$store/$fmt.$((last+1))"
	done


	[ -z "$v" ] || dbg_on_stderr "moving $store/$fmt to $store/$fmt.1"
	[ -z "$v" ] || dbg_on_stderr "moving temp file $tmpFile to $store/$fmt"


	mv -- "$store/$fmt" "$store/$fmt.1"
	mv -- "$tmpFile" "$store/$fmt"


	[ -z "$v" ] || dbg_on_stderr 'export end'
done
