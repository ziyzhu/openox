window.ox.install(({action})=>{
 action('listSessions',{async invoke(){
 const r=await fetch('https://www.coinbase.com/api/v2/user',{credentials:'include'});
 if(r.status===401)return [];
 if(!r.ok)throw new Error('Coinbase account discovery HTTP '+r.status);
 const j=await r.json();const u=j.data;
 if(!u||typeof u.id!=='string'||!u.id||typeof u.email!=='string'||!u.email)throw new Error('Coinbase account identity response is unrecognized');
 return [{id:u.id,label:u.email,url:'https://www.coinbase.com/'}];
 }});
 action('login',{async invoke(){
 const end=Date.now()+20000;
 while(Date.now()<end){
 const input=document.querySelector('input[type="email"]');
 if(input&&!input.disabled&&getComputedStyle(input).display!=='none'&&document.body.innerText.includes('Sign in to Coinbase'))return null;
 await new Promise(r=>setTimeout(r,200));
 }
 throw new Error('Coinbase sign-in controls did not become usable');
 }});
 action('getProfile',{async invoke(){const r=await fetch('https://www.coinbase.com/api/v2/user',{credentials:'include'});if(!r.ok)throw new Error('Coinbase profile HTTP '+r.status);const {data:u}=await r.json();if(!u?.id||typeof u.email!=='string')throw new Error('Unrecognized Coinbase profile');return {id:u.id,name:u.name||'',email:u.email,timeZone:u.time_zone||'',nativeCurrency:u.native_currency||''};}});
 action('listAccounts',{async invoke(args){const q=new URLSearchParams({limit:String(args.limit??25)});if(args.cursor)q.set('starting_after',args.cursor);const r=await fetch('https://www.coinbase.com/api/v2/accounts?'+q,{credentials:'include'});if(!r.ok)throw new Error('Coinbase asset accounts HTTP '+r.status);const j=await r.json();if(!Array.isArray(j.data)||!j.pagination)throw new Error('Unrecognized Coinbase asset accounts response');const items=j.data.map(a=>{if(typeof a.id!=='string'||typeof a.balance?.amount!=='string'||typeof a.currency?.code!=='string')throw new Error('Unrecognized Coinbase asset balance');return {id:a.id,name:a.name||'',type:a.type||'',currency:a.currency.code,currencyName:a.currency.name||'',balance:a.balance.amount,primary:!!a.primary};});let nextCursor=null;if(j.pagination.next_uri){const u=new URL(j.pagination.next_uri,'https://www.coinbase.com');nextCursor=u.searchParams.get('starting_after');if(!nextCursor)throw new Error('Unrecognized Coinbase pagination');}return {items,nextCursor};}});

});