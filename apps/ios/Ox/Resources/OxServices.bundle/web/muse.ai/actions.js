// WebKit suspends animation frames on hidden service pages. Muse waits on
// these frames before mounting its chat. Race only hidden-page frames with
// a timer, preserving cancellation and exactly-once callback delivery.
(() => {
 if(typeof window.requestAnimationFrame!=='function'||typeof window.cancelAnimationFrame!=='function')return;
 const request=window.requestAnimationFrame.bind(window);
 const cancel=window.cancelAnimationFrame.bind(window);
 const pending=new Map();let sequence=-1;
 window.requestAnimationFrame=callback=>{
  if(!document.hidden)return request(callback);
  const id=sequence--;let native,timer;
  const run=time=>{if(!pending.has(id))return;pending.delete(id);cancel(native);clearTimeout(timer);callback(time);};
  native=request(run);timer=setTimeout(()=>run(performance.now()),100);
  pending.set(id,{native,timer});return id;
 };
 window.cancelAnimationFrame=id=>{const entry=pending.get(id);if(entry){cancel(entry.native);clearTimeout(entry.timer);pending.delete(id);}else cancel(id);};
})();
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const visible = e => !!e && !e.hidden && getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility !== 'hidden';
async function ready(timeout=7000) {
  const end = Date.now()+timeout;
  while(Date.now()<end){const e=document.querySelector('textarea[aria-label="Message"]');if(visible(e)&&!e.disabled&&document.querySelector('[data-message-item]'))return e;await sleep(150);}
  throw new Error('Muse editor unavailable; no message sent. '+JSON.stringify({path:location.pathname,ready:document.readyState,messageMarkers:document.querySelectorAll('[data-message-item]').length,testids:[...document.querySelectorAll('[data-testid]')].map(e=>e.getAttribute('data-testid')).slice(0,25),editors:[...document.querySelectorAll('textarea,[contenteditable=true]')].map(e=>({tag:e.tagName,label:e.getAttribute('aria-label'),visible:visible(e),disabled:!!e.disabled})),buttons:[...document.querySelectorAll('button')].map(e=>e.getAttribute('aria-label')).filter(Boolean).slice(0,12)}));
}
function readConversation(limit=30){
 const items=[...document.querySelectorAll('[data-message-item]')].slice(-limit);
 return {url:location.origin+location.pathname,messages:items.map(e=>({role:e.getAttribute('data-message-role')||'unknown',text:(e.querySelector('[data-hatch-assistant-message-body]')||e).innerText.trim()})),scope:'rendered',pending:visible(document.querySelector('button[aria-label="Stop"]'))};
}
async function signInState(){
 const r=await fetch('/api/auth/check',{method:'POST',credentials:'include',cache:'no-store'});
 if(r.redirected)throw new Error('Unexpected Muse authentication redirect');
 const j=await r.json();
 if(r.status===200&&j.ok===true&&j.outcome==='validated'&&typeof j.viewer_id==='string')return {signedIn:true};
 if(r.status===401&&j.type==='hatchAdmissionInvalidated'&&j.reason==='session')return {signedIn:false};
 throw new Error('Unclassified Muse authentication response: '+r.status);
}
async function sendMessage({message}){
 if(!message.trim())throw new Error('Message cannot be blank');
 const e=await ready();
 if(e.value.trim())throw new Error('Muse contains an existing draft; refusing to overwrite it.');
 if(readConversation().pending)throw new Error('Muse is still responding; no message sent.');
 const before=new Set([...document.querySelectorAll('[data-message-item]')].map(n=>n.getAttribute('data-message-id')));
 const set=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set;
 set.call(e,message);e.dispatchEvent(new Event('input',{bubbles:true}));
 let button;const deadline=Date.now()+2000;
 while(Date.now()<deadline){button=document.querySelector('button[aria-label="Send"]');if(visible(button)&&!button.disabled)break;await sleep(100);}
 if(!visible(button)||button.disabled){if(e.value===message){set.call(e,'');e.dispatchEvent(new Event('input',{bubbles:true}));}throw new Error('Muse send control unavailable; no message sent.');}
 button.click();
 const end=Date.now()+16000;let submitted=false,reply=null,last='',stable=0;
 while(Date.now()<end){
   const fresh=[...document.querySelectorAll('[data-message-item]')].filter(n=>!before.has(n.getAttribute('data-message-id')));
   if(fresh.some(n=>n.getAttribute('data-message-role')==='user'&&n.innerText.includes(message)))submitted=true;
   const assistants=fresh.filter(n=>n.getAttribute('data-message-role')==='assistant');
   if(assistants.length&&submitted){reply=assistants.map(n=>(n.querySelector('[data-hatch-assistant-message-body]')||n).innerText.trim()).join('\n\n');if(reply===last)stable++;else stable=0;last=reply;if(reply&&stable>=3&&!readConversation().pending)return {submitted:true,status:'replied',reply,conversation:readConversation()};}
   await sleep(350);
 }
 if(!submitted)throw new Error('Muse submission outcome uncertain. Inspect the current conversation before any retry; do not resend automatically.');
 return {submitted:true,status:'pending',reply,conversation:readConversation()};
}

async function searchSaved({query}){if(!query.trim())throw Error('Search query must not be blank');const composer=await ready();if(composer.value.trim())throw Error('Existing Muse draft preserved');let input=document.querySelector('input[aria-label="Search Muse"]');if(!input){const b=document.querySelector('button[aria-label="Search"]');if(!b)throw Error('Muse search control unavailable');b.click();const end=Date.now()+5000;while(Date.now()<end&&!input){await sleep(100);input=document.querySelector('input[aria-label="Search Muse"]');}}if(!input)throw Error('Muse search panel unavailable');const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;setter.call(input,query);input.dispatchEvent(new Event('input',{bubbles:true}));let previous='',stable=Date.now();const deadline=Date.now()+10000;while(Date.now()<deadline){const dialog=input.closest('[role="dialog"]');const all=[...(dialog?.querySelectorAll('[role="option"]')||[])];const empty=dialog?.innerText.includes('No results found');const signature=all.map(e=>e.getAttribute('data-value')+'|'+e.innerText).join('~')+(empty?'empty':'');if(signature!==previous){previous=signature;stable=Date.now();}if(input.value===query&&(all.length||empty)&&!dialog.querySelector('[aria-busy="true"]')&&Date.now()-stable>900){const rows=all.filter(e=>e.getAttribute('data-value')?.startsWith('chat:message:'));if(rows.length>100)throw Error('Muse search exceeds safe result bound');return {items:rows.map(e=>{const lines=e.innerText.split(String.fromCharCode(10)).map(s=>s.trim()).filter(Boolean);return {id:e.getAttribute('data-value'),title:lines[0]||'',excerpt:lines.slice(1).join(' ')};}),nextCursor:null,scope:'native-palette-chat-messages',complete:false};}await sleep(150);}throw Error('Muse search did not settle');}

window.ox.install(({action})=>{
 action('searchConversations',{invoke:searchSaved});
 action('getSignInUrl',{async invoke(){return {url:'https://muse.ai/'};}});
 action('getSignInState',{invoke:signInState});
 action('getCurrentConversation',{async invoke(args){await ready(22000);return readConversation(args.limit||30);}});
 action('chat',{invoke:sendMessage});
 action('continueChat',{invoke:sendMessage});
});
