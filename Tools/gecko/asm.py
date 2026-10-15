"""Tiny PowerPC assembler for Gecko C2 codes (just what Tools/gecko needs)."""
import struct
def D(op,rt,ra,d): return (op<<26)|(rt<<21)|(ra<<16)|(d&0xffff)
def lfs(f,d,ra): return D(48,f,ra,d)
def lwz(r,d,ra): return D(32,r,ra,d)
def lha(r,d,ra): return D(42,r,ra,d)
def lis(r,i): return D(15,r,0,i)
def ori(ra,rs,i): return D(24,rs,ra,i)
def cmpwi(ra,i): return D(11,0,ra,i)
def cmpw(ra,rb): return (31<<26)|(ra<<16)|(rb<<11)|(0<<1)
def cmplw(ra,rb): return (31<<26)|(ra<<16)|(rb<<11)|(32<<1)
def mr(ra,rs): return (31<<26)|(rs<<21)|(ra<<16)|(rs<<11)|(444<<1)
def subf(rd,ra,rb): return (31<<26)|(rd<<21)|(ra<<16)|(rb<<11)|(40<<1)
def mflr(r): return 0x7C0802A6|(r<<21)
def flt(v): return struct.unpack('>I',struct.pack('>f',v))[0]
class Prog:
    def __init__(s): s.items=[]; s.labels={}
    def __call__(s,w): s.items.append(('w',w))
    def label(s,n): s.labels[n]=len(s.items)
    def bc(s,cond,n): s.items.append(('bc',cond,n))
    def b(s,n,link=False): s.items.append(('b',n,link))
    def words(s):
        out=[]
        for i,it in enumerate(s.items):
            if it[0]=='w': out.append(it[1]); continue
            off=(s.labels[it[-2] if it[0]=='b' else it[2]]-i)*4
            if it[0]=='b': out.append((18<<26)|(off&0x03fffffc)|(1 if it[2] else 0))
            else:
                bo,bi={'lt':(12,0),'ge':(4,0),'gt':(12,1),'le':(4,1)}[it[1]]
                out.append((16<<26)|(bo<<21)|(bi<<16)|(off&0xfffc))
        return out
def c2(addr, words):
    w=list(words)
    if len(w)%2==1: w.append(0)
    else: w+= [0x60000000,0]
    lines=['C2%06X %08X'%(addr&0x01FFFFFF, len(w)//2)]
    for i in range(0,len(w),2): lines.append('%08X %08X'%(w[i],w[i+1]))
    return '\n'.join(lines)
