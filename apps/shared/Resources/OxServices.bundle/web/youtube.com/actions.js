const clean=v=>String(v??'').replace(/\s+/g,' ').trim();
const text=v=>clean(v?.simpleText??v?.runs?.map(x=>x.text).join('')??'');
async function waitFor(fn,ms=18000){const end=Date.now()+ms;while(Date.now()<end){const v=fn();if(v)return v;await new Promise(r=>setTimeout(r,180));}throw new Error('YouTube page or transcript did not become ready. It may be restricted, loading, or unavailable.');}
function collect(data){const items=[];let nextCursor=null;const seen=new Set();function walk(o){if(!o||typeof o!=='object')return;if(o.videoRenderer){const v=o.videoRenderer;if(!seen.has(v.videoId)){seen.add(v.videoId);items.push({videoId:v.videoId,title:text(v.title),url:'https://www.youtube.com/watch?v='+v.videoId,channel:text(v.ownerText||v.longBylineText),duration:text(v.lengthText),views:text(v.viewCountText),published:text(v.publishedTimeText)});}}if(o.continuationItemRenderer)nextCursor=o.continuationItemRenderer.continuationEndpoint?.continuationCommand?.token||nextCursor;for(const v of Object.values(o))if(typeof v==='object')walk(v);}walk(data);return {items,nextCursor};}
window.ox.install(({action})=>{
action('listSessions',{async invoke(){await waitFor(()=>typeof window.ytcfg?.get('LOGGED_IN')==='boolean');if(window.ytcfg.get('LOGGED_IN')===false)return [];throw new Error('YouTube is signed in; account identity discovery must be verified before private reads.');}});
action('login',{async invoke(){await waitFor(()=>window.ytInitialData?.topbar);if(window.ytcfg?.get('LOGGED_IN')===true)return null;const buttons=window.ytInitialData.topbar.desktopTopbarRenderer?.topbarButtons||[];const b=buttons.map(x=>x.buttonRenderer).find(x=>x?.navigationEndpoint?.signInEndpoint);const url=b?.navigationEndpoint?.commandMetadata?.webCommandMetadata?.url;if(!url||new URL(url).hostname!=='accounts.google.com')throw new Error('YouTube did not expose its Google sign-in route');location.assign(url);return null;}});
action('searchVideos',{async invoke(args){await waitFor(()=>window.ytInitialData&&window.ytcfg?.get('INNERTUBE_CONTEXT'));if(new URL(location.href).searchParams.get('search_query')!==args.query)throw new Error('Search page identity mismatch');let data=window.ytInitialData;if(args.cursor){const r=await fetch('/youtubei/v1/search?prettyPrint=false',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:JSON.stringify({context:window.ytcfg.get('INNERTUBE_CONTEXT'),continuation:args.cursor})});if(!r.ok)throw new Error('YouTube search HTTP '+r.status);data=await r.json();if(!data.onResponseReceivedCommands)throw new Error('Unexpected YouTube continuation response');}const result=collect(data);if(!result.items.length&&!JSON.stringify(data).includes('messageRenderer'))throw new Error('YouTube returned no recognizable video results; try another query or check restrictions.');return result;}});
action('getTranscript',{async invoke(args){
if(new URL(location.href).searchParams.get('v')!==args.videoId)throw new Error('Video page identity mismatch');
await waitFor(()=>document.querySelector('ytd-watch-flexy[video-id="'+args.videoId+'"]'));
document.querySelector('video')?.pause();
const rows=()=>[...document.querySelectorAll('ytd-transcript-segment-renderer, transcript-segment-view-model')];
if(!rows().length){
document.querySelector('#description-inline-expander #expand')?.click();
const button=await waitFor(()=>[...document.querySelectorAll('button')].find(x=>x.getClientRects().length&&(x.getAttribute('aria-label')==='Show transcript'||clean(x.textContent)==='Show transcript')));
button.click();
}
const result=await waitFor(()=>{
const r=rows();if(r.length)return {rows:r};
const p=[...document.querySelectorAll('ytd-engagement-panel-section-list-renderer')].filter(x=>x.getAttribute('visibility')==='ENGAGEMENT_PANEL_VISIBILITY_EXPANDED');
if(p.some(x=>/no transcript|transcript (is )?not available/i.test(x.textContent)))return {unavailable:true};return null;
});
const segments=(result.rows||[]).map(x=>{const timestamp=clean(x.querySelector('.segment-timestamp, .ytwTranscriptSegmentViewModelTimestamp')?.textContent);const value=clean(x.querySelector('.segment-text, span.ytAttributedStringHost')?.textContent);if(!/^\d+(?::\d{2}){1,2}$/.test(timestamp)||!value)throw new Error('Unrecognized transcript segment');return {timestamp,startSeconds:timestamp.split(':').map(Number).reduce((a,n)=>a*60+n,0),text:value};});
return {videoId:args.videoId,title:clean(document.querySelector('h1.ytd-watch-metadata')?.textContent||document.title.replace(/ - YouTube$/,'')),url:'https://www.youtube.com/watch?v='+args.videoId,status:result.unavailable?'unavailable':'available',segments,text:segments.map(s=>s.timestamp+' '+s.text).join('\n')};}});
});