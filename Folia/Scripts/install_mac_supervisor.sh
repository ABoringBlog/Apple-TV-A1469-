#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 MAC_LAN_IPV4 APPLE_TV_IPV4 /path/to/DedicatedFoliaATV3.app" >&2
  exit 2
fi
MAC_IP="$1"
ATV_IP="$2"
APP_BUNDLE="$3"
export FOLIA_INPUT_MAC_IP="$MAC_IP"
export FOLIA_INPUT_ATV_IP="$ATV_IP"
export FOLIA_INPUT_APP_BUNDLE="$APP_BUNDLE"
export FOLIA_INPUT_ROOT="$ROOT"
AGENTS="$HOME/Library/LaunchAgents"
TARGET="$AGENTS/org.atv3.bridge.folia-supervisor.plist"
mkdir -p "$AGENTS" "$HOME/Library/Logs/FoliaATV3"
if [[ ! -x "$APP_BUNDLE/Contents/MacOS/Folia" ]]; then
  echo "Missing dedicated patched Folia executable: $APP_BUNDLE/Contents/MacOS/Folia" >&2
  exit 3
fi
if [[ ! -x "$ROOT/Mac/Bridge/folia_native_vt1080_encoder" ]]; then
  echo "Build the Mac VideoToolbox encoder first: ./Scripts/build_mac_encoder.sh" >&2
  exit 4
fi
/usr/bin/python3 - "$TARGET" <<'PY'
import ipaddress,os,plistlib,pathlib,sys
m=os.environ['FOLIA_INPUT_MAC_IP']
a=os.environ['FOLIA_INPUT_ATV_IP']
for v in (m,a): ipaddress.IPv4Address(v)
root=pathlib.Path(os.environ['FOLIA_INPUT_ROOT'])
bundle=pathlib.Path(os.environ['FOLIA_INPUT_APP_BUNDLE']).expanduser().resolve()
target=pathlib.Path(sys.argv[1])
config={'Label':'org.atv3.bridge.folia-supervisor',
 'RunAtLoad':True,'KeepAlive':True,
 'ProgramArguments':['/usr/bin/python3','-u',str(root/'Mac/Supervisor/folia_supervisor.py')],
 'WorkingDirectory':str(root),
 'EnvironmentVariables':{'FOLIA_ATV3_MAC_HOST':m, 'FOLIA_ATV3_ATV_IP':a,
    'FOLIA_ATV3_APP':str(bundle/'Contents/MacOS/Folia'),
    'FOLIA_ATV3_NATIVE_ENCODER':str(root/'Mac/Bridge/folia_native_vt1080_encoder')},
 'StandardOutPath':str(pathlib.Path.home()/'Library/Logs/FoliaATV3/supervisor.log'),
 'StandardErrorPath':str(pathlib.Path.home()/'Library/Logs/FoliaATV3/supervisor-error.log')}
if target.exists():
  old=target.with_suffix('.plist.backup')
  old.write_bytes(target.read_bytes())
target.write_bytes(plistlib.dumps(config))
print('Installed per-user supervisor:',target)
PY
# Do not modify/stop the dedicated Folia process; only reload the supervisor.
UID_NUM="$(id -u)"
/bin/launchctl bootout "gui/$UID_NUM" "$TARGET" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$UID_NUM" "$TARGET"
/bin/launchctl kickstart "gui/$UID_NUM/org.atv3.bridge.folia-supervisor" >/dev/null
echo "Supervisor configured. Mac and Apple TV must remain on the same trusted LAN."
