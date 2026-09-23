window.ox.install(1, ({ action, retryFetch, lib }) => {
  const { cleanText } = lib;
  const enc = encodeURIComponent;
  const int = (v, d) => Number.isInteger(v) ? v : d;
  const cursor = v => typeof v === "string" && v ? v : null;
  const name = v => cleanText(String(v || "")).replace(/^r\//i, "").replace(/^u\//i, "");
  const postId = v => { const x=String(v||""); const m=x.match(/\/comments\/([a-z0-9]+)/i); return (m?m[1]:x.replace(/^t3_/,"")).trim(); };
  async function json(path) {
    const res = await retryFetch(path, { credentials: "include", headers: { accept: "application/json" } });
    if (res.status === 404) throw new Error("Reddit resource not found.");
    if (!res.ok) throw new Error("Reddit request failed with HTTP " + res.status + ".");
    const type=res.headers.get("content-type")||""; if(!type.includes("json")) throw new Error("Reddit returned an unexpected response.");
    return await res.json();
  }
  const str = v => cleanText(v == null ? "" : String(v));
  const nullable = v => v == null || v === "[deleted]" ? null : str(v);
  function mapPost(d){ return {id:str(d.id),fullname:str(d.name),title:str(d.title),author:nullable(d.author),subreddit:str(d.subreddit),selfText:str(d.selftext),url:str(d.url),permalink:str(d.permalink),score:int(d.score,0),numComments:int(d.num_comments,0),createdUtc:Number(d.created_utc)||0,isSelf:!!d.is_self,over18:!!d.over_18}; }
  function mapComment(d, depth=0){ const children=Array.isArray(d?.replies?.data?.children)?d.replies.data.children:[]; return {id:str(d.id),fullname:str(d.name),author:nullable(d.author),body:str(d.body),score:int(d.score,0),createdUtc:Number(d.created_utc)||0,permalink:str(d.permalink),depth:int(d.depth,depth),replies:children.filter(x=>x.kind==="t1").map(x=>mapComment(x.data,depth+1))}; }
  function mapCommunity(d){ return {name:str(d.display_name),title:str(d.title),publicDescription:str(d.public_description),subscribers:Number.isInteger(d.subscribers)?d.subscribers:null,createdUtc:Number(d.created_utc)||0,over18:!!d.over18,url:str(d.url)}; }
  function qs(params){ const q=new URLSearchParams(); for(const [k,v] of Object.entries(params)) if(v!==undefined&&v!==null&&v!=="") q.set(k,String(v)); return q.toString(); }
  action("searchPosts",{async invoke(a){const path=a.subreddit?"/r/"+enc(name(a.subreddit))+"/search.json":"/search.json";const j=await json(path+"?"+qs({q:a.query,restrict_sr:a.subreddit?"on":undefined,sort:a.sort||"relevance",t:a.time||"all",limit:int(a.limit,25),after:cursor(a.cursor),raw_json:1}));return {items:j.data.children.filter(x=>x.kind==="t3").map(x=>mapPost(x.data)),nextCursor:j.data.after||null};}});
  action("listSubredditPosts",{async invoke(a){const sort=a.sort||"hot";const j=await json("/r/"+enc(name(a.subreddit))+"/"+sort+".json?"+qs({t:sort==="top"?(a.time||"all"):undefined,limit:int(a.limit,25),after:cursor(a.cursor),raw_json:1}));return {items:j.data.children.filter(x=>x.kind==="t3").map(x=>mapPost(x.data)),nextCursor:j.data.after||null};}});
  action("getPost",{async invoke(a){const j=await json("/comments/"+enc(postId(a.post))+".json?limit=1&raw_json=1");const d=j?.[0]?.data?.children?.[0]?.data;if(!d)throw new Error("Reddit post not found.");return {post:mapPost(d)};}});
  action("listPostComments",{async invoke(a){const j=await json("/comments/"+enc(postId(a.post))+".json?"+qs({limit:int(a.limit,25),depth:int(a.depth,3),raw_json:1}));const l=j?.[1]?.data;return {items:(l?.children||[]).filter(x=>x.kind==="t1").map(x=>mapComment(x.data)),nextCursor:l?.after||null};}});
  action("searchSubreddits",{async invoke(a){const j=await json("/subreddits/search.json?"+qs({q:a.query,limit:int(a.limit,25),after:cursor(a.cursor),raw_json:1}));return {items:j.data.children.filter(x=>x.kind==="t5").map(x=>mapCommunity(x.data)),nextCursor:j.data.after||null};}});
  action("getSubreddit",{async invoke(a){const j=await json("/r/"+enc(name(a.subreddit))+"/about.json?raw_json=1");return {community:mapCommunity(j.data)};}});
  action("getUserProfile",{async invoke(a){const j=await json("/user/"+enc(name(a.username))+"/about.json?raw_json=1");const d=j.data;return {profile:{name:str(d.name),id:str(d.id),createdUtc:Number(d.created_utc)||0,commentKarma:int(d.comment_karma,0),linkKarma:int(d.link_karma,0),isEmployee:!!d.is_employee,isGold:!!d.is_gold,verified:!!d.verified,iconUrl:d.icon_img?str(d.icon_img):null}};}});
  action("listUserPosts",{async invoke(a){const j=await json("/user/"+enc(name(a.username))+"/submitted.json?"+qs({limit:int(a.limit,25),after:cursor(a.cursor),raw_json:1}));return {items:j.data.children.filter(x=>x.kind==="t3").map(x=>mapPost(x.data)),nextCursor:j.data.after||null};}});
  action("listUserComments",{async invoke(a){const j=await json("/user/"+enc(name(a.username))+"/comments.json?"+qs({limit:int(a.limit,25),after:cursor(a.cursor),raw_json:1}));return {items:j.data.children.filter(x=>x.kind==="t1").map(x=>mapComment(x.data)),nextCursor:j.data.after||null};}});
});
