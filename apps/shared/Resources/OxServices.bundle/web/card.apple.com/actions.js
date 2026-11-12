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
 const end=Date.now()+8000;while(Date.now()<end&&!/Statements|Export Transactions/i.test(document.body.innerText))await new Promise(r=>setTimeout(r,150));
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
