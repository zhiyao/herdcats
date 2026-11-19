/** Live Pi TUI integration. Uses extension APIs only: never starts or resumes Pi. */
import { createServer } from 'node:net';
import { chmod, lstat, mkdir, unlink } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { isAbsolute, join, parse, relative } from 'node:path';
const MAX_FRAME = 1024 * 1024;
const MAX_STATE_ENTRIES = 100;
const MAX_PAGE_ENTRIES = 100;
const MAX_CURSOR_BYTES = 512;
const THROUGH_CURSOR = 'herdcats-through:';
const UUID = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i;
const fail = code => { throw new Error(code); };
function plain(value) { return typeof value === 'string' && Buffer.byteLength(value) <= 256 * 1024 && !value.includes('\0'); }
function dialogString(value) { return plain(value) && Buffer.byteLength(value) <= 8192; }
function answerString(value) { return plain(value) && Buffer.byteLength(value) <= 65536; }
async function privateDirectory(path) {
  if (!isAbsolute(path)) fail('unsafe_control_directory');
  // Verify every component; mkdir's recursive traversal alone follows symlinks.
  let current = parse(path).root;
  for (const part of relative(current, path).split('/').filter(Boolean)) {
    current = join(current, part);
    try { await mkdir(current, {mode:0o700}); } catch (error) { if (error.code !== 'EEXIST') throw error; }
    const stat = await lstat(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail('unsafe_control_directory');
  }
  const stat = await lstat(path);
  if (stat.uid !== process.getuid?.()) fail('unsafe_control_directory');
  await chmod(path, 0o700);
}
export function createIntegration(pi, {getSupportedThinkingLevels, version}) {
  let ctx, server, socketPath, instance = randomUUID(), revision = 1, pending = [], live, liveID, prompting = false, changing = false, fingerprint = '', restores = [], closed = false;
  let serialized = Promise.resolve();
  const bump = () => { revision++; };
  const current = () => ctx?.sessionManager.getSessionId();
  const key = model => `${model.provider}/${model.id}`;
  function catalog() {
    const available = ctx.modelRegistry.getAvailable();
    return available.map(model => ({native:model,id:key(model),label:`${model.name || model.id} (${model.provider})`,efforts:getSupportedThinkingLevels(model).map(id=>({id,label:id}))}));
  }
  function packWindow(branch, end, maxEntries, tailEntry, makeEnvelope) {
    if (!Array.isArray(branch)) fail('invalid_pi_response');
    // Native metadata is not projected into Timeline. Do not let a suffix of
    // those records conceal the newest message (including an oversized one).
    if (!tailEntry) {
      while (end > 0 && branch[end - 1]?.type !== 'message') end--;
    }
    if (end <= 0) {
      const entries = tailEntry ? [tailEntry] : [];
      const result = makeEnvelope(entries, false, null);
      if (Buffer.byteLength(JSON.stringify({ result })) + 1 > MAX_FRAME) fail('pi_state_too_large');
      return result;
    }
    const emptyBytes = Buffer.byteLength(JSON.stringify({ result: makeEnvelope([], false, null) })) + 1;
    const tailBytes = tailEntry ? Buffer.byteLength(JSON.stringify(tailEntry)) : 0;
    if (emptyBytes + tailBytes > MAX_FRAME) fail('pi_state_too_large');
    const minStart = Math.max(0, end - maxEntries);
    let usedBytes = emptyBytes + tailBytes;
    let start = end;
    let chosenCount = 0;
    for (let i = end - 1; i >= minStart; i--) {
      const itemBytes = Buffer.byteLength(JSON.stringify(branch[i])) + (chosenCount > 0 || tailEntry ? 1 : 0);
      const id = branch[i]?.id;
      const cursorOverhead = i > 0 && typeof id === 'string' ? Math.max(0, Buffer.byteLength(JSON.stringify(id)) - 4) : 0;
      if (usedBytes + itemBytes + cursorOverhead > MAX_FRAME) {
        if (chosenCount === 0 && !tailEntry) fail('pi_state_too_large');
        break;
      }
      usedBytes += itemBytes;
      start = i;
      chosenCount++;
    }
    while (start < end || tailEntry) {
      const slice = branch.slice(start, end);
      const anchor = start === end ? branch[end - 1]?.id : slice[0]?.id;
      if (start > 0 && (typeof anchor !== 'string' || !anchor || Buffer.byteLength(anchor) > 256)) {
        fail('invalid_pi_response');
      }
      const before = start === end ? THROUGH_CURSOR + anchor : start > 0 ? anchor : null;
      const entries = tailEntry ? [...slice, tailEntry] : slice;
      const result = makeEnvelope(entries, start > 0, before);
      if (Buffer.byteLength(JSON.stringify({ result })) + 1 <= MAX_FRAME) return result;
      if (start === end || (!tailEntry && end - start === 1)) fail('pi_state_too_large');
      start++;
    }
    fail('pi_state_too_large');
  }
  function stateData() {
    if (!ctx || closed) fail('pi_extension_unavailable');
    const models = catalog();
    const branch = ctx.sessionManager.getBranch();
    if (!Array.isArray(branch)) fail('invalid_pi_response');
    const authoritative = JSON.stringify({session:current(),file:ctx.sessionManager.getSessionFile(),leaf:branch.at(-1)?.id,model:ctx.model && key(ctx.model),effort:pi.getThinkingLevel(),idle:ctx.isIdle(),queued:ctx.hasPendingMessages(),draft:ctx.ui.getEditorText()});
    if (fingerprint && fingerprint !== authoritative) bump();
    fingerprint = authoritative;
    const tailEntry = live ? {type:'message',id:liveID, message:live} : null;
    const base = {
      protocol: 1,
      version,
      session_id: current(),
      session_file: ctx.sessionManager.getSessionFile() ?? null,
      instance_id: instance,
      revision,
      status: pending.length ? 'blocked' : (ctx.isIdle() && !changing && !prompting ? 'idle' : 'working'),
      model: ctx.model ? {id:key(ctx.model),label:`${ctx.model.name || ctx.model.id} (${ctx.model.provider})`,effort:pi.getThinkingLevel()} : null,
      models: models.map(({native,...model})=>model),
      pending: pending.at(-1)?.public ?? null,
      capabilities: {prompts:true,cancel:true,model_control:true,dialogs:true,dialog_kinds:['confirm','select','input'],editor:false,custom:false,history:true},
    };
    return {branch, tailEntry, base};
  }
  function state() {
    const {branch, tailEntry, base} = stateData();
    return packWindow(branch, branch.length, MAX_STATE_ENTRIES, tailEntry, (entries, has_more, before) => ({
      ...base,
      entries,
      has_more,
      before,
    }));
  }
  function history(params = {}) {
    if (!ctx || closed) fail('pi_extension_unavailable');
    if (!params?.expect || params.expect.session_id !== current() || params.expect.instance_id !== instance) fail('stale');
    const before = params.before;
    if (typeof before !== 'string' || !before || Buffer.byteLength(before) > MAX_CURSOR_BYTES) fail('invalid_cursor');
    const branch = ctx.sessionManager.getBranch();
    const inclusive = before.startsWith(THROUGH_CURSOR);
    const anchor = inclusive ? before.slice(THROUGH_CURSOR.length) : before;
    const index = branch.findIndex(entry => entry?.id === anchor);
    if (index < 0) fail('stale_cursor');
    return packWindow(branch, index + (inclusive ? 1 : 0), MAX_PAGE_ENTRIES, null, (entries, has_more, nextBefore) => ({
      protocol: 1,
      session_id: current(),
      instance_id: instance,
      entries,
      has_more,
      before: nextBefore,
    }));
  }
  function check(expect) {
    const now=state();
    if (changing || !expect || expect.session_id!==now.session_id || expect.instance_id!==instance || expect.revision!==revision) fail('stale');
    return now;
  }
  function idle() {
    if (!ctx.isProjectTrusted()) fail('terminal_required');
    if (prompting || pending.length || !ctx.isIdle() || ctx.hasPendingMessages()) fail('agent_busy');
    if (ctx.ui.getEditorText() !== '') fail('composer_not_empty');
  }
  function wrapUI() {
    const ui=ctx.ui;
    function install(name, factory) {
      const original=ui[name]; const wrapped=factory(original.bind(ui)); ui[name]=wrapped;
      restores.push(()=>{if(ui[name]===wrapped) ui[name]=original;});
    }
    for (const kind of ['confirm','select','input']) install(kind,original=>(title, second, opts)=>{
      if (opts?.signal?.aborted) return original(title,second,opts);
      // Only the plain public dialog schema is forwarded. Overlarge/ambiguous
      // schemas still display normally in Terminal and inhibit phone actions.
      const supported=dialogString(title) && (kind==='select' ? Array.isArray(second) && second.length>0 && second.length<=100 && second.every(dialogString) && new Set(second).size===second.length : second===undefined || dialogString(second));
      const controller=new AbortController();
      const onAbort=()=>controller.abort(); opts?.signal?.addEventListener('abort',onAbort,{once:true});
      let settle;
      const remote=new Promise(resolve=>{settle=resolve;});
      const item={public:{id:randomUUID(),kind:supported?kind:'terminal',title:dialogString(title)?title:'Continue in Terminal',...(kind==='select' && supported ? {options:[...second]} : {}),...(kind==='confirm' && supported ? {message:second} : {}),...(kind==='input' && supported ? {message:second ?? ''} : {})},settle};
      pending.push(item);bump();
      let terminal;
      try { terminal=Promise.resolve(original(title,second,{...opts,signal:controller.signal})); }
      catch(error) {terminal=Promise.reject(error);}
      return Promise.race([terminal.then(value=>({value,remote:false})),remote.then(value=>({value,remote:true}))]).then(result=>{
        // Resolve the remote result before aborting the terminal widget. Its
        // cancellation result must never replace an explicit phone response.
        if(result.remote)controller.abort();
        return result.value;
      }).finally(()=>{opts?.signal?.removeEventListener('abort',onAbort);pending=pending.filter(value=>value!==item);bump();});
    });
    for(const kind of ['custom','editor']) install(kind,original=>(...args)=>{
      const item={public:{id:randomUUID(),kind:'terminal',title:kind==='editor'&&dialogString(args[0])?args[0]:'Custom dialog — continue in Terminal'}};
      pending.push(item);bump();
      let result;try{result=original(...args);}catch(error){result=Promise.reject(error);}
      return Promise.resolve(result).finally(()=>{pending=pending.filter(value=>value!==item);bump();});
    });
  }
  async function request(method, params={}) {
    if(method==='state')return state();
    if(method==='history')return history(params);
    // Serializing the async model mutation prevents another request from
    // passing guards while setModel awaits credentials/model hooks.
    const run=async()=>{
      const now=check(params.expect);
      if(method==='prompt') {
        idle();if(!plain(params.text)||!params.text.trim()||params.text.trimStart().startsWith('/'))fail('invalid_prompt');
        prompting=true;bump();try{pi.sendUserMessage(params.text);}catch(error){prompting=false;throw error;}return {accepted:true};
      }
      if(method==='cancel') {
        if(pending.length)fail('terminal_required');
        if(ctx.isIdle())fail('agent_idle');bump();ctx.abort();return {accepted:true};
      }
      if(method==='dialog.respond') {
        const item=pending.at(-1);if(!item||item.public.id!==params.request_id)fail('stale');
        const kind=item.public.kind;
        if(kind==='terminal')fail('terminal_required');
        if(kind==='confirm' ? typeof params.value!=='boolean' : kind==='select' ? !item.public.options.includes(params.value) : !answerString(params.value))fail('invalid_response');
        bump();item.settle(params.value);return {accepted:true};
      }
      if(method==='model.set') {
        idle();const models=catalog();const target=models.find(model=>model.id===(params.model??now.model?.id));
        if(!target)fail('invalid_model');
        const effort=params.effort??(target.efforts.some(level=>level.id===now.model?.effort)?now.model.effort:target.efforts[0]?.id);
        if(!target.efforts.some(level=>level.id===effort))fail('invalid_effort');
        changing=true;bump();
        try {
          if(!await pi.setModel(target.native))fail('model_change_rejected');
          // A local session switch during the await invalidates this action.
          if(current()!==now.session_id || instance!==now.instance_id)fail('stale');
          pi.setThinkingLevel(effort);
          if(!ctx.model||key(ctx.model)!==target.id||pi.getThinkingLevel()!==effort)fail('model_change_unconfirmed');
        }finally{changing=false;bump();}
        return {confirmed:true,applied:true,model:state().model};
      }
      fail('unsupported_method');
    };
    const action=serialized.then(run,run);serialized=action.catch(()=>{});return action;
  }
  async function stop() {
    closed=true;bump();restores.splice(0).forEach(restore=>restore());
    const old=server;server=undefined;
    if(old) await new Promise(resolve=>old.close(resolve));
    if(socketPath){try{await unlink(socketPath);}catch(error){if(error.code!=='ENOENT')throw error;}socketPath=undefined;}
  }
  async function start(context,{directory=join(homedir(),'.pi','agent','herdcats')}={}) {
    if(server)await stop();ctx=context;closed=false;instance=randomUUID();revision=1;fingerprint='';live=undefined;prompting=false;pending=[];
    if(ctx.mode!=='tui'||!ctx.hasUI)fail('pi_tui_required');
    // Validate the public API contract, not the Pi release number.
    for (const [object, methods] of [
      [ctx, ['isIdle','isProjectTrusted','hasPendingMessages','abort']],
      [ctx.sessionManager, ['getSessionId','getSessionFile','getBranch']],
      [ctx.modelRegistry, ['getAvailable']],
      [ctx.ui, ['getEditorText','confirm','select','input','custom','editor']],
      [pi, ['sendUserMessage','getThinkingLevel','setModel','setThinkingLevel']],
      [{getSupportedThinkingLevels}, ['getSupportedThinkingLevels']],
    ]) {
      if (methods.some(method => typeof object?.[method] !== 'function')) fail('pi_api_unavailable');
    }
    stateData();
    const id=current();if(!UUID.test(id))fail('invalid_session_reference');
    await privateDirectory(directory);const candidate=join(directory,`${id}.sock`);
    // Never unlink another live or stale process's endpoint automatically.
    // A duplicate native session must not become an ambiguous control target.
    try {await lstat(candidate);fail('pi_endpoint_exists');}catch(error){if(error.code!=='ENOENT')throw error;}
    server=createServer(socket=>{
      socket.setTimeout(2000,()=>socket.destroy());let buffer=Buffer.alloc(0);let received=false;
      socket.on('error',()=>{});
      socket.on('data',chunk=>{
        if(received)return;buffer=Buffer.concat([buffer,chunk]);if(buffer.length>MAX_FRAME){received=true;socket.end(JSON.stringify({error:{code:'request_too_large'}})+'\n');return;}
        const newline=buffer.indexOf(10);if(newline<0)return;received=true;
        let frame;try{frame=JSON.parse(buffer.subarray(0,newline).toString('utf8'));}catch{socket.end(JSON.stringify({error:{code:'invalid_request'}})+'\n');return;}
        request(frame.method,frame.params).then(result=>{
          let output=JSON.stringify({result});if(Buffer.byteLength(output)+1>MAX_FRAME)output=JSON.stringify({error:{code:'pi_state_too_large'}});socket.end(output+'\n');
        },error=>socket.end(JSON.stringify({error:{code:/^[a-z_]+$/.test(error.message)?error.message:'pi_extension_error'}})+'\n'));
      });
    });
    try { await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(candidate,resolve);});socketPath=candidate;await chmod(socketPath,0o600);wrapUI();}
    catch(error){await stop();throw error;}
    return socketPath;
  }
  for(const event of ['agent_start','agent_end','agent_settled','tool_execution_start','tool_execution_update','tool_execution_end','model_select','thinking_level_select','turn_end'])pi.on(event,(_event,context)=>{ctx=context;bump();if(['agent_start','agent_end','agent_settled'].includes(event))prompting=false;if(event==='agent_end')live=undefined;});
  for(const event of ['message_start','message_update'])pi.on(event,(event,context)=>{ctx=context;if(event.message?.role==='assistant'){if(!live)liveID=`herdcats-live:${randomUUID()}`;live=event.message;}bump();});
  pi.on('message_end',(_event,context)=>{ctx=context;live=undefined;bump();});
  // A different extension may have retained a bound UI method before our
  // installation. Pi's public UI prompt events still make that dialog a
  // Terminal-only gate, rather than allowing remote prompts past it.
  pi.on('ui_prompt_start',(event,context)=>{
    ctx=context;
    if(!pending.length)pending.push({external:true,public:{id:randomUUID(),kind:'terminal',title:dialogString(event.title)?event.title:'Continue in Terminal'}});
    bump();
  });
  pi.on('ui_prompt_end',(_event,context)=>{ctx=context;pending=pending.filter(item=>!item.external);bump();});
  return {start,stop,request,get socketPath(){return socketPath;}};
}
