
import sys,re
label,f=sys.argv[1:3]
rows=[]
for l in open(f):
    if not l.startswith('conns='): continue
    rows.append({k:float(v) for k,v in re.findall(r'(\S+?)=([-\d.]+)',l)})
mc=max(r['conns'] for r in rows)
st=[r for r in rows if r['conns']>=0.98*mc and r['req/s']>2000][1:-1]
n=len(st); a=lambda k: sum(r[k] for r in st)/n
print(f"{label}: secs={n} req/s={a('req/s'):.0f} cpu={a('cpu'):.1f}% total_us/req={a('cpu')*1e4/a('req/s'):.2f} user_us/req={a('busy')*1e4/a('req/s'):.2f} passes/s={a('passes'):.0f} ckpt/s={a('ckpt'):.2f} holds/s={a('holds'):.2f}")
