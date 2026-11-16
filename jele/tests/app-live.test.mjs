import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const sources=Object.fromEntries(['app.js','core.js','catalog.js','visuals.js'].map(name=>[name,readFileSync(new URL('../'+name,import.meta.url),'utf8')]));
const STORE='22222222-2222-4222-8222-222222222222';
function harness(){
  const nodes=new Map(),events=new Map(),timers=new Map();let timerId=0,uuidId=0;
  const node=()=>({textContent:'',innerHTML:'',open:false,dataset:{},addEventListener(){},setAttribute(){},focus(){},classList:{add(){},remove(){},toggle(){}},showModal(){this.open=true;},close(){this.open=false;}});
  const document={body:{dataset:{}},visibilityState:'visible',querySelector(s){if(!nodes.has(s))nodes.set(s,node());return nodes.get(s);},querySelectorAll(){return[];},addEventListener(name,fn){if(!events.has(name))events.set(name,[]);events.get(name).push(fn);}};
  const location={hash:'#/menu',reload(){}};
  const memory={getItem(){return null;},setItem(){},removeItem(){}};
  const crypto={randomUUID:()=>'99999999-9999-4999-8999-'+String(++uuidId).padStart(12,'0')};
  const stubs="class PracticeRepository{constructor(c){this.stored=defaultState(c);}subscribe(){}} class PlatformRepository{} const liveConfigured=()=>true;const launchMode=()=> 'live';function bannerMarkup(){return '';}";
  const code=[sources['catalog.js'],sources['visuals.js'],sources['core.js'],stubs,sources['app.js'].replace(/^import .*;$/gm,'').replace(/^initBannerViewer\\(\\);$/m,'').replace(/^await start\\(\\);$/m,'')].join('\n').replace(/\bexport /g,'');
  const expose="return {reload,ensureLivePolling,isAuthFailure,showPayment,setRepo(r){repo=r;},setState(s){state=s;},getState(){return clone(state);},setMode(v){mode=v;},mode:()=>mode,makeState(label){const s=defaultState(CATALOG);s.live=true;s.storeId='"+STORE+"';s.label=label;return s;}};";
  const clean=code.replace('initBannerViewer();','').replace('await start();','');
  const api=new Function('document','window','location','localStorage','crypto','structuredClone','setInterval','clearInterval','setTimeout','clearTimeout',clean+'\n'+expose)(document,{addEventListener(){},scrollTo(){}},location,memory,crypto,v=>v===undefined?undefined:JSON.parse(JSON.stringify(v)),fn=>{timers.set(++timerId,fn);return timerId;},id=>timers.delete(id),()=>1,()=>{});
  return {api,document,location,timers,async click(action){const button={disabled:false,dataset:{action}};const event={target:{closest(selector){return selector==='[data-action]'?button:null;}}};for(const fn of events.get('click')||[])await fn(event);}};
}
test('live startup does not select practice and network errors do not masquerade as login failures',()=>{
  const h=harness();assert.equal(h.api.mode(),'live');
  assert.equal(h.api.isAuthFailure(Error('Failed to fetch')),false);
  assert.equal(h.api.isAuthFailure({status:401}),true);
});
test('a slower obsolete load cannot replace a newer owner view',async()=>{
  const h=harness(),pending=[];h.api.setRepo({load(){return new Promise(resolve=>pending.push(resolve));}});
  const first=h.api.reload({renderPage:false});
  h.location.hash='#/mother/pending';const second=h.api.reload({renderPage:false});
  pending[1](h.api.makeState('newer'));assert.equal(await second,true);
  pending[0](h.api.makeState('older'));assert.equal(await first,false);
  assert.equal(h.api.getState().label,'newer');
});
test('an owner response arriving after logout cannot put private data back on screen',async()=>{
  const h=harness();let resolve;
  h.location.hash='#/mother';h.api.setState(h.api.makeState('private'));
  h.api.setRepo({load(){return new Promise(r=>resolve=r);},async logout(){}});
  const pending=h.api.reload({renderPage:false});
  await h.click('logout');assert.equal(h.api.getState(),null);
  resolve(h.api.makeState('stale-private'));assert.equal(await pending,false);
  assert.equal(h.api.getState(),null);
  assert.ok(h.document.querySelector('#app').innerHTML.includes('เข้าสู่งานของแม่'));
});
test('polling has one timer and does not overlap slow database requests',async()=>{
  const h=harness(),pending=[];let loads=0;
  h.api.setRepo({load(){loads++;return new Promise(resolve=>pending.push(resolve));}});
  h.api.ensureLivePolling();h.api.ensureLivePolling();assert.equal(h.timers.size,1);
  const tick=[...h.timers.values()][0],first=tick();await tick();assert.equal(loads,1);
  pending[0](h.api.makeState('live'));await first;
  assert.equal(h.timers.size,1);
});
