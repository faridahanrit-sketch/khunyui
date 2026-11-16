import test from 'node:test';
import assert from 'node:assert/strict';
import {PlatformRepository,liveConfigured} from '../platform.js';

const STORE='22222222-2222-4222-8222-222222222222';
const OTHER='33333333-3333-4333-8333-333333333333';
const USER='44444444-4444-4444-8444-444444444444';
const CATEGORY='55555555-5555-4555-8555-555555555555';
const MENU='66666666-6666-4666-8666-666666666666';
const ARCHIVED='77777777-7777-4777-8777-777777777777';
const HERO='stores/'+STORE+'/menu/hero-test.png';
const CONFIG={url:'https://example.supabase.co',anonKey:'public-test-key',storeId:STORE,legacyStoreId:'11111111-1111-4111-8111-111111111111'};
function fixture(){
  const calls=[],db={
    store_members:[{store_id:STORE,user_id:USER,role:'owner',is_active:true}],
    store_public_settings:[{store_id:STORE,is_accepting_orders:false,closed_for_date:null,hero_image_path:HERO}],
    menu_categories:[{id:CATEGORY,store_id:STORE,code:'MADE',name:'อาหารตามสั่ง',sort_order:0,is_active:true}],
    menu_items:[{id:MENU,store_id:STORE,sku:'J1',name:'จานหนึ่ง',description:'',price_satang:5000,category_id:CATEGORY,image_path:null,is_available:true,is_archived:false,is_recommended:false,sort_order:0},{id:ARCHIVED,store_id:STORE,sku:'J2',name:'จานรอ',description:'',price_satang:5000,category_id:CATEGORY,image_path:null,is_available:true,is_archived:true,is_recommended:false,sort_order:1}],
    menu_item_option_groups:[],orders:[],daily_closings:[]
  };
  let ownerSession={user:{id:USER}},customerSession=null,clock=0,signing=0,bulkSigning=0;
  class Query{
    constructor(table,actor){this.table=table;this.actor=actor;this.filters=[];}
    select(){return this;}
    eq(key,value){this.filters.push(row=>row[key]===value);return this;}
    in(key,values){this.filters.push(row=>values.includes(row[key]));return this;}
    order(){return this;}
    limit(){return this;}
    rows(){return (db[this.table]||[]).filter(row=>this.filters.every(fn=>fn(row)));}
    async maybeSingle(){calls.push({kind:'query',table:this.table,actor:this.actor});return {data:this.rows()[0]||null,error:null};}
    then(resolve,reject){calls.push({kind:'query',table:this.table,actor:this.actor});return Promise.resolve({data:this.rows(),error:null}).then(resolve,reject);}
  }
  function client(actor){
    return {
      auth:{
        async getSession(){return {data:{session:actor==='owner'?ownerSession:customerSession},error:null};},
        async signInWithPassword(){ownerSession={user:{id:USER}};return {data:{session:ownerSession},error:null};},
        async signInAnonymously(){customerSession={user:{id:OTHER}};return {data:{session:customerSession},error:null};},
        async signOut(){calls.push({kind:'logout',actor});ownerSession=null;return {error:null};}
      },
      from(table){return new Query(table,actor);},
      async rpc(name,args){
        calls.push({kind:'rpc',actor,name,args});
        if(name==='get_store_open_state')return {data:{is_open:false},error:null};
        if(name==='get_owner_dashboard_summary')return {data:{business_date:'2026-11-17'},error:null};
        if(name==='create_order')return {data:[{order_id:MENU}],error:null};
        return {data:true,error:null};
      },
      storage:{from(bucket){return {
        async upload(path,file,options){calls.push({kind:'upload',actor,bucket,path,file,options});return {data:{path},error:null};},
        async createSignedUrl(path,ttl){signing++;calls.push({kind:'sign',actor,bucket,path,ttl});return {data:{signedUrl:'https://storage.example/'+actor+'/'+signing},error:null};},
        async createSignedUrls(paths,ttl){bulkSigning++;calls.push({kind:'bulk-sign',actor,bucket,paths,ttl});return {data:paths.map(path=>({path,signedUrl:'https://storage.example/'+actor+'/bulk-'+bulkSigning+'/'+path})),error:null};}
      };}}
    };
  }
  let created=0;
  const repo=new PlatformRepository({config:CONFIG,clientFactory(){return client(created++===0?'owner':'customer');},now:()=>clock});
  return {repo,calls,db,setClock:n=>clock=n,removeOwnerSession:()=>ownerSession=null,liveState:()=>({live:true,storeId:STORE,storeSlug:'jele',menu:[{id:MENU}],orders:[]})};
}
test('unconfigured and legacy stores cannot initialize a live Jele repository',()=>{
  assert.equal(liveConfigured({...CONFIG,storeId:null}),false);
  assert.equal(liveConfigured({...CONFIG,storeId:CONFIG.legacyStoreId}),false);
  assert.throws(()=>new PlatformRepository({config:{...CONFIG,storeId:null},clientFactory(){throw Error('must not create client');}}),/ยังไม่ได้ผูก/);
});
test('public menu reads exclude archived drafts and carry the actual store identity and hero',async()=>{
  const h=fixture(),state=await h.repo.load();
  assert.deepEqual(state.menu.map(d=>d.id),[MENU]);
  assert.equal(state.settings.bannerPhotoKey,HERO);
  assert.equal(state.storeId,STORE);
  assert.equal(state.live,true);
});
test('owner menu reads retain archived drafts after membership verification',async()=>{
  const h=fixture(),state=await h.repo.load({owner:true});
  assert.equal(state.menu.length,2);
  assert.equal(state.menu.find(d=>d.id===ARCHIVED).published,false);
  assert.ok(h.calls.some(c=>c.table==='store_members'));
});
test('a revoked member cannot upload or change the shop poster even after an earlier successful check',async()=>{
  const h=fixture();await h.repo.checkMember();h.db.store_members[0].is_active=false;
  await assert.rejects(()=>h.repo.execute('shop-banner',{photoKey:HERO},h.liveState()),/ไม่มีสิทธิ์/);
  await assert.rejects(()=>h.repo.savePhoto('__shop-banner__',{type:'image/png'}),/ไม่มีสิทธิ์/);
  assert.equal(h.calls.filter(c=>c.kind==='rpc'||c.kind==='upload').length,0);
});
test('an expired owner session cannot perform any shop write',async()=>{
  const h=fixture();h.removeOwnerSession();
  await assert.rejects(()=>h.repo.execute('open',{},h.liveState()),/เข้าสู่งานร้าน/);
  assert.equal(h.calls.filter(c=>c.kind==='rpc').length,0);
});
test('state and record identifiers from another store are rejected before write RPCs',async()=>{
  const h=fixture();
  await assert.rejects(()=>h.repo.execute('open',{}, {...h.liveState(),storeId:OTHER}),/ข้อมูลร้านเปลี่ยน/);
  await assert.rejects(()=>h.repo.execute('unpublish',{id:OTHER},h.liveState()),/ไม่พบเมนู/);
  await assert.rejects(()=>h.repo.execute('cancel',{id:OTHER,reason:'ทดสอบ'},h.liveState()),/ไม่พบรายการ/);
  assert.equal(h.calls.filter(c=>c.kind==='rpc').length,0);
});
test('poster upload preserves the original PNG without a client size cap or an overwrite',async()=>{
  const h=fixture(),file={type:'image/png',size:20*1024*1024};
  const path=await h.repo.savePhoto('__shop-banner__',file);
  const call=h.calls.find(c=>c.kind==='upload');
  assert.equal(call.file,file);
  assert.equal(call.options.contentType,'image/png');
  assert.equal(call.options.upsert,false);
  assert.match(path,new RegExp('^stores/'+STORE+'/menu/hero-jele-.*\\.png$'));
});
test('poster metadata is saved through the existing server RPC and rejects another store image',async()=>{
  const h=fixture();
  await h.repo.execute('shop-banner',{photoKey:HERO},h.liveState());
  const saved=h.calls.filter(c=>c.kind==='rpc');
  assert.equal(saved.length,1);assert.equal(saved[0].name,'set_store_hero_image');
  assert.deepEqual(saved[0].args,{p_store_id:STORE,p_image_path:HERO});
  await assert.rejects(()=>h.repo.execute('shop-banner',{photoKey:'stores/'+OTHER+'/menu/hero.png'},h.liveState()),/ไม่ได้อยู่ในพื้นที่/);
  assert.equal(h.calls.filter(c=>c.kind==='rpc').length,1);
});
test('signed images renew before expiry and never sign foreign or traversing storage paths',async()=>{
  const h=fixture();
  const first=await h.repo.photo(HERO);assert.equal(await h.repo.photo(HERO),first);
  h.setClock(50*60*1000+1);assert.ok(await h.repo.photo(HERO)!==first);
  assert.equal(await h.repo.photo('stores/'+OTHER+'/menu/image.png'),null);
  assert.equal(await h.repo.photo('stores/'+STORE+'/menu/../other.png'),null);
  assert.equal(h.calls.filter(c=>c.kind==='sign').length,2);
});
test('bulk signing deduplicates paths and separates owner and customer caches',async()=>{
  const h=fixture(),second='stores/'+STORE+'/menu/second.png';
  await h.repo.preloadPhotos([HERO,HERO,second,'stores/'+OTHER+'/menu/no.png']);
  assert.equal(h.calls.filter(c=>c.kind==='bulk-sign').length,1);
  assert.equal(h.calls.find(c=>c.kind==='bulk-sign').paths.length,2);
  await h.repo.photo(HERO);assert.equal(h.calls.filter(c=>c.kind==='sign').length,0);
  h.repo.photoAudience='owner';await h.repo.preloadPhotos([HERO]);
  assert.equal(h.calls.filter(c=>c.kind==='bulk-sign').length,2);
});
test('payment confirmation refuses a different method before recording money',async()=>{
  const h=fixture(),state=h.liveState();
  state.orders=[{id:MENU,status:'ready',paid:false,paymentMethod:'cash'}];
  await assert.rejects(()=>h.repo.execute('pay',{id:MENU,method:'promptpay_qr',finish:true},state),/ช่องทางรับเงินไม่ตรง/);
  assert.equal(h.calls.filter(c=>c.kind==='rpc').length,0);
});
test('logout clears member and image caches instead of retaining owner URLs',async()=>{
  const h=fixture();await h.repo.checkMember();h.repo.photoAudience='owner';await h.repo.photo(HERO);
  await h.repo.logout();
  assert.equal(h.repo.member,null);assert.equal(h.repo.memberUserId,null);assert.equal(h.repo.photoCache.size,0);assert.equal(h.repo.photoAudience,'customer');
});
