#!/bin/sh

# Run a command; post it and its standard input, output, and error to Slack.
#
# This program expects SLACK_WEBHOOK_URL in its environment.  You can get one
# by creating a new Incoming Webhook at <https://my.slack.com/services/new>.
#
#/ Usage: slack [--attach] [--channel=<channel>] [--stdin] ...
#/   --attach            post to Slack with an attachment (defaults to fixed-width text)
#/   --channel=<channel> post to this Slack channel (defaults to the integration's default channel)
#/   --stdin             capture standard input and include it as a heredoc

set -e

usage() {
    grep "^#/" "$0" | cut -c"4-" >&2
    exit "$1"
}
ATTACH="" CHANNEL="null" STDIN=""
while [ "$#" -gt 0 ]
do
    case "$1" in
        -a|--attach) ATTACH="--attach" shift;;
        -c|--ch|--channel) CHANNEL="\"$2\"" shift 2;;
        -c*) CHANNEL="\"$(echo "$1" | cut -c"3-")\"" shift;;
        --ch=*) CHANNEL="\"$(echo "$1" | cut -d"=" -f"2-")\"" shift;;
        --channel=*) CHANNEL="\"$(echo "$1" | cut -d"=" -f"2-")\"" shift;;
        -s|--stdin) STDIN="--stdin" shift;;
        -h|--help) usage 0;;
        -*) usage 1;;
        *) break;;
    esac
done

TMP="$(mktemp -d "/tmp/slack-XXXXXX")"
trap "rm -rf \"$TMP\"" EXIT INT QUIT TERM

# Run the command and capture standard input, output, and error.
if [ "$STDIN" ]
then

    # Close standard input if it's requested and is a TTY.  This offers
    # some protection against accidentally piping passwords into Slack.
    if [ -t 0 ]
    then
        echo "slack: not reading standard input from a TTY" >&2
        exec <"/dev/null"
    fi

    tee "$TMP/stdin" | "$@" 2>&1 | tee "$TMP/stdout+stderr"
else
    touch "$TMP/stdin"
    "$@" 2>&1 | tee "$TMP/stdout+stderr"
fi

# Produce a properly-quoted command line for posting to Slack.  This should
# be copy-pastable into a shell to run it again.
QUOTED="${SUDO_USER:-"$USER"}@$(hostname)"
if [ "$(whoami)" = "root" ]
then QUOTED="$QUOTED #"
else QUOTED="$QUOTED \$"
fi
for ARG in "$@"
do
    if echo "$ARG" | grep -F -q " "
    then QUOTED="$QUOTED \\\"$ARG\\\""
    else QUOTED="$QUOTED $ARG"
    fi
done

# Clean up quotes, newlines, tabs, and control characters for a JSON string.
jsonify() {
    tr "\n\t" "\036\037" |
    sed "s/$(printf "\036")/\\\\n/g; s/$(printf "\037")/\\\\t/g; s/\"/\\\\\"/g" |
    tr -d "[:cntrl:]"
}

# Construct a JSON payload with attachments for each standard stream.  This
# is not the default behavior because the text isn't fixed-width.
if [ "$ATTACH" ]
then
    cat >"$TMP/data" <<EOF
payload={
    "attachments": [
        {
            "fallback": "$QUOTED",
            "pretext": "$QUOTED",
            "mrkdwn_in": ["fallback", "pretext"],
            "fields": [
EOF
    cat >>"$TMP/data" <<EOF
                {
                    "mrkdwn_in": ["text"],
                    "short": false,
                    "title": "standard input",
                    "value": "$(jsonify <"$TMP/stdin")"
                },
EOF
    cat >>"$TMP/data" <<EOF
                {
                    "mrkdwn_in": ["text"],
                    "short": false,
                    "title": "standard output + standard error",
                    "value": "$(jsonify <"$TMP/stdout+stderr")"
                }
            ]
        }
    ],
    "channel": $CHANNEL,
    "username": "${SUDO_USER:-"$USER"}@$(hostname)"
}
EOF

# Construct a JSON payload the looks a bit like a shell session.  This is
# the default behavior.  If standard input's been captured, it is shown
# in heredoc syntax so it can be copy-pasted.
else
    FENCE='```'
    cat >"$TMP/data" <<EOF
payload={
    "channel": $CHANNEL,
    "mrkdwn": true,
    "text": "$FENCE$QUOTED$(
        if [ -s "$TMP/stdin" ]
        then
            printf " <<EOF\\\\n"
            jsonify <"$TMP/stdin"
            printf "EOF"
        fi
    )\\n$(
        jsonify <"$TMP/stdout+stderr"
    )$FENCE",
    "username": "${SUDO_USER:-"$USER"}@$(hostname)"
}
EOF
fi

# Post to Slack and print the Slack API output to standard error.
printf "slack: " >&2
curl --data-urlencode "$(cat "$TMP/data")" -s "$SLACK_WEBHOOK_URL" >&2
echo >&2
