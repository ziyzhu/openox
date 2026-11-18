window.ox.install(({action}) => {
 const clean = v => String(v || '').trim();
 function store() {
  const root=document.getElementById('ac-app-portal') || document.getElementById('root');
  if(!root)return null;
  const key=Object.keys(root).find(k=>k.startsWith('__reactContainer$'));
  const start=key?root[key]:null;
  const queue=start?[start]:[],seen=new Set();
  for(let i=0;i<queue.length && i<12000;i++){
   const f=queue[i];if(!f||seen.has(f))continue;seen.add(f);
   for(const p of [f.memoizedProps,f.pendingProps]){
    const s=p && (p.store || (p.value && p.value.store));
    if(s && typeof s.accountId==='string' && s.account && s.userNameData)return s;
   }
   if(f.child)queue.push(f.child);if(f.sibling)queue.push(f.sibling);
   if(f.stateNode && f.stateNode.current)queue.push(f.stateNode.current);
   if(f.alternate)queue.push(f.alternate);
  }
  return null;
 }
 action('getBalanceSummary',{async invoke(){
  const deadline=Date.now()+15000;
  while(Date.now()<deadline){
   if(!store())throw Error('Apple Card account is not authenticated');
   const lines=document.body.innerText.split('\n').map(clean).filter(Boolean);
   const balances=[];
   for(let i=0;i<lines.length;i++){
    if(!/^(?:card balance|total balance|current balance|available credit|remaining balance|statement balance|minimum payment(?: due)?|[A-Za-z]+ balance)(?:\s*[:$]|$)/i.test(lines[i]))continue;
    const label=lines[i].replace(/\s*-?\$[0-9,.]+.*$/,'').replace(/:$/,'').trim();
    const same=lines[i].match(/-?\$[0-9,]+\.[0-9]{2}/);
    const next=lines[i+1]?.match(/^-?\$[0-9,]+\.[0-9]{2}$/);
    const raw=same?.[0]||next?.[0];
    if(raw)balances.push({label,displayAmount:raw,currency:'USD'});
   }
   if(balances.length)return {balances,checkedAt:new Date().toISOString()};
   await new Promise(r=>setTimeout(r,200));
  }
  throw Error('Authenticated Apple Card page has no verified labeled balance amounts');
 }});
 action('getExpenseExportOptions',{async invoke(){
 if(!store())throw Error('Apple Card account is not authenticated on this page');
 const controls=()=>[...document.querySelectorAll('a,button,ui-button,[role="button"]')];
 const statements=controls().find(e=>clean(e.textContent)==='Statements');
 if(statements)statements.click();
 const ready=()=>[...document.querySelectorAll('h1,h2,h3')].some(e=>clean(e.textContent)==='Statements')&&controls().some(e=>/export transactions|download statement/i.test(e.textContent+' '+(e.getAttribute('aria-label')||'')));
 const end=Date.now()+15000;while(Date.now()<end&&!ready())await new Promise(r=>setTimeout(r,150));
 if(!ready())throw Error('Apple Card Statements page did not finish loading; expense coverage is unverified');
 return {statementsAvailable:!!statements,exportAvailable:controls().some(e=>/export transactions/i.test(e.textContent)),controls:controls().filter(e=>/statement|export|download|activity|transaction/i.test(e.textContent)).map(e=>({tag:e.tagName,label:clean(e.textContent).slice(0,150),id:e.id||''})).slice(0,30),notices:[...document.querySelectorAll('h1,h2,h3,[role="alert"]')].map(e=>clean(e.textContent)).filter(Boolean).slice(0,20)};
 }});
 const signIn=()=>Array.from(document.querySelectorAll('ui-button,button,[role=button]')).find(e=>clean(e.textContent)==='Sign In' && getComputedStyle(e).display!=='none');
 action('listSessions',{async invoke(){
  const deadline=Date.now()+18000;
  while(Date.now()<deadline){
   const s=store();
   if(s){const n=s.userNameData;const label=clean(n.fullName)||[clean(n.firstName),clean(n.lastName)].filter(Boolean).join(' ');if(!label)throw Error('Authenticated Apple Card account has no verified display identity');return [{id:s.accountId,label:'Apple Card — '+label,url:'https://card.apple.com/'}];}
   if(signIn() && document.body.textContent.includes('Pay your bill online.'))return [];
   await new Promise(r=>setTimeout(r,200));
  }
  throw Error('Apple Card session discovery incomplete: neither authenticated account nor signed-out landing page was established');
 }});

 action('getTransactionExport',{async invoke({startDate,endDate}){
  if(!store())throw Error('Apple Card account is not authenticated');
  const click=e=>{const target=e.querySelector('button')||e;target.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));target.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));target.click();};
  const text=e=>clean(e.textContent);
  let dialog=document.querySelector('dialog');
  if(!dialog||!dialog.textContent.includes('Export Transactions')){
   const nav=[...document.querySelectorAll('a')].find(e=>text(e)==='Statements');if(nav)nav.click();
   const end=Date.now()+15000;let exportButton;while(Date.now()<end){exportButton=[...document.querySelectorAll('ui-button')].find(e=>text(e)==='Export Transactions');if(exportButton)break;await new Promise(r=>setTimeout(r,150));}
   if(!exportButton)throw Error('Apple Card transaction export button unavailable');click(exportButton);
   const endDialog=Date.now()+8000;while(Date.now()<endDialog){dialog=document.querySelector('dialog');if(dialog?.textContent.includes('Export Transactions'))break;await new Promise(r=>setTimeout(r,100));}
  }
  if(!dialog)throw Error('Apple Card export dialog unavailable');
  const dateButtons=[...dialog.querySelectorAll('ui-button')].filter(e=>Number.isFinite(Date.parse(text(e))));
  const iso=value=>{const d=new Date(value);return [d.getFullYear(),String(d.getMonth()+1).padStart(2,'0'),String(d.getDate()).padStart(2,'0')].join('-');};
  const dates=dateButtons.map(e=>iso(text(e)));if(dates.length!==2||dates[0]!==startDate||dates[1]!==endDate)throw Error('Apple Card export date selection does not match the requested range; select the dates on the live export dialog');
  if(!dialog.textContent.includes('Comma Separated Values (CSV)'))throw Error('Apple Card export format is not CSV');
  const submit=[...dialog.querySelectorAll('ui-button')].find(e=>text(e)==='Export');if(!submit)throw Error('Apple Card Export control unavailable');
  const original=URL.createObjectURL;let captured=null;
  URL.createObjectURL=function(blob){if(blob instanceof Blob)captured=blob;return original.call(this,blob);};
  try{click(submit);const end=Date.now()+25000;while(Date.now()<end&&!captured)await new Promise(r=>setTimeout(r,100));if(!captured)throw Error('Apple Card export was initiated, but its CSV data was not captured; inspect the live download before repeating');const csv=await captured.text();if(!csv||csv.length>2000000)throw Error('Apple Card CSV export is empty or exceeds safe text limit');return {startDate,endDate,format:'CSV',csv,observedAt:new Date().toISOString()};}finally{URL.createObjectURL=original;}
 }});
 action('signOut',{async invoke(){const s=store();if(!s||typeof s.signOut!=='function')throw Error('Authenticated Apple Card sign-out handler unavailable');await s.signOut();return {requested:true};}});
 action('login',{async invoke(){
  if(store())throw Error('Apple Card is already signed in; existing authentication was preserved');
  const deadline=Date.now()+18000;let opened=false;
  while(Date.now()<deadline){
   const frame=document.querySelector('iframe[name="aid-auth-widget"]');
   const close=document.querySelector('.ac-modal-close-button');
   if(frame && frame.src.startsWith('https://idmsa.apple.com/appleauth/auth/authorize/signin') && close && getComputedStyle(frame).visibility==='visible' && getComputedStyle(frame).display!=='none')return null;
   const b=signIn();if(b&&!opened){b.click();opened=true;}
   await new Promise(r=>setTimeout(r,200));
  }
  throw Error('Apple Card sign-in preparation failed: Apple Account sign-in frame did not become available');
 }});
});
