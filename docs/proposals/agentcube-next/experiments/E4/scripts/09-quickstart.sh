#!/usr/bin/env bash
# E2 step 09: CubeSandbox's Quick Start, steps 3 and 4: a code-interpreter
# template from the published image, then code executed in a sandbox through
# the E2B Python SDK. The SDK is installed with uv into its own environment;
# the system Python is not touched.
set -uo pipefail
T=/usr/local/services/cubetoolbox
CLI=$T/CubeMaster/bin/cubemastercli
IMAGE=${IMAGE:-cube-sandbox-int.tencentcloudcr.com/cube-sandbox/sandbox-code:latest}
W=${W:-/root/e2/quickstart}
install -d -m 0755 "$W" /root/e2/bin
before=$(journalctl -k -b --no-pager -q | wc -l)

echo "## uv"
if [[ ! -x /root/e2/bin/uv ]]; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/root/e2/bin UV_NO_MODIFY_PATH=1 sh > "$W/uv-install.out" 2>&1 || { tail -5 "$W/uv-install.out"; exit 1; }
fi
/root/e2/bin/uv --version; sha256sum /root/e2/bin/uv

echo "## template from $IMAGE"
if [[ -s "$W/template-id" ]] && "$CLI" template info --template-id "$(cat "$W/template-id")" --json 2> /dev/null | grep -q '"status": *"READY"'; then
  echo "reusing READY template $(cat "$W/template-id")"
else
  start=$(date +%s)
  "$CLI" template create-from-image --image "$IMAGE" --writable-layer-size 1G \
    --expose-port 49999 --expose-port 49983 --probe 49999 --detach --json > "$W/template-submit.json" 2> "$W/template-submit.err"
  rc=$?
  cut -c1-500 "$W/template-submit.json"; echo; [[ $rc -eq 0 ]] || { echo "submit failed (exit $rc):"; cut -c1-500 "$W/template-submit.err"; exit 1; }
  job=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("job",{}).get("job_id",""))' "$W/template-submit.json")
  tpl=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("job",{}).get("template_id",""))' "$W/template-submit.json")
  [[ -n "$job" && -n "$tpl" ]] || { echo "no job id or template id in the answer"; exit 1; }
  status=""; last=""
  for _ in $(seq 1 240); do
    "$CLI" template status --job-id "$job" --json > "$W/template-status.json" 2> /dev/null
    status=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])).get("job",{}); print(d.get("status",""), d.get("phase",""))' "$W/template-status.json" 2> /dev/null)
    [[ "$status" != "$last" ]] && { echo "+$(( $(date +%s) - start )) s: $status"; last=$status; }
    case "$status" in SUCCEEDED*|SUCCESS*|READY*) break ;; FAILED*) break ;; esac
    sleep 5
  done
  echo "template job ended as: $status after $(( $(date +%s) - start )) s"
  case "$status" in
    SUCCEEDED*|SUCCESS*|READY*) echo "$tpl" > "$W/template-id" ;;
    *) echo "template was not created:"; cut -c1-1500 "$W/template-status.json"; echo
       journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" | grep -v -E 'IN=.*OUT=' | cut -c1-220 | tail -20
       exit 1 ;;
  esac
fi
tpl=$(cat "$W/template-id")
"$CLI" template info --template-id "$tpl" --json 2>&1 | cut -c1-900; echo

echo "## code in a sandbox, through the E2B SDK"
cat > "$W/sdk_run.py" <<'PY'
import os, sys, time
from e2b_code_interpreter import Sandbox

tpl = os.environ["CUBE_TEMPLATE_ID"]
n = int(sys.argv[1]) if len(sys.argv) > 1 else 1
code = "import platform, os\nprint('kernel', platform.release())\nprint('cpus', os.cpu_count())\nprint('sum', sum(range(101)))"
ms = lambda a, b: int((b - a) * 1000)
ok = 0
print("cycle | create_ms | run_code_ms | kill_ms | output | result")
for i in range(1, n + 1):
    sbx = None
    t0 = time.time()
    try:
        sbx = Sandbox.create(template=tpl, timeout=120)
        t1 = time.time()
        ex = sbx.run_code(code)
        t2 = time.time()
        out = "".join(ex.logs.stdout).strip().replace("\n", "; ")
        err = ex.error
        sbx.kill()
        t3 = time.time()
        good = err is None and "sum 5050" in out
        ok += good
        print(f"{i} | {ms(t0, t1)} | {ms(t1, t2)} | {ms(t2, t3)} | {out} | {'PASS' if good else 'FAIL'} {err or ''}", flush=True)
    except Exception as e:
        print(f"{i} | - | - | - | | FAIL {type(e).__name__}: {str(e)[:400]}", flush=True)
        try:
            if sbx is not None:
                sbx.kill()
        except Exception:
            pass
print(f"SDK_CYCLES={ok}/{n}")
sys.exit(0 if ok == n else 1)
PY
# The SDK goes into its own virtual environment first, with the system's CA
# bundle. SSL_CERT_FILE is set only for the run itself: the Quick Start points
# it at the mkcert root that signs the sandbox domains, and with that as the
# only CA nothing can be downloaded from PyPI.
if [[ ! -x /root/e2/venv/bin/python ]]; then
  /root/e2/bin/uv venv --quiet /root/e2/venv && /root/e2/bin/uv pip install --quiet --python /root/e2/venv/bin/python e2b-code-interpreter || { echo "cannot install the SDK"; exit 1; }
fi
/root/e2/venv/bin/python -c 'import importlib.metadata as m, sys; print("python", sys.version.split()[0], "| e2b-code-interpreter", m.version("e2b-code-interpreter"), "| e2b", m.version("e2b"))'
ca=/root/.local/share/mkcert/rootCA.pem
ls -l "$ca" 2>&1 | awk '{print $5, $9}'
export E2B_API_URL=http://127.0.0.1:3000 E2B_API_KEY=e2b_000000 CUBE_TEMPLATE_ID="$tpl" SSL_CERT_FILE="$ca"
cd "$W" && timeout 600 /root/e2/venv/bin/python sdk_run.py "${CYCLES:-1}"
rc=$?
echo "sdk exit=$rc"
echo "host kernel: $(uname -r)"
echo "## host kernel log lines added"
journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" | grep -v -E 'IN=.*OUT=' | cut -c1-220 | tail -20
echo "(end)"
exit "$rc"
