#!/usr/bin/env bash
# Probe the CURRENT terminal for graphics-protocol support. Run this IN the
# window you want to test (e.g. the WezTerm SSH session). It sends terminal
# queries and reports what comes back.

echo "TERM=$TERM"
echo "TERM_PROGRAM=${TERM_PROGRAM:-(unset)}"
echo "COLORTERM=${COLORTERM:-(unset)}"
wz=$(env | grep -i wezterm | tr '\n' ' ')
echo "WEZTERM env: ${wz:-(none)}"
echo

# Send an escape sequence to the tty and collect whatever the terminal replies
# (raw mode, byte-by-byte, with a short idle timeout).
query() {
  local old out="" c
  old=$(stty -g </dev/tty)
  stty -echo raw </dev/tty
  printf '%b' "$1" >/dev/tty
  sleep 0.3
  while IFS= read -r -t 0.1 -n 1 c </dev/tty; do
    out+="$c"
  done
  stty "$old" </dev/tty
  printf '%s' "$out"
}

echo "== Primary Device Attributes (sixel advertised if the list contains 4) =="
da=$(query '\033[c')
printf '%s\n' "$da" | cat -v
case ";$da;" in
  *';4;'* | *';4c'*) echo ">> SIXEL: SUPPORTED" ;;
  *) echo ">> SIXEL: not advertised" ;;
esac
echo

echo "== Kitty graphics query (supported if reply contains OK) =="
kt=$(query '\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\033\\\033[c')
printf '%s\n' "$kt" | cat -v
case "$kt" in
  *OK*) echo ">> KITTY GRAPHICS: SUPPORTED" ;;
  *) echo ">> KITTY GRAPHICS: not supported (no OK in reply)" ;;
esac
echo
echo "(If BOTH replies are empty, the tty/transport is swallowing responses —"
echo " you're likely still on the ConPTY path, not WezTerm's native SSH.)"
