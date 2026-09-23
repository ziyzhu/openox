const text = v => v == null ? null : String(v);
async function request(path) {
 const r = await fetch('https://api.suitz.co' + path, {credentials:'omit',cache:'no-store'});
 if(r.status === 404) throw new Error('SETTLEMENT_NOT_FOUND');
 if(!r.ok) throw new Error('Suitz HTTP ' + r.status);
 if(!(r.headers.get('content-type') || '').includes('application/json')) throw new Error('Unexpected Suitz response type');
 return await r.json();
}
function summary(x) {
 if(!x || typeof x.id !== 'string' || typeof x.company !== 'string') throw new Error('Unexpected settlement record');
 return {id:x.id,company:x.company,url:'https://www.suitz.co/settlement/'+encodeURIComponent(x.slug || x.id),deadline:text(x.deadline),payout:typeof x.payout==='number'?x.payout:null,proof:text(x.proof),claimIdRequired:typeof x.claimid_required==='boolean'?x.claimid_required:null,states:Array.isArray(x.settlement_states)?x.settlement_states.map(String):[],settlementType:text(x.settlement_type),industry:text(x.industry)};
}
async function page(limit,cursor) {
 const p=new URLSearchParams({pageSize:String(limit)}); if(cursor) p.set('cursor',cursor);
 const j=await request('/api/available-settlements?'+p);
 if(!Array.isArray(j.items) || !(j.nextCursor===null || typeof j.nextCursor==='string')) throw new Error('Unexpected catalog response');
 if(cursor && j.nextCursor===cursor) throw new Error('Catalog cursor did not advance');
 return j;
}
window.ox.install(2,({action})=>{
 action('listSettlements',{async invoke(args){const j=await page(args.limit??25,args.cursor);return {items:j.items.map(summary),nextCursor:j.nextCursor};}});
 action('searchSettlements',{async invoke(args){
 const query=args.query.trim().toLowerCase(); if(!query) throw new Error('Search query must not be blank');
 const limit=args.limit??25;let cursor=args.cursor;const items=[];const seen=new Set();
 for(let n=0;n<300;n++){
 const j=await page(limit-items.length,cursor);
 for(const x of j.items){const hay=[x.company,x.description,x.eligibility,x.settlement_type,x.industry,...(x.settlement_states||[])].join(' ').toLowerCase();if(hay.includes(query))items.push(summary(x));}
 if(j.nextCursor===null || items.length>=limit)return {items,nextCursor:j.nextCursor};
 if(seen.has(j.nextCursor))throw new Error('Catalog pagination loop');seen.add(j.nextCursor);cursor=j.nextCursor;
 }
 throw new Error('Catalog search exceeded safety bound');
 }});
 action('getSettlement',{async invoke(args){
 const x=await request('/api/settlements/'+encodeURIComponent(args.id));if(x.id!==args.id && x.slug!==args.id)throw new Error('Settlement identity mismatch');
 return {...summary(x),description:text(x.description),eligibility:text(x.eligibility),officialUrl:text(x.website),claimFormUrl:typeof x.pdf_link==='string' && /^https?:\/\//.test(x.pdf_link)?x.pdf_link:null,expired:typeof x.expired==='boolean'?x.expired:null,updatedAt:text(x.updated_at)};
 }});
});
