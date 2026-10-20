#!/usr/bin/env python3
"""Run each parser for a fixed duration; preserve logs/artifacts outside source."""
import argparse,json,os,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--build-dir',type=Path,required=True);p.add_argument('--seconds',type=int,default=300);p.add_argument('--timeout',type=int,default=5,help='per-input watchdog; raise it on a loaded machine, where a starved process trips it with inputs that run in under a millisecond')
a=p.parse_args();root=Path(__file__).resolve().parents[2];build=a.build_dir.resolve();out=build/'fuzz-runs';out.mkdir(exist_ok=True)
if a.seconds<=0:p.error('--seconds must be positive')
processes=[];env=dict(os.environ,ASAN_OPTIONS=os.environ.get('ASAN_OPTIONS','detect_leaks=0'),UBSAN_OPTIONS='halt_on_error=1')
for name in ['heif_reader','heif_inspect','tmap','exif','hvcc','cube']:
    corpus=out/(name+'-corpus');shutil.copytree(root/'tests/fuzz/seeds'/name,corpus,dirs_exist_ok=True)
    artifacts=out/(name+'-artifacts');artifacts.mkdir(exist_ok=True)
    log=(out/(name+'.log')).open('w')
    cmd=[str(build/'tests/fuzz'/('fuzz_'+name)),str(corpus),f'-max_total_time={a.seconds}','-max_len=65536',f'-timeout={a.timeout}','-rss_limit_mb=2048','-artifact_prefix='+str(artifacts)+'/']
    processes.append((name,subprocess.Popen(cmd,env=env,stdout=log,stderr=log),log))
results={}
try:
    for name,process,log in processes:results[name]=process.wait();log.close()
finally:
    for _,process,log in processes:
        if process.poll() is None:process.terminate();process.wait()
        log.close()
(out/'exit-codes.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results),flush=True)
raise SystemExit(any(results.values()))
