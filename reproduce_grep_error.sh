#!/bin/bash
_DANGER_PATTERNS=(
    '\brm[[:space:]]+(-[a-zA-Z]*[rfRF][a-zA-Z]*[[:space:]]+)+(/|/\*|~|/etc|/var|/usr|/bin|/sbin|/boot|/lib|\$HOME)'
    '\bmkfs(\.|[[:space:]])'
    '\bdd[[:space:]].*of=/dev/[sh]d'
    ':\(\)\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:[[:space:]]*&[[:space:]]*\}'
    '\b(shutdown|reboot|halt|poweroff)\b'
    '\b(mount|umount)[[:space:]]+'
    '\bchmod[[:space:]]+(-R[[:space:]]+)?[0-7]*777[[:space:]]+/'
    '\bchown[[:space:]]+(-R[[:space:]]+)?[^[:space:]]+[[:space:]]+/'
    '(cat|less|more|head|tail|tee|cp|scp|mv|tar|zip|gzip)[[:space:]]+[^|;&]*(/etc/(passwd|shadow|sudoers)|~/\.ssh/|/\.aws/credentials|\.netrc|\.pgpass|\.git-credentials|id_[rde][sca])'
    '\$\{?(API_KEY|TG_TOKEN|TAVILY|SECRET|PASSWORD|PRIVATE_KEY)[A-Z_]*\}?[^|;&]*\|[[:space:]]*(curl|wget|nc|netcat|telnet|ssh)\b'
    '\b(nc|ncat|netcat)\b[^|;&]*-e[[:space:]]+'
    'bash[[:space:]]+-i[[:space:]]+>'
    '/dev/tcp/'
    '(>+|tee|cp|mv|sed)[^|;&]*(\.env|brain/state/permissions\.json)'
)

cmd="ls"
for pat in "${_DANGER_PATTERNS[@]}"; do
    echo "Testing pattern: $pat"
    echo "$cmd" | LC_ALL=C grep -qE "$pat"
    if [ $? -gt 1 ]; then
        echo "FAILED with status $?"
    fi
done
