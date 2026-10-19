#!/usr/bin/env python3
"""CC0 deterministic tiny HEIF robustness corpus; no external images/codecs.
Run from any directory. Each checked-in specimen stays below 64 KiB.
"""
from pathlib import Path
import struct,json
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
u16=lambda n:struct.pack('>H',n)
u32=lambda n:struct.pack('>I',n)
u64=lambda n:struct.pack('>Q',n)
def box(t,p):return u32(len(p)+8)+t.encode()+p
def config():
    sets=[bytes.fromhex(s) for s in (REPO/'modules/container/tests/fixtures/heif_writer/params8.txt').read_text().split()[:3]]
    header=bytes([1,1])+bytes(10)+bytes([120,0xf0,0,0xfc,0xfd,0xf8,0xf8,0,0,15,3])
    return header+b''.join(bytes([128+32+i])+u16(1)+u16(len(p))+p for i,p in enumerate(sets))
HVCC=config()
SAMPLE=b'\0\0\0\4\x26\1\x80\1'
FTYP=box('ftyp',b'heic'+bytes(4)+b'mif1heic')
ISPE=box('ispe',bytes(4)+u32(512)+u32(512))
COLR=box('colr',b'nclx'+u16(1)+u16(13)+u16(1)+b'\x80')

def make(*,types=('hvc1',),samples=None,properties=None,associations=None,refs=(),primary=1,drop=(),method=0,widths=(4,4,0,0),base=0,offset_delta=0,force_offsets=None,duplicate_ids=False,iloc_version=1,infe_version=2,ipma_version=0,wide=False,groups=(),large_boxes=()):
    def box(t,p):
        return u32(1)+t.encode()+u64(len(p)+16)+p if t in large_boxes else globals()["box"](t,p)
    samples=list(samples or [SAMPLE for _ in types]);props=list(properties if properties is not None else [ISPE,box('hvcC',HVCC),COLR]);assoc=associations or [[1,130,3] for _ in types]
    ids=[1 if duplicate_ids else i+1 for i in range(len(types))]
    idsize=4 if infe_version==3 else 2;uid=lambda i:i.to_bytes(idsize,'big')
    infe=[box('infe',bytes([infe_version,0,0,0])+uid(i)+u16(0)+t.encode()+b'\0'+(b'application/rdf+xml\0' if t=='mime' else b'')) for i,t in zip(ids,types)]
    iinf=box('iinf',bytes(4)+u16(len(infe))+b''.join(infe))
    def meta(offsets):
        fields=[]
        fields.append(('hdlr',box('hdlr',bytes(8)+b'pict'+bytes(13))))
        fields.append(('pitm',box('pitm',bytes(4)+u16(primary))))
        fields.append(('iinf',iinf))
        off,ln,bas,ix=widths;loc=bytes([iloc_version,0,0,0,(off<<4)|ln,(bas<<4)|ix])+len(ids).to_bytes(4 if iloc_version==2 else 2,'big')
        for i,(item,offset,sample) in enumerate(zip(ids,offsets,samples)):
            loc+=item.to_bytes(4 if iloc_version==2 else 2,'big')+(u16(method) if iloc_version else b'')+u16(0)+base.to_bytes(bas,'big')+u16(1)
            loc+=bytes(ix)+(force_offsets[i] if force_offsets else offset+offset_delta).to_bytes(off,'big')+len(sample).to_bytes(ln,'big')
        fields.append(('iloc',box('iloc',loc)))
        payload=bytes([ipma_version,0,0,int(wide)])+u32(len(ids))
        for i,ass in zip(ids,assoc):payload+=i.to_bytes(4 if ipma_version else 2,'big')+bytes([len(ass)])+b''.join(a.to_bytes(2 if wide else 1,'big') for a in ass)
        fields.append(('iprp',box('iprp',box('ipco',b''.join(props))+box('ipma',payload))))
        if refs:fields.append(('iref',box('iref',bytes(4)+b''.join(box(t,u16(src)+u16(len(dst))+b''.join(u16(i)for i in dst))for t,src,dst in refs))))
        if groups:fields.append(('grpl',box('grpl',b''.join(box(t,bytes(4)+u32(gid)+u32(len(members))+b''.join(u32(i)for i in members))for t,gid,members in groups))))
        if method==1:fields.append(('idat',box('idat',b''.join(samples))))
        return box('meta',bytes(4)+b''.join(v for k,v in fields if k not in drop))
    placeholder=meta([0]*len(ids));at=len(FTYP)+len(placeholder)+8;offsets=[]
    for s in samples:offsets.append(at);at+=len(s)
    return FTYP+meta(offsets)+box('mdat',b''.join(samples))

def grid(rows=1,cols=1,w=512,h=512):return bytes([0,1,rows-1,cols-1])+u32(w)+u32(h)
cases=[]
def add(name,data,code='decode_failed',feature=''):
    assert len(data)<65536,(name,len(data));(ROOT/(name+'.heic')).write_bytes(data);cases.append(dict(file=name+'.heic',code=code,feature=feature))
base=make()
add('valid',base,'ok')
add('empty',b'');add('ftyp-only',FTYP);add('half',base[:len(base)//2]);add('tail',base[:-1])
add('ftyp-length',u32(7)+base[4:]);at=base.index(b'meta')-4;add('meta-length',base[:at]+u32(0xffffffff)+base[at+4:])
add('bad-nal-header',make(samples=[SAMPLE[:4]+bytes([0xa6])+SAMPLE[5:]]))
add('bad-nal-length',make(samples=[u32(100)+SAMPLE[4:]]))
add('no-slice',make(samples=[u32(3)+b'\x4e\1\x80']))
add('bad-inband-parameter',make(samples=[u32(4)+b'\x40\1\x80\1'+SAMPLE]),'unsupported_format','hevc_parameter_change')
add('layer-id',make(samples=[SAMPLE[:5]+b'\x09'+SAMPLE[6:]]))
add('temporal-id-zero',make(samples=[SAMPLE[:5]+b'\0'+SAMPLE[6:]]))
add('missing-pitm',make(drop=['pitm']));add('missing-primary',make(primary=2));add('duplicate-id',make(types=('hvc1','hvc1'),duplicate_ids=True))
add('extent-eof',make(offset_delta=1000000));add('offset-overflow',make(widths=(8,4,8,0),base=2**64-1))
add('idat-eof',make(method=1));add('construction-method-2',make(method=2),'unsupported_format','construction_method')
add('bad-location-width',make(widths=(3,4,0,0)))
add('property-index',make(associations=[[1,127]]))
add('essential-property',make(properties=[ISPE,box('hvcC',HVCC),box('zzzz',b'')],associations=[[1,130,131]]),'unsupported_format','essential_property')
add('optional-property',make(properties=[ISPE,box('hvcC',HVCC),box('zzzz',b'')],associations=[[1,130,3]]),'ok')
for n in [0,2**31]:add('ispe-'+str(n),make(properties=[box('ispe',bytes(4)+u32(n)+u32(512)),box('hvcC',HVCC),COLR]))
for name,cfg in [('hvcc-truncated',HVCC[:-1]),('hvcc-length-size-3',HVCC[:21]+bytes([(HVCC[21]&252)|2])+HVCC[22:]),('hvcc-many-nals',HVCC[:24]+u16(65)+HVCC[26:])]:add(name,make(properties=[ISPE,box('hvcC',cfg),COLR]))
add('clap-zero-denominator',make(properties=[ISPE,box('hvcC',HVCC),box('clap',u32(512)+bytes(28))]))
add('clap-fractional',make(properties=[ISPE,box('hvcC',HVCC),box('clap',b''.join(u32(v)for v in [511,1,512,1,0,1,0,1]))]))
add('irot-reserved',make(properties=[ISPE,box('hvcC',HVCC),box('irot',b'\x04')]))
add('imir-reserved',make(properties=[ISPE,box('hvcC',HVCC),box('imir',b'\x02')]))
add('exif-offset',make(types=('hvc1','Exif'),samples=[SAMPLE,u32(100)+b'II*\0'+bytes(4)],associations=[[1,130,3],[]]))
add('tmap-version',make(types=('hvc1','tmap'),samples=[SAMPLE,b'\x01'+bytes(31)],associations=[[1,130,3],[]]))
add('tmap-self',make(types=('hvc1','tmap'),samples=[SAMPLE,bytes(32)],refs=[('dimg',2,[1,2])],associations=[[1,130,3],[]]))
add('iref-cycle',make(types=('grid','hvc1'),samples=[grid(),SAMPLE],refs=[('dimg',1,[2]),('dimg',2,[1])]))
add('grid-self',make(types=('grid',),samples=[grid()],refs=[('dimg',1,[1])]))
add('grid-nested',make(types=('grid','grid','hvc1'),samples=[grid(),grid(),SAMPLE],refs=[('dimg',1,[2]),('dimg',2,[3])]))
add('iden-long',make(types=('iden','iden','iden','hvc1'),samples=[b'',b'',b'',SAMPLE],refs=[('dimg',1,[2]),('dimg',2,[3]),('dimg',3,[4])]))
add('grid-tile-count',make(types=('grid','hvc1'),samples=[grid(256,256),SAMPLE],refs=[('dimg',1,[2])]))
add('grid-coverage',make(types=('grid','hvc1'),samples=[grid(w=1024),SAMPLE],properties=[box('ispe',bytes(4)+u32(1024)+u32(512)),box('hvcC',HVCC),COLR],refs=[('dimg',1,[2])]))
add('valid-grid',make(types=('grid','hvc1'),samples=[grid(),SAMPLE],refs=[('dimg',1,[2])]),'ok')
add('valid-wide-ids',make(iloc_version=2,infe_version=3,ipma_version=1,wide=True,associations=[[1,0x8002,3]]),'ok')
nested=b''
for _ in range(1000):nested=box('meta',bytes(4)+nested)
add('meta-depth-1000',FTYP+nested)
add('box-size-7',FTYP+u32(7)+b'free');add('largesize-15',FTYP+u32(1)+b'free'+u64(15))
add('nested-size-zero',FTYP+box('meta',bytes(4)+bytes(4)+b'free'))
add('icc-claim-100mb',base[:base.index(b'colr')-4]+u32(100*1024*1024)+base[base.index(b'colr'):])
# Sequence brands are structurally valid but outside the still-image reader.
add('image-sequence',base[:8]+b'msf1'+base[12:],'unsupported_format','image_sequence')

add('valid-idat',make(method=1,force_offsets=[0]),'ok')
add('valid-iden-grid',make(types=('iden','grid','hvc1'),samples=[b'',grid(),SAMPLE],refs=[('dimg',1,[2]),('dimg',2,[3])]),'ok')
for urn in ['urn:mpeg:hevc:2015:auxid:1','urn:mpeg:mpegB:cicp:systems:auxiliary:alpha','urn:com:apple:photo:2020:aux:hdrgainmap']:
    label='legacy-gain' if 'hdrgainmap' in urn else 'alpha-'+('1' if '2015' in urn else '2')
    props=[ISPE,box('hvcC',HVCC),COLR,box('auxC',bytes(4)+urn.encode()+b'\0')]
    refs=[('auxl',2,[1])]
    if label=='alpha-1':refs.append(('prem',1,[2]))
    add('valid-'+label,make(types=('hvc1','hvc1'),properties=props,associations=[[1,130,3],[1,130,3,4]],refs=refs),'ok')
add('unknown-essential-unused',make(types=('hvc1','hvc1'),properties=[ISPE,box('hvcC',HVCC),COLR,box('zzzz',b'')],associations=[[1,130,3],[1,130,3,132]]),'ok')
add('valid-transforms',make(properties=[ISPE,box('hvcC',HVCC),COLR,box('irot',b'\1'),box('imir',b'\1'),box('clap',b''.join(u32(v)for v in [256,1,128,1,0,1,0,1]))],associations=[[1,130,3,4,5,6]]),'ok')
add('inspect-short-iref',FTYP+box('iref',b''))

valid_tmap=bytes(5)+bytes([0])+b''.join(u32(n)+u32(d)for n,d in [(0,1),(3,1),(0,1),(3,1),(1,1),(0,1),(0,1)])
add('tmap-two-channel-body',make(types=('hvc1','tmap'),samples=[SAMPLE,valid_tmap[:5]+bytes([128])+valid_tmap[6:]+valid_tmap[22:]],associations=[[1,130,3],[]]))
props=[ISPE,box('hvcC',HVCC),COLR,box('ispe',bytes(4)+u32(1024)+u32(512))]
add('gain-larger-than-base',make(types=('hvc1','grid','hvc1','tmap'),samples=[SAMPLE,grid(cols=2,w=1024),SAMPLE,valid_tmap],properties=props,associations=[[1,130,3],[4,3],[1,130,3],[]],refs=[('dimg',2,[3,3]),('dimg',4,[1,2]),('auxl',2,[1])],groups=[('altr',5,[4,1])]))
add('clap-outside',make(properties=[ISPE,box('hvcC',HVCC),box('clap',b''.join(u32(v)for v in [256,1,128,1,2147483647,1,0,1]))]))
add('valid-irot-max',make(properties=[ISPE,box('hvcC',HVCC),box('irot',b'\3')]),'ok')
add('reserved-irap',make(samples=[SAMPLE[:4]+bytes([44])+SAMPLE[5:]]))
add('duplicate-tmap-altr',make(types=('hvc1','hvc1','tmap'),samples=[SAMPLE,SAMPLE,valid_tmap],associations=[[1,130,3],[1,130,3],[]],refs=[('dimg',3,[1,2])],groups=[('altr',4,[3,1]),('altr',5,[3,1])]))
# Review regressions: consumed metadata properties and 64-bit box headers.
for essential in [False, True]:
    add('tmap-'+('essential' if essential else 'optional')+'-unknown',
        make(types=('hvc1','hvc1','tmap'),samples=[SAMPLE,SAMPLE,valid_tmap],
             properties=[ISPE,box('hvcC',HVCC),COLR,box('zzzz',b'')],
             associations=[[1,130,3],[1,130,3],[132 if essential else 4]],
             refs=[('dimg',3,[1,2])],groups=[('altr',4,[3,1])]),
        'unsupported_format' if essential else 'ok','essential_property' if essential else '')
for large in [('meta',),('iref',),('iprp',),('ipma',),('altr',),('meta','iref','iprp','ipma','altr')]:
    add('valid-largesize-'+'-'.join(large),
        make(types=('hvc1','hvc1','tmap'),samples=[SAMPLE,SAMPLE,valid_tmap],
             properties=[ISPE,box('hvcC',HVCC),COLR,box('auxC',bytes(4)+b'urn:iso:std:iso:ts:21496:-1\0')],
             associations=[[1,130,3],[1,130,3,4],[]],
             refs=[('dimg',3,[1,2]),('auxl',2,[1])],groups=[('altr',4,[3,1])],
             large_boxes=large),'ok')
(ROOT/'manifest.json').write_text(json.dumps(cases,indent=2)+'\n')
print(f'Generated {len(cases)} deterministic specimens')
