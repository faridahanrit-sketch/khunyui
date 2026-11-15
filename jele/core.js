export const STATUS={new:'ใหม่',preparing:'กำลังทำ',ready:'พร้อมรับ',completed:'เสร็จสิ้น',cancelled:'ยกเลิก'};
export const CATEGORIES=[['all','ทั้งหมด'],['made','อาหารตามสั่ง'],['yum','ยำ'],['som','ส้มตำ'],['side','ของทานคู่']];
export const STOCK=[['pork','หมู'],['shrimp','กุ้ง'],['squid','หมึก'],['fish','ปลา'],['glass','วุ้นเส้น'],['small','เส้นเล็ก'],['sticky','ข้าวเหนียว'],['khanom','ขนมจีน']];
export const uuid=()=>globalThis.crypto.randomUUID();
export const clone=value=>structuredClone(value);
export function bangkokDate(value=new Date()){const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Bangkok',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(value));return ['year','month','day'].map(k=>parts.find(p=>p.type===k).value).join('-');}
export function parseBaht(raw,{allowZero=false}={}){if(raw===null||raw===undefined||String(raw).trim()==='')return null;const s=String(raw).trim();if(!/^\d{1,6}(?:\.\d{1,2})?$/.test(s))throw Error('ใส่ราคาเป็นตัวเลข ไม่เกิน 2 ตำแหน่งทศนิยม');const [whole,part='']=s.split('.');const n=Number(whole)*100+Number(part.padEnd(2,'0'));if(!Number.isSafeInteger(n)||n<0||(!allowZero&&n===0))throw Error('ราคาจานต้องมากกว่า 0 บาท');return n;}
export function defaultState(catalog){return {version:2,revision:0,storeSlug:'jele',settings:{open:false,closedDate:null},stock:Object.fromEntries(STOCK.map(([k])=>[k,true])),menu:clone(catalog).map(d=>({...d,published:false})),orders:[],requests:{},closings:[],sequence:0,createdAt:new Date().toISOString()};}
export const groupsFor=dish=>(dish.groups||[]).filter(g=>g.active!==false);
export const isStockReady=(state,keys=[])=>keys.every(key=>state.stock[key]!==false);
export function choiceAvailable(state,value){return value.available!==false&&isStockReady(state,value.stockKeys);}
export function baseAvailable(state,dish){return dish.active!==false&&dish.available!==false&&isStockReady(state,dish.stockKeys)&&(!dish.recipeRequired||(!!dish.recipe?.trim()&&dish.stockKeys?.length>0));}
export function dishConfigured(state,dish){if(!baseAvailable(state,dish))return false;if(dish.priceMode==='choice'){const first=groupsFor(dish)[0];return !!first?.values.some(v=>choiceAvailable(state,v)&&Number.isInteger(v.price)&&v.price>0);}return Number.isInteger(dish.price)&&dish.price>0&&groupsFor(dish).every(g=>!g.required||g.values.some(v=>choiceAvailable(state,v)&&Number.isInteger(v.delta??0)));}
export function displayPrices(state,dish){if(!dishConfigured(state,dish))return [];return dish.priceMode==='choice'?groupsFor(dish)[0].values.filter(v=>choiceAvailable(state,v)&&Number.isInteger(v.price)&&v.price>0).map(v=>v.price):[dish.price];}
export function lineFor(state,dishId,{selected=[],qty=1,note='',spice='เผ็ดน้อย'}={}){const dish=state.menu.find(d=>d.id===dishId);if(!dish||!menuReady(state,dish))throw Error('เมนูนี้ยังไม่พร้อมขาย กรุณาตรวจราคาและของที่มี');if(!Number.isInteger(qty)||qty<1||qty>99)throw Error('จำนวนต้องอยู่ระหว่าง 1 ถึง 99');if(!Array.isArray(selected)||new Set(selected).size!==selected.length)throw Error('ตัวเลือกไม่ถูกต้อง');const groups=groupsFor(dish);const all=groups.flatMap(g=>g.values);if(selected.some(id=>!all.some(v=>v.id===id)))throw Error('พบตัวเลือกที่ไม่ได้อยู่ในเมนูนี้');let price=dish.priceMode==='choice'?null:dish.price;const names=[];const selections=[];
  for(let i=0;i<groups.length;i++){const g=groups[i];const picked=g.values.filter(v=>selected.includes(v.id));const min=g.min??(g.required?1:0),max=g.max??1;if(picked.length<min||picked.length>max)throw Error('กรุณา'+g.name+(max===1?' 1 อย่าง':''));for(const v of picked){if(!choiceAvailable(state,v))throw Error(v.name+'หมดชั่วคราว');if(dish.priceMode==='choice'&&i===0){if(!Number.isInteger(v.price)||v.price<=0)throw Error(v.name+'ยังไม่ได้ตั้งราคา');price=v.price;}else price+=(v.delta??0);names.push(v.name);selections.push({id:v.id,name:v.name,group:g.name});}}
  if(!Number.isInteger(price)||price<=0)throw Error('เมนูนี้ยังไม่ได้ตั้งราคา');return {dishId:dish.id,name:dish.name,unitPrice:price,qty,total:price*qty,selected:[...selected],selections,optionNames:names,note:String(note).trim().slice(0,200),spice:dish.category==='side'?'':String(spice).slice(0,40),photoKey:dish.photoKey||null};}
export function createOrder(state,input,now=new Date().toISOString()){const s=clone(state);const requestId=String(input.requestId||'');if(!/^[A-Za-z0-9_-]{8,100}$/.test(requestId))throw Error('กรุณาส่งรายการใหม่อีกครั้ง');if(s.requests[requestId]){const order=s.orders.find(o=>o.id===s.requests[requestId]);if(order)return {state:s,order,duplicate:true};throw Error('ไม่พบรายการเดิม กรุณาตรวจประวัติ');}if(!s.settings.open)throw Error('แม่ยังไม่เปิดรับรายการค่ะ');if(!Array.isArray(input.lines)||!input.lines.length||input.lines.length>50)throw Error('เลือกอาหารก่อนส่งรายการค่ะ');if(!['dine_in','takeaway'].includes(input.fulfillment))throw Error('เลือกทานที่ร้านหรือกลับบ้าน');const lines=input.lines.map(l=>lineFor(s,l.dishId,l));s.sequence+=1;const order={id:uuid(),code:'ฝึก '+String(s.sequence).padStart(3,'0'),status:'new',fulfillment:input.fulfillment,customerId:String(input.customerId||'practice').slice(0,100),lines,total:lines.reduce((t,l)=>t+l.total,0),paid:false,paymentMethod:null,paidAt:null,refund:null,createdAt:now,updatedAt:now,businessDate:bangkokDate(now),requestId};s.orders.push(order);s.requests[requestId]=order.id;return {state:s,order,duplicate:false};}
function orderIn(s,id){const order=s.orders.find(o=>o.id===id);if(!order)throw Error('ไม่พบรายการนี้');return order;}
export function advanceOrder(state,id,now=new Date().toISOString()){const s=clone(state),o=orderIn(s,id);if(o.status==='new')o.status='preparing';else if(o.status==='preparing')o.status='ready';else if(o.status==='ready'&&o.paid)o.status='completed';else if(o.status==='completed')return s;else throw Error(o.status==='ready'?'รับเงินก่อนจบรายการค่ะ':'รายการนี้เลื่อนต่อไม่ได้');o.updatedAt=now;return s;}
export function payOrder(state,id,{finish=true,method='cash'}={},now=new Date().toISOString()){const s=clone(state),o=orderIn(s,id);if(o.status==='cancelled')throw Error('รายการนี้ยกเลิกแล้ว');if(!['cash','promptpay_qr'].includes(method))throw Error('เลือกวิธีรับเงิน');if(finish&&!['ready','completed'].includes(o.status))throw Error('กดทำเสร็จแล้วก่อนจบรายการ');if(!o.paid){o.paid=true;o.paidAt=now;o.paymentMethod=method;}if(finish)o.status='completed';o.updatedAt=now;return s;}
export function cancelOrder(state,id,reason,now=new Date().toISOString()){const s=clone(state),o=orderIn(s,id);if(o.status==='cancelled')return s;if(o.status==='completed')throw Error('รายการเสร็จแล้ว กรุณาตรวจจากประวัติ');const text=String(reason||'').trim().slice(0,200);if(!text)throw Error('ใส่เหตุผลที่ยกเลิกค่ะ');o.status='cancelled';o.cancelReason=text;o.updatedAt=now;if(o.paid)o.refund={status:'required',amount:o.total,createdAt:now,completedAt:null};return s;}
export function refundOrder(state,id,now=new Date().toISOString()){const s=clone(state),o=orderIn(s,id);if(o.refund?.status==='completed')return s;if(!o.refund||o.refund.status!=='required')throw Error('รายการนี้ไม่มีเงินที่ต้องคืน');o.refund.status='completed';o.refund.completedAt=now;o.updatedAt=now;return s;}
export function totals(state,day=bangkokDate()){const today=state.orders.filter(o=>o.businessDate===day),received=state.orders.filter(o=>o.paidAt&&bangkokDate(o.paidAt)===day).reduce((a,o)=>a+o.total,0),refunded=state.orders.filter(o=>o.refund?.completedAt&&bangkokDate(o.refund.completedAt)===day).reduce((a,o)=>a+o.refund.amount,0),refundDue=state.orders.filter(o=>o.refund?.status==='required').reduce((a,o)=>a+o.refund.amount,0),pending=state.orders.filter(o=>!['completed','cancelled'].includes(o.status)),unpaid=pending.filter(o=>!o.paid).reduce((a,o)=>a+o.total,0);return {day,count:today.filter(o=>o.status!=='cancelled').length,received,refunded,net:received-refunded,refundDue,pendingCount:pending.length,unpaid,newCount:pending.filter(o=>o.status==='new').length,preparingCount:pending.filter(o=>o.status==='preparing').length,readyCount:pending.filter(o=>o.status==='ready').length};}
export function closeDay(state,now=new Date().toISOString()){const s=clone(state),summary=totals(s,bangkokDate(now));if(summary.pendingCount)throw Error('ยังมีรายการค้าง '+summary.pendingCount+' รายการ ปิดรับรายการใหม่ก่อนได้');if(summary.refundDue)throw Error('ยังมีเงินที่ต้องคืน กรุณาตรวจให้ครบก่อนจบวัน');s.settings.open=false;s.settings.closedDate=summary.day;const record={...summary,closedAt:now};const old=s.closings.findIndex(c=>c.day===summary.day);if(old<0)s.closings.push(record);else s.closings[old]=record;return s;}
export function changeStock(state,key,available){if(!STOCK.some(([id])=>id===key))throw Error('ไม่พบวัตถุดิบนี้');const s=clone(state);s.stock[key]=!!available;return s;}
export function stockImpact(state,key){const names=[];for(const d of state.menu.filter(m=>m.active)){if((d.stockKeys||[]).includes(key))names.push(d.name);for(const g of groupsFor(d))for(const v of g.values)if((v.stockKeys||[]).includes(key))names.push(d.name+' · '+v.name);}return [...new Set(names)];}
export function openShop(state){if(!state.menu.some(d=>menuReady(state,d)))throw Error('ตั้งราคาและกดเปิดขายอย่างน้อย 1 เมนูก่อนเปิดร้านค่ะ');const s=clone(state);s.settings.open=true;s.settings.closedDate=null;return s;}
export const visibleMenu=state=>state.menu.filter(d=>d.active!==false&&d.published===true);
export const menuReady=(state,dish)=>dish.published===true&&dishConfigured(state,dish);

export function upgradeState(state){
  if(state.version>=2&&state.menu.every(d=>typeof d.published==='boolean'))return state;
  const s=clone(state);
  for(const d of s.menu)if(typeof d.published!=='boolean')d.published=false;
  s.settings.open=false;
  s.version=2;
  return s;
}

function validateDish(state,dish){
  dish.name=String(dish.name||'').trim();
  if(!dish.name||dish.name.length>80)throw Error('ใส่ชื่ออาหารไม่เกิน 80 ตัวอักษร');
  if(!CATEGORIES.some(([id])=>id!=='all'&&id===dish.category))throw Error('เลือกหมวดยำ ส้มตำ อาหารตามสั่ง หรือของทานคู่');
  const normalized=s=>s.trim().replace(/\s+/g,' ').toLocaleLowerCase('th');
  if(state.menu.some(d=>d.id!==dish.id&&d.active!==false&&d.category===dish.category&&normalized(d.name)===normalized(dish.name)))throw Error('ชื่อเมนูนี้มีอยู่แล้วในหมวดนี้ค่ะ');
  for(const key of dish.stockKeys||[])if(!STOCK.some(([id])=>id===key))throw Error('วัตถุดิบไม่ถูกต้อง');
  if(dish.price!==null&&(!Number.isSafeInteger(dish.price)||dish.price<=0))throw Error('ตรวจราคาจานอีกครั้ง');
  for(const g of dish.groups||[])for(const v of g.values)if(v.price!==null&&v.price!==undefined&&(!Number.isSafeInteger(v.price)||v.price<=0))throw Error('ตรวจราคาตัวเลือกอีกครั้ง');
}

export function updateDish(state,id,patch){
  const s=clone(state),d=s.menu.find(d=>d.id===id);
  if(!d)throw Error('ไม่พบเมนูนี้');
  const allowed=['name','category','description','recipe','stockKeys','price','groups','available','active','recommended','special','photoKey'];
  for(const key of allowed)if(Object.hasOwn(patch,key))d[key]=clone(patch[key]);
  validateDish(s,d);
  // Editing a name, price, category or photo never publishes a draft.
  if(d.active===false)d.published=false;
  d.updatedAt=new Date().toISOString();
  return s;
}

export function addDish(state,input,now=new Date().toISOString()){
  const s=clone(state),id=input.id||'custom-'+uuid();
  if(!/^custom-[0-9a-f-]{36}$/i.test(id))throw Error('รหัสเมนูใหม่ไม่ถูกต้อง');
  if(s.menu.some(d=>d.id===id))return s; // One form owns one creation ID, including retries.
  const dish={id,name:input.name,category:input.category,description:input.description||'',recipe:input.recipe||'',stockKeys:clone(input.stockKeys||[]),price:input.price??null,priceMode:'base',groups:[],active:true,published:false,available:input.available!==false,recommended:!!input.recommended,special:!!input.special,recipeRequired:false,photoKey:input.photoKey||null,custom:true,createdAt:now};
  validateDish(s,dish);
  s.menu.push(dish);
  return s;
}

export function publishDish(state,id){
  const s=clone(state),d=s.menu.find(d=>d.id===id);
  if(!d)throw Error('ไม่พบเมนูนี้');
  if(!dishConfigured(s,d))throw Error('ตั้งราคาและตรวจของในจานให้พร้อมก่อนเปิดขายค่ะ');
  d.published=true;
  return s;
}

export function unpublishDish(state,id){
  const s=clone(state),d=s.menu.find(d=>d.id===id);
  if(!d)throw Error('ไม่พบเมนูนี้');
  d.published=false;
  return s;
}
