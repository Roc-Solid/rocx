#!/usr/bin/env bash
# Runs a command (a CI test step's), and if it is still running after ROCX_HANG_MINUTES (20), says
# once what is running: each process, its state and what it waits in, so that a hang is seen in the
# log, not only as the job's limit. The command goes on; its exit is this script's.
minutes=${ROCX_HANG_MINUTES:-20}
"$@" &
command=$!
(
	sleep $((minutes * 60))
	if kill -0 "$command" 2>/dev/null; then
		echo "::group::Still running after $minutes minutes: $*"
		ps -eo pid,ppid,etime,stat,wchan:24,args --forest | cut -c1-240
		echo "::endgroup::"
	fi
) &
watch=$!
wait "$command"
code=$?
pkill -P "$watch" 2>/dev/null
kill "$watch" 2>/dev/null
exit "$code"
