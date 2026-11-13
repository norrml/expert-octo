## line 14 15 add you local dir here or in env
#!/usr/bin/env bash
# TorBox <-> Telegram bridge. Needs: bash>=4, curl, jq, awk, sed, procps, util-linux
set -u
shopt -s nullglob

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/.env"
: "${BOT_TOKEN:?}" "${TORBOX_KEY:?}" "${GROUP_ID:?}" "${OWNER_ID:?}"
POLL_SECS="${POLL_SECS:-10}"
MAX_FILES="${MAX_FILES:-25}"
LINK_MAX="${LINK_MAX:-10}"
JOB_TTL_DAYS="${JOB_TTL_DAYS:-14}"
EXT_RE="${EXT_RE:-mp4|mkv|srt}"
DL_DIR="${DL_DIR:-/home/user}"   
DL_MOUNT="${DL_MOUNT:-/home/xxxxx}"
DL_REQUIRE_MOUNT="${DL_REQUIRE_MOUNT:-1}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"
MAX_FILE_GB="${MAX_FILE_GB:-0}"

STATE="$DIR/state"; JOBS="$STATE/jobs"; USERS="$STATE/users.txt"
ACT="$STATE/active.json"; ACT_ERR="$STATE/active.err"
SELF="$(basename "${BASH_SOURCE[0]}")"
mkdir -p "$JOBS"; touch "$USERS"

TG="https://api.telegram.org/bot${BOT_TOKEN}"
TB="https://api.torbox.app/v1/api"

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
jset(){ local f=$1; shift; jq "$@" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }
set_last(){ jq --arg l "$2" '.last=$l' "$1" >"$1.tmp" && mv "$1.tmp" "$1"; }
jobset(){ # jobfile idx expr [jq args...]  -> updates .files[idx]
  local f=$1 i=$2 e=$3; shift 3
  jq --argjson i "$i" "$@" ".files[\$i] |= ($e)" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}
pid_ours(){ [[ -r /proc/$1/cmdline ]] && tr '\0' ' ' </proc/$1/cmdline | grep -qF "$SELF"; }

# torrent file names are attacker-controlled: basename only, no control chars, no leading dots
safe_name(){ # name fid
  local n=${1##*/} ext=""
  n=$(printf '%s' "$n" | tr -d '\000-\037\177')
  n=${n#"${n%%[!. ]*}"}
  [[ -n $n ]] || n="file-$2"
  if (( ${#n} > 120 )); then
    [[ $n == *.* ]] && ext=${n##*.}
    (( ${#ext} > 8 )) && ext=""
    n="${n:0:110}${ext:+.$ext}"
  fi
  printf '%s' "$n"
}

tg(){ local m=$1; shift; curl -sS --max-time 30 -X POST "$TG/$m" "$@"; }

send(){ # chat text [reply_to] [markup] -> prints message_id
  local chat=$1 text=$2 reply=${3:-} markup=${4:-}
  local a=(--data-urlencode "chat_id=$chat" --data-urlencode "text=$text"
           -d parse_mode=HTML -d 'link_preview_options={"is_disabled":true}')
  [[ -n $reply ]]  && a+=(--data-urlencode "reply_parameters={\"message_id\":$reply,\"allow_sending_without_reply\":true}")
  [[ -n $markup ]] && a+=(--data-urlencode "reply_markup=$markup")
  tg sendMessage "${a[@]}" | jq -r '.result.message_id // empty'
}

edit(){ # chat msg text [markup]  (no markup => buttons removed). returns 0 on success
  local a=(--data-urlencode "chat_id=$1" -d "message_id=$2" --data-urlencode "text=$3"
           -d parse_mode=HTML -d 'link_preview_options={"is_disabled":true}') out
  [[ -n ${4:-} ]] && a+=(--data-urlencode "reply_markup=$4")
  out=$(tg editMessageText "${a[@]}")
  jq -e '.ok==true' <<<"$out" >/dev/null 2>&1 && return 0
  [[ $out == *"not modified"* ]] && return 0
  log "edit failed: ${out:0:160}"; return 1
}

set_markup(){ tg editMessageReplyMarkup --data-urlencode "chat_id=$1" -d "message_id=$2" --data-urlencode "reply_markup=$3" >/dev/null; }
cb_answer(){ tg answerCallbackQuery -d "callback_query_id=$1" --data-urlencode "text=$2" >/dev/null; }

kb_confirm(){ jq -nc --arg y "delc:$1" --arg n "delx:$1" '{inline_keyboard:[[{text:"⚠️ Yes, delete all",callback_data:$y},{text:"Cancel",callback_data:$n}]]}'; }

tb_get(){ local ep=$1; shift; curl -sS --max-time 30 -G -H "Authorization: Bearer $TORBOX_KEY" "$TB/$ep" "$@"; }
tb_magnet(){ curl -sS --max-time 60 -H "Authorization: Bearer $TORBOX_KEY" -F "magnet=$1" "$TB/torrents/createtorrent"; }
tb_file(){ curl -sS --max-time 90 -H "Authorization: Bearer $TORBOX_KEY" -F "file=@$1;type=application/x-bittorrent" "$TB/torrents/createtorrent"; }
tb_delete(){ curl -sS --max-time 30 -X POST -H "Authorization: Bearer $TORBOX_KEY" -H "Content-Type: application/json" \
             -d "{\"torrent_id\":$1,\"operation\":\"delete\"}" "$TB/torrents/controltorrent"; }
tb_link(){ # torrent_id file_id -> prints url or nothing
  tb_get torrents/requestdl --data-urlencode "token=$TORBOX_KEY" -d "torrent_id=$1" -d "file_id=$2" -d redirect=false </dev/null \
    | jq -r 'if (.data|type)=="string" then .data else empty end' 2>/dev/null
}

# ---------- torrent-phase status text ----------
render_torrent(){ # mylist item json -> status text
  local state prog speed eta size seeds peers name pct fill bar i
  IFS=$'\t' read -r state prog speed eta size seeds peers name < <(jq -r \
    '[(.download_state//"unknown"),(.progress//0),(.download_speed//0),(.eta//0),(.size//0),(.seeds//0),(.peers//0),(.name//"...")]|@tsv' <<<"$1")
  pct=$(awk -v p="$prog" 'BEGIN{printf "%d",p*100}')
  fill=$((pct/10)); bar=""
  for ((i=0;i<10;i++)); do ((i<fill)) && bar+="▓" || bar+="░"; done
  printf '📥 <b>%s</b>\nState: <code>%s</code>\n%s %s%%\n⚡ %s/s · ETA %s · %s\n🌱 %s seeds · %s peers' \
    "$(esc "$name")" "$(esc "$state")" "$bar" "$pct" "$(hb "$speed")" "$(ht "$eta")" "$(hb "$size")" "$seeds" "$peers"
}

# ---------- files-phase message ----------
render_job_text(){ # job_json active_json(optional)
  local name shown total all jkey akey ai abytes aspeed asize
  name=$(jq -r '.name' <<<"$1"); shown=$(jq '.files|length' <<<"$1")
  total=$(jq '.total' <<<"$1"); all=$(jq '.all' <<<"$1"); jkey=$(jq -r '.key' <<<"$1")
  akey=""; ai=-1; abytes=0; aspeed=0; asize=0
  if [[ -n ${2:-} ]]; then
    IFS=$'\t' read -r akey ai abytes aspeed asize < <(jq -r '[.key,.i,.bytes,.speed,.size]|@tsv' <<<"$2")
  fi
  if (( shown == 0 )); then
    printf '📦 <b>%s</b>\nNo %s files found (%s files total, samples ignored).' "$(esc "$name")" "${EXT_RE//|//}" "$all"
    return
  fi
  local -a L=() U=()
  local n st size url err base icon line short pct fill bar i eta
  while IFS=$'\t' read -r n st size url err base; do
    case $st in done) icon="✅";; running) icon="⬇️";; queued) icon="⏳";; failed) icon="❌";; *) icon="⬜";; esac
    short=${base:0:55}; (( ${#base} > 55 )) && short+="…"
    line="$icon $n. $(esc "$short")"
    if [[ $st == running && $jkey == "$akey" && $((n-1)) == "$ai" ]]; then
      pct=0; (( size > 0 )) && pct=$(( abytes * 100 / size )); (( pct > 100 )) && pct=100
      fill=$((pct/10)); bar=""
      for ((i=0;i<10;i++)); do ((i<fill)) && bar+="▓" || bar+="░"; done
      eta=0; (( aspeed > 0 && size > abytes )) && eta=$(( (size - abytes) / aspeed ))
      line+=$'\n'"   $bar ${pct}% · $(hb "$aspeed")/s · ETA $(ht "$eta") · $(hb "$abytes") / $(hb "$size")"
    elif [[ $st == failed && $err != "-" ]]; then
      line+=" — $(esc "${err:0:80}")"
    fi
    L+=("$line")
    if [[ $url != "-" && $st != done ]]; then U+=("<code>$(esc "$url")</code>"); else U+=(""); fi
  done < <(jq -r '.files[]|[.n,.state,.size,(if (.url//"")=="" then "-" else .url end),(if (.err//"")=="" then "-" else .err end),.base]|@tsv' <<<"$1")

  local head tail used budget out k have=0 skipped=0
  head="📦 <b>$(esc "$name")</b> · ${total} of ${all} file(s)"$'\n'"Tap a number below to save it to the server."
  tail=""; (( total > shown )) && tail=$'\n\n'"… $((total-shown)) more matching file(s) not shown."
  used=$(( ${#head} + ${#tail} + 150 ))
  for line in "${L[@]}"; do used=$(( used + ${#line} + 1 )); done
  budget=$(( 3900 - used ))
  out="$head"
  for k in "${!L[@]}"; do
    out+=$'\n'"${L[$k]}"
    if [[ -n ${U[$k]} ]]; then
      if (( ${#U[$k]} + 1 <= budget && have < LINK_MAX )); then
        out+=$'\n'"${U[$k]}"; budget=$(( budget - ${#U[$k]} - 1 )); ((have++))
      else
        ((skipped++))
      fi
    fi
  done
  (( skipped > 0 )) && out+=$'\n\n'"ℹ️ Links hidden for $skipped file(s) (message size limit); use the buttons."
  out+="$tail"
  printf '%s' "$out"
}

render_job_kb(){ # job_json
  jq -c --arg key "$(jq -r '.key' <<<"$1")" '
    (.files // []) as $f
    | (($f | map(select(.state=="queued" or .state=="running")) | length) > 0) as $act
    | ([range(0; ($f|length); 5)] | map(. as $i | $f[$i:$i+5] | map({
        text: ((if .state=="done" then "✅" elif .state=="running" then "⬇️" elif .state=="queued" then "⏳" elif .state=="failed" then "❌" else "⬜" end) + " " + (.n|tostring)),
        callback_data: ("dl:" + $key + ":" + (.n|tostring))
      }))) as $rows
    | {inline_keyboard: ($rows + (if $act then [[{text:"⛔ Cancel all", callback_data:("dc:"+$key)}]]
                                          else [[{text:"🗑 Delete from TorBox", callback_data:("del:"+$key)}]] end))}' <<<"$1"
}

refresh_job(){ # jobfile -> re-render + edit only if changed
  local f=$1 j act text kb sig last chat msg
  [[ -f $f ]] || return 0
  j=$(<"$f")
  [[ $(jq -r '.phase' <<<"$j") == files ]] || return 0
  act=""; [[ -f $ACT ]] && act=$(<"$ACT")
  text=$(render_job_text "$j" "$act"); kb=$(render_job_kb "$j")
  sig=$(printf '%s%s' "$text" "$kb" | cksum | cut -d' ' -f1)
  last=$(jq -r '.last//""' <<<"$j")
  if [[ $sig != "$last" ]]; then
    IFS=$'\t' read -r chat msg < <(jq -r '[.chat,.msg]|@tsv' <<<"$j")
    edit "$chat" "$msg" "$text" "$kb" && set_last "$f" "$sig"
  fi
}

render_jobs(){
  local f now chat msg ts
  now=$(date +%s)
  for f in "$JOBS"/*.json; do
    [[ $(jq -r '.phase' "$f") == files ]] || continue
    ts=$(jq -r '.ts' "$f")
    if (( now - ts > JOB_TTL_DAYS*86400 )) && ! jq -e '[.files[]|select(.state=="queued" or .state=="running")]|length>0' "$f" >/dev/null 2>&1; then
      IFS=$'\t' read -r chat msg < <(jq -r '[.chat,.msg]|@tsv' "$f")
      set_markup "$chat" "$msg" '{"inline_keyboard":[]}'; rm -f "$f"; continue
    fi
    refresh_job "$f"
  done
}

# ---------- torrent jobs ----------
torrent_ready(){ # jobfile item_json -> builds file list, switches job to files phase
  local f=$1 item=$2 tid name all total arr n fid size fname base url
  tid=$(jq -r '.id' <<<"$item"); name=$(jq -r '.name//"torrent"' <<<"$item")
  all=$(jq '.files|length' <<<"$item")
  total=$(jq --arg re "$EXT_RE" '[.files[]? | '"$JQ_SEL"'] | length' <<<"$item")
  arr="[]"; n=0
  while IFS=$'\t' read -r fid size fname; do
    ((n++)); ((n>MAX_FILES)) && break
    [[ $fid =~ ^[0-9]+$ ]] || continue
    [[ $size =~ ^[0-9]+$ ]] || size=0
    url=""; (( n <= LINK_MAX )) && url=$(tb_link "$tid" "$fid")
    base=$(safe_name "$fname" "$fid")
    arr=$(jq -c --argjson n "$n" --argjson fid "$fid" --argjson size "$size" --arg base "$base" --arg url "$url" \
      '. + [{n:$n,fid:$fid,size:$size,base:$base,url:$url,state:"idle",err:"",final:"",qts:0}]' <<<"$arr")
  done < <(jq -r --arg re "$EXT_RE" '.files[]? | '"$JQ_SEL"' | [.id,(.size//0),(.short_name//.name//"file")] | @tsv' <<<"$item")
  jset "$f" --argjson files "$arr" --argjson total "$total" --argjson all "$all" --arg name "$name" --argjson tid "$tid" \
    '.phase="files"|.files=$files|.total=$total|.all=$all|.name=$name|.tid=$tid|.last=""'
}

poll_torrents(){
  local files=("$JOBS"/*.json) f list id hash chat msg ts last item state key name now cnt
  ((${#files[@]})) || return 0
  cnt=$(jq -rs 'map(select(.phase=="torrent"))|length' "${files[@]}" 2>/dev/null)
  (( ${cnt:-0} > 0 )) || return 0
  list=$(tb_get torrents/mylist -d bypass_cache=true </dev/null)
  jq -e '.success==true' <<<"$list" >/dev/null 2>&1 || { log "mylist failed"; return 0; }
  now=$(date +%s)
  for f in "${files[@]}"; do
    [[ $(jq -r '.phase' "$f") == torrent ]] || continue
    IFS=$'\t' read -r id hash chat msg ts last < <(jq -r \
      '[(.id|if .==""then"-"else . end),(.hash|if .==""then"-"else . end),.chat,.msg,.ts,(if (.last//"")=="" then "-" else .last end)]|@tsv' "$f")
    item=$(jq -c --arg id "$id" --arg h "${hash,,}" \
      '(.data//[])|(if type=="array" then . else [.] end)|map(select(((.id|tostring)==$id) or ((.hash//""|ascii_downcase)==$h)))|.[0]//empty' <<<"$list")

    if [[ -z $item ]]; then
      if (( now-ts > 7200 )); then
        edit "$chat" "$msg" "⚠️ Torrent no longer found on TorBox."; rm -f "$f"
      elif [[ $last != queued ]]; then
        edit "$chat" "$msg" "⏳ Queued on TorBox, waiting for a slot…" && set_last "$f" queued
      fi
      continue
    fi

    state=$(jq -r '.download_state//""' <<<"$item")
    name=$(jq -r '.name//"torrent"' <<<"$item")
    if [[ ${state,,} =~ ^(error|failed) ]]; then
      edit "$chat" "$msg" "❌ <b>$(esc "$name")</b>"$'\n'"TorBox state: <code>$(esc "$state")</code>"; rm -f "$f"; continue
    fi
    if jq -e '.download_finished==true' <<<"$item" >/dev/null 2>&1; then
      torrent_ready "$f" "$item"; continue
    fi
    key=$(jq -r '"\(.download_state)|\((.progress//0)*100|floor)"' <<<"$item")
    if [[ $key != "$last" ]]; then
      edit "$chat" "$msg" "$(render_torrent "$item")" && set_last "$f" "$key"
    fi
  done
}

after_create(){ # chat mid from resp name
  local chat=$1 mid=$2 from=$3 resp=$4 name=$5 id hash detail msgid key
  if ! jq -e '.success==true' <<<"$resp" >/dev/null 2>&1; then
    detail=$(jq -r '.detail//empty' <<<"$resp" 2>/dev/null)
    send "$chat" "❌ TorBox rejected it: $(esc "${detail:-no valid response}")" "$mid" >/dev/null; return
  fi
  id=$(jq -r '.data.torrent_id//""' <<<"$resp"); hash=$(jq -r '.data.hash//""' <<<"$resp")
  msgid=$(send "$chat" "✅ <b>Accepted by TorBox</b>"$'\n'"$(esc "$name")"$'\n'"ID: <code>${id:-queued}</code> · fetching status…" "$mid")
  [[ $msgid =~ ^[0-9]+$ ]] || return
  key="$(date +%s)-$RANDOM"
  jq -n --arg key "$key" --arg id "$id" --arg hash "$hash" --arg name "$name" \
        --argjson chat "$chat" --argjson msg "$msgid" --argjson reply "$mid" --argjson user "$from" --argjson ts "$(date +%s)" \
        '{key:$key,phase:"torrent",id:$id,hash:$hash,name:$name,chat:$chat,msg:$msg,reply:$reply,user:$user,ts:$ts,last:"",tid:0,total:0,all:0,files:[]}' \
        >"$JOBS/$key.json"
}

# ---------- server downloads (one at a time, global) ----------
file_fail(){ jobset "$1" "$2" '.state="failed"|.err=$e' --arg e "$3"; }

dl_fail(){ # reason  (fails the active download)
  local key i f
  IFS=$'\t' read -r key i < <(jq -r '[.key,.i]|@tsv' "$ACT")
  f="$JOBS/$key.json"
  [[ -f $f ]] && file_fail "$f" "$i" "$1"
  rm -f "$ACT" "$ACT_ERR" "$STATE"/active.*.exit
}

dl_bump(){ # reason -> returns 1 if gave up
  local t; t=$(jq -r '.tries' "$ACT"); t=$((t+1))
  if (( t >= 3 )); then dl_fail "$1"; return 1; fi
  jset "$ACT" --argjson t "$t" '.tries=$t'; return 0
}

dl_launch(){ # (re)start curl for the active download with a FRESH link; resumes .part
  local tid fid final size url part nonce pb pid
  IFS=$'\t' read -r tid fid final size < <(jq -r '[.tid,.fid,.final,.size]|@tsv' "$ACT")
  url=$(tb_link "$tid" "$fid")
  if [[ -z $url ]]; then dl_bump "couldn't get a download link from TorBox"; return 1; fi
  part="$DL_DIR/$final.part"; nonce="$RANDOM$RANDOM"
  rm -f "$STATE"/active.*.exit
  pb=$(stat -c %s "$part" 2>/dev/null || echo 0)
  if (( size > 0 && pb == size )); then      # already complete, nothing to fetch
    echo 0 >"$STATE/active.$nonce.exit"
    jset "$ACT" --arg nonce "$nonce" --argjson pb "$pb" --argjson pt "$(date +%s)" '.pid=0|.nonce=$nonce|.pb=$pb|.pt=$pt'
    return 0
  fi
  ( printf 'url = "%s"\n' "$url" | curl -K - -fL -sS -C - --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
        -o "$part" 2>"$ACT_ERR"; echo $? >"$STATE/active.$nonce.exit" ) &
  pid=$!
  disown "$pid" 2>/dev/null
  jset "$ACT" --argjson p "$pid" --arg nonce "$nonce" --argjson pb "$pb" --argjson pt "$(date +%s)" '.pid=$p|.nonce=$nonce|.pb=$pb|.pt=$pt'
}

dl_try_start(){ # key idx
  local key=$1 i=$2 f="$JOBS/$1.json" tid fid base size final free need
  IFS=$'\t' read -r tid fid base size < <(jq -r --argjson i "$i" '[.tid,.files[$i].fid,.files[$i].base,.files[$i].size]|@tsv' "$f")
  if [[ $DL_REQUIRE_MOUNT == 1 ]] && ! mountpoint -q "$DL_MOUNT"; then file_fail "$f" "$i" "$DL_MOUNT is not mounted"; return; fi
  mkdir -p "$DL_DIR" 2>/dev/null; [[ -w $DL_DIR ]] || { file_fail "$f" "$i" "download dir not writable"; return; }
  free=$(df --output=avail -B1 "$DL_DIR" 2>/dev/null | tail -n1 | tr -d ' ')
  need=$(( size + MIN_FREE_GB*1073741824 ))
  if [[ $free =~ ^[0-9]+$ ]] && (( free < need )); then
    file_fail "$f" "$i" "not enough free space ($(hb "$free") free)"; return
  fi
  final=$base
  if [[ -e $DL_DIR/$final ]]; then
    if [[ $(stat -c %s "$DL_DIR/$final") == "$size" ]]; then
      jobset "$f" "$i" '.state="done"|.final=$fn|.err=""' --arg fn "$final"; return
    fi
    if [[ $final == *.* ]]; then final="${final%.*}.${tid}-${fid}.${final##*.}"; else final="$final.${tid}-${fid}"; fi
  fi
  jq -n --arg key "$key" --argjson i "$i" --argjson tid "$tid" --argjson fid "$fid" --arg final "$final" --argjson size "$size" \
    '{key:$key,i:$i,tid:$tid,fid:$fid,final:$final,size:$size,pid:0,pb:0,pt:0,tries:0,nonce:"",bytes:0,speed:0}' >"$ACT"
  jobset "$f" "$i" '.state="running"|.final=$fn|.err=""' --arg fn "$final"
  dl_launch
}

dl_next(){ # start the oldest queued file (any job) if nothing is running
  [[ -f $ACT ]] && return 0
  local files q key i guard=0
  while (( guard++ < 30 )); do
    files=("$JOBS"/*.json); ((${#files[@]})) || return 0
    key=""; q=""; i=""
    read -r q key i < <(jq -r '.key as $k|(.files//[])|to_entries[]|select(.value.state=="queued")|[.value.qts,$k,.key]|@tsv' "${files[@]}" 2>/dev/null | sort -n | head -n1)
    [[ -n $key ]] || return 0
    dl_try_start "$key" "$i"
    [[ -f $ACT ]] && return 0
  done
}

dl_cancel(){ # key idx
  local key=$1 i=$2 f="$JOBS/$1.json" st final pid
  st=$(jq -r --argjson i "$i" '.files[$i].state' "$f")
  if [[ $st == running && -f $ACT ]] && [[ $(jq -r '.key' "$ACT") == "$key" && $(jq -r '.i' "$ACT") == "$i" ]]; then
    pid=$(jq -r '.pid' "$ACT"); final=$(jq -r '.final' "$ACT")
    if (( pid > 0 )); then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; fi
    rm -f "$DL_DIR/$final.part" "$ACT" "$ACT_ERR" "$STATE"/active.*.exit
  fi
  jobset "$f" "$i" '.state="idle"|.err=""|.final=""'
}

dl_check(){
  [[ -f $ACT ]] || return 0
  local key i final size pid pb pt nonce f exitf part rc bytes now speed errtxt
  IFS=$'\t' read -r key i final size pid pb pt nonce < <(jq -r '[.key,.i,.final,.size,.pid,.pb,.pt,(if .nonce=="" then "-" else .nonce end)]|@tsv' "$ACT")
  f="$JOBS/$key.json"; part="$DL_DIR/$final.part"; exitf="$STATE/active.$nonce.exit"

  if [[ ! -f $f ]]; then                       # job vanished: stop everything
    (( pid > 0 )) && { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
    rm -f "$part" "$ACT" "$ACT_ERR" "$STATE"/active.*.exit; return 0
  fi

  if [[ -f $exitf ]]; then
    rc=$(<"$exitf"); rm -f "$exitf"
    if [[ $rc == 0 ]]; then
      bytes=$(stat -c %s "$part" 2>/dev/null || echo 0)
      if (( size > 0 && bytes != size )); then rm -f "$part"; dl_fail "size mismatch (got $(hb "$bytes"), expected $(hb "$size"))"; return 0; fi
      if [[ -e $DL_DIR/$final ]]; then dl_fail "target file already exists"; return 0; fi
      mv -n "$part" "$DL_DIR/$final"
      jobset "$f" "$i" '.state="done"|.err=""'
      rm -f "$ACT" "$ACT_ERR"
    else
      errtxt=$(tail -c 150 "$ACT_ERR" 2>/dev/null | tr '\n' ' ')
      [[ $rc == 33 ]] && rm -f "$part"          # server refused resume: start over
      dl_bump "curl exit $rc $errtxt" && dl_launch
    fi
    return 0
  fi

  # no exit file: still running, or died with the bot -> resume
  if ! { (( pid > 0 )) && pid_ours "$pid"; }; then dl_launch; return 0; fi

  now=$(date +%s)
  bytes=$(stat -c %s "$part" 2>/dev/null || echo 0)
  speed=0; (( now > pt )) && speed=$(( (bytes - pb) / (now - pt) )); (( speed < 0 )) && speed=0
  jset "$ACT" --argjson b "$bytes" --argjson s "$speed" --argjson pt "$now" '.bytes=$b|.speed=$s|.pb=$b|.pt=$pt'
}

# ---------- button presses ----------
handle_cb(){
  local u=$1 cid from chat mid data act key n f user i st size r detail tid name idx
  IFS=$'\t' read -r cid from chat mid data < <(jq -r '[.callback_query.id,.callback_query.from.id,.callback_query.message.chat.id,.callback_query.message.message_id,.callback_query.data]|@tsv' <<<"$u")
  IFS=: read -r act key n <<<"${data:-}"
  [[ $chat == "$GROUP_ID" || $chat == "$OWNER_ID" ]] || return 0
  is_user "$from" || return 0
  [[ $key =~ ^[0-9]+-[0-9]+$ ]] || return 0
  f="$JOBS/$key.json"
  [[ -f $f ]] || { cb_answer "$cid" "This message is no longer active."; return 0; }
  user=$(jq -r '.user' "$f")
  if [[ $from != "$OWNER_ID" && $from != "$user" ]]; then cb_answer "$cid" "Only the requester or the owner can do that."; return 0; fi

  case $act in
    dl)
      [[ $n =~ ^[0-9]+$ ]] || { cb_answer "$cid" "Bad request."; return 0; }
      i=$((n-1))
      IFS=$'\t' read -r st size < <(jq -r --argjson i "$i" '.files[$i]|[(.state//"-"),(.size//0)]|@tsv' "$f")
      [[ $st != "-" && -n $st ]] || { cb_answer "$cid" "File not found."; return 0; }
      case $st in
        done)         cb_answer "$cid" "Already saved on the server." ;;
        queued|running) dl_cancel "$key" "$i"; cb_answer "$cid" "Cancelled." ;;
        *)
          if [[ $from != "$OWNER_ID" ]] && (( MAX_FILE_GB > 0 && size > MAX_FILE_GB*1073741824 )); then
            cb_answer "$cid" "File is over the ${MAX_FILE_GB} GB limit."; return 0
          fi
          jobset "$f" "$i" '.state="queued"|.qts=$q|.err=""' --argjson q "$(date +%s%3N)"
          cb_answer "$cid" "Queued." ;;
      esac
      dl_next; refresh_job "$f" ;;

    dc)
      while IFS= read -r idx; do dl_cancel "$key" "$idx"; done < <(jq -r '.files|to_entries[]|select(.value.state=="queued" or .value.state=="running")|.key' "$f")
      cb_answer "$cid" "Cancelled."
      dl_next; refresh_job "$f" ;;

    del|delx|delc)
      if [[ $act != delx ]] && jq -e '[.files[]|select(.state=="queued" or .state=="running")]|length>0' "$f" >/dev/null 2>&1; then
        cb_answer "$cid" "Downloads are queued/running. Wait or cancel them first."; return 0
      fi
      case $act in
        del)  set_markup "$chat" "$mid" "$(kb_confirm "$key")"; cb_answer "$cid" "This deletes the WHOLE torrent." ;;
        delx) set_markup "$chat" "$mid" "$(render_job_kb "$(<"$f")")"; cb_answer "$cid" "Cancelled." ;;
        delc)
          tid=$(jq -r '.tid' "$f"); name=$(jq -r '.name' "$f")
          r=$(tb_delete "$tid")
          if jq -e '.success==true' <<<"$r" >/dev/null 2>&1; then
            edit "$chat" "$mid" "🗑 <b>$(esc "$name")</b> deleted from TorBox (all files)."
            rm -f "$f"; cb_answer "$cid" "Deleted."
          else
            detail=$(jq -r '.detail//"error"' <<<"$r" 2>/dev/null)
            cb_answer "$cid" "Failed: ${detail:0:150}"
          fi ;;
      esac ;;
  esac
}

# ---------- messages ----------
handle(){
  local u=$1 chat from mid text fname mime fid cmd arg tmp resp m f fp files
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
        send "$chat" $'<b>TorBox bridge</b>\nSend a magnet link or a .torrent file.\n/jobs - torrents being tracked\n/downloads - server downloads\nOwner: /users /adduser &lt;id&gt; /deluser &lt;id&gt;' "$mid" >/dev/null ;;
      /jobs)
        m=""; for f in "$JOBS"/*.json; do m+="• $(jq -r '"\(.phase) · \(if .name=="" then .hash[0:8] else .name end)"' "$f" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"$'\n'; done
        send "$chat" "${m:-No tracked torrents.}" "$mid" >/dev/null ;;
      /downloads)
        files=("$JOBS"/*.json); m=""
        if ((${#files[@]})); then
          m=$(jq -rs '[.[]|(.files//[])[]|select(.state=="queued" or .state=="running")|"\(.state) · \(.base)"]|.[]' "${files[@]}" 2>/dev/null | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
        fi
        send "$chat" "${m:-No queued or running downloads.}" "$mid" >/dev/null ;;
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
tick(){ poll_torrents; dl_check; dl_next; render_jobs; }

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
  if (( now - LAST_POLL >= POLL_SECS )); then tick; LAST_POLL=$now; fi
done
