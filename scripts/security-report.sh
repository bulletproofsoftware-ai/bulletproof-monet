#!/bin/bash
#
# Security Report Script - Universal (cPanel + non-cPanel)
# Generates a comprehensive security analysis report
# Works on: hg (cPanel), hi (cPanel), h2 (bare), c2 (bare)
#

# Detect environment
HAS_CPANEL=false
[ -d /usr/local/cpanel ] && HAS_CPANEL=true
HAS_CSF=false
command -v csf &>/dev/null && HAS_CSF=true
HAS_F2B=false
command -v fail2ban-client &>/dev/null && HAS_F2B=true

# No ANSI colors — output is delivered to Telegram
# Use plain text with clear section markers

HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S %Z')

echo "============================================================"
echo "           SECURITY REPORT - $HOSTNAME"
echo "           Generated: $DATE"
echo "============================================================"
echo ""

# ============================================================
# QUICK SUMMARY
# ============================================================
echo "=== QUICK SUMMARY ==="
echo ""

# Count SSH failed attempts (recent from /var/log/secure)
SSH_FAILED_TOTAL=$(grep -cE "(Failed|Invalid)" /var/log/secure 2>/dev/null)
: "${SSH_FAILED_TOTAL:=0}"
if [ "$SSH_FAILED_TOTAL" -gt 500 ]; then
    SSH_FAILED_TOTAL="500+ (sampled)"
fi

# Unique attacking IPs (from recent entries)
UNIQUE_IPS=$(grep -E "(Failed|Invalid)" /var/log/secure 2>/dev/null | tail -500 | \
    awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i}' | \
    sort -u | wc -l | tr -d ' ')

# Blocked IPs
if $HAS_CSF; then
    BLOCKED_IPS=$(wc -l < /etc/csf/csf.deny 2>/dev/null | tr -d ' ')
    TEMP_BLOCKS=$(csf -t 2>/dev/null | grep -c "^[0-9]")
    : "${TEMP_BLOCKS:=0}"
else
    BLOCKED_IPS=$(iptables -L INPUT -n 2>/dev/null | grep -c "DROP")
    TEMP_BLOCKS="N/A"
fi

# cPHulk (cPanel only)
if $HAS_CPANEL && [ -f /usr/local/cpanel/logs/cphulkd.log ]; then
    CPHULK_BLOCKS=$(grep "Login Blocked" /usr/local/cpanel/logs/cphulkd.log 2>/dev/null | \
        grep "$(date '+%Y-%m-%d')" | wc -l | tr -d ' ')
else
    CPHULK_BLOCKS="N/A"
fi

# Web attack patterns
if [ -f /var/log/nginx/access.log ]; then
    WEB_444=$(grep -c '" 444 ' /var/log/nginx/access.log 2>/dev/null)
    : "${WEB_444:=0}"
    WEB_ATTACKS=$(grep -cE "(wp-login|xmlrpc|\.\.\/|SELECT.*FROM|UNION.*SELECT|/etc/passwd)" /var/log/nginx/access.log 2>/dev/null)
    : "${WEB_ATTACKS:=0}"
elif $HAS_CPANEL && [ -f /usr/local/cpanel/logs/access_log ]; then
    WEB_444="N/A"
    WEB_ATTACKS=$(grep -cE "(wp-login|xmlrpc|\.\.\/|SELECT.*FROM|UNION.*SELECT|/etc/passwd)" /usr/local/cpanel/logs/access_log 2>/dev/null)
    : "${WEB_ATTACKS:=0}"
else
    WEB_444="N/A"
    WEB_ATTACKS="N/A"
fi

echo "  SSH failed attempts (recent):  $SSH_FAILED_TOTAL"
echo "  Unique attacking IPs:          $UNIQUE_IPS"
echo "  IPs in deny list:              $BLOCKED_IPS"
echo "  Temp blocks:                   $TEMP_BLOCKS"
[ "$CPHULK_BLOCKS" != "N/A" ] && echo "  cPHulk blocks (today):         $CPHULK_BLOCKS"
[ "$WEB_444" != "N/A" ] && echo "  nginx 444 drops (today):       $WEB_444"
echo "  Suspicious web requests:       $WEB_ATTACKS"
echo ""

# ============================================================
# SSH ATTACK DETAILS
# ============================================================
echo "=== SSH ATTACK DETAILS ==="
echo ""
echo "Top 10 Attacking IPs:"
echo "------------------------------------------------------------"
printf "%-6s %-20s %s\n" "Count" "IP Address" "Status"
echo "------------------------------------------------------------"

grep -E "(Failed|Invalid)" /var/log/secure 2>/dev/null | tail -500 | \
    awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i}' | \
    sort | uniq -c | sort -rn | head -10 | \
    while read count ip; do
        if $HAS_CSF; then
            if grep -q "$ip" /etc/csf/csf.deny 2>/dev/null; then
                status="BLOCKED"
            else
                status="NOT BLOCKED"
            fi
        else
            if iptables -L INPUT -n 2>/dev/null | grep -q "$ip"; then
                status="BLOCKED"
            else
                status="NOT BLOCKED"
            fi
        fi
        printf "%-6s %-20s %s\n" "$count" "$ip" "$status"
    done

echo ""
echo "Targeted Usernames:"
echo "------------------------------------------------------------"
grep -E "(Failed|Invalid)" /var/log/secure 2>/dev/null | tail -500 | \
    grep -oP "user \K\w+" | sort | uniq -c | sort -rn | head -10 | \
    while read count user; do
        printf "  %-6s %s\n" "$count" "$user"
    done
echo ""

# ============================================================
# SUCCESSFUL SSH LOGINS
# ============================================================
echo "=== SUCCESSFUL SSH LOGINS ==="
echo ""
echo "------------------------------------------------------------"
printf "%-20s %-18s %-12s %s\n" "Timestamp" "IP Address" "User" "Method"
echo "------------------------------------------------------------"

grep "Accepted" /var/log/secure 2>/dev/null | tail -10 | \
    awk '{
        timestamp=$1" "$2" "$3
        for(i=1;i<=NF;i++) {
            if($i == "for") user=$(i+1)
            if($i == "from") ip=$(i+1)
            if($i ~ /publickey|password/) method=$i
        }
        gsub(/publickey/, "Key", method)
        gsub(/password/, "Pass", method)
        printf "  %-20s %-18s %-12s %s\n", timestamp, ip, user, method
    }'
echo ""

# ============================================================
# ROOT LOGIN HISTORY
# ============================================================
echo "=== ROOT LOGIN HISTORY ==="
echo ""
last -10 root 2>/dev/null | head -10
echo ""

# ============================================================
# FAILED CONSOLE LOGINS
# ============================================================
echo "=== FAILED CONSOLE/TERMINAL LOGINS ==="
echo ""
LASTB_OUT=$(lastb -10 2>/dev/null | head -10)
if [ -n "$LASTB_OUT" ] && ! echo "$LASTB_OUT" | grep -q "^$"; then
    echo "$LASTB_OUT"
else
    echo "  No failed console logins recorded"
fi
echo ""

# ============================================================
# FIREWALL STATUS
# ============================================================
echo "=== FIREWALL STATUS ==="
echo ""

if $HAS_CSF; then
    echo "CSF (ConfigServer Firewall):"
    echo "------------------------------------------------------------"
    CSF_VER=$(csf -v 2>/dev/null | head -1)
    echo "  Version: $CSF_VER"
    TESTING=$(grep "^TESTING " /etc/csf/csf.conf 2>/dev/null | awk -F'"' '{print $2}')
    echo "  Testing mode: $TESTING"
    TCP_IN=$(grep "^TCP_IN" /etc/csf/csf.conf 2>/dev/null | awk -F'"' '{print $2}')
    echo "  TCP_IN: $TCP_IN"
    DENY_COUNT=$(grep -cv '^#\|^$' /etc/csf/csf.deny 2>/dev/null)
    : "${DENY_COUNT:=0}"
    echo "  Deny list entries: $DENY_COUNT"
    echo ""

    # Temporary blocks
    echo "CSF Temporary Blocks:"
    TEMP_OUT=$(csf -t 2>/dev/null | head -15)
    if echo "$TEMP_OUT" | grep -q "no temporary"; then
        echo "  No temporary IP blocks"
    else
        echo "$TEMP_OUT" | head -10
    fi
    echo ""

    # LFD status
    LFD_STATUS=$(systemctl is-active lfd 2>/dev/null)
    echo "  LFD status: $LFD_STATUS"

    # CSF Cluster
    CLUSTER=$(grep "^CLUSTER_SENDTO" /etc/csf/csf.conf 2>/dev/null | awk -F'"' '{print $2}')
    if [ -n "$CLUSTER" ]; then
        echo "  Cluster peers: $CLUSTER"
    fi
    echo ""
fi

if $HAS_F2B; then
    echo "Fail2ban Status:"
    echo "------------------------------------------------------------"
    F2B_STATUS=$(fail2ban-client status 2>/dev/null)
    echo "$F2B_STATUS"
    echo ""

    for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,//g' | xargs); do
        JAIL_INFO=$(fail2ban-client status "$jail" 2>/dev/null | grep -E "Currently|Total")
        echo "  Jail: $jail"
        echo "$JAIL_INFO" | sed 's/^/    /'
    done
    echo ""
fi

if ! $HAS_CSF && ! $HAS_F2B; then
    echo "  No CSF or fail2ban detected"
    echo ""
    echo "iptables summary:"
    echo "------------------------------------------------------------"
    iptables -L INPUT -n --line-numbers 2>/dev/null | grep DROP | head -20
    echo ""
fi

# ============================================================
# CPHULK (cPanel servers only)
# ============================================================
if $HAS_CPANEL && [ -f /usr/local/cpanel/logs/cphulkd.log ]; then
    echo "=== CPHULK BRUTE FORCE PROTECTION ==="
    echo ""
    echo "Recent Blocks (last 15):"
    echo "------------------------------------------------------------"
    grep "Login Blocked" /usr/local/cpanel/logs/cphulkd.log 2>/dev/null | tail -15 | \
        sed 's/\[cPhulkd\] //' | \
        awk -F'[][]' '{
            timestamp=$2
            rest=$0
            gsub(/.*\[Remote IP Address\]=\[/, "", rest)
            gsub(/\].*/, "", rest)
            ip=rest

            service=""
            if ($0 ~ /sshd/) service="SSH"
            else if ($0 ~ /dovecot/) service="MAIL"
            else if ($0 ~ /cpaneld/) service="CPANEL"
            else if ($0 ~ /whostmgrd/) service="WHM"
            else service="OTHER"

            printf "  [%s] %-15s %s\n", timestamp, ip, service
        }' 2>/dev/null | tail -15
    echo ""

    echo "Blocks by Service (today):"
    echo "------------------------------------------------------------"
    grep "Login Blocked" /usr/local/cpanel/logs/cphulkd.log 2>/dev/null | \
        grep "$(date '+%Y-%m-%d')" | \
        grep -oP '\[Service\]=\[\K[^\]]+' | sort | uniq -c | sort -rn
    echo ""
fi

# ============================================================
# WEB ATTACK INDICATORS
# ============================================================
echo "=== WEB ATTACK INDICATORS ==="
echo ""

# Determine which access log to use
ACCESS_LOG=""
if [ -f /var/log/nginx/access.log ]; then
    ACCESS_LOG="/var/log/nginx/access.log"
elif $HAS_CPANEL && [ -f /usr/local/cpanel/logs/access_log ]; then
    ACCESS_LOG="/usr/local/cpanel/logs/access_log"
fi

if [ -n "$ACCESS_LOG" ]; then
    echo "Suspicious Requests (last 15 from $ACCESS_LOG):"
    echo "------------------------------------------------------------"
    grep -E "(wp-login|xmlrpc|\.\.\/|SELECT.*FROM|UNION.*SELECT|/etc/passwd|/bin/bash|\.php\?)" \
        "$ACCESS_LOG" 2>/dev/null | tail -15 | \
        awk '{
            ip=$1
            request=""
            for(i=1;i<=NF;i++) {
                if($i ~ /^"(GET|POST|HEAD|PUT|DELETE)/) {
                    request=$(i+1)
                    break
                }
            }
            printf "  %-18s %s\n", ip, substr(request,1,60)
        }'
    echo ""

    # nginx 444 drops (non-cPanel servers)
    if [ "$ACCESS_LOG" = "/var/log/nginx/access.log" ]; then
        echo "Top 10 IPs getting 444 (silent drop):"
        echo "------------------------------------------------------------"
        grep '" 444 ' "$ACCESS_LOG" 2>/dev/null | \
            awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | \
            while read count ip; do
                printf "  %-6s %s\n" "$count" "$ip"
            done
        echo ""
    fi
else
    echo "  No web access log found"
    echo ""
fi

# ============================================================
# MAIL ATTACK INDICATORS (cPanel only)
# ============================================================
if $HAS_CPANEL && [ -f /usr/local/cpanel/logs/cphulkd.log ]; then
    echo "=== MAIL ATTACK INDICATORS ==="
    echo ""
    MAIL_ATTACKS=$(grep "Login Blocked.*dovecot" /usr/local/cpanel/logs/cphulkd.log 2>/dev/null | \
        grep -c "$(date '+%Y-%m-%d')")
    : "${MAIL_ATTACKS:=0}"
    echo "  Mail auth blocks (today): $MAIL_ATTACKS"
    echo ""
    echo "Targeted Mail Accounts:"
    echo "------------------------------------------------------------"
    grep "Login Blocked.*dovecot" /usr/local/cpanel/logs/cphulkd.log 2>/dev/null | \
        grep -oP '\[Username\]=\[\K[^\]]+' | sort | uniq -c | sort -rn | head -10
    echo ""
fi

# ============================================================
# CPANEL/WHM LOGIN ATTEMPTS (cPanel only)
# ============================================================
if $HAS_CPANEL && [ -f /usr/local/cpanel/logs/login_log ]; then
    echo "=== CPANEL/WHM LOGIN ATTEMPTS ==="
    echo ""
    echo "Failed cPanel/WHM Logins (last 15):"
    echo "------------------------------------------------------------"
    grep -i "FAILED\|DEFERRED" /usr/local/cpanel/logs/login_log 2>/dev/null | tail -15 | \
        cut -c1-100
    echo ""
fi

# ============================================================
# DOCKER SECURITY (non-cPanel servers)
# ============================================================
if command -v docker &>/dev/null; then
    echo "=== DOCKER SECURITY ==="
    echo ""
    CONTAINER_COUNT=$(docker info --format '{{.Containers}}' 2>/dev/null || echo "?")
    RUNNING_COUNT=$(docker info --format '{{.ContainersRunning}}' 2>/dev/null || echo "?")
    echo "  Containers: $RUNNING_COUNT running / $CONTAINER_COUNT total"

    # Check for privileged containers
    PRIV=$(docker ps -q 2>/dev/null | xargs -I{} docker inspect {} --format '{{.Name}} {{.HostConfig.Privileged}}' 2>/dev/null | grep "true" | wc -l | tr -d ' ')
    echo "  Privileged containers: $PRIV"

    # Docker socket permissions
    SOCK_PERMS=$(stat -c "%U:%G %a" /var/run/docker.sock 2>/dev/null || echo "unknown")
    echo "  Docker socket: $SOCK_PERMS"
    echo ""
fi

# ============================================================
# RECOMMENDATIONS
# ============================================================
echo "=== RECOMMENDATIONS ==="
echo ""

RECOMMENDATIONS=0

# Check SSH config
SSH_ROOT=$(grep -E "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
SSH_PASS=$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')

if [ "$SSH_ROOT" = "yes" ]; then
    echo "  [HIGH] SSH root login is fully permitted (PermitRootLogin yes)"
    RECOMMENDATIONS=$((RECOMMENDATIONS+1))
fi

if [ "$SSH_PASS" = "yes" ]; then
    echo "  [MEDIUM] SSH password authentication enabled"
    RECOMMENDATIONS=$((RECOMMENDATIONS+1))
fi

# Check for unblocked repeat offenders
grep -E "(Failed|Invalid)" /var/log/secure 2>/dev/null | tail -500 | \
    awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i}' | \
    sort | uniq -c | sort -rn | head -5 | \
    while read count ip; do
        if [ "$count" -ge 10 ]; then
            BLOCKED=false
            if $HAS_CSF; then
                grep -q "$ip" /etc/csf/csf.deny 2>/dev/null && BLOCKED=true
            else
                iptables -L INPUT -n 2>/dev/null | grep -q "$ip" && BLOCKED=true
            fi
            if ! $BLOCKED; then
                echo "  [HIGH] Unblocked repeat offender: $ip ($count attempts)"
            fi
        fi
    done

if [ $RECOMMENDATIONS -eq 0 ]; then
    echo "  No immediate recommendations. Security posture looks good."
fi

echo ""
echo "============================================================"
echo "                    END OF REPORT"
echo "============================================================"
