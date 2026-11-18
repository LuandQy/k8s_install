#!/usr/bin/env bash
# Read-only validation of explicitly recorded Service routing on owned nodes.
set -euo pipefail
python3 - "$1" "$2" <<'PY'
import ipaddress,json,os,stat,subprocess,sys
from pathlib import Path

def require(condition, message):
    # Safety checks must remain active even when PYTHONOPTIMIZE is set.
    if not condition:
        raise RuntimeError(message)

def validate(owner,routes,cidr,deployment):
    require(owner.get('schema')==1 and owner.get('deployment_id')==deployment, 'Service route deployment identity differs')
    require(owner.get('destination')==cidr, 'Service route destination differs')
    network=ipaddress.ip_network(cidr,strict=True)
    require(network.version==4 and network.prefixlen>0, 'Only an exact non-default IPv4 Service route is allowed')
    require(owner.get('protocol')=='static' and type(owner.get('metric')) is int, 'Service route protocol/metric is invalid')
    require(0<owner['metric']<2**32 and isinstance(owner.get('device'),str) and owner['device'], 'Service route metric/device is invalid')
    require(ipaddress.ip_address(owner['gateway']).version==4, 'Service route gateway must be IPv4')
    matching=[r for r in routes if r.get('dst')==cidr]
    require(len(matching)==1, 'Expected exactly one matching Service route')
    route=matching[0]
    require(route.get('type','unicast')=='unicast', 'Service route type is not unicast')
    require(all(route.get(k)==owner[v] for k,v in [('gateway','gateway'),('dev','device'),('protocol','protocol'),('metric','metric')]), 'Live Service route differs from ownership record')

if __name__=='__main__':
    require(os.geteuid()==0, 'Root is required to verify route ownership')
    path=Path('/etc/kubekey/rise/service-route.json')
    require(not path.is_symlink() and not path.parent.is_symlink(), 'Service route ownership path is a symlink')
    info=path.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid==0 and info.st_mode&0o022==0, 'Service route ownership file permissions are unsafe')
    owner=json.loads(path.read_text())
    require(Path('/etc/kubekey/rise/deployment-id').read_text().strip()==sys.argv[2], 'Node deployment marker differs')
    routes=json.loads(subprocess.check_output(['ip','-j','-4','route','show','table','main'],text=True))
    validate(owner,routes,sys.argv[1],sys.argv[2])
    print('[OK] Recorded Service route and live route belong to this deployment')
PY
