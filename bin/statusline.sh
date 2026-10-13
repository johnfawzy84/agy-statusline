#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "agy"
    exit 0
fi

# ── User Configuration ──────────────────────────────────
CONFIG_FILE="${STATUSLINE_CONFIG:-${HOME}/.gemini/statusline.env}"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Display mode: "multiline" (HUD with progress bars) or "inline" (single row)
STATUSLINE_MODE="${STATUSLINE_MODE:-multiline}"

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Token limits ─────────────────────────────────────────
# Benchmark: ~25M tokens/week, ~3.5M tokens/day
DAILY_TOKEN_LIMIT=3500000
WEEKLY_TOKEN_LIMIT=25000000

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

format_reset_time() {
    local reset_iso=$1
    local style=$2  # "time" for 5h/daily, "datetime" for weekly
    [ -z "$reset_iso" ] || [ "$reset_iso" = "null" ] && return

    local epoch
    # Try GNU date first
    epoch=$(date -d "$reset_iso" +%s 2>/dev/null)
    # If GNU date failed (e.g. macOS BSD date), try BSD date formats
    if [ -z "$epoch" ]; then
        local clean_iso
        clean_iso=$(echo "$reset_iso" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$clean_iso" +%s 2>/dev/null)
        if [ -z "$epoch" ]; then
            epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$reset_iso" +%s 2>/dev/null)
        fi
    fi
    [ -z "$epoch" ] && return

    local result
    if [ "$style" = "time" ]; then
        result=$(date -d "@$epoch" +"%H:%M" 2>/dev/null || date -r "$epoch" +"%H:%M" 2>/dev/null)
    else
        result=$(date -d "@$epoch" +"%b %-d, %H:%M" 2>/dev/null || date -r "$epoch" +"%b %-d, %H:%M" 2>/dev/null)
        result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
    fi
    printf "%s" "$result"
}

fmt_tokens() {
    local tokens=$1
    awk -v t="$tokens" 'BEGIN {
        if (t <= 0) printf "0.0M"
        else printf "%.1fM", t / 1000000
    }'
}

# ── Extract JSON data ────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "agy"')
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | awk '{printf "%.0f", $1}')
agent_state=$(echo "$input" | jq -r '.agent_state // ""')
plan_tier=$(echo "$input" | jq -r '.plan_tier // ""')
terminal_width=$(echo "$input" | jq -r '.terminal_width // 80')
conv_id=$(echo "$input" | jq -r '.conversation_id // empty')

# ── Git info ─────────────────────────────────────────────
git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

# ── Agent state icon ─────────────────────────────────────
state_icon=""
case "$agent_state" in
    working|running) state_icon="⚡ " ;;
    idle)            state_icon="" ;;
    *)               state_icon="" ;;
esac

# ── Colors & styles ──────────────────────────────────────
ctx_color=$(color_for_pct "$ctx_pct")

# ── Detect model pool (3p = Claude/Anthropic, gemini = Google) ──
model_id=$(echo "$input" | jq -r '.model.id // ""' | tr '[:upper:]' '[:lower:]')
if echo "$model_id" | grep -qiE 'claude|anthropic|3p'; then
    quota_pool="3p"
    pool_label="claude"
else
    quota_pool="gemini"
    pool_label="gemini"
fi

# ── Quota & Token Processing ─────────────────────────────
q5h_key="${quota_pool}-5h"
qwk_key="${quota_pool}-weekly"

# 1. 5h quota (rolling window)
q5h_remaining=$(echo "$input" | jq -r ".quota.\"${q5h_key}\".remaining_fraction // empty")
q5h_pct=""
q5h_reset_fmt=""
if [ -n "$q5h_remaining" ]; then
    q5h_pct=$(echo "$q5h_remaining" | awk '{printf "%.0f", (1 - $1) * 100}')
    q5h_reset_iso=$(echo "$input" | jq -r ".quota.\"${q5h_key}\".reset_time // empty")
    q5h_reset_fmt=$(format_reset_time "$q5h_reset_iso" "time")
fi

# 2. Check server weekly quota & explicit daily quota
qwk_remaining=$(echo "$input" | jq -r ".quota.\"${qwk_key}\".remaining_fraction // empty")
qwk_pct=""
qwk_used_tokens=0
qwk_reset_iso=""
has_weekly=false
has_daily=false

qday_remaining=""
qday_reset_iso=""
for k in "${quota_pool}-daily" "${pool_label}-daily" "daily" "${quota_pool}-24h" "${pool_label}-24h" "24h"; do
    val=$(echo "$input" | jq -r ".quota.\"$k\".remaining_fraction // empty")
    if [ -n "$val" ]; then
        qday_remaining="$val"
        qday_reset_iso=$(echo "$input" | jq -r ".quota.\"$k\".reset_time // empty")
        break
    fi
done

cache_dir="${HOME}/.gemini"
[ -d "$cache_dir" ] && [ -w "$cache_dir" ] || cache_dir="/tmp"
today=$(date +%Y-%m-%d)
current_week=$(date +%Y-W%V 2>/dev/null || date +%Y-%W)

if [ -n "$qday_remaining" ]; then
    # Case A: Server provided explicit daily bucket
    has_daily=true
    qday_pct=$(echo "$qday_remaining" | awk '{printf "%.0f", (1 - $1) * 100}')
    qday_used_tokens=$(awk -v p="$qday_pct" -v lim="$DAILY_TOKEN_LIMIT" 'BEGIN { printf "%.0f", (p / 100) * lim }')
    qday_reset_fmt=$(format_reset_time "$qday_reset_iso" "time")
fi

if [ -n "$qwk_remaining" ]; then
    # Case B: Server provided weekly quota (consumer tier)
    has_weekly=true
    qwk_pct=$(echo "$qwk_remaining" | awk '{printf "%.0f", (1 - $1) * 100}')
    qwk_used_tokens=$(awk -v p="$qwk_pct" -v lim="$WEEKLY_TOKEN_LIMIT" 'BEGIN { printf "%.0f", (p / 100) * lim }')
    qwk_reset_iso=$(echo "$input" | jq -r ".quota.\"${qwk_key}\".reset_time // empty")
    qwk_reset_fmt=$(format_reset_time "$qwk_reset_iso" "datetime")

    # If server didn't have explicit daily bucket, derive daily from weekly quota
    if [ "$has_daily" = false ]; then
        has_daily=true
        cache_file="${cache_dir}/.agy_statusline_${USER:-default}_daily_${quota_pool}.json"

        baseline_tokens=""
        cached_date=""
        cached_reset=""
        if [ -f "$cache_file" ]; then
            cached_date=$(jq -r '.date // empty' "$cache_file" 2>/dev/null)
            baseline_tokens=$(jq -r '.baseline_weekly_tokens // empty' "$cache_file" 2>/dev/null)
            cached_reset=$(jq -r '.weekly_reset_time // empty' "$cache_file" 2>/dev/null)
        fi

        if [ "$cached_date" = "$today" ] && [ -n "$baseline_tokens" ]; then
            if { [ -n "$cached_reset" ] && [ -n "$qwk_reset_iso" ] && [ "$cached_reset" != "$qwk_reset_iso" ]; } || \
               { [ "$baseline_tokens" -gt "$qwk_used_tokens" ] && [ $(( baseline_tokens - qwk_used_tokens )) -gt 1000000 ] 2>/dev/null; }; then
                baseline_tokens=0
                qday_used_tokens=$qwk_used_tokens
                printf '{"date":"%s","baseline_weekly_tokens":%d,"weekly_reset_time":"%s"}\n' "$today" "$baseline_tokens" "$qwk_reset_iso" > "$cache_file" 2>/dev/null
            elif [ "$qwk_used_tokens" -ge "$baseline_tokens" ] 2>/dev/null; then
                qday_used_tokens=$(( qwk_used_tokens - baseline_tokens ))
            else
                baseline_tokens=$qwk_used_tokens
                qday_used_tokens=0
                printf '{"date":"%s","baseline_weekly_tokens":%d,"weekly_reset_time":"%s"}\n' "$today" "$baseline_tokens" "$qwk_reset_iso" > "$cache_file" 2>/dev/null
            fi
        else
            if [ -n "$q5h_pct" ] && [ "$q5h_pct" -gt 0 ] 2>/dev/null; then
                est_5h=$(awk -v p="$q5h_pct" -v d="$DAILY_TOKEN_LIMIT" 'BEGIN { printf "%.0f", (p / 100) * d * (5 / 24) }')
                if [ "$qwk_used_tokens" -ge "$est_5h" ] 2>/dev/null; then
                    baseline_tokens=$(( qwk_used_tokens - est_5h ))
                    qday_used_tokens=$est_5h
                else
                    baseline_tokens=0
                    qday_used_tokens=$qwk_used_tokens
                fi
            else
                baseline_tokens=$qwk_used_tokens
                qday_used_tokens=0
            fi
            printf '{"date":"%s","baseline_weekly_tokens":%d,"weekly_reset_time":"%s"}\n' "$today" "$baseline_tokens" "$qwk_reset_iso" > "$cache_file" 2>/dev/null
        fi

        if [ "$qwk_used_tokens" -gt 0 ] 2>/dev/null && [ "$qday_used_tokens" -gt "$qwk_used_tokens" ] 2>/dev/null; then
            qday_used_tokens=$qwk_used_tokens
        fi

        qday_pct=$(awk -v u="$qday_used_tokens" -v l="$DAILY_TOKEN_LIMIT" 'BEGIN {
            if (l <= 0) printf "0"
            else {
                p = (u / l) * 100
                if (p > 100) p = 100
                if (p < 0) p = 0
                printf "%.0f", p
            }
        }')
        qday_reset_fmt="00:00"
    fi
else
    # Case C: Server quota is absent (enterprise tier, gcp-ge-plus-tier, etc.)
    # Track conversation token consumption locally against daily (3.5M) and weekly (25M) limits
    has_daily=true
    has_weekly=true

    ctx_window_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
    ctx_current_tokens=$(echo "$input" | jq -r '.context_window.current_tokens // .context_window.total_output_tokens // empty')

    if [ -n "$ctx_current_tokens" ] && [ "$ctx_current_tokens" -gt 0 ] 2>/dev/null; then
        est_conv_tokens=$ctx_current_tokens
    else
        if [ -n "$ctx_window_size" ] && [ "$ctx_window_size" -gt 0 ] 2>/dev/null; then
            model_context_size=$ctx_window_size
        elif echo "$model_id" | grep -qiE 'pro'; then
            model_context_size=2000000
        elif echo "$model_id" | grep -qiE 'claude|anthropic|3p'; then
            model_context_size=200000
        else
            model_context_size=1000000
        fi
        est_conv_tokens=$(awk -v p="$ctx_pct" -v s="$model_context_size" 'BEGIN { printf "%.0f", (p / 100) * s }')
    fi

    sess_key="${conv_id:-${cwd:-main}}"
    tracker_file="${cache_dir}/.agy_statusline_${USER:-default}_tracker_${quota_pool}.json"

    if [ ! -f "$tracker_file" ]; then
        init_tracker=$(printf '{"date":"%s","week":"%s","daily_tokens":0,"weekly_tokens":0,"sessions":{}}' "$today" "$current_week")
    else
        init_tracker=$(cat "$tracker_file" 2>/dev/null)
        [ -z "$init_tracker" ] && init_tracker=$(printf '{"date":"%s","week":"%s","daily_tokens":0,"weekly_tokens":0,"sessions":{}}' "$today" "$current_week")
    fi

    updated_tracker=$(echo "$init_tracker" | jq \
      --arg today "$today" \
      --arg week "$current_week" \
      --arg sess "$sess_key" \
      --argjson tokens "$est_conv_tokens" '
      (if .date != $today then
         .date = $today |
         .daily_tokens = 0
       else . end) as $s1 |
      (if $s1.week != $week then
         $s1 | .week = $week | .weekly_tokens = 0
       else $s1 end) as $s2 |
      ($s2.sessions[$sess] // 0) as $prev |
      (if $tokens > $prev then ($tokens - $prev) else 0 end) as $delta |
      (if $s2.daily_tokens == 0 and $s2.weekly_tokens == 0 and $delta == 0 and $tokens > 0 then $tokens else $delta end) as $effective_delta |
      $s2 |
      .daily_tokens = (.daily_tokens + $effective_delta) |
      .weekly_tokens = (.weekly_tokens + $effective_delta) |
      .sessions[$sess] = $tokens
    ' 2>/dev/null)

    if [ -n "$updated_tracker" ]; then
        echo "$updated_tracker" > "$tracker_file" 2>/dev/null
        qday_used_tokens=$(echo "$updated_tracker" | jq -r '.daily_tokens // 0')
        qwk_used_tokens=$(echo "$updated_tracker" | jq -r '.weekly_tokens // 0')
    else
        qday_used_tokens=$est_conv_tokens
        qwk_used_tokens=$est_conv_tokens
    fi

    qday_pct=$(awk -v u="$qday_used_tokens" -v l="$DAILY_TOKEN_LIMIT" 'BEGIN {
        if (l <= 0) printf "0"
        else {
            p = (u / l) * 100
            if (p > 100) p = 100
            if (p < 0) p = 0
            printf "%.0f", p
        }
    }')
    qwk_pct=$(awk -v u="$qwk_used_tokens" -v l="$WEEKLY_TOKEN_LIMIT" 'BEGIN {
        if (l <= 0) printf "0"
        else {
            p = (u / l) * 100
            if (p > 100) p = 100
            if (p < 0) p = 0
            printf "%.0f", p
        }
    }')
    qday_reset_fmt="00:00"

    next_mon=$(date -v +Mon +"%b %-d, 00:00" 2>/dev/null || date -d "next monday" +"%b %-d, 00:00" 2>/dev/null)
    next_mon=$(echo "$next_mon" | tr '[:upper:]' '[:lower:]')
    qwk_reset_fmt="${next_mon:-mon 00:00}"
fi

# ── Format values ────────────────────────────────────────
qday_used_fmt=$(fmt_tokens "$qday_used_tokens")
qwk_used_fmt=$(fmt_tokens "$qwk_used_tokens")
qday_color=$(color_for_pct "$qday_pct")
qwk_color=$(color_for_pct "$qwk_pct")

# ── Render Status Line ───────────────────────────────────
if [ "$STATUSLINE_MODE" = "inline" ] || [ "$STATUSLINE_MODE" = "singleline" ]; then
    # ── Single-line inline mode ──────────────────────────
    line1="${blue}${model_name}${reset}"
    line1+="${sep}"
    line1+="✍️  ${ctx_color}${ctx_pct}%${reset}"

    if [ -n "$q5h_pct" ]; then
        q5h_color=$(color_for_pct "$q5h_pct")
        line1+="${sep}⏳ ${q5h_color}${q5h_pct}%${reset}"
    fi

    if [ "$has_daily" = true ]; then
        if [ "$terminal_width" -lt 95 ] 2>/dev/null; then
            line1+="${sep}☀️  ${qday_color}${qday_pct}%${reset}"
        else
            line1+="${sep}☀️  ${qday_used_fmt}/3.5M ${dim}(${qday_color}${qday_pct}%${dim})${reset}"
        fi
    fi

    if [ "$has_weekly" = true ]; then
        if [ "$terminal_width" -lt 95 ] 2>/dev/null; then
            line1+="${sep}📅 ${qwk_color}${qwk_pct}%${reset}"
        else
            line1+="${sep}📅 ${qwk_used_fmt}/25M ${dim}(${qwk_color}${qwk_pct}%${dim})${reset}"
        fi
    fi

    line1+="${sep}"
    line1+="${state_icon}${cyan}${dirname}${reset}"
    if [ -n "$git_branch" ]; then
        line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
    fi
    if [ -n "$plan_tier" ] && [ "$plan_tier" != "null" ]; then
        line1+="${sep}${dim}${plan_tier}${reset}"
    fi

    printf "%b" "$line1"
else
    # ── Multi-line HUD mode (default) ────────────────────
    line1="${blue}${model_name}${reset}"
    line1+="${sep}"
    line1+="✍️  ${ctx_color}${ctx_pct}%${reset}"
    line1+="${sep}"
    line1+="${state_icon}${cyan}${dirname}${reset}"
    if [ -n "$git_branch" ]; then
        line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
    fi
    if [ -n "$plan_tier" ] && [ "$plan_tier" != "null" ]; then
        line1+="${sep}${dim}${plan_tier}${reset}"
    fi

    bar_width=10
    quota_lines=""

    if [ -n "$q5h_pct" ]; then
        q5h_bar=$(build_bar "$q5h_pct" "$bar_width")
        q5h_color=$(color_for_pct "$q5h_pct")
        q5h_pct_fmt=$(printf "%3d" "$q5h_pct")
        q5h_label=$(printf "%-13s" "${pool_label} 5h")
        quota_lines+="${white}${q5h_label}${reset} ${q5h_bar} ${q5h_color}${q5h_pct_fmt}%${reset}"
        [ -n "$q5h_reset_fmt" ] && quota_lines+=" ${dim}⟳${reset} ${white}${q5h_reset_fmt}${reset}"
    fi

    if [ "$has_daily" = true ]; then
        qday_bar=$(build_bar "$qday_pct" "$bar_width")
        qday_pct_fmt=$(printf "%3d" "$qday_pct")
        qday_label=$(printf "%-13s" "${pool_label} daily")
        [ -n "$quota_lines" ] && quota_lines+="\n"
        quota_lines+="${white}${qday_label}${reset} ${qday_bar} ${qday_color}${qday_pct_fmt}%${reset} ${dim}(${reset}${white}${qday_used_fmt}${reset}${dim} / 3.5M)${reset}"
        [ -n "$qday_reset_fmt" ] && quota_lines+=" ${dim}⟳${reset} ${white}${qday_reset_fmt}${reset}"
    fi

    if [ "$has_weekly" = true ]; then
        qwk_bar=$(build_bar "$qwk_pct" "$bar_width")
        qwk_pct_fmt=$(printf "%3d" "$qwk_pct")
        qwk_label=$(printf "%-13s" "${pool_label} weekly")
        [ -n "$quota_lines" ] && quota_lines+="\n"
        quota_lines+="${white}${qwk_label}${reset} ${qwk_bar} ${qwk_color}${qwk_pct_fmt}%${reset} ${dim}(${reset}${white}${qwk_used_fmt}${reset}${dim} / 25M)${reset}"
        [ -n "$qwk_reset_fmt" ] && quota_lines+=" ${dim}⟳${reset} ${white}${qwk_reset_fmt}${reset}"
    fi

    printf "%b" "$line1"
    [ -n "$quota_lines" ] && printf "\n\n%b" "$quota_lines"
fi

exit 0
