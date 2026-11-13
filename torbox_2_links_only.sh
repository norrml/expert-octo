## this one spits out the links only for each magnet
#!/usr/bin/env bash
# TorBox <-> Telegram bridge. Needs: bash>=4, curl, jq, awk, sed
set -u
shopt -s nullglob

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/.env"
: "${BOT_TOKEN:?}" "${TORBOX_KEY:?}" "${GROUP_ID:?}" "${OWNER_ID:?}"
POLL_SECS="${POLL_SECS:-10}"
MAX_FILES="${MAX_FILES:-25}"
EXT_RE="${EXT_RE:-mp4|mkv|srt}"

STATE="$DIR/state"; JOBS="$STATE/jobs"; USERS="$STATE/users.txt"
mkdir -p "$JOBS"; touch "$USERS"

TG="https://api.telegram.org/bot${BOT_TOKEN}"
TB="https://api.torbox.app/v1/api"

# keep only wanted extensions, drop anything with "sample" as its own word
JQ_SEL='select(((.name//.short_name//"")|test("\\.(" + $re + ")$";"i")) and (((.name//.short_name//"")|test("(^|[/._ -])sample([/._ -]|$)";"i"))|not))'

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >&2; }

IFS=',' read -ra _seed <<<"${ALLOWED_IDS:-}"
for i in "${_seed[@]}"; do
  i=${i// /}
  [[ $i =~ ^[0-9]+$ ]] && ! grep -qxF "$i" "$USERS" && echo "$i" >>"$USERS"
done

is_user(){ [[ $1 == "$OWNER_ID" ]] || grep -qxF "$1" "$USERS"; }

# ---------- helpers ----------
esc(){ printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
hb(){ awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.1f %s",b,u[i]}'; }
ht(){ awk -v s="${1:-0}" 'BEGIN{if(s<=0){print "-";exit}h=int(s/3600);m=int((s%3600)/60);if(h>0)printf "%dh %dm",h,m;else if(m>0)printf "%dm",m;else printf "%ds",s}'; }

tg(){ local m=$1; shift; curl -sS --max-time 30 -X POST "$TG/$m" "$@"; }

send(){ # chat text [reply_to] [markup] -> prints message_id
  local chat=$1 text=$2 reply=${3:-} markup=${4:-}
  local a=(--data-urlencode "chat_id=$chat" --data-urlencode "text=$text"
           -d parse_mode=HTML -d 'link_preview_options={"is_disabled":true}')
  [[ -n $reply ]]  && a+=(--data-urlencode "reply_parameters={\"message_id\":$reply,\"allow_sending_without_reply\":true}")
  [[ -n $markup ]] && a+=(--data-urlencode "reply_markup=$markup")
  tg sendMessage "${a[@]}" | jq -r '.result.message_id // empty'
}

edit(){ # chat msg text
  tg editMessageText --data-urlencode "chat_id=$1" -d "message_id=$2" \
     --data-urlencode "text=$3" -d parse_mode=HTML \
     -d 'link_preview_options={"is_disabled":true}' >/dev/null
}

set_markup(){ tg editMessageReplyMarkup --data-urlencode "chat_id=$1" -d "message_id=$2" --data-urlencode "reply_markup=$3" >/dev/null; }
cb_answer(){ tg answerCallbackQuery -d "callback_query_id=$1" --data-urlencode "text=$2" >/dev/null; }

kb_delete(){ jq -nc --arg d "del:$1:$2" '{inline_keyboard:[[{text:"🗑 Delete from TorBox",callback_data:$d}]]}'; }
kb_confirm(){ jq -nc --arg y "delc:$1:$2" --arg n "delx:$1:$2" '{inline_keyboard:[[{text:"⚠️ Yes, delete all",callback_data:$y},{text:"Cancel",callback_data:$n}]]}'; }

tb_get(){ local ep=$1; shift; curl -sS --max-time 30 -G -H "Authorization: Bearer $TORBOX_KEY" "$TB/$ep" "$@"; }
tb_magnet(){ curl -sS --max-time 60 -H "Authorization: Bearer $TORBOX_KEY" -F "magnet=$1" "$TB/torrents/createtorrent"; }
tb_file(){ curl -sS --max-time 90 -H "Authorization: Bearer $TORBOX_KEY" -F "file=@$1;type=application/x-bittorrent" "$TB/torrents/createtorrent"; }
tb_delete(){ curl -sS --max-time 30 -X POST -H "Authorization: Bearer $TORBOX_KEY" -H "Content-Type: application/json" \
             -d "{\"torrent_id\":$1,\"operation\":\"delete\"}" "$TB/torrents/controltorrent"; }

# ---------- rendering ----------
render(){ # mylist item json -> status text
  local state prog speed eta size seeds peers name pct fill bar i
  IFS=$'\t' read -r state prog speed eta size seeds peers name < <(jq -r \
    '[(.download_state//"unknown"),(.progress//0),(.download_speed//0),(.eta//0),(.size//0),(.seeds//0),(.peers//0),(.name//"...")]|@tsv' <<<"$1")
  pct=$(awk -v p="$prog" 'BEGIN{printf "%d",p*100}')
  fill=$((pct/10)); bar=""
  for ((i=0;i<10;i++)); do ((i<fill)) && bar+="▓" || bar+="░"; done
  printf '📥 <b>%s</b>\nState: <code>%s</code>\n%s %s%%\n⚡ %s/s · ETA %s · %s\n🌱 %s seeds · %s peers' \
    "$(esc "$name")" "$(esc "$state")" "$bar" "$pct" "$(hb "$speed")" "$(ht "$eta")" "$(hb "$size")" "$seeds" "$peers"
}

send_links(){ # chat reply_to torrent_id item_json requester_id
  local chat=$1 reply=$2 tid=$3 item=$4 uid=$5 name n total all buf block fid fname r url kb
  name=$(jq -r '.name//"torrent"' <<<"$item")
  all=$(jq '.files|length' <<<"$item")
  total=$(jq --arg re "$EXT_RE" '[.files[]? | '"$JQ_SEL"'] | length' <<<"$item")
  kb=$(kb_delete "$tid" "$uid")
  if (( total == 0 )); then
    send "$chat" "📦 <b>$(esc "$name")</b>"$'\n'"No ${EXT_RE//|//} files found (${all} files total, samples ignored)." "$reply" "$kb" >/dev/null
    return
  fi
  buf="📦 <b>$(esc "$name")</b> · ${total} of ${all} file(s)"$'\n'
  n=0
  while IFS=$'\t' read -r fid fname; do
    ((n>=MAX_FILES)) && break
    r=$(tb_get torrents/requestdl --data-urlencode "token=$TORBOX_KEY" -d "torrent_id=$tid" -d "file_id=$fid" -d redirect=false </dev/null)
    url=$(jq -r 'if (.data|type)=="string" then .data else empty end' <<<"$r" 2>/dev/null)
    if [[ -n $url ]]; then
      block=$'\n'"<b>$(esc "${fname##*/}")</b>"$'\n'"<code>$(esc "$url")</code>"
    else
      block=$'\n'"⚠️ $(esc "${fname##*/}"): no link ($(esc "$(jq -r '.detail//"error"' <<<"$r" 2>/dev/null)"))"
    fi
    if (( ${#buf} + ${#block} > 3500 )); then send "$chat" "$buf" "$reply" >/dev/null; buf=""; fi
    buf+="$block"
    ((n++))
  done < <(jq -r --arg re "$EXT_RE" '.files[]? | '"$JQ_SEL"' | [.id, (.short_name // .name // "file")] | @tsv' <<<"$item")
  ((total>MAX_FILES)) && buf+=$'\n\n'"… $((total-MAX_FILES)) more matching file(s) not shown (MAX_FILES=$MAX_FILES)."
  send "$chat" "$buf" "$reply" "$kb" >/dev/null
}

# ---------- jobs ----------
set_last(){ jq --arg l "$2" '.last=$l' "$1" >"$1.tmp" && mv "$1.tmp" "$1"; }

poll_jobs(){
  local files=("$JOBS"/*.json) list f j id hash chat msg reply ts user last item state key tid now name
  ((${#files[@]})) || return 0
  list=$(tb_get torrents/mylist -d bypass_cache=true </dev/null)
  jq -e '.success==true' <<<"$list" >/dev/null 2>&1 || { log "mylist failed"; return 0; }
  now=$(date +%s)
  for f in "${files[@]}"; do
    j=$(<"$f")
    IFS=$'\t' read -r id hash chat msg reply ts user last < <(jq -r \
      '[(.id|if .==""then"-"else . end),(.hash|if .==""then"-"else . end),.chat,.msg,.reply,.ts,(.user//0),(if (.last//"")=="" then "-" else .last end)]|@tsv' <<<"$j")
    item=$(jq -c --arg id "$id" --arg h "${hash,,}" \
      '(.data//[])|(if type=="array" then . else [.] end)|map(select(((.id|tostring)==$id) or ((.hash//""|ascii_downcase)==$h)))|.[0]//empty' <<<"$list")

    if [[ -z $item ]]; then
      if (( now-ts > 7200 )); then
        edit "$chat" "$msg" "⚠️ Torrent no longer found on TorBox."; rm -f "$f"
      elif [[ $last != queued ]]; then
        edit "$chat" "$msg" "⏳ Queued on TorBox, waiting for a slot…"; set_last "$f" queued
      fi
      continue
    fi

    tid=$(jq -r '.id' <<<"$item")
    state=$(jq -r '.download_state//""' <<<"$item")
    name=$(jq -r '.name//"torrent"' <<<"$item")

    if [[ ${state,,} =~ ^(error|failed) ]]; then
      edit "$chat" "$msg" "❌ <b>$(esc "$name")</b>"$'\n'"TorBox state: <code>$(esc "$state")</code>"; rm -f "$f"; continue
    fi
    if jq -e '.download_finished==true' <<<"$item" >/dev/null 2>&1; then
      edit "$chat" "$msg" "✅ <b>$(esc "$name")</b> is ready on TorBox"
      send_links "$chat" "$reply" "$tid" "$item" "$user"
      rm -f "$f"; continue
    fi
    key=$(jq -r '"\(.download_state)|\((.progress//0)*100|floor)"' <<<"$item")
    if [[ $key != "$last" ]]; then
      edit "$chat" "$msg" "$(render "$item")"; set_last "$f" "$key"
    fi
  done
}

after_create(){ # chat mid from resp name
  local chat=$1 mid=$2 from=$3 resp=$4 name=$5 id hash detail msgid
  if ! jq -e '.success==true' <<<"$resp" >/dev/null 2>&1; then
    detail=$(jq -r '.detail//empty' <<<"$resp" 2>/dev/null)
    send "$chat" "❌ TorBox rejected it: $(esc "${detail:-no valid response}")" "$mid" >/dev/null; return
  fi
  id=$(jq -r '.data.torrent_id//""' <<<"$resp"); hash=$(jq -r '.data.hash//""' <<<"$resp")
  msgid=$(send "$chat" "✅ <b>Accepted by TorBox</b>"$'\n'"$(esc "$name")"$'\n'"ID: <code>${id:-queued}</code> · fetching status…" "$mid")
  [[ $msgid =~ ^[0-9]+$ ]] || return
  jq -n --arg id "$id" --arg hash "$hash" --argjson chat "$chat" --argjson msg "$msgid" \
        --argjson reply "$mid" --argjson user "$from" --argjson ts "$(date +%s)" \
        '{id:$id,hash:$hash,chat:$chat,msg:$msg,reply:$reply,user:$user,ts:$ts,last:""}' \
        >"$JOBS/$(date +%s)-$RANDOM.json"
}

# ---------- button presses ----------
handle_cb(){
  local u=$1 cid from chat mid data act tid uid r detail
  IFS=$'\t' read -r cid from chat mid data < <(jq -r '[.callback_query.id,.callback_query.from.id,.callback_query.message.chat.id,.callback_query.message.message_id,.callback_query.data]|@tsv' <<<"$u")
  IFS=: read -r act tid uid <<<"${data:-}"
  [[ $chat == "$GROUP_ID" || $chat == "$OWNER_ID" ]] || return 0
  is_user "$from" || return 0
  if [[ $from != "$OWNER_ID" && $from != "$uid" ]]; then cb_answer "$cid" "Only the requester or the owner can do that."; return 0; fi
  [[ $tid =~ ^[0-9]+$ ]] || { cb_answer "$cid" "Bad request."; return 0; }
  case $act in
    del)  set_markup "$chat" "$mid" "$(kb_confirm "$tid" "$uid")"; cb_answer "$cid" "This deletes the WHOLE torrent." ;;
    delx) set_markup "$chat" "$mid" "$(kb_delete "$tid" "$uid")";  cb_answer "$cid" "Cancelled." ;;
    delc)
      r=$(tb_delete "$tid")
      if jq -e '.success==true' <<<"$r" >/dev/null 2>&1; then
        set_markup "$chat" "$mid" '{"inline_keyboard":[]}'
        send "$chat" "🗑 Torrent <code>$tid</code> deleted from TorBox (all files). Its links no longer work." "$mid" >/dev/null
        cb_answer "$cid" "Deleted."
      else
        detail=$(jq -r '.detail//"error"' <<<"$r" 2>/dev/null)
        cb_answer "$cid" "Failed: ${detail:0:150}"
      fi ;;
  esac
}

# ---------- messages ----------
handle(){
  local u=$1 chat from mid text fname mime fid cmd arg tmp resp m f fp
  IFS=$'\t' read -r chat from mid < <(jq -r '[.message.chat.id,.message.from.id,.message.message_id]|@tsv' <<<"$u")
  [[ -n ${chat:-} && $chat != null ]] || return 0
  [[ $chat == "$GROUP_ID" || $chat == "$OWNER_ID" ]] || return 0
  is_user "$from" || return 0

  text=$(jq -r '.message.text // .message.caption // ""' <<<"$u")
  IFS=$'\t' read -r fname mime fid < <(jq -r '[(.message.document.file_name//"-"),(.message.document.mime_type//"-"),(.message.document.file_id//"-")]|@tsv' <<<"$u")

  if [[ $fid != "-" ]] && [[ ${fname,,} == *.torrent || $mime == application/x-bittorrent ]]; then
    fp=$(tg getFile -d "file_id=$fid" | jq -r '.result.file_path//empty')
    [[ -n $fp ]] || { send "$chat" "❌ Couldn't fetch that file from Telegram." "$mid" >/dev/null; return 0; }
    tmp=$(mktemp --suffix=.torrent)
    curl -sS --max-time 60 -o "$tmp" "https://api.telegram.org/file/bot${BOT_TOKEN}/$fp"
    resp=$(tb_file "$tmp"); rm -f "$tmp"
    after_create "$chat" "$mid" "$from" "$resp" "${fname%.torrent}"
    return 0
  fi

  if [[ $text == /* ]]; then
    cmd=${text%%[[:space:]]*}; cmd=${cmd%%@*}
    if [[ $text == *[[:space:]]* ]]; then arg=${text#*[[:space:]]}; arg=${arg%%[[:space:]]*}; else arg=""; fi
    case $cmd in
      /start|/help)
        send "$chat" $'<b>TorBox bridge</b>\nSend a magnet link or a .torrent file.\n/jobs - active downloads\nOwner: /users /adduser &lt;id&gt; /deluser &lt;id&gt;' "$mid" >/dev/null ;;
      /jobs)
        m=""; for f in "$JOBS"/*.json; do m+="• $(jq -r '"\(.hash[0:8]) · \(if .last=="" then "starting" else .last end)"' "$f")"$'\n'; done
        send "$chat" "${m:-No active jobs.}" "$mid" >/dev/null ;;
      /users|/adduser|/deluser)
        if [[ $from != "$OWNER_ID" ]]; then send "$chat" "Owner only." "$mid" >/dev/null; return 0; fi
        case $cmd in
          /users) send "$chat" "Owner: <code>$OWNER_ID</code>"$'\n'"Users:"$'\n'"<code>$(cat "$USERS")</code>" "$mid" >/dev/null ;;
          /adduser)
            if [[ $arg =~ ^[0-9]+$ ]]; then grep -qxF "$arg" "$USERS" || echo "$arg" >>"$USERS"; send "$chat" "Added <code>$arg</code>" "$mid" >/dev/null
            else send "$chat" "Usage: /adduser &lt;numeric id&gt;" "$mid" >/dev/null; fi ;;
          /deluser)
            if [[ $arg =~ ^[0-9]+$ ]]; then grep -vxF "$arg" "$USERS" >"$USERS.tmp"; mv "$USERS.tmp" "$USERS"; send "$chat" "Removed <code>$arg</code>" "$mid" >/dev/null
            else send "$chat" "Usage: /deluser &lt;numeric id&gt;" "$mid" >/dev/null; fi ;;
        esac ;;
    esac
    return 0
  fi

  while IFS= read -r m; do
    resp=$(tb_magnet "$m" </dev/null)
    after_create "$chat" "$mid" "$from" "$resp" "Fetching metadata…"
  done < <(grep -oE 'magnet:\?xt=urn:btih:[^[:space:]]+' <<<"$text")
  return 0
}

# ---------- main loop ----------
tg deleteWebhook >/dev/null 2>&1
OFFSET=$(cat "$STATE/offset" 2>/dev/null || echo 0)
LAST_POLL=0
log "bot started"
while true; do
  resp=$(curl -sS --max-time 30 -G "$TG/getUpdates" --data-urlencode "offset=$OFFSET" \
         -d timeout=10 --data-urlencode 'allowed_updates=["message","callback_query"]') || { sleep 5; continue; }
  if jq -e '.ok==true' <<<"$resp" >/dev/null 2>&1; then
    while IFS= read -r u; do
      OFFSET=$(( $(jq -r .update_id <<<"$u") + 1 )); echo "$OFFSET" >"$STATE/offset"
      if jq -e '.callback_query' <<<"$u" >/dev/null 2>&1; then
        handle_cb "$u" </dev/null || log "callback error"
      else
        handle "$u" </dev/null || log "handler error"
      fi
    done < <(jq -c '.result[]' <<<"$resp")
  else
    sleep 5
  fi
  now=$(date +%s)
  if (( now - LAST_POLL >= POLL_SECS )); then poll_jobs; LAST_POLL=$now; fi
done
