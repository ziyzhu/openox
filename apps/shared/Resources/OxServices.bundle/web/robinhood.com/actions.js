window.ox.install(({ action }) => {
const clean = s => String(s ?? '').replace(/\s+/g,' ').trim();
const usable = e => !!e && !e.disabled && !e.hidden && getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility !== 'hidden';
const signedOut = () => usable(document.querySelector('input[name="username"]')) && usable(document.querySelector('input[name="password"]'));
function accountKey(){
 for(const a of document.querySelectorAll('a[href]')){
  const u=new URL(a.href,location.href); if(u.origin!==location.origin || u.pathname!=='/account/investing') continue;
  const nested=u.searchParams.get('applink'); if(!nested) continue;
  const q=nested.indexOf('?'); if(q<0) continue;
  const params=new URLSearchParams(nested.slice(q+1)); const key=params.get('accountNumber')||params.get('account_number'); if(key) return key;
 } return null;
}
function rows(){return [...document.querySelectorAll('tr')].map(r=>[...r.querySelectorAll('td')].map(c=>clean(c.textContent))).filter(c=>c.length===2);}
async function ready(){const end=Date.now()+20000;do{if(signedOut())return false;if(location.pathname==='/account/investing' && clean(document.querySelector('h1')?.textContent) && accountKey() && rows().some(r=>r[0]==='Withdrawable Cash'))return true;await new Promise(r=>setTimeout(r,200));}while(Date.now()<end);throw new Error('Robinhood account identity and balance rows did not finish loading; no balances inferred.');}
function amount(s){const text=clean(s);if(!/^[-+]?\$[\d,]+\.\d{2}$/.test(text))throw new Error('Unrecognized Robinhood currency amount');return Number(text.replace(/[$,]/g,''));}
action('listSessions',{async invoke(){if(!await ready())return [];const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode('robinhood-brokerage:'+accountKey()));const id=Array.from(new Uint8Array(bytes)).map(x=>x.toString(16).padStart(2,'0')).join('');return [{id:'brokerage:'+id,label:clean(document.querySelector('h1').textContent)+' — brokerage',url:'https://robinhood.com/account/investing'}];}});
action('login',{async invoke(){const end=Date.now()+15000;do{if(signedOut()&&usable(document.querySelector('button[type="submit"]')))return null;await new Promise(r=>setTimeout(r,200));}while(Date.now()<end);throw new Error('Robinhood sign-in controls are not ready; cannot present login.');}});
action('getBalances',{async invoke(){if(!await ready())throw new Error('Robinhood sign-in required');const values=rows();const read=label=>{const found=values.filter(r=>r[0]===label);if(found.length!==1)throw new Error('Missing or ambiguous balance row: '+label);return amount(found[0][1]);};let total;const end=Date.now()+15000;do{const headers=[...document.querySelectorAll('header')].filter(h=>[...h.querySelectorAll('p')].some(p=>clean(p.textContent)==='Total portfolio value'));if(headers.length>1)throw new Error('Portfolio value header is ambiguous');total=headers[0]?.querySelector('[aria-atomic="true"][aria-label]')?.getAttribute('aria-label');if(total)break;await new Promise(r=>setTimeout(r,200));}while(Date.now()<end);if(!total)throw new Error('Portfolio value did not finish loading');return {accountType:'brokerage',accountLabel:clean(document.querySelector('h1').textContent),currency:'USD',portfolioValue:amount(total),individualCash:read('Individual Cash'),withdrawableCash:read('Withdrawable Cash'),pendingDeposits:read('Total pending deposits'),instantDeposits:read('Instant Deposits'),instantDepositsUsed:read('Instant Deposits used'),observedAt:new Date().toISOString(),sourceUrl:'https://robinhood.com/account/investing',scope:'Currently displayed brokerage account only; excludes separate Robinhood Banking checking and savings accounts.'};}});
action('checkCreditCardAccess',{async invoke(){
 if(!await ready())throw new Error('Robinhood sign-in required');
 let auth;try{auth=JSON.parse(localStorage.getItem('web:auth_state')||'null');}catch{throw new Error('Robinhood web authentication state is unreadable');}
 if(!auth?.access_token||!auth.user_uuid)throw new Error('Active Robinhood web authentication is unavailable');
 const call=async(query,operationName,variables)=>{const response=await fetch('https://api.robinhood.com/creditcard/graphql',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json','Authorization':'Bearer '+auth.access_token},body:JSON.stringify({query,operationName,variables})});if(!response.ok)throw new Error('Robinhood credit-card API HTTP '+response.status);let json;try{json=await response.json();}catch{throw new Error('Robinhood credit-card API returned non-JSON data');}return json;};
 const identityResult=await call('query CriticalDataLoaderQuery { authIdentity { rhUserId creditCustomers { id } } }','CriticalDataLoaderQuery',{});
 const identity=identityResult.data?.authIdentity;if(!identity||identityResult.errors?.length)throw new Error('Credit-card identity query was rejected');
 if(identity.rhUserId!==auth.user_uuid)throw new Error('Credit-card identity does not match the signed-in web account');
 const customers=identity.creditCustomers;if(!Array.isArray(customers))throw new Error('Missing credit customer collection');
 if(customers.length!==1)throw new Error('Expected exactly one credit customer; found '+customers.length);
 const creditCustomerId=customers[0].id;
 const balance=await call('query BalanceQuery($creditCustomerId: String!) { creditAccount(q: {creditCustomerId: $creditCustomerId}) { balances { currentMicro } } }','BalanceQuery',{creditCustomerId});
 const transactions=await call('query TransactionListQuery($q: TransactionSearchRequest!) { transactionSearch(q: $q) { items { id amountMicro transactionAt merchantDetails { merchantName } } cursor } }','TransactionListQuery',{q:{creditCustomerId,filters:{values:[]},sortDetails:{field:'TIME',ascending:false},limit:1}});
 return {identityAccepted:true,identityMatchesWebAccount:true,creditCustomerCount:customers.length,balanceReadable:!balance.errors?.length&&balance.data?.creditAccount?.balances?.currentMicro!=null,transactionsReadable:!transactions.errors?.length&&Array.isArray(transactions.data?.transactionSearch?.items),scope:'Tests the existing website token with the observed credit-card queries only. Query failure does not prove its cause or that separate authentication is required.',observedAt:new Date().toISOString()};
}});

action('getCreditCardAccessDetails',{async invoke(){
 if(!await ready())throw new Error('Robinhood sign-in required');
 let auth;try{auth=JSON.parse(localStorage.getItem('web:auth_state')||'null');}catch{throw new Error('Robinhood web session state is unreadable');}
 if(!auth?.access_token||!auth.user_uuid)throw new Error('No active Robinhood web session');
 const query='query CriticalDataLoaderQuery { authIdentity { rhUserId roles creditCustomers { id capabilities { feature scope mode } } settings { authConditions } } }';
 const r=await fetch('https://api.robinhood.com/creditcard/graphql',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json',Authorization:'Bearer '+auth.access_token},body:JSON.stringify({query,operationName:'CriticalDataLoaderQuery',variables:{}})});
 if(!r.ok)throw new Error('Robinhood credit API HTTP '+r.status);
 const j=await r.json();if(j.errors?.length)throw new Error('Robinhood rejected the credit access metadata query');
 const identity=j.data?.authIdentity;if(!identity||identity.rhUserId!==auth.user_uuid)throw new Error('Credit identity differs from signed-in website account');
 if(!Array.isArray(identity.creditCustomers)||identity.creditCustomers.length!==1)throw new Error('Cannot select a single credit customer');
 const roles=identity.roles,capabilities=identity.creditCustomers[0].capabilities,authConditions=identity.settings?.authConditions;
 if(!Array.isArray(roles)||!roles.every(x=>typeof x==='string')||!Array.isArray(authConditions)||!authConditions.every(x=>typeof x==='string'))throw new Error('Unsupported access metadata schema; no raw authentication conditions exposed');
 if(!Array.isArray(capabilities)||!capabilities.every(c=>['feature','scope','mode'].every(k=>typeof c[k]==='string')))throw new Error('Unsupported credit capability schema');
 return {roles,capabilities:capabilities.map(({feature,scope,mode})=>({feature,scope,mode})),authConditions,observedAt:new Date().toISOString()};
}});

});
