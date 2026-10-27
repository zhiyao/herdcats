#!/usr/bin/env python3
"""Disposable Pi 1.4.0 TUI integration probe; synthetic local provider only.

Does not inspect existing sessions, use provider credentials, or control active panes.
"""
import argparse
import os, pty, subprocess, tempfile, time, glob, socket, json, select, shutil
from pathlib import Path
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pi-package', default=str(Path.home()/'.bun/install/global/node_modules/@earendil-works/pi-coding-agent'))
args = parser.parse_args()
pi_package = Path(args.pi_package).resolve()
assert json.loads((pi_package/'package.json').read_text())['version'] == '1.4.0', 'Pi 1.4.0 required'
root=tempfile.mkdtemp(prefix='hpt-',dir='/private/tmp' if Path('/private/tmp').is_dir() else '/tmp')
repo=str(Path(__file__).resolve().parents[2])
probe=root+'/probe.ts'
with open(probe,'w') as f:f.write('''import { writeFileSync } from 'node:fs';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
export default function(pi) {
pi.registerProvider('hc-synthetic',{baseUrl:'http://127.0.0.1:1',apiKey:'synthetic-no-network',api:'hc-synthetic-api',models:['one','two'].map(id=>({id,name:'Synthetic '+id,reasoning:true,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:8192,maxTokens:1024})),streamSimple:(model,context,opts)=>{const stream=createAssistantMessageEventStream();setTimeout(async()=>{const message={role:'assistant',content:[{type:'text',text:''}],api:model.api,provider:model.provider,model:model.id,timestamp:Date.now(),stopReason:'pending',usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}}};stream.push({type:'start',partial:message});message.content[0].text='Synthetic streaming response';stream.push({type:'text_start',contentIndex:0,partial:message});stream.push({type:'text_delta',contentIndex:0,delta:message.content[0].text,partial:message});await new Promise(resolve=>{opts.signal.addEventListener('abort',resolve,{once:true});setTimeout(resolve,5000);});if(opts.signal.aborted){message.stopReason='aborted';message.errorMessage='Synthetic cancellation';stream.push({type:'error',reason:'aborted',error:message});}else{message.stopReason='stop';stream.push({type:'text_end',contentIndex:0,content:message.content[0].text,partial:message});stream.push({type:'done',reason:'stop',message});}stream.end();},0);return stream;}});
pi.registerCommand('hc-probe', {handler:async (_args,ctx)=>{ const value=await ctx.ui.confirm('Synthetic permission','Run synthetic test once?'); writeFileSync(process.env.HC_PROBE_RESULT,JSON.stringify({value})); }}); }
''')
master,slave=pty.openpty();env=dict(os.environ,PI_CODING_AGENT_DIR=root+'/agent',HC_PROBE_RESULT=root+'/result.json',TERM='xterm-256color')
p=subprocess.Popen(['node',str(pi_package/'dist/bundle/cli.js'),'--no-extensions','--no-skills','--no-prompt-templates','-e',repo+'/bridge/pi-extension/index.ts','-e',probe,'--session',root+'/session.jsonl'],stdin=slave,stdout=slave,stderr=slave,env=env,cwd=root);os.close(slave)
output=b''
def drain():
 global output
 while select.select([master],[],[],0)[0]:
  try: output+=os.read(master,65536)
  except OSError:break

def req(path,method,params={}):
 s=socket.socket(socket.AF_UNIX);s.settimeout(10);s.connect(path);s.sendall((json.dumps({'method':method,'params':params})+'\n').encode());data=b''
 deadline=time.monotonic()+10
 while not data.endswith(b'\n'):
  if time.monotonic()>deadline:raise TimeoutError('Pi state response timed out')
  ready=select.select([master,s],[],[],.1)[0]
  if master in ready:drain()
  if s in ready:
   chunk=s.recv(65536)
   if not chunk:raise RuntimeError('Pi closed incomplete response')
   data+=chunk
 s.close();value=json.loads(data)
 if 'error' in value:raise RuntimeError(value['error'])
 return value['result']
try:
 for i in range(100):
  drain();paths=glob.glob(root+'/agent/herdcats/*.sock')
  if paths:break
  if p.poll()!=None:raise RuntimeError('Pi exited '+str(p.returncode)+' '+output.decode(errors='replace')[-4000:])
  time.sleep(.1)
 else:raise RuntimeError('No socket: '+output.decode(errors='replace')[-4000:])
 state=req(paths[0],'state');print('STATE',json.dumps({key:state[key] for key in ['protocol','version','session_id','instance_id','status','capabilities']}))
 os.write(master,b'/hc-probe\r')
 for i in range(60):
  drain();state=req(paths[0],'state')
  if state['pending']:break
  time.sleep(.1)
 else:raise RuntimeError('No dialog: '+output.decode(errors='replace')[-4000:])
 print('DIALOG',json.dumps(state['pending']))
 expect={key:state[key] for key in ['session_id','instance_id','revision']}
 print('REPLY',req(paths[0],'dialog.respond',{'expect':expect,'request_id':state['pending']['id'],'value':False}))
 for i in range(30):
  drain()
  if os.path.exists(root+'/result.json'):break
  time.sleep(.1)
 print('TERMINAL_RESULT',open(root+'/result.json').read())
 assert json.load(open(root+'/result.json'))=={'value':False}
 print('FINAL_PENDING',req(paths[0],'state')['pending'])
 state=req(paths[0],'state');expect={key:state[key] for key in ['session_id','instance_id','revision']}
 print('MODEL_SET',req(paths[0],'model.set',{'expect':expect,'model':'hc-synthetic/two','effort':'high'}))
 state=req(paths[0],'state');assert state['model']['id']=='hc-synthetic/two' and state['model']['effort']=='high';expect={key:state[key] for key in ['session_id','instance_id','revision']}
 effort_reply=req(paths[0],'model.set',{'expect':expect,'effort':'low'})
 assert effort_reply['confirmed'] is True and effort_reply['model']['id']=='hc-synthetic/two' and effort_reply['model']['effort']=='low'
 state=req(paths[0],'state');assert state['model']['effort']=='low';expect={key:state[key] for key in ['session_id','instance_id','revision']}
 print('EFFORT_ONLY',json.dumps(effort_reply))
 print('PROMPT',req(paths[0],'prompt',{'expect':expect,'text':'Synthetic local provider prompt'}))
 for i in range(50):
  drain();state=req(paths[0],'state')
  if any(e.get('id','').startswith('herdcats-live:') for e in state['entries']):break
  time.sleep(.1)
 else:raise RuntimeError('No streaming message: '+output.decode(errors='replace')[-3000:])
 print('STREAM',json.dumps(state['entries'][-1]));assert state['session_id']==expect['session_id'];expect={key:state[key] for key in ['session_id','instance_id','revision']}
 print('CANCEL',req(paths[0],'cancel',{'expect':expect}))
 for i in range(30):
  drain();state=req(paths[0],'state')
  if state['status']=='idle':break
  time.sleep(.1)
 print('FINAL',json.dumps({'status':state['status'],'roles':[e.get('message',{}).get('role') for e in state['entries']],'session_id':state['session_id']}))
 assert state['status']=='idle'

finally:
 p.terminate()
 try:p.wait(5)
 except: p.kill();p.wait()
 os.close(master);shutil.rmtree(root)
