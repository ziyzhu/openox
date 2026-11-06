const pause=ms=>new Promise(r=>setTimeout(r,ms));
const txt=()=>document.body.innerText;
async function snapshot(kind){
 if(kind==='completed' && location.pathname!=='/dashboard/completed'){
  const link=document.querySelector('a[href="/dashboard/completed"]');
  if(!link)throw new Error('Taskrabbit completed tasks navigation unavailable');
  link.click();
  const deadline=Date.now()+12000;
  while(Date.now()<deadline && location.pathname!=='/dashboard/completed')await pause(150);
  if(location.pathname!=='/dashboard/completed')throw new Error('Taskrabbit completed tasks page did not load');
 }
 if(kind==='active'){
  const input={0:{json:{filters:{status:'active'},locale:'en-US',page:1,perPage:5}}};
  const url=new URL('/next-api/trpc/page.tasks.list',location.origin);url.searchParams.set('batch','1');url.searchParams.set('input',JSON.stringify(input));
  const response=await fetch(url.toString(),{credentials:'include',cache:'no-store'});
  if(!response.ok)throw new Error('Taskrabbit task list failed: HTTP '+response.status);
  const data=await response.json(),page=data?.[0]?.result?.data?.json?.bff;
  if(!page||!Array.isArray(page.items)||!Number.isInteger(page.totalItems))throw new Error('Taskrabbit task list response is unrecognized');
  if(page.totalItems===0&&page.items.length===0)return {url:'https://www.taskrabbit.com/dashboard/active',text:'No current tasks. Confirmed by the Taskrabbit task list.',partial:false};
 }
 const end=Date.now()+18000;while(Date.now()<end){if(txt().includes('See task details'))break;await pause(200);}if(!txt().includes('See task details'))throw new Error('Taskrabbit task cards did not finish loading');const text=txt().split('Follow us!')[0].slice(0,24000);return {url:location.href,text,partial:true};
}
window.ox.install(({action})=>{
action('listSessions',{async invoke(){const r=await fetch('/account',{credentials:'include',cache:'no-store'});const path=new URL(r.url).pathname;if(path==='/login')return [];if(!r.ok||path!=='/account')throw new Error('Taskrabbit account response unavailable');const text=await r.text();const match=text.match(/app\.currentUser\.sets\((\{[^\n]*?\})\);/);if(!match)throw new Error('Taskrabbit account identity unavailable');const u=JSON.parse(match[1]);if(!Number.isSafeInteger(u.id)||u.id<=0||typeof u.email!=='string'||!u.email.includes('@'))throw new Error('Taskrabbit account identity invalid');return [{id:String(u.id),label:u.email,url:'https://www.taskrabbit.com/dashboard/active'}];}});
action('login',{async invoke(){location.assign('https://www.taskrabbit.com/login?source=header');return null;}});
action('getCurrentTasks',{async invoke(){return snapshot('active');}});
action('getCompletedTasks',{async invoke(){return snapshot('completed');}});
});