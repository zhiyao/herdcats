import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, lstat, symlink, mkdir, realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { connect } from 'node:net';
import { createIntegration } from './runtime.mjs';
// Keep Unix socket paths short and resolve macOS's /tmp symlink before validation.
const testTmp = await realpath('/tmp');
const sid = '12345678-1234-4234-8234-123456789abc';
function fixture() {
  const hooks = new Map(); const sent = []; let model = {provider:'provider',id:'model',name:'Model'}; let effort='low'; let aborted=0;
  const original = {};
  const ui = { getEditorText:()=>'', notify:()=>{}, select:(title,options,opts)=>new Promise(resolve=>{ original.select=resolve; opts?.signal?.addEventListener('abort',()=>resolve(undefined)); }), confirm:(title,message,opts)=>new Promise(resolve=>{original.confirm=resolve; opts?.signal?.addEventListener('abort',()=>resolve(false));}), input:(title,value,opts)=>new Promise(resolve=>{ original.input=resolve; opts?.signal?.addEventListener('abort',()=>resolve(undefined));}), editor:()=>new Promise(resolve=>{original.editor=resolve;}), custom:()=>new Promise(resolve=>{original.custom=resolve;}) };
  const ctx = {mode:'tui',hasUI:true,ui,sessionManager:{getSessionId:()=>sid,getSessionFile:()=>'/fixture/session.jsonl',getBranch:()=>[]},modelRegistry:{getAvailable:()=>[model,{provider:'other',id:'model',name:'Other'}]},get model(){return model;},isIdle:()=>true,isProjectTrusted:()=>true,hasPendingMessages:()=>false,abort:()=>{aborted++;}};
  const pi = {on:(event,fn)=>hooks.set(event,fn),sendUserMessage:text=>sent.push(text),getThinkingLevel:()=>effort,setThinkingLevel:value=>{effort=value;},setModel:async value=>{model=value; return true;}};
  const integration=createIntegration(pi,{version:'1.5.0',getSupportedThinkingLevels:()=>['off','low','high']});
  return {integration,ctx,pi,hooks,sent,original,get aborted(){return aborted;}};
}
async function started(t) { const f=fixture(); const root=await mkdtemp(join(testTmp,'hpi-')); t.after(()=>rm(root,{recursive:true,force:true})); await f.integration.start(f.ctx,{directory:join(root,'control')}); t.after(()=>f.integration.stop()); return f; }
function expectOf(state){return {session_id:state.session_id,instance_id:state.instance_id,revision:state.revision};}
test('guards bind controls to live instance and revision and preserve provider identity',async t=>{const f=await started(t); const state=await f.integration.request('state'); assert.equal(state.models[1].id,'other/model'); await assert.rejects(f.integration.request('prompt',{text:'hello',expect:{...expectOf(state),instance_id:'old'}}),/stale/); await f.integration.request('prompt',{text:'hello',expect:expectOf(state)}); assert.deepEqual(f.sent,['hello']); assert.equal((await f.integration.request('state')).status,'working'); await assert.rejects(f.integration.request('prompt',{text:'repeat',expect:expectOf(state)}),/stale/);});
test('confirm requires exact boolean, preserves original cancellation and rejects stale replies',async t=>{const f=await started(t); const dialog=f.ctx.ui.confirm('Permission','Run once?'); const state=await f.integration.request('state'); assert.equal(state.pending.kind,'confirm'); await assert.rejects(f.integration.request('dialog.respond',{request_id:state.pending.id,value:'true',expect:expectOf(state)}),/invalid_response/); await f.integration.request('dialog.respond',{request_id:state.pending.id,value:false,expect:expectOf(state)}); assert.equal(await dialog,false); await assert.rejects(f.integration.request('dialog.respond',{request_id:state.pending.id,value:true,expect:expectOf(state)}),/stale/);});
test('terminal resolution wins and timeout/abort do not grant permission',async t=>{const f=await started(t); const controller=new AbortController();const dialog=f.ctx.ui.confirm('Gate','Allow?',{signal:controller.signal}); const state=await f.integration.request('state');controller.abort();assert.equal(await dialog,false); assert.equal((await f.integration.request('state')).pending,null);await assert.rejects(f.integration.request('dialog.respond',{request_id:state.pending.id,value:true,expect:expectOf(state)}),/stale/);});
test('unknown custom and uncancellable editor remain in Terminal and block prompt',async t=>{const f=await started(t); const dialog=f.ctx.ui.editor('Edit','prefill');const state=await f.integration.request('state');assert.equal(state.pending.kind,'terminal');await assert.rejects(f.integration.request('prompt',{text:'hello',expect:expectOf(state)}),/agent_busy/); f.original.editor('edited');assert.equal(await dialog,'edited');assert.equal((await f.integration.request('state')).pending,null);});
test('dynamic model and thinking validation applies on same live session',async t=>{const f=await started(t);let state=await f.integration.request('state');await assert.rejects(f.integration.request('model.set',{model:'other/model',effort:'invented',expect:expectOf(state)}),/invalid_effort/);const result=await f.integration.request('model.set',{model:'other/model',effort:'high',expect:expectOf(state)});assert.equal(result.confirmed,true);state=await f.integration.request('state');assert.equal(state.model.id,'other/model');assert.equal(state.model.effort,'high');});
test('socket is private, bounded and responds without a second process',async t=>{const f=await started(t);const path=f.integration.socketPath;assert.equal((await lstat(path)).mode&0o777,0o600);const response=await new Promise((resolve,reject)=>{const socket=connect(path);let text='';socket.on('error',reject);socket.on('connect',()=>socket.write('{"method":"state"}\n'));socket.on('data',chunk=>text+=chunk);socket.on('end',()=>resolve(JSON.parse(text)));});assert.equal(response.result.session_id,sid);});
test('rejects symlink endpoint roots',async t=>{const f=fixture();const root=await mkdtemp(join(testTmp,'hpi-'));t.after(()=>rm(root,{recursive:true,force:true}));await mkdir(join(root,'actual'));await symlink(join(root,'actual'),join(root,'link'));await assert.rejects(f.integration.start(f.ctx,{directory:join(root,'link')}),/unsafe_control_directory/);});
test('duplicate native session refuses control without deleting original endpoint',async t=>{const first=await started(t);const second=fixture();const directory=join(first.integration.socketPath,'..');await assert.rejects(second.integration.start(second.ctx,{directory}),/pi_endpoint_exists/);await second.integration.stop();assert.equal((await lstat(first.integration.socketPath)).isSocket(),true);});
test('select forwards exact scope labels and input returns literal text',async t=>{const f=await started(t);const options=['Run once','Allow in this conversation','Persist to settings.json','Deny'];const selection=f.ctx.ui.select('Permission scope',options);let state=await f.integration.request('state');assert.deepEqual(state.pending.options,options);await assert.rejects(f.integration.request('dialog.respond',{request_id:state.pending.id,value:'allow',expect:expectOf(state)}),/invalid_response/);await f.integration.request('dialog.respond',{request_id:state.pending.id,value:options[1],expect:expectOf(state)});assert.equal(await selection,options[1]);const input=f.ctx.ui.input('Question','Type your answer');state=await f.integration.request('state');await f.integration.request('dialog.respond',{request_id:state.pending.id,value:'literal\nanswer',expect:expectOf(state)});assert.equal(await input,'literal\nanswer');});
test('custom dialogs block cancellation and retain original terminal result',async t=>{const f=await started(t);const custom=f.ctx.ui.custom(()=>{});const state=await f.integration.request('state');assert.equal(state.pending.kind,'terminal');await assert.rejects(f.integration.request('cancel',{expect:expectOf(state)}),/terminal_required/);f.original.custom({custom:'answer'});assert.deepEqual(await custom,{custom:'answer'});});
test('local draft changes invalidate previously captured actions without sending',async t=>{const f=await started(t);const state=await f.integration.request('state');f.ctx.ui.getEditorText=()=> 'unsent local draft';await assert.rejects(f.integration.request('prompt',{text:'phone prompt',expect:expectOf(state)}),/stale/);assert.deepEqual(f.sent,[]);});
test('live assistant updates appear in state and invalidate old controls',async t=>{const f=await started(t);const state=await f.integration.request('state');const message={role:'assistant',content:[{type:'text',text:'Streaming synthetic text'}]};f.hooks.get('message_update')({message},f.ctx);const updated=await f.integration.request('state');assert.equal(updated.entries.at(-1).message.content[0].text,'Streaming synthetic text');assert.ok(updated.revision>state.revision);await assert.rejects(f.integration.request('prompt',{text:'old',expect:expectOf(state)}),/stale/);f.hooks.get('message_end')({message},f.ctx);assert.equal((await f.integration.request('state')).entries.length,0);});
test('oversized socket frames are rejected before parsing',async t=>{const f=await started(t);const response=await new Promise((resolve,reject)=>{const socket=connect(f.integration.socketPath);let text='';socket.on('error',reject);socket.on('connect',()=>socket.write('x'.repeat(1024*1024+1)));socket.on('data',chunk=>text+=chunk);socket.on('end',()=>resolve(JSON.parse(text)));});assert.equal(response.error.code,'request_too_large');});

test('project trust stays a Terminal gate',async t=>{const f=await started(t);f.ctx.isProjectTrusted=()=>false;const state=await f.integration.request('state');await assert.rejects(f.integration.request('prompt',{text:'hello',expect:expectOf(state)}),/terminal_required/);assert.deepEqual(f.sent,[]);});

test('effort-only changes return a confirmed model without changing provider identity',async t=>{
  const f=await started(t);
  const state=await f.integration.request('state');
  const result=await f.integration.request('model.set',{effort:'high',expect:expectOf(state)});
  assert.equal(result.confirmed,true);
  assert.equal(result.model.id,state.model.id);
  assert.equal(result.model.effort,'high');
  const updated=await f.integration.request('state');
  assert.equal(updated.model.effort,'high');
});

test('dialog strings use iOS UTF-8 byte limits and omit oversized fields', async t => {
  const f = await started(t);
  for (const text of ['a'.repeat(8192), 'é'.repeat(4096), 'a'.repeat(8193), 'é'.repeat(4096)+'a']) {
    const supported = Buffer.byteLength(text) === 8192;
    for (const kind of ['confirm','input','select']) {
      for (const field of ['title','second']) {
        const title = field === 'title' ? text : 'Title';
        const second = kind === 'select' ? [field === 'second' ? text : 'Option'] : field === 'second' ? text : 'Message';
        const dialog = f.ctx.ui[kind](title, second);
        const {pending} = await f.integration.request('state');
        assert.equal(pending.kind, supported ? kind : 'terminal');
        assert.ok(Buffer.byteLength(pending.title) <= 8192);
        if (!supported) {
          assert.equal(pending.message, undefined);
          assert.equal(pending.options, undefined);
        }
        f.original[kind](undefined); await dialog;
      }
    }
  }
});

test('editor and external prompt titles remain bounded for Terminal fallback', async t => {
  const f = await started(t);
  const title = '界'.repeat(2731);
  const dialog = f.ctx.ui.editor(title, 'prefill');
  assert.equal((await f.integration.request('state')).pending.title, 'Custom dialog — continue in Terminal');
  f.original.editor('done'); await dialog;
  f.hooks.get('ui_prompt_start')({title}, f.ctx);
  const {pending} = await f.integration.request('state');
  assert.equal(pending.kind, 'terminal');
  assert.equal(pending.title, 'Continue in Terminal');
  f.hooks.get('ui_prompt_end')({}, f.ctx);
});

test('text answers use the iOS 65536-byte limit while prompts retain their limit', async t => {
  const f = await started(t);
  const dialog = f.ctx.ui.input('Question', 'Answer');
  const state = await f.integration.request('state');
  for (const value of ['a'.repeat(65537), 'é'.repeat(32768)+'a', 'null\0byte']) {
    await assert.rejects(f.integration.request('dialog.respond',{request_id:state.pending.id,value,expect:expectOf(state)}),/invalid_response/);
  }
  const answer = 'é'.repeat(32768);
  await f.integration.request('dialog.respond',{request_id:state.pending.id,value:answer,expect:expectOf(state)});
  assert.equal(await dialog, answer);
  await f.integration.request('prompt',{text:'a'.repeat(65537),expect:expectOf(await f.integration.request('state'))});
  assert.equal(f.sent[0].length, 65537);
});

test('ambiguous, null-byte and excessive selection schemas remain Terminal-only', async t => {
  const f = await started(t);
  for (const options of [[], ['duplicate','duplicate'], ['null\0byte'], Array.from({length:101},(_,i)=>`${i}`)]) {
    const dialog = f.ctx.ui.select('Choose', options);
    const {pending} = await f.integration.request('state');
    assert.equal(pending.kind, 'terminal');
    assert.equal(pending.options, undefined);
    f.original.select(undefined); await dialog;
  }
  const options = Array.from({length:100},(_,i)=>`${i}`);
  const dialog = f.ctx.ui.select('Choose', options);
  assert.deepEqual((await f.integration.request('state')).pending.options, options);
  f.original.select(undefined); await dialog;
});

test('state reports the actual Pi version and integration protocol', async t => {
  const f = await started(t);
  const state = await f.integration.request('state');
  assert.equal(state.protocol, 1);
  assert.equal(state.version, '1.5.0');
});

test('missing required Pi APIs refuse startup before publishing a control socket', async t => {
  for (const remove of [f => delete f.ctx.isProjectTrusted, f => delete f.ctx.ui.confirm, f => delete f.pi.setModel]) {
    const f = fixture();
    remove(f);
    const root = await mkdtemp(join(testTmp, 'hpi-api-'));
    t.after(() => rm(root, {recursive:true, force:true}));
    t.after(() => f.integration.stop());
  await assert.rejects(f.integration.start(f.ctx, {directory:join(root, 'control')}), /pi_api_unavailable/);
    assert.equal(f.integration.socketPath, undefined);
    assert.deepEqual(f.sent, []);
  }
});

async function socketCall(socketPath, payload) {
  return await new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    const chunks = [];
    socket.on('error', reject);
    socket.on('connect', () => socket.write(JSON.stringify(payload) + '\n'));
    socket.on('data', chunk => chunks.push(chunk));
    socket.on('end', () => {
      const raw = Buffer.concat(chunks);
      resolve({ bytes: raw.length, frame: JSON.parse(raw.toString('utf8')) });
    });
  });
}

test('oversized startup and reload retain an endpoint with an explicit state error', async t => {
  for (const kind of ['newest', 'empty-metadata', 'metadata']) {
    const f = fixture();
    const huge = 'x'.repeat(1024 * 1024);
    f.ctx.sessionManager.getBranch = () => kind === 'empty-metadata' ? [] : [
      {type:'message', id:'newest', message:{role:'user', content:kind === 'newest' ? huge : 'hello'}},
    ];
    if (kind !== 'newest') f.ctx.modelRegistry.getAvailable = () => [{provider:'provider', id:'model', name:huge}];
    const root = await mkdtemp(join(testTmp, 'hpi-size-'));
    t.after(() => rm(root, {recursive:true, force:true}));
    t.after(() => f.integration.stop());
    for (let attempt = 0; attempt < 2; attempt++) {
      await f.integration.start(f.ctx, {directory:join(root, 'control')});
      const reply = await socketCall(f.integration.socketPath, {method:'state'});
      assert.equal(reply.frame.error.code, 'pi_state_too_large');
      assert.ok(reply.bytes <= 1024 * 1024);
    }
    f.ctx.sessionManager.getBranch = () => [];
    f.ctx.modelRegistry.getAvailable = () => [];
    assert.equal((await socketCall(f.integration.socketPath, {method:'state'})).frame.result.session_id, sid);
  }
});

test('trailing metadata cannot hide the newest message or its oversized error', async t => {
  const f = await started(t);
  const newest = {type:'message', id:'newest', message:{role:'user', content:'x'.repeat(1024 * 1024)}};
  const metadata = Array.from({length:110}, (_, i) => ({type:'thinking_level_change', id:`meta-${i}`, thinkingLevel:'low'}));
  let branch = [newest, ...metadata];
  f.ctx.sessionManager.getBranch = () => branch;
  const oversized = await socketCall(f.integration.socketPath, {method:'state'});
  assert.equal(oversized.frame.error?.code, 'pi_state_too_large');
  assert.ok(oversized.bytes <= 1024 * 1024);
  newest.message.content = 'hello';
  const initial = await socketCall(f.integration.socketPath, {method:'state'});
  assert.ok(initial.bytes <= 1024 * 1024);
  assert.ok(initial.frame.result.entries.some(entry => entry.id === newest.id));
  newest.message.content = 'x'.repeat(1024 * 1024);

  // Paging to the same native message must surface the same explicit error.
  branch = [...branch, {type:'message', id:'after', message:{role:'assistant', content:'after'}}];
  const current = (await socketCall(f.integration.socketPath, {method:'state'})).frame.result;
  assert.equal(current.has_more, true);
  for (let attempt = 0; attempt < 2; attempt++) {
    const page = await socketCall(f.integration.socketPath, {method:'history', params:{expect:expectOf(current), before:current.before}});
    assert.equal(page.frame.error.code, 'pi_state_too_large');
    assert.ok(page.bytes <= 1024 * 1024);
  }
});

test('progressive history opens 2.58 MiB and >5 MiB sessions within 1 MiB frames without gaps or duplicates', async t => {
  for (const [count, textBytes] of [[100, 27000], [180, 34000]]) {
    const branch = Array.from({ length: count }, (_, i) => ({
      type: 'message',
      id: `m-${String(i).padStart(4, '0')}`,
      message: { role: i % 2 === 0 ? 'user' : 'assistant', content: `entry-${i}-` + 'x'.repeat(textBytes) },
    }));
    const totalBytes = Buffer.byteLength(JSON.stringify(branch));
    assert.ok(count === 100 ? totalBytes > 2_580_000 : totalBytes > 5 * 1024 * 1024);

    const f = fixture();
    f.ctx.sessionManager.getBranch = () => branch;
    const root = await mkdtemp(join(testTmp, 'hpi-prog-'));
    t.after(() => rm(root, { recursive: true, force: true }));
    await f.integration.start(f.ctx, { directory: join(root, 'control') });
    t.after(() => f.integration.stop());

    const initial = await socketCall(f.integration.socketPath, { method: 'state' });
    assert.ok(initial.bytes <= 1024 * 1024);
    assert.equal(initial.frame.result.capabilities.history, true);
    assert.equal(initial.frame.result.has_more, true);

    const collected = [...initial.frame.result.entries];
    let hasMore = initial.frame.result.has_more;
    let before = initial.frame.result.before;
    const expect = { session_id: initial.frame.result.session_id, instance_id: initial.frame.result.instance_id };
    while (hasMore) {
      const page = await socketCall(f.integration.socketPath, { method: 'history', params: { expect, before } });
      assert.ok(page.bytes <= 1024 * 1024, `page exceeded 1 MiB: ${page.bytes}`);
      const r = page.frame.result;
      assert.ok(r.entries.length > 0 || !r.has_more);
      collected.unshift(...r.entries);
      hasMore = r.has_more;
      before = r.before;
    }
    assert.equal(before, null);
    assert.deepEqual(collected.map(e => e.id), branch.map(e => e.id));
  }
});

test('UTF-8 multibyte boundaries stay strictly within 1 MiB and oversized single items fail explicitly', async t => {
  const f = fixture();
  let branch = [
    { type: 'message', id: 'old-utf8', message: { role: 'user', content: '界'.repeat(200_000) } },
    { type: 'message', id: 'mid-utf8', message: { role: 'assistant', content: 'é'.repeat(300_000) } },
    { type: 'message', id: 'new-utf8', message: { role: 'user', content: 'é'.repeat(300_000) } },
  ];
  f.ctx.sessionManager.getBranch = () => branch;
  const root = await mkdtemp(join(testTmp, 'hpi-utf8-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await f.integration.start(f.ctx, { directory: join(root, 'control') });
  t.after(() => f.integration.stop());

  const st = await socketCall(f.integration.socketPath, { method: 'state' });
  assert.ok(st.bytes <= 1024 * 1024);
  assert.deepEqual(st.frame.result.entries.map(e => e.id), ['new-utf8']);
  assert.equal(st.frame.result.has_more, true);

  const p1 = await socketCall(f.integration.socketPath, {
    method: 'history',
    params: { expect: { session_id: sid, instance_id: st.frame.result.instance_id }, before: st.frame.result.before },
  });
  assert.ok(p1.bytes <= 1024 * 1024);
  assert.deepEqual(p1.frame.result.entries.map(e => e.id), ['mid-utf8']);

  // Single oversized older item fails explicitly without skipping 'old-utf8'.
  branch[1] = { type: 'message', id: 'huge-old', message: { role: 'assistant', content: '界'.repeat(350_000) } };
  const hugeOlder = await socketCall(f.integration.socketPath, {
    method: 'history',
    params: { expect: { session_id: sid, instance_id: st.frame.result.instance_id }, before: 'new-utf8' },
  });
  assert.equal(hugeOlder.frame.error.code, 'pi_state_too_large');

  // Single oversized newest item fails explicitly instead of silently returning older items.
  branch.push({ type: 'message', id: 'huge-new', message: { role: 'assistant', content: '界'.repeat(350_000) } });
  const hugeNew = await socketCall(f.integration.socketPath, { method: 'state' });
  assert.equal(hugeNew.frame.error.code, 'pi_state_too_large');
});

test('history cursor survives appends and streaming but rejects branch switches, session swaps, and invalid cursors', async t => {
  const f = fixture();
  let currentSid = sid;
  f.ctx.sessionManager.getSessionId = () => currentSid;
  let branch = Array.from({ length: 4 }, (_, i) => ({
    type: 'message',
    id: `n-${i}`,
    message: { role: 'user', content: 'b'.repeat(300_000) },
  }));
  f.ctx.sessionManager.getBranch = () => branch;
  const root = await mkdtemp(join(testTmp, 'hpi-cur-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await f.integration.start(f.ctx, { directory: join(root, 'control') });
  t.after(() => f.integration.stop());

  const initial = await f.integration.request('state');
  const expect = { session_id: initial.session_id, instance_id: initial.instance_id };
  const cursor = initial.before;

  // Append and stream (bumps revision): history cursor remains valid.
  branch.push({ type: 'message', id: 'n-4', message: { role: 'assistant', content: 'ok' } });
  f.hooks.get('message_update')({ message: { role: 'assistant', content: [{ type: 'text', text: 'stream' }] } }, f.ctx);
  const afterAppend = await f.integration.request('state');
  assert.ok(afterAppend.revision > initial.revision);
  const older = await f.integration.request('history', { expect, before: cursor });
  assert.ok(older.entries.length > 0);
  f.hooks.get('message_end')({}, f.ctx);

  // Branch switch removes cursor node -> stale_cursor.
  branch = [{ type: 'message', id: 'alt-0', message: { role: 'user', content: 'alt' } }];
  await assert.rejects(f.integration.request('history', { expect, before: cursor }), /stale_cursor/);
  await assert.rejects(f.integration.request('history', { expect, before: '' }), /invalid_cursor/);

  // Session swap -> stale.
  currentSid = '99999999-1234-4234-8234-123456789abc';
  await assert.rejects(f.integration.request('history', { expect, before: 'alt-0' }), /stale/);
});

test('live-only windows retain cancel and page the omitted native tail without gaps', async t => {
  for (const nativeID of ['native-tail', 'n'.repeat(256)]) {
    const f = await started(t);
    const native = {type:'message', id:nativeID, message:{role:'user', content:'n'.repeat(600 * 1024)}};
    let branch = [{type:'message', id:'old', message:{role:'user', content:'old'}}, native];
    f.ctx.sessionManager.getBranch = () => branch;
    f.ctx.isIdle = () => false;
    const initial = await socketCall(f.integration.socketPath, {method:'state'});
    assert.deepEqual(initial.frame.result.entries, branch);
    const message = {role:'assistant', content:'s'.repeat(600 * 1024)};
    f.hooks.get('message_update')({message}, f.ctx);
    const reply = await socketCall(f.integration.socketPath, {method:'state'});
    assert.ok(reply.bytes <= 1024 * 1024);
    const state = reply.frame.result;
    assert.equal(state.status, 'working');
    assert.equal(state.entries.length, 1);
    assert.deepEqual(state.entries[0].message, message);
    assert.equal(state.has_more, true);
    const expect = expectOf(state);
    const older = await socketCall(f.integration.socketPath, {method:'history', params:{expect, before:state.before}});
    assert.ok(older.bytes <= 1024 * 1024);
    assert.deepEqual(older.frame.result.entries, branch);
    assert.equal(older.frame.result.has_more, false);
    const cancel = await socketCall(f.integration.socketPath, {method:'cancel', params:{expect}});
    assert.equal(cancel.frame.result.accepted, true);
    assert.equal(f.aborted, 1);
    branch = [...branch, {type:'message', id:'finished', message}];
    f.hooks.get('message_end')({}, f.ctx);
    const afterEnd = await socketCall(f.integration.socketPath, {method:'history', params:{expect, before:state.before}});
    assert.deepEqual(afterEnd.frame.result.entries, branch.slice(0, -1));
    const completed = await socketCall(f.integration.socketPath, {method:'state'});
    assert.ok(completed.bytes <= 1024 * 1024);
    assert.deepEqual(completed.frame.result.entries, branch.slice(-1));
    branch = [{type:'message', id:'alternate', message:{role:'user', content:'other'}}];
    await assert.rejects(f.integration.request('history', {expect, before:state.before}), /stale_cursor/);
  }
});
