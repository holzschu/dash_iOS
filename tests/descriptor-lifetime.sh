#!/bin/sh
# Run inside a-Shell: dash tests/descriptor-lifetime.sh "$APPDIR/Frameworks/dash.framework/dash"
set -eu
DASH=${1:?Pass the embedded Dash executable}
[ -d /dev/fd ] || { printf '%s\n' 'SKIP: /dev/fd is unavailable'; exit 77; }
set -- /dev/fd/*
before=$#
[ "$(true)" = '' ]
[ "$(cd /tmp)" = '' ]
[ "$(: )" = '' ]
[ "$(printf '')" = '' ]
x=$(sleep 1; echo late &)
[ "$x" = late ]
sleep 2
y=$( (sleep 1; echo z) & )
[ "$y" = z ]
printf '%s\n' 'SUBSTITUTION_LIFETIME_PASS'
input=$PWD/dash-stdin-$$
script=$PWD/dash-substitution-$$.sh
interactive=$PWD/dash-interactive-$$.out
trap 'set -- /dev/fd/*; printf "Descriptors on exit: before=%s after=%s\n" "$before" "$#"; rm -f "$input" "$script" "$interactive"' EXIT
trap 'rm -f "$input" "$script" "$interactive"' HUP INT TERM
printf 'a\nb\n' >"$input"
i=0
while [ "$i" -lt 200 ]; do
	read value <"$input"
	[ "$value" = a ]
	i=$((i + 1))
done
exec 3<"$input"
read value <&3
[ "$value" = a ]
exec 4<&3
read value <&4
[ "$value" = b ]
exec 4<&-
exec 3<&-
exec 3<"$input"
lines=
while read value <&3; do
	lines="$lines$value"
done </dev/null
[ "$lines" = ab ]
exec 3<&-
printf '%s\n' 'BUILTIN_STDIN_PASS'
exec 3<"$input"
set -- /dev/fd/*
error_before=$#
i=0
while [ "$i" -lt 20 ]; do
	if read -Z value <&3 2>/dev/null; then
		printf '%s\n' 'FAIL: read accepted an invalid option'
		exit 1
	fi
	i=$((i + 1))
done
read value <&3
[ "$value" = a ]
set -- /dev/fd/*
error_after=$#
printf 'Builtin error descriptors: before=%s after=%s\n' "$error_before" "$error_after"
exec 3<&-
value=$(printf 'pipe output\n' | cat)
[ "$value" = 'pipe output' ]
value=$(sh -c "ls $input" | cat)
[ "$value" = "$input" ]
printf '%s\n' 'PIPELINE_EOF_PASS'
set +e
x=$(sh -c 'true && printf ok' 2>/dev/null)
status=$?
set -e
# Some a-Shell command lists omit native printf; both exit paths must release streams.
[ "$status" -ne 0 ] || [ "$x" = ok ]
printf '%s\n' 'value=$(printf "substitution output")' '[ "$value" = "substitution output" ]' >"$script"
i=0
while [ "$i" -lt 20 ]; do
	value=$(printf 'substitution output')
	[ "$value" = 'substitution output' ]
	value=$(sh -c "ls $input")
	[ "$value" = "$input" ]
	value=$(sh -c "ls $input && ls $input" 2>/dev/null)
	[ "$value" = "$input
$input" ]
	value=$(sh -c "ls $input && ls $input && ls $input" 2>/dev/null)
	[ "$value" = "$input
$input
$input" ]
	read value </dev/null && exit 1
	"$DASH" -c 'printf "child output\n"' </dev/null
	"$DASH" "$script" </dev/null
	i=$((i + 1))
done
padding='# Refill script input after the recoverable error.'
i=0
while [ "$i" -lt 10 ]; do
	padding="$padding
$padding"
	i=$((i + 1))
done
printf '%s\n' 'readonly dash_readonly=before' 'dash_readonly=after' "$padding" \
	'printf "INTERACTIVE_RECOVERY_PASS\n"' >"$script"
PS1= PS2= ENV= "$DASH" -i "$script" </dev/null >"$interactive" 2>/dev/null
[ "$(cat "$interactive")" = INTERACTIVE_RECOVERY_PASS ]
printf '%s\n' 'INTERACTIVE_RECOVERY_PASS'
set -- /dev/fd/*
after=$#
printf 'Descriptors: before=%s after=%s\n' "$before" "$after"
[ "$error_after" -le "$error_before" ]
printf '%s\n' 'BUILTIN_ERROR_PASS'
[ "$after" -le "$((before + 2))" ]
printf '%s\n' 'DESCRIPTOR_LIFETIME_PASS'
