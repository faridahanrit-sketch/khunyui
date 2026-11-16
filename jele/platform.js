import {PLATFORM} from './platform-config.js';
import {bangkokDate,STOCK,dishConfigured} from './core.js?v=3';
export const liveConfigured=(config=PLATFORM)=>!!config.storeId&&config.storeId!==config.legacyStoreId&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(config.storeId);
export const launchMode=()=>PLATFORM.launchMode==='practice'?'practice':'live';
// This adapter uses the existing platform, tables and RPCs. It never falls back
// to Khun Yui's store, and it never writes training data to that store.
export class PlatformRepository {
  constructor({config=PLATFORM,clientFactory=globalThis.supabase?.createClient,now=()=>Date.now()}={}){
    if(!liveConfigured(config))throw Error('ร้านเจ๊เล่ยังไม่ได้ผูกกับระบบกลาง');
    if(typeof clientFactory!=='function')throw Error('เปิดการเชื่อมต่อไม่สำเร็จ กรุณาลองใหม่');
    this.storeId=config.storeId;this.now=now;this.photoCache=new Map();this.photoAudience='customer';
    const options=storageKey=>({auth:{flowType:'pkce',storageKey,persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
    this.owner=clientFactory(config.url,config.anonKey,options('khunyui-auth'));
    this.customer=clientFactory(config.url,config.anonKey,options('jele-customer-auth'));
    this.member=null;this.memberUserId=null;
  }
  assertState(state){if(!state||state.storeId!==this.storeId||state.storeSlug!=='jele'||state.live!==true)throw Error('ข้อมูลร้านเปลี่ยน กรุณาเปิดหน้าร้านใหม่อีกครั้ง');}
  assertPhotoPath(path){if(typeof path!=='string'||!path.startsWith('stores/'+this.storeId+'/menu/')||path.split('/').some(p=>!p||p==='.'||p==='..')||/[\\?#%]/.test(path))throw Error('ภาพนี้ไม่ได้อยู่ในพื้นที่ของร้านเจ๊เล่');return path;}
  async session(owner=true){const r=await(owner?this.owner:this.customer).auth.getSession();if(r.error)throw r.error;return r.data?.session||null;}

  async rpc(name,args,owner=true){const r=await(owner?this.owner:this.customer).rpc(name,args);if(r.error)throw r.error;return r.data;}
  async login(email,password){const r=await this.owner.auth.signInWithPassword({email,password});if(r.error)throw Error('อีเมลหรือรหัสผ่านไม่ถูกต้อง หรือยังเชื่อมต่อไม่ได้');await this.checkMember();}
  async checkMember(){
    const session=await this.session();
    if(!session){this.member=null;this.memberUserId=null;this.photoCache.clear();throw Error('กรุณาเข้าสู่งานร้านก่อนค่ะ');}
    if(this.memberUserId&&this.memberUserId!==session.user.id)this.photoCache.clear();
    const r=await this.owner.from('store_members').select('role,is_active').eq('store_id',this.storeId).eq('user_id',session.user.id).maybeSingle();
    if(r.error)throw r.error;
    if(!r.data?.is_active||!['owner','staff','manager'].includes(r.data.role)){this.member=null;this.memberUserId=null;this.photoCache.clear();throw Error('บัญชีนี้ยังไม่มีสิทธิ์ดูแลงานร้านเจ๊เล่');}
    this.member=r.data;this.memberUserId=session.user.id;return r.data;
  }

  menuQuery(cli,owner){let q=cli.from('menu_items').select('id,sku,name,description,price_satang,category_id,image_path,is_available,is_archived,is_recommended,sort_order').eq('store_id',this.storeId);if(!owner)q=q.eq('is_archived',false);return q.order('sort_order');}
  async load({owner=false}={}){if(owner)await this.checkMember();this.photoAudience=owner?'owner':'customer';const cli=owner?this.owner:this.customer;const [settings,menus,cats]=await Promise.all([cli.from('store_public_settings').select('is_accepting_orders,closed_for_date,hero_image_path').eq('store_id',this.storeId).maybeSingle(),this.menuQuery(cli,owner),cli.from('menu_categories').select('id,code,name,sort_order').eq('store_id',this.storeId).eq('is_active',true).order('sort_order')]);for(const r of [settings,menus,cats])if(r.error)throw r.error;if(!settings.data)throw Error('ยังไม่พบการตั้งค่าร้านเจ๊เล่ในระบบกลาง');const openState=await this.rpc('get_store_open_state',{p_store_id:this.storeId},owner);const dashboard=owner?await this.rpc('get_owner_dashboard_summary',{p_store_id:this.storeId}):null;const ids=(menus.data||[]).map(m=>m.id);let links=[];if(ids.length){const r=await cli.from('menu_item_option_groups').select('menu_item_id,sort_order,menu_option_groups(id,code,name,selection_type,min_select,max_select,is_active,sort_order,menu_option_values(id,code,name,price_delta_satang,is_available,is_default,sort_order))').in('menu_item_id',ids);if(r.error)throw r.error;links=r.data||[];}
    const category=id=>{const c=cats.data.find(x=>x.id===id),s=(c?.code||'')+' '+(c?.name||'');return /ยำ|YUM|YSP/i.test(s)?'yum':/ส้มตำ|ตำ|SOM|SPE|SNL|GHL/i.test(s)?'som':/ทานคู่|TOP|SIDE/i.test(s)?'side':'made';};
    this.categoryIds={};for(const c of cats.data||[])if(!this.categoryIds[category(c.id)])this.categoryIds[category(c.id)]=c.id;
    const menu=(menus.data||[]).map(m=>({id:m.id,name:m.name,description:m.description||'',category:category(m.category_id),categoryId:m.category_id,active:true,published:!m.is_archived,available:m.is_available,price:Number.isInteger(m.price_satang)&&m.price_satang>0?m.price_satang:null,priceMode:'base',recommended:m.is_recommended,photoKey:m.image_path,stockKeys:[],recipeRequired:false,groups:links.filter(l=>l.menu_item_id===m.id).map(l=>l.menu_option_groups).filter(g=>g?.is_active).map(g=>({id:g.id,name:g.name,required:g.min_select>0,min:g.min_select,max:g.max_select,active:true,values:g.menu_option_values.map(v=>({id:v.id,name:v.name,delta:v.price_delta_satang,available:v.is_available,stockKeys:[]}))}))}));
    let orders=[];const session=await this.session(owner);if(session){let query=cli.from('orders').select('*,order_items(*,order_item_options(*)),payments(*,payment_refunds(*))').eq('store_id',this.storeId).order('created_at',{ascending:false}).limit(150);if(!owner)query=query.eq('customer_user_id',session.user.id);else query=query.eq('business_date',dashboard.business_date);const r=await query;if(r.error)throw r.error;orders=(r.data||[]).map(normalizeOrder);}
    const state={version:2,storeSlug:'jele',storeId:this.storeId,settings:{open:!!openState.is_open,closedDate:settings.data.closed_for_date,bannerPhotoKey:settings.data.hero_image_path||null},stock:Object.fromEntries(STOCK.map(([k])=>[k,true])),menu,orders,closings:[],requests:{},sequence:0,live:true};if(owner){const n=k=>Number(dashboard[k]||0);state.liveSummary={day:dashboard.business_date,count:n('orders_total'),received:n('received_total_satang'),refunded:n('refund_completed_satang'),net:n('net_after_completed_refunds_satang'),refundDue:n('refund_pending_satang'),unpaid:n('pending_cash_satang')+n('pending_qr_satang'),pendingCount:n('new_count')+n('preparing_count')+n('ready_count'),newCount:n('new_count'),preparingCount:n('preparing_count'),readyCount:n('ready_count')};const r=await this.owner.from('daily_closings').select('business_date,closed_at,summary,revision').eq('store_id',this.storeId).order('business_date',{ascending:false}).limit(30);if(!r.error)state.closings=(r.data||[]).map(c=>({day:c.business_date,closedAt:c.closed_at,received:c.summary?.received_total_satang||0,net:c.summary?.net_after_completed_refunds_satang||0,count:c.summary?.orders_total||0}));}return state;
  }
  async ensureCustomer(){const session=await this.session(false);if(!session){const r=await this.customer.auth.signInAnonymously();if(r.error)throw r.error;if(!r.data?.session)throw Error('ยังเริ่มรายการสั่งอาหารไม่ได้ กรุณาลองอีกครั้ง');}}
  async create(input){await this.ensureCustomer();await this.rpc('reserve_queue',{p_store_id:this.storeId},false);const result=await this.rpc('create_order',{p_store_id:this.storeId,p_fulfillment_type:input.fulfillment,p_payment_method:'cash',p_customer_note:null,p_client_request_id:input.requestId,p_items:input.lines.map(l=>({menu_item_id:l.dishId,quantity:l.qty,option_value_ids:l.selected||[],customer_note:[l.spice,l.note].filter(Boolean).join(' · ')||null}))},false);const id=(Array.isArray(result)?result[0]:result)?.order_id;if(!id||typeof id!=='string')throw Error('ยังไม่ได้รับเลขรายการจากร้าน กรุณาตรวจรายการก่อนส่งซ้ำ');return id;}
  async execute(action,payload,state){this.assertState(state);await this.checkMember();const id=payload.id;if(['dish','publish','unpublish'].includes(action)&&!state.menu.some(d=>d.id===id))throw Error('ไม่พบเมนูนี้ในร้านเจ๊เล่');if(['advance','pay','cancel','refund'].includes(action)&&!state.orders.some(o=>o.id===id))throw Error('ไม่พบรายการนี้ในร้านเจ๊เล่');switch(action){case'shop-banner':{const key=payload.photoKey===null?null:this.assertPhotoPath(payload.photoKey);return this.rpc('set_store_hero_image',{p_store_id:this.storeId,p_image_path:key});}case'open':return this.rpc('set_store_accepting_orders',{p_store_id:this.storeId,p_is_accepting_orders:true});case'pause':return this.rpc('set_store_accepting_orders',{p_store_id:this.storeId,p_is_accepting_orders:false});case'advance':return this.rpc('advance_order_status',{p_order_id:id});case'pay':{const o=state.orders.find(x=>x.id===id);if(!o||o.status==='cancelled')throw Error('รายการนี้รับเงินไม่ได้');if(payload.method&&o.paymentMethod&&payload.method!==o.paymentMethod)throw Error('ช่องทางรับเงินไม่ตรงกับรายการ กรุณาตรวจอีกครั้ง');if(payload.finish!==false&&o.status!=='ready'&&o.status!=='completed')throw Error('กดทำเสร็จแล้วก่อนจบรายการ');if(!o.paid)await this.rpc('confirm_payment',{p_order_id:id});if(payload.finish!==false&&o.status==='ready')await this.rpc('advance_order_status',{p_order_id:id});return;}case'cancel':return this.rpc('cancel_order',{p_order_id:id,p_cancel_reason:payload.reason});case'refund':{const o=state.orders.find(x=>x.id===id);if(!o?.refund?.id)throw Error('ไม่พบรายการคืนเงิน');return this.rpc('complete_refund',{p_refund_id:o.refund.id,p_provider_reference:null});}case'publish':if(!dishConfigured(state,state.menu.find(d=>d.id===id)))throw Error('ตั้งราคาและตรวจเมนูให้พร้อมก่อนเปิดขาย');return this.rpc('set_menu_archived',{p_menu_item_id:id,p_is_archived:false});case'unpublish':return this.rpc('set_menu_archived',{p_menu_item_id:id,p_is_archived:true});case'close':return this.rpc('close_business_day',{p_store_id:this.storeId});case'dish':{const d=state.menu.find(x=>x.id===id),p=payload.patch;if(!d)throw Error('ไม่พบเมนูนี้ในร้านเจ๊เล่');if(p.photoKey)this.assertPhotoPath(p.photoKey);const price=p.price===undefined?d.price:p.price,categoryId=p.category&&p.category!==d.category?this.categoryIds[p.category]:d.categoryId;if(!categoryId)throw Error('ยังไม่มีหมวดนี้ในระบบกลางของร้านเจ๊เล่');if(!Number.isInteger(price)||price<=0)throw Error('กำหนดราคาก่อนบันทึกเข้าร้านจริง');await this.rpc('update_menu_item',{p_menu_item_id:id,p_name:p.name??d.name,p_description:p.description??d.description,p_price_satang:price,p_category_id:categoryId,p_image_path:p.photoKey===undefined?d.photoKey:p.photoKey,p_is_available:p.available??d.available});if(p.active!==undefined&&p.active!==d.active)await this.rpc('set_menu_archived',{p_menu_item_id:id,p_is_archived:!p.active});if(p.recommended!==undefined)await this.rpc('set_menu_recommended',{p_menu_item_id:id,p_is_recommended:p.recommended});for(const g of p.groups||[])for(const v of g.values)await this.rpc('save_menu_option_value',{p_option_group_id:g.id,p_option_value_id:v.id,p_name:v.name,p_price_satang:v.delta??0,p_is_available:v.available});return;}default:throw Error('งานนี้ยังต้องเพิ่มในระบบกลางก่อนเปิดใช้จริง');}}
  async savePhoto(id,file){
    await this.checkMember();
    if(!file||!['image/jpeg','image/png','image/webp'].includes(file.type))throw Error('เลือกภาพ JPG PNG หรือ WEBP');
    const ext=file.type==='image/png'?'png':file.type==='image/webp'?'webp':'jpg';
    const prefix=id==='__shop-banner__'?'hero-jele':'jele';
    const path=this.assertPhotoPath('stores/'+this.storeId+'/menu/'+prefix+'-'+crypto.randomUUID()+'.'+ext);
    const r=await this.owner.storage.from('menu-images').upload(path,file,{contentType:file.type,upsert:false});
    if(r.error)throw r.error;
    return path;
  }
  async preloadPhotos(keys){
    const audience=this.photoAudience,now=this.now();
    const missing=[...new Set(keys)].filter(key=>{try{this.assertPhotoPath(key);}catch{return false;}const cached=this.photoCache.get(audience+':'+key);return !cached||cached.expiresAt<=now;});
    if(!missing.length)return;
    const cli=audience==='owner'?this.owner:this.customer;
    const result=await cli.storage.from('menu-images').createSignedUrls(missing,3600);
    const rows=new Map((result.data||[]).map(row=>[row.path,row]));
    for(const key of missing){
      const url=!result.error&&rows.get(key)?.signedUrl||null;
      this.photoCache.set(audience+':'+key,{url,expiresAt:now+(url?50*60*1000:15000)});
    }
  }
  async photo(key){
    if(!key)return null;
    try{this.assertPhotoPath(key);}catch{return null;}
    const cacheKey=this.photoAudience+':'+key,cached=this.photoCache.get(cacheKey);
    if(cached&&cached.expiresAt>this.now())return cached.url;
    const cli=this.photoAudience==='owner'?this.owner:this.customer;
    const r=await cli.storage.from('menu-images').createSignedUrl(key,3600);
    if(r.error||!r.data?.signedUrl){this.photoCache.delete(cacheKey);return null;}
    const url=r.data.signedUrl;
    this.photoCache.set(cacheKey,{url,expiresAt:this.now()+50*60*1000});
    return url;
  }
  async logout(){
    const r=await this.owner.auth.signOut({scope:'local'});
    if(r.error)throw r.error;
    this.member=null;this.memberUserId=null;this.photoCache.clear();this.photoAudience='customer';
  }

}
function normalizeOrder(o){const p=o.payments?.[0]||{},r=p.payment_refunds?.[0];const lines=(o.order_items||[]).map(l=>({dishId:l.menu_item_id,name:l.menu_name_snapshot||l.name||'รายการอาหาร',qty:l.quantity,unitPrice:l.unit_price_satang,total:l.line_total_satang??l.unit_price_satang*l.quantity,note:l.customer_note||'',spice:'',optionNames:(l.order_item_options||[]).map(v=>v.option_value_name_snapshot||v.option_name_snapshot||v.name||''),selections:[]}));return {id:o.id,code:o.queue_code,status:o.status,fulfillment:o.fulfillment_type,total:o.total_satang,createdAt:o.created_at,updatedAt:o.updated_at,businessDate:o.business_date||bangkokDate(o.created_at),customerId:o.customer_user_id,lines,paid:p.status==='confirmed',paidAt:p.confirmed_at||(p.status==='confirmed'?p.updated_at:null),paymentMethod:p.method,refund:r?{id:r.id,status:r.status==='completed'?'completed':'required',amount:r.amount_satang,completedAt:r.completed_at}:null,cancelReason:o.cancel_reason};}
