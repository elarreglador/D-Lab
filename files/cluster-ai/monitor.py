import asyncio, logging, time
from kubernetes import client, config
import httpx

log = logging.getLogger("monitor")

# Config
TELEGRAM_BOT_URL = "http://telegram-bot.pods.svc:8080/notify"
CHECK_INTERVAL = 300  # 5m

def k8s():
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()
    return client.CoreV1Api(), client.AppsV1Api(), client.CustomObjectsApi()

async def notify(text: str):
    try:
        async with httpx.AsyncClient(timeout=10) as c:
            await c.post(TELEGRAM_BOT_URL, json={"text": text})
            log.info(f"notify sent: {text[:100]}")
    except Exception as e:
        log.warning(f"notify fail: {e}")

def check_pods() -> list:
    v1, _, _ = k8s()
    issues = []
    for p in v1.list_pod_for_all_namespaces().items:
        for cs in (p.status.container_statuses or []):
            if cs.state.waiting and cs.state.waiting.reason == "CrashLoopBackOff":
                issues.append(f"🔥 CrashLoop {p.metadata.namespace}/{p.metadata.name} restarts={cs.restart_count}")
        if p.status.phase == "Pending":
            age = time.time() - p.metadata.creation_timestamp.timestamp() if p.metadata.creation_timestamp else 0
            if age > 300:
                issues.append(f"⏳ Pending {p.metadata.namespace}/{p.metadata.name} {int(age/60)}m")
    return issues

def check_nodes() -> list:
    v1, _, _ = k8s()
    issues = []
    for n in v1.list_node().items:
        for cond in n.status.conditions:
            if cond.type == "Ready" and cond.status != "True":
                issues.append(f"❌ NodeNotReady {n.metadata.name} {cond.reason}")
            if cond.type == "DiskPressure" and cond.status == "True":
                issues.append(f"⚠️ DiskPressure {n.metadata.name}")
            if cond.type == "MemoryPressure" and cond.status == "True":
                issues.append(f"⚠️ MemoryPressure {n.metadata.name}")
    return issues

def check_storage() -> list:
    issues = []
    try:
        import socket
        s = socket.create_connection(("192.168.1.30", 2049), timeout=3)
        s.close()
    except Exception as e:
        issues.append(f"🔥 Storage VIP 192.168.1.30 unreachable: {e}")
    return issues

def check_etcd() -> list:
    issues = []
    try:
        import httpx
        tok = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read()
        with httpx.Client(verify=False, timeout=5) as c:
            r = c.get("https://10.96.0.1:443/readyz", headers={"Authorization": f"Bearer {tok}"})
            if r.status_code != 200 or "ok" not in r.text.lower():
                issues.append(f"❌ etcd readyZ {r.status_code} {r.text[:100]}")
    except Exception as e:
        issues.append(f"❌ etcd readyZ error: {e}")
    return issues

def check_certs() -> list:
    _, _, custom = k8s()
    issues = []
    try:
        from datetime import datetime, timezone
        certs = custom.list_cluster_custom_object(group="cert-manager.io", version="v1", plural="certificates")
        now = datetime.now(timezone.utc)
        for c in certs.get("items", []):
            ns, name = c["metadata"]["namespace"], c["metadata"]["name"]
            exp = c.get("status", {}).get("notAfter")
            if exp:
                days = (datetime.fromisoformat(exp.replace("Z", "+00:00")) - now).days
                if days < 30:
                    issues.append(f"⏰ Cert {ns}/{name} expires in {days}d")
            for cond in c.get("status", {}).get("conditions", []):
                if cond.get("type") == "Ready" and cond.get("status") != "True":
                    issues.append(f"🔴 CertNotReady {ns}/{name} {cond.get('message','')[:50]}")
    except Exception as e:
        log.warning(f"cert check fail: {e}")
    return issues

async def run_checks():
    log.info("monitor 5m check start")
    all_issues = []
    try:
        all_issues += await asyncio.to_thread(check_pods)
        all_issues += await asyncio.to_thread(check_nodes)
        all_issues += await asyncio.to_thread(check_storage)
        all_issues += await asyncio.to_thread(check_etcd)
        all_issues += await asyncio.to_thread(check_certs)
    except Exception as e:
        log.warning(f"monitor error: {e}")
        return
    if not all_issues:
        log.info("monitor healthy")
        return
    # Deduplicate and limit
    uniq = list(dict.fromkeys(all_issues))[:10]
    text = "🚨 Cluster Alert\n" + "\n".join(uniq)
    if len(text) > 3000:
        text = text[:3000]
    await notify(text)
    log.info(f"monitor alert sent {len(uniq)} issues")

def create_monitor(scheduler):
    scheduler.add_job(run_checks, "interval", seconds=CHECK_INTERVAL, id="monitor", replace_existing=True)
